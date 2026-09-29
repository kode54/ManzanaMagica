// SPDX-License-Identifier: GPL-2.0-only
@preconcurrency import AVFoundation
import CoreMedia
import Foundation
import MagicaCapture
import VideoToolbox

public struct RecordingOptions: Sendable, Codable, Equatable {
    public enum Codec: String, Sendable, Codable, CaseIterable, Identifiable {
        case h264, hevc
        public var id: String { rawValue }
        public var name: String { self == .h264 ? "H.264" : "HEVC" }
    }

    public enum Size: String, Sendable, Codable, CaseIterable, Identifiable {
        /// 720×480 / 720×576 as captured, with its pixel aspect ratio flagged
        case native
        /// Square pixels, 4:3 at 720 lines
        case hd720
        /// 1280×720 with the 4:3 picture pillarboxed, for players that want 16:9
        case hd720Pillarbox
        public var id: String { rawValue }
        public var name: String {
            switch self {
            case .native: "Native (SD)"
            case .hd720: "720p, 4:3 (960×720)"
            case .hd720Pillarbox: "720p, 16:9 pillarbox (1280×720)"
            }
        }
    }

    public var codec: Codec = .h264
    public var size: Size = .hd720
    /// Average video bit rate, megabits per second
    public var videoMbps: Double = 8
    public var audioKbps: Int = 256

    public init() {}

    func dimensions(for standard: VideoStandard) -> (width: Int, height: Int) {
        switch size {
        case .native: (720, standard.height)
        case .hd720: (960, 720)
        case .hd720Pillarbox: (1280, 720)
        }
    }
}

/// Writes deinterlaced video and the audio input to a QuickTime movie.
///
/// Appends come from the video pipeline's and the audio capture's queues.
/// Each track then goes through a bounded buffer to its own task, which
/// hands buffers to the writer with the receivers' async `append`, waiting
/// whenever the encoder is busy. If it falls more than a couple of seconds
/// behind, new buffers are dropped (and counted).
public final class Recorder: @unchecked Sendable {
    public let url: URL
    public let options: RecordingOptions
    private let writer: AVAssetWriter
    /// Orders session start against the first appends
    private let queue = DispatchQueue(label: "magica.recorder")
    /// The encoder's input pictures, filled on the video pipeline's queue
    private let pool: CVMutablePixelBuffer.Pool
    private let scaler: VTPixelTransferSession?
    private let size: (width: Int, height: Int)
    private let hd: Bool
    private let hasAudio: Bool

    private struct Picture: Sendable {
        var image: CVReadOnlyPixelBuffer
        var pts: CMTime
        var duration: CMTime
    }

    private let videoFeed: AsyncStream<Picture>.Continuation
    private let audioFeed: AsyncStream<CMReadySampleBuffer<CMSampleBuffer.DynamicContent>>.Continuation
    private var tasks: [Task<Void, Never>] = []

    // queue-confined
    private var started = false
    private var finished = false
    private var startTime: CMTime = .invalid
    private var lastQueuedPTS: CMTime = .invalid

    // lock
    private let lock = NSLock()
    private var _failure: Error?
    private var _duration: CMTime = .zero
    private var _startTime: CMTime = .invalid   // the session start, set before any append
    private var lastVideoPTS: CMTime = .invalid
    private var videoDropped = 0, audioDropped = 0, audioWritten = 0
    private var firstAudioPTS: CMTime = .invalid, lastAudioEnd: CMTime = .invalid

    /// Seconds recorded so far
    public var duration: Double { lock.withLock { _duration.seconds } }

    /// Set once the writer has failed; nothing more gets recorded
    public var failure: Error? { lock.withLock { _failure } }

    /// Pictures skipped because the encoder fell too far behind
    public var droppedVideo: Int { lock.withLock { videoDropped } }

    /// Counters for debugging stalls
    public var diagnostics: String {
        lock.withLock {
            let start = _startTime
            let a = firstAudioPTS.isValid ? (firstAudioPTS - start).seconds : .nan
            let e = lastAudioEnd.isValid ? (lastAudioEnd - start).seconds : .nan
            let v = lastVideoPTS.isValid ? (lastVideoPTS - start).seconds : .nan
            return String(format: "video to %.2fs, %d dropped | audio %.3f…%.2fs, %d written, %d dropped | status %d",
                          v, videoDropped, a, e, audioWritten, audioDropped, writer.status.rawValue)
        }
    }

