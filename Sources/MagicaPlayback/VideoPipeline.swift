// SPDX-License-Identifier: GPL-2.0-only
@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import MagicaCapture

/// Takes woven frames from the capture device, deinterlaces them on the GPU
/// to field rate, and hands the progressive pictures to the display layer
/// and, while one is set, the recorder.
public final class VideoPipeline: @unchecked Sendable {
    public struct Stats: Sendable, Equatable {
        public var frames = 0           // woven frames in
        public var output = 0           // pictures out
        public var dropped = 0          // frames skipped because we fell behind
        public var incomplete = 0       // frames with a field cut short
        public var gpuTime: Double = 0  // last field, seconds
        public var mode: DeinterlaceMode = .yadif
        public init() {}
    }

    public let layer: AVSampleBufferDisplayLayer
    private let queue = DispatchQueue(label: "magica.video", qos: .userInteractive)
    private let deinterlacer: Deinterlacer?
    private let lock = NSLock()
    private var _mode: DeinterlaceMode
    private var _recorder: Recorder?
    private var inFlight = 0             // frames queued but not yet processed (lock)

    // queue-confined
    private var history: [VideoFrame] = []
    private var stats = Stats()
    private var format: CMVideoFormatDescription?

    /// Pictures carry host-clock timestamps; the layer shows each one this
    /// long after its field was captured. YADIF needs the next frame before
    /// it can output a frame's first field, so it sets the floor.
    public static let latency = 0.085

    public init(layer: AVSampleBufferDisplayLayer, mode: DeinterlaceMode = .yadif) {
        self.layer = layer
        _mode = mode
        deinterlacer = try? Deinterlacer()
        layer.videoGravity = .resizeAspect
        var tb: CMTimebase?
        CMTimebaseCreateWithSourceClock(allocator: nil, sourceClock: CMClockGetHostTimeClock(), timebaseOut: &tb)
        if let tb {
            CMTimebaseSetTime(tb, time: CMClockGetTime(CMClockGetHostTimeClock()) - CMTime(seconds: Self.latency,
                                                                                         preferredTimescale: 1_000_000))
            CMTimebaseSetRate(tb, rate: 1)
            layer.controlTimebase = tb
        }
    }

    public var mode: DeinterlaceMode {
        get { lock.withLock { _mode } }
        set { lock.withLock { _mode = newValue } }
    }

    public var recorder: Recorder? {
        get { lock.withLock { _recorder } }
        set { lock.withLock { _recorder = newValue } }
    }

    public func currentStats() -> Stats { queue.sync { stats } }

    /// From the capture device's USB thread
    public func push(_ frame: VideoFrame) {
        let busy = lock.withLock {
            // the GPU normally keeps up; if it doesn't, don't let latency pile up
            if inFlight >= 3 { return true }
            inFlight += 1
            return false
        }
        if busy {
            queue.async { self.stats.dropped += 1 }
            return
        }
        queue.async {
            self.lock.withLock { self.inFlight -= 1 }
            self.process(frame)
        }
    }

    /// Drops held frames (after a restart or standard change)
    public func reset() {
        queue.async {
            self.history.removeAll()
            self.layer.sampleBufferRenderer.flush(removingDisplayedImage: false, completionHandler: nil)
        }
    }

    // MARK: - queue

    private func process(_ frame: VideoFrame) {
        stats.frames += 1
        if !frame.complete { stats.incomplete += 1 }
        let mode = self.mode
        stats.mode = deinterlacer == nil ? .off : mode

        guard let deinterlacer, mode != .off else {
            history.removeAll()
            output(frame.image, pts: frame.pts, duration: frame.duration)
            return
        }

        if mode == .bob {
            history.removeAll()
            emitFields(prev: frame.image, cur: frame, next: frame.image, with: deinterlacer, mode: mode)
            return
        }

        // YADIF: a frame's fields go out once the next frame arrives
        history.append(frame)
        if history.count > 3 { history.removeFirst(history.count - 3) }
        guard history.count >= 2 else { return }
        let cur = history[history.count - 2], next = history[history.count - 1]
        // a gap (lost frames) makes the neighbours meaningless: treat the edges as still
        let gap = (next.pts - cur.pts).seconds > cur.duration.seconds * 2.5
        let prev = history.count == 3 ? history[0] : cur
        let prevGap = (cur.pts - prev.pts).seconds > cur.duration.seconds * 2.5
        emitFields(prev: prevGap ? cur.image : prev.image, cur: cur, next: gap ? cur.image : next.image,
                   with: deinterlacer, mode: mode)
    }

    private func emitFields(prev: CVPixelBuffer, cur: VideoFrame, next: CVPixelBuffer, with d: Deinterlacer,
                            mode: DeinterlaceMode) {
        let half = CMTimeMultiplyByRatio(cur.duration, multiplier: 1, divisor: 2)
        for first in [true, false] {
            guard let out = try? d.field(prev: prev, cur: cur.image, next: next, first: first,
                                         topFieldFirst: true, mode: mode) else { continue }
            stats.gpuTime = d.lastGPUTime
            output(out, pts: first ? cur.pts : cur.pts + half, duration: half)
        }
    }

    private func output(_ image: CVPixelBuffer, pts: CMTime, duration: CMTime) {
        stats.output += 1
        recorder?.appendVideo(image, pts: pts, duration: duration)

        if format == nil || !CMVideoFormatDescriptionMatchesImageBuffer(format!, imageBuffer: image) {
            var f: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image, formatDescriptionOut: &f)
            format = f
        }
        guard let format else { return }
        var timing = CMSampleTimingInfo(duration: duration, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image, formatDescription: format,
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        guard let sample else { return }
        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sample)
    }
}
