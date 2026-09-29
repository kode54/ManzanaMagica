// SPDX-License-Identifier: GPL-2.0-only
import CoreVideo
import Foundation
import Metal

public enum DeinterlaceMode: String, Sendable, CaseIterable, Identifiable {
    /// Spatial + temporal (YADIF), field rate, one frame of latency
    case yadif
    /// Line interpolation, field rate, no latency
    case bob
    /// Show the woven frames as captured
    case off

    public var id: String { rawValue }

    var kernel: UInt32? {
        switch self {
        case .yadif: 0
        case .bob: 1
        case .off: nil
        }
    }
}

public enum DeinterlaceError: Error, Sendable {
    case noDevice
    case metal(String)
    case pixelBuffer(CVReturn)
}

/// Field-rate deinterlacing of woven biplanar YCbCr frames (4:2:0 or 4:2:2)
/// on the GPU. Each input frame yields two output frames, one per field, in
/// temporal order, in the input's pixel format.
public final class Deinterlacer {
    public let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLComputePipelineState
    private var textureCache: CVMetalTextureCache?
    private var pool: CVPixelBufferPool?
    private var poolSize = (0, 0)
    private var poolFormat: OSType = 0
    public private(set) var lastGPUTime: Double = 0

    struct Params {
        var keep: UInt32        // parity of the lines this output keeps (0 = top)
        var firstField: UInt32  // 1 if this output is the frame's first field in time
        var kernel: UInt32      // 0 = YADIF, 1 = bob
    }

    public init(device: MTLDevice? = MTLCreateSystemDefaultDevice()) throws {
        guard let device, let queue = device.makeCommandQueue() else { throw DeinterlaceError.noDevice }
        self.device = device
        self.queue = queue
        let library: MTLLibrary
        do {
            library = try device.makeLibrary(source: Self.shaderSource, options: nil)
        } catch {
            throw DeinterlaceError.metal("shader compile: \(error)")
        }
        guard let fn = library.makeFunction(name: "deinterlace") else { throw DeinterlaceError.metal("no kernel") }
        pipeline = try device.makeComputePipelineState(function: fn)
        CVMetalTextureCacheCreate(nil, nil, device, nil, &textureCache)
    }