    private func fail(_ error: Error?) {
        lock.withLock {
            if _failure == nil { _failure = error ?? writer.error ?? CocoaError(.fileWriteUnknown) }
        }
    }

    /// The whole chain of underlying errors, for messages and logs
    public static func describe(_ error: Error) -> String {
        var parts: [String] = []
        var e: NSError? = error as NSError
        while let err = e {
            parts.append("\(err.localizedDescription) (\(err.domain) \(err.code))")
            e = err.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        return parts.joined(separator: " ← ")
    }

    public init(url: URL, options: RecordingOptions, standard: VideoStandard, audio: Bool) throws {
        self.url = url
        self.options = options
        size = options.dimensions(for: standard)
        hd = options.size != .native
        // A QuickTime movie, fragmented while it's written, so a crash or an
        // unplug leaves a playable file up to the last fragment. (Fragmented
        // MP4 from AVAssetWriter fails to finish, -16341, once the session
        // starts partway into a capture.) YouTube takes .mov as it is.
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        writer.movieFragmentInterval = CMTime(value: 10, timescale: 1)

        var compression: [String: Any] = [
            AVVideoAverageBitRateKey: Int(options.videoMbps * 1_000_000),
            AVVideoExpectedSourceFrameRateKey: standard.is50Hz ? 50 : 60,
            AVVideoMaxKeyFrameIntervalDurationKey: 2,
            AVVideoAllowFrameReorderingKey: true,
        ]
        compression[AVVideoProfileLevelKey] = options.codec == .h264
            ? AVVideoProfileLevelH264HighAutoLevel
            : kVTProfileLevel_HEVC_Main_AutoLevel as String
        var settings: [String: Any] = [
            AVVideoCodecKey: options.codec == .h264 ? AVVideoCodecType.h264 : AVVideoCodecType.hevc,
            AVVideoWidthKey: size.width,
            AVVideoHeightKey: size.height,
            AVVideoCompressionPropertiesKey: compression,
            AVVideoColorPropertiesKey: hd ? [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ] : [
                AVVideoColorPrimariesKey: standard.is50Hz ? AVVideoColorPrimaries_EBU_3213 : AVVideoColorPrimaries_SMPTE_C,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_601_4,
            ],
        ]
        if !hd {
            let par = standard.pixelAspect
            settings[AVVideoPixelAspectRatioKey] = [
                AVVideoPixelAspectRatioHorizontalSpacingKey: par.h,
                AVVideoPixelAspectRatioVerticalSpacingKey: par.v,
            ]
            settings[AVVideoCleanApertureKey] = [
                AVVideoCleanApertureWidthKey: 704,
                AVVideoCleanApertureHeightKey: standard.height,
                AVVideoCleanApertureHorizontalOffsetKey: 0,
                AVVideoCleanApertureVerticalOffsetKey: 0,
            ]
        }
        let videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        guard writer.canAdd(videoInput) else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        var attributes = CVPixelBufferCreationAttributes(
            pixelFormatType: CVPixelFormatType(rawValue: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange),
            size: CVImageSize(width: size.width, height: size.height))
        attributes.backing = .ioSurface
        let videoReceiver = writer.inputPixelBufferReceiver(for: videoInput, pixelBufferAttributes: attributes)
        pool = try CVMutablePixelBuffer.Pool(pixelBufferAttributes: attributes, configuration: .init(minimumBufferCount: 8))

        var audioReceiver: AVAssetWriterInput.SampleBufferReceiver?
        if audio {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: options.audioKbps * 1000,
            ])
            if writer.canAdd(a) { audioReceiver = writer.inputReceiver(for: a) }
        }
        hasAudio = audioReceiver != nil

        var s: VTPixelTransferSession?
        VTPixelTransferSessionCreate(allocator: nil, pixelTransferSessionOut: &s)
        scaler = s
        if let s {
            // Letterbox scales the source's clean aperture (the 704-sample 4:3
            // area) by its pixel aspect ratio into square pixels: it fills
            // 960×720, and sits pillarboxed in 1280×720
            VTSessionSetProperty(s, key: kVTPixelTransferPropertyKey_ScalingMode,
                                 value: hd ? kVTScalingMode_Letterbox : kVTScalingMode_Normal)
            if hd {
                VTSessionSetProperty(s, key: kVTPixelTransferPropertyKey_DestinationPixelAspectRatio, value: [
                    kCVImageBufferPixelAspectRatioHorizontalSpacingKey: 1,
                    kCVImageBufferPixelAspectRatioVerticalSpacingKey: 1,
                ] as CFDictionary)
                VTSessionSetProperty(s, key: kVTPixelTransferPropertyKey_DestinationColorPrimaries,
                                     value: kCVImageBufferColorPrimaries_ITU_R_709_2)
                VTSessionSetProperty(s, key: kVTPixelTransferPropertyKey_DestinationTransferFunction,
                                     value: kCVImageBufferTransferFunction_ITU_R_709_2)
                VTSessionSetProperty(s, key: kVTPixelTransferPropertyKey_DestinationYCbCrMatrix,
                                     value: kCVImageBufferYCbCrMatrix_ITU_R_709_2)
            }
        }

