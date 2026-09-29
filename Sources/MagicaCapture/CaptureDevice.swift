// SPDX-License-Identifier: GPL-2.0-only
import CoreMedia
import CoreVideo
import Foundation
import MagicaCore

public enum CaptureError: Error, Sendable, Equatable, LocalizedError {
    case noDevice
    case busy
    case unplugged
    case unsupported
    case io
    case other(Int32)

    init(_ code: Int32) {
        switch Int(code) {
        case MAGICA_ENODEV: self = .noDevice
        case MAGICA_EBUSY: self = .busy
        case MAGICA_EGONE: self = .unplugged
        case MAGICA_EUNSUPPORTED: self = .unsupported
        case MAGICA_EIO: self = .io
        default: self = .other(code)
        }
    }

    public var errorDescription: String? {
        let code = switch self {
        case .other(let code): Int(code)
        case .noDevice: MAGICA_ENODEV
        case .busy: MAGICA_EBUSY
        case .unplugged: MAGICA_EGONE
        case .unsupported: MAGICA_EUNSUPPORTED
        case .io: MAGICA_EIO
        }
        return String(cString: magica_strerror(Int32(code)))
    }
}

public enum VideoInput: Int, Sendable, CaseIterable, Identifiable {
    case composite = 0
    case sVideo = 1
    public var id: Int { rawValue }
    public var name: String { self == .composite ? "Composite" : "S-Video" }
}

public enum VideoStandard: String, Sendable, CaseIterable, Identifiable {
    case ntsc, ntscJ, palM, pal60, ntsc443, pal, palN, secam
    public var id: String { rawValue }

    var c: magica_std {
        switch self {
        case .ntsc: MAGICA_STD_NTSC_M
        case .ntscJ: MAGICA_STD_NTSC_J
        case .palM: MAGICA_STD_PAL_M
        case .pal60: MAGICA_STD_PAL_60
        case .ntsc443: MAGICA_STD_NTSC_443
        case .pal: MAGICA_STD_PAL
        case .palN: MAGICA_STD_PAL_N
        case .secam: MAGICA_STD_SECAM
        }
    }

    public var name: String { String(cString: magica_std_name(c)) }
    public var is50Hz: Bool { magica_std_is_50hz(c) != 0 }
    public var height: Int { is50Hz ? 576 : 480 }
    /// One frame (two fields)
    public var frameDuration: CMTime { is50Hz ? CMTime(value: 1, timescale: 25) : CMTime(value: 1001, timescale: 30000) }
    /// ITU-R BT.601 sampling: 704 active of 720 samples map to 4:3
    public var pixelAspect: (h: Int, v: Int) { is50Hz ? (12, 11) : (10, 11) }
}

public struct DeviceInfo: Sendable, Equatable {
    public var board: String
    public var bridge: String
    public var decoder: String
    public var audio: String
    public var vendorID: Int
    public var productID: Int
    /// The OS drives the sound through a USB Audio Class interface
    public var usbAudioClass: Bool
}

public struct DeviceStatus: Sendable, Equatable {
    public var locked = false
    public var is50Hz = false
    public var color = false
    public var fields: UInt32 = 0
    public var shortFields: UInt32 = 0
    public var packetErrors: UInt32 = 0
    public var unplugged = false
    public init() {}
}

/// One interlaced frame: two consecutive fields woven into biplanar 4:2:2
/// ('422v'), the top field first in time
public struct VideoFrame: @unchecked Sendable {
    public let image: CVPixelBuffer
    /// Host time (CMClockGetHostTimeClock) of the first field
    public let pts: CMTime
    public let duration: CMTime
    public let complete: Bool
}

/// The em28xx capture device. Controls are serialised by the C library;
/// frames arrive on its USB thread.
public final class CaptureDevice: @unchecked Sendable {
    public let info: DeviceInfo
    private let dev: OpaquePointer
    private let lock = NSLock()
    private var weaver: FieldWeaver?
    public private(set) var standard: VideoStandard = .ntsc
    public private(set) var input: VideoInput = .composite

    public static func setVerbosity(_ level: Int) { magica_set_verbosity(Int32(level)) }

    public init() throws {
        var d: OpaquePointer?
        var i = magica_info()
        let ret = magica_open(&d, &i)
        guard ret == 0, let d else { throw CaptureError(ret) }
        dev = d
        func str<T>(_ t: T) -> String {
            withUnsafeBytes(of: t) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        }
        info = DeviceInfo(board: str(i.board), bridge: str(i.chip), decoder: str(i.decoder), audio: str(i.audio),
                          vendorID: Int(i.vid), productID: Int(i.pid), usbAudioClass: i.usb_audio_class != 0)
    }

    deinit {
        magica_close(dev)
    }

    /// The decoder's field-rate detector (needs a signal to mean anything)
    public func detects50Hz() -> Bool? {
        let r = magica_detect_50hz(dev)
        return r < 0 ? nil : r == 1
    }

    /// Changing the standard restarts streaming if it's running
    public func setStandard(_ std: VideoStandard) throws {
        try lock.withLock {
            let running = weaver != nil
            let sink = weaver?.sink
            if running { stopLocked() }
            let ret = magica_set_std(dev, std.c)
            guard ret == 0 else { throw CaptureError(ret) }
            standard = std
            if running, let sink { try startLocked(sink) }
        }
    }

