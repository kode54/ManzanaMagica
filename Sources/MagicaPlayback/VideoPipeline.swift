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
        public var rendererFlushes = 0  // the renderer failed and was flushed to resume
        public var progressiveSource = false  // the last picture was 240p/288p, shown line-doubled
        public init() {}
    }

    public let layer: AVSampleBufferDisplayLayer
    /// Paces the layer on the host clock (there's no audio renderer to drive it)
    private let synchronizer = AVSampleBufferRenderSynchronizer()
    /// The layer's renderer, attached to the synchronizer; used only on `queue`
    private let receiver: AVSampleBufferVideoRenderer.Receiver
    private var eventTask: Task<Void, Never>?
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
    private var lastPicture: CVPixelBuffer?

    /// Pictures carry host-clock timestamps; the layer shows each one this
    /// long after its field was captured. YADIF needs the next frame before
    /// it can output a frame's first field, so it sets the floor.
    public static let latency = 0.085

    /// On the main actor, like the layer it configures
    @MainActor
    public init(layer: AVSampleBufferDisplayLayer, mode: DeinterlaceMode = .yadif) {
        self.layer = layer
        _mode = mode
        deinterlacer = try? Deinterlacer()
        layer.videoGravity = .resizeAspect
        receiver = synchronizer.sampleBufferReceiver(adding: layer.sampleBufferRenderer)
        // live: run now, whatever is queued, with the timebase `latency` behind the host clock
        synchronizer.delaysRateChangeUntilHasSufficientMediaData = false
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        synchronizer.setRate(1, time: now - CMTime(seconds: Self.latency, preferredTimescale: 1_000_000), atHostTime: now)

        let events = receiver.renderingEventsAfterFinishedEnqueuing
        eventTask = Task { [weak self] in
            for await event in events {
                switch event {
                case .requiresFlushToResumeDecoding, .failed:
                    guard let pipeline = self else { return }
                    pipeline.queue.async { pipeline.flushRenderer() }
                case .didFailToDecode:
                    break
                @unknown default:
                    break
                }
            }
        }
    }

    deinit {
        eventTask?.cancel()
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

    /// The newest picture sent to the display (deinterlaced or line-doubled), for screenshots
    public func currentPicture() -> CVPixelBuffer? { queue.sync { lastPicture } }

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
            // keeps showing the last picture until new ones arrive
            self.receiver.flush()
        }
    }

    // MARK: - queue

    private func process(_ frame: VideoFrame) {
        stats.frames += 1
        if !frame.complete { stats.incomplete += 1 }
        let mode = self.mode
        stats.mode = deinterlacer == nil ? .off : mode
        stats.progressiveSource = !frame.interlaced

        // 240p/288p: already a whole picture
        guard frame.interlaced, let deinterlacer, mode != .off else {
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
        lastPicture = image
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
        // handed over for good: nothing here touches the sample after this
        nonisolated(unsafe) let owned = sample
        switch receiver.enqueueImmediately(CMReadySampleBuffer(unsafeBuffer: owned)) {
        case .enqueued, .enqueuedWithDecodeFailures, .cancelledDueToFlush:
            break
        case .cancelledDueToFlushRequiredToResume, .cancelledDueToError:
            flushRenderer()
        @unknown default:
            break
        }
    }

    /// Clears a failed renderer so the next picture can go through
    private func flushRenderer() {
        stats.rendererFlushes += 1
        receiver.flush()
    }
}