        // about two seconds of slack for each track before anything is dropped
        let (videoStream, videoFeed) = AsyncStream.makeStream(of: Picture.self, bufferingPolicy: .bufferingOldest(120))
        let (audioStream, audioFeed) = AsyncStream.makeStream(
            of: CMReadySampleBuffer<CMSampleBuffer.DynamicContent>.self, bufferingPolicy: .bufferingOldest(200))
        self.videoFeed = videoFeed
        self.audioFeed = audioFeed

        try writer.start()

        tasks.append(Task { [self] in
            for await p in videoStream {
                do {
                    try await videoReceiver.append(p.image, with: p.pts)
                } catch {
                    fail(error)
                    break
                }
                lock.withLock {
                    lastVideoPTS = p.pts
                    _duration = p.pts + p.duration - _startTime
                }
            }
            videoReceiver.finish()
        })
        if let audioReceiver {
            tasks.append(Task { [self] in
                for await sample in audioStream {
                    let pts = sample.presentationTimeStamp, end = pts + sample.duration
                    do {
                        try await audioReceiver.append(sample)
                    } catch {
                        fail(error)
                        break
                    }
                    lock.withLock {
                        if !firstAudioPTS.isValid { firstAudioPTS = pts }
                        lastAudioEnd = end
                        audioWritten += 1
                    }
                }
                audioReceiver.finish()
            })
        } else {
            audioFeed.finish()
        }
    }

    /// Progressive pictures, host-time stamped, from the video pipeline's queue
    public func appendVideo(_ image: CVPixelBuffer, pts: CMTime, duration: CMTime) {
        guard let out = convert(image) else { return }
        queue.async { [self] in
            guard !finished, failure == nil else { return }
            if !started {
                writer.startSession(atSourceTime: pts)
                startTime = pts
                lock.withLock { _startTime = pts }
                started = true
            }
            if lastQueuedPTS.isValid, pts <= lastQueuedPTS { return }
            lastQueuedPTS = pts
            if case .dropped = videoFeed.yield(Picture(image: out, pts: pts, duration: duration)) {
                lock.withLock { videoDropped += 1 }
            }
        }
    }

    /// Audio buffers from the capture session, host-time stamped
    public func appendAudio(_ sample: CMSampleBuffer) {
        guard hasAudio else { return }
        nonisolated(unsafe) let owned = sample
        queue.async { [self] in
            guard started, !finished, failure == nil else { return }
            // nothing from before the first picture
            let end = CMSampleBufferGetPresentationTimeStamp(owned) + CMSampleBufferGetDuration(owned)
            guard end > startTime else { return }
            if case .dropped = audioFeed.yield(CMReadySampleBuffer(unsafeBuffer: owned)) {
                lock.withLock { audioDropped += 1 }
            }
        }
    }

    /// Closes the file once everything queued is written; returns it, or the writer's error
    public func finish() async throws -> URL {
        let started = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            queue.async { [self] in
                finished = true
                videoFeed.finish()
                audioFeed.finish()
                cont.resume(returning: self.started)
            }
        }
        for task in tasks { await task.value }
        guard started, failure == nil, writer.status == .writing else {
            let error = failure ?? writer.error ?? CocoaError(.fileWriteUnknown)
            writer.cancelWriting()
            throw error
        }
        let end = lock.withLock { lastVideoPTS.isValid ? lastVideoPTS : _startTime }
        writer.endSession(atSourceTime: end)
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        return url
    }

    /// Scales and converts to the encoder's 4:2:0 on the calling queue
    private func convert(_ image: CVPixelBuffer) -> CVReadOnlyPixelBuffer? {
        guard let scaler, let out = try? pool.makeMutablePixelBuffer() else { return nil }
        let status = out.withUnsafeBuffer { VTPixelTransferSessionTransferImage(scaler, from: image, to: $0) }
        guard status == noErr else { return nil }
        return CVReadOnlyPixelBuffer(out)
    }
}