    public func setInput(_ input: VideoInput) throws {
        let ret = magica_set_input(dev, magica_input(rawValue: UInt32(input.rawValue)))
        guard ret == 0 else { throw CaptureError(ret) }
        self.input = input
    }

    /// brightness 0–255 (128), contrast 0–127 (64), saturation 0–127 (64), hue -128–127 (0)
    public func setPicture(brightness: Int, contrast: Int, saturation: Int, hue: Int) throws {
        let ret = magica_set_picture(dev, Int32(brightness), Int32(contrast), Int32(saturation), Int32(hue))
        guard ret == 0 else { throw CaptureError(ret) }
    }

    public func status() -> DeviceStatus {
        var s = magica_status()
        _ = magica_status_get(dev, &s)
        var out = DeviceStatus()
        out.locked = s.locked != 0
        out.is50Hz = s.is_50hz != 0
        out.color = s.color != 0
        out.fields = s.fields
        out.shortFields = s.short_fields
        out.packetErrors = s.packet_errors
        out.unplugged = s.gone != 0
        return out
    }

    public var isStreaming: Bool { lock.withLock { weaver != nil } }

    /// Frames go to `frames` on the USB thread: hand them off quickly
    public func start(frames: @escaping @Sendable (VideoFrame) -> Void) throws {
        try lock.withLock { try startLocked(frames) }
    }

    public func stop() {
        lock.withLock { stopLocked() }
    }

    private func startLocked(_ sink: @escaping @Sendable (VideoFrame) -> Void) throws {
        guard weaver == nil else { return }
        let w = FieldWeaver(width: Int(magica_width(dev)), height: Int(magica_height(dev)), standard: standard, sink: sink)
        let ctx = Unmanaged.passUnretained(w).toOpaque()
        let ret = magica_start(dev, { ctx, field in
            Unmanaged<FieldWeaver>.fromOpaque(ctx!).takeUnretainedValue().field(field!.pointee)
        }, nil, ctx)
        guard ret == 0 else { throw CaptureError(ret) }
        weaver = w
    }

    private func stopLocked() {
        guard weaver != nil else { return }
        magica_stop(dev)  // joins the USB thread: no callbacks after this
        weaver = nil
    }
}

/// Pairs each top field with the bottom field after it into one frame
final class FieldWeaver: @unchecked Sendable {
    let sink: @Sendable (VideoFrame) -> Void
    private let pool: CVPixelBufferPool
    private let standard: VideoStandard
    private var current: CVPixelBuffer?
    private var currentPTS: CMTime = .invalid
    private var currentComplete = true

    init(width: Int, height: Int, standard: VideoStandard, sink: @escaping @Sendable (VideoFrame) -> Void) {
        self.sink = sink
        self.standard = standard
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_422YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var p: CVPixelBufferPool?
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 8] as CFDictionary,
                                attrs as CFDictionary, &p)
        pool = p!
    }

    func field(_ f: magica_field) {
        if f.top != 0 {
            var pb: CVPixelBuffer?
            guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) == kCVReturnSuccess, let pb else { return }
            Self.tag(pb, standard: standard)
            current = pb
            currentPTS = CMTime(value: CMTimeValue(f.time_ns), timescale: 1_000_000_000)
            currentComplete = f.complete != 0
            weave(f, into: pb, parity: 0)
        } else if let pb = current {
            weave(f, into: pb, parity: 1)
            current = nil
            sink(VideoFrame(image: pb, pts: currentPTS, duration: standard.frameDuration,
                            complete: currentComplete && f.complete != 0))
        }
        // a bottom field with no top before it (a dropped field) is skipped
    }

    private func weave(_ f: magica_field, into pb: CVPixelBuffer, parity: Int32) {
        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }
        var field = f
        magica_weave_field(&field, parity,
                           CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self),
                           Int32(CVPixelBufferGetBytesPerRowOfPlane(pb, 0)),
                           CVPixelBufferGetBaseAddressOfPlane(pb, 1)!.assumingMemoryBound(to: UInt8.self),
                           Int32(CVPixelBufferGetBytesPerRowOfPlane(pb, 1)))
    }

    /// Interlacing, BT.601 colour, and the 704-sample 4:3 picture area
    static func tag(_ pb: CVPixelBuffer, standard: VideoStandard) {
        let h = CVPixelBufferGetHeight(pb)
        CVBufferSetAttachment(pb, kCVImageBufferFieldCountKey, 2 as CFNumber, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferFieldDetailKey, kCVImageBufferFieldDetailTemporalTopFirst, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferYCbCrMatrixKey, kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferColorPrimariesKey,
                              standard.is50Hz ? kCVImageBufferColorPrimaries_EBU_3213 : kCVImageBufferColorPrimaries_SMPTE_C,
                              .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        let par = standard.pixelAspect
        CVBufferSetAttachment(pb, kCVImageBufferPixelAspectRatioKey, [
            kCVImageBufferPixelAspectRatioHorizontalSpacingKey: par.h,
            kCVImageBufferPixelAspectRatioVerticalSpacingKey: par.v,
        ] as CFDictionary, .shouldPropagate)
        CVBufferSetAttachment(pb, kCVImageBufferCleanApertureKey, [
            kCVImageBufferCleanApertureWidthKey: 704,
            kCVImageBufferCleanApertureHeightKey: h,
            kCVImageBufferCleanApertureHorizontalOffsetKey: 0,
            kCVImageBufferCleanApertureVerticalOffsetKey: 0,
        ] as CFDictionary, .shouldPropagate)
    }
}