    /// Output frame for one field of `cur`. prev/next are the neighbouring
    /// frames (pass cur again at the edges of the stream).
    public func field(prev: CVPixelBuffer, cur: CVPixelBuffer, next: CVPixelBuffer,
                      first: Bool, topFieldFirst: Bool, mode: DeinterlaceMode) throws -> CVPixelBuffer {
        let w = CVPixelBufferGetWidth(cur), h = CVPixelBufferGetHeight(cur)
        let out = try makeOutput(width: w, height: h, format: CVPixelBufferGetPixelFormatType(cur))
        CVBufferPropagateAttachments(cur, out)
        CVBufferSetAttachment(out, kCVImageBufferFieldCountKey, 1 as CFNumber, .shouldPropagate)
        CVBufferRemoveAttachment(out, kCVImageBufferFieldDetailKey)

        var params = Params(keep: (first == topFieldFirst) ? 0 : 1, firstField: first ? 1 : 0,
                            kernel: mode.kernel ?? 0)
        guard let cmd = queue.makeCommandBuffer(), let enc = cmd.makeComputeCommandEncoder() else {
            throw DeinterlaceError.metal("command buffer")
        }
        var keepAlive: [CVMetalTexture] = []
        enc.setComputePipelineState(pipeline)
        for plane in 0..<2 {
            let format: MTLPixelFormat = plane == 0 ? .r8Unorm : .rg8Unorm
            let textures = try [prev, cur, next, out].map { try texture($0, plane: plane, format: format, keep: &keepAlive) }
            for (i, t) in textures.enumerated() { enc.setTexture(t, index: i) }
            enc.setBytes(&params, length: MemoryLayout<Params>.stride, index: 0)
            let tw = pipeline.threadExecutionWidth
            let th = pipeline.maxTotalThreadsPerThreadgroup / tw
            enc.dispatchThreads(MTLSize(width: textures[3].width, height: textures[3].height, depth: 1),
                                threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
        }
        enc.endEncoding()
        cmd.commit()
        cmd.waitUntilCompleted()
        lastGPUTime = cmd.gpuEndTime - cmd.gpuStartTime
        withExtendedLifetime(keepAlive) {}
        if let error = cmd.error { throw DeinterlaceError.metal("\(error)") }
        return out
    }

    private func makeOutput(width: Int, height: Int, format: OSType) throws -> CVPixelBuffer {
        if pool == nil || poolSize != (width, height) || poolFormat != format {
            let attrs: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: format,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
                kCVPixelBufferMetalCompatibilityKey: true,
            ]
            var p: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 8] as CFDictionary,
                                    attrs as CFDictionary, &p)
            pool = p
            poolSize = (width, height)
            poolFormat = format
        }
        var out: CVPixelBuffer?
        let st = CVPixelBufferPoolCreatePixelBuffer(nil, pool!, &out)
        guard st == kCVReturnSuccess, let out else { throw DeinterlaceError.pixelBuffer(st) }
        return out
    }

    private func texture(_ pb: CVPixelBuffer, plane: Int, format: MTLPixelFormat,
                         keep: inout [CVMetalTexture]) throws -> MTLTexture {
        var t: CVMetalTexture?
        let st = CVMetalTextureCacheCreateTextureFromImage(
            nil, textureCache!, pb, nil, format, CVPixelBufferGetWidthOfPlane(pb, plane),
            CVPixelBufferGetHeightOfPlane(pb, plane), plane, &t)
        guard st == kCVReturnSuccess, let t, let tex = CVMetalTextureGetTexture(t) else {
            throw DeinterlaceError.pixelBuffer(st)
        }
        keep.append(t)
        return tex
    }

    /// YADIF (after FFmpeg's vf_yadif, mode 0 with spatial check) and bob, for
    /// one plane of biplanar YCbCr (r8 luma or rg8 chroma), in normalised floats.
    ///
    /// Temporal neighbours of a missing line at this output's time: for the
    /// first field they are the previous frame's and this frame's opposite
    /// field; for the second, this frame's and the next frame's.
    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct Params { uint keep; uint firstField; uint algo; };

    static inline float4 px(texture2d<float, access::read> t, int x, int y) {
        int w = int(t.get_width()), h = int(t.get_height());
        return t.read(uint2(clamp(x, 0, w - 1), clamp(y, 0, h - 1)));
    }

    // y + d, reflected back inside the plane so the row keeps y + d's parity
    static inline int row(int y, int d, int h) {
        int r = y + d;
        if (r < 0) r = y - d;
        if (r >= h) r = y - d;
        return clamp(r, 0, h - 1);
    }

    kernel void deinterlace(texture2d<float, access::read> prev [[texture(0)]],
                            texture2d<float, access::read> cur  [[texture(1)]],
                            texture2d<float, access::read> next [[texture(2)]],
                            texture2d<float, access::write> out [[texture(3)]],
                            constant Params &p [[buffer(0)]],
                            uint2 gid [[thread_position_in_grid]]) {
        int w = int(out.get_width()), h = int(out.get_height());
        int x = int(gid.x), y = int(gid.y);
        if (x >= w || y >= h) return;
        if (uint(y & 1) == p.keep) {
            out.write(cur.read(gid), gid);
            return;
        }
        int ym = row(y, -1, h), yp = row(y, 1, h);
        float4 c = px(cur, x, ym), e = px(cur, x, yp);
        if (p.algo == 1) {  // bob
            out.write((c + e) * 0.5, gid);
            return;
        }

        bool first = p.firstField != 0;
        // opposite-field samples at this position, before and after this field in time
        float4 before = first ? px(prev, x, y) : px(cur, x, y);
        float4 after  = first ? px(cur, x, y)  : px(next, x, y);
        float4 d = (before + after) * 0.5;
        float4 tdiff0 = abs(before - after);
        float4 tdiff1 = (abs(px(prev, x, ym) - c) + abs(px(prev, x, yp) - e)) * 0.5;
        float4 tdiff2 = (abs(px(next, x, ym) - c) + abs(px(next, x, yp) - e)) * 0.5;
        float4 diff = max(max(tdiff0 * 0.5, tdiff1), tdiff2);

        // edge-directed spatial prediction
        float4 spred = (c + e) * 0.5;
        float4 sscore = abs(px(cur, x - 1, ym) - px(cur, x - 1, yp)) + abs(c - e)
                      + abs(px(cur, x + 1, ym) - px(cur, x + 1, yp)) - 1.0 / 255.0;
        for (int dir = -1; dir <= 1; dir += 2) {
            for (int j = dir; abs(j) <= 2; j += dir) {
                float4 score = abs(px(cur, x - 1 + j, ym) - px(cur, x - 1 - j, yp))
                             + abs(px(cur, x + j, ym) - px(cur, x - j, yp))
                             + abs(px(cur, x + 1 + j, ym) - px(cur, x + 1 - j, yp));
                bool4 better = score < sscore;
                sscore = select(sscore, score, better);
                spred = select(spred, (px(cur, x + j, ym) + px(cur, x - j, yp)) * 0.5, better);
                if (!any(better)) break;
            }
        }

        // spatial interlacing check against lines two above and below
        int ymm = row(y, -2, h), ypp = row(y, 2, h);
        float4 b = first ? (px(prev, x, ymm) + px(cur, x, ymm)) * 0.5 : (px(cur, x, ymm) + px(next, x, ymm)) * 0.5;
        float4 f = first ? (px(prev, x, ypp) + px(cur, x, ypp)) * 0.5 : (px(cur, x, ypp) + px(next, x, ypp)) * 0.5;
        float4 mx = max(max(d - e, d - c), min(b - c, f - e));
        float4 mn = min(min(d - e, d - c), max(b - c, f - e));
        diff = max(max(diff, mn), -mx);

        out.write(clamp(spred, d - diff, d + diff), gid);
    }
    """
}
