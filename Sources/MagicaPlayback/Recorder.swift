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

/// Writes deinterlaced video and the audio input to a QuickTime movie. Appends come from
/// the video and audio queues; the writer itself lives on a private queue.
public final class Recorder: @unchecked Sendable {
    public let url: URL
    public let options: RecordingOptions
    private let queue = DispatchQueue(label: "magica.recorder")
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private let audioInput: AVAssetWriterInput?
    private let scaler: VTPixelTransferSession?
    private let size: (width: Int, height: Int)
    private let hd: Bool

    // queue-confined
    private var started = false
    private var startTime: CMTime = .invalid
    private var lastVideoPTS: CMTime = .invalid
    private var finished = false
    public private(set) var droppedVideo = 0
    private var _duration: CMTime = .zero
    private let lock = NSLock()

    private var _failure: Error?
    // diagnostics (queue)
    private var audioNotReady = 0, audioAppended = 0, audioEarly = 0
    private var firstAudioPTS: CMTime = .invalid, lastAudioEnd: CMTime = .invalid

    /// Counters for debugging stalls
    public var diagnostics: String {
        queue.sync {
            let a = firstAudioPTS.isValid ? (firstAudioPTS - startTime).seconds : .nan
            let e = lastAudioEnd.isValid ? (lastAudioEnd - startTime).seconds : .nan
            let v = lastVideoPTS.isValid ? (lastVideoPTS - startTime).seconds : .nan
            return String(format: "video to %.2fs, not ready %d | audio %.3f…%.2fs, %d appended, %d early, not ready %d | %@",
                          v, droppedVideo, a, e, audioAppended, audioEarly, audioNotReady, "\(writer.status.rawValue)")
        }
    }

    /// Seconds recorded so far
    public var duration: Double { lock.withLock { _duration.seconds } }

    /// Set once the writer has failed; nothing more gets recorded
    public var failure: Error? { lock.withLock { _failure } }

    private func checkFailed() -> Bool {
        guard writer.status == .failed else { return false }
        lock.withLock {
            if _failure == nil { _failure = writer.error ?? CocoaError(.fileWriteUnknown) }
        }
        return true
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
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        videoInput.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: videoInput, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferWidthKey as String: size.width,
            kCVPixelBufferHeightKey as String: size.height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
        ])
        guard writer.canAdd(videoInput) else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
        writer.add(videoInput)

        if audio {
            let a = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48000,
                AVNumberOfChannelsKey: 2,
                AVEncoderBitRateKey: options.audioKbps * 1000,
            ])
            a.expectsMediaDataInRealTime = true
            if writer.canAdd(a) {
                writer.add(a)
                audioInput = a
            } else {
                audioInput = nil
            }
        } else {
            audioInput = nil
        }

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

        guard writer.startWriting() else { throw writer.error ?? CocoaError(.fileWriteUnknown) }
    }

    /// Progressive pictures, host-time stamped, from the video pipeline's queue
    public func appendVideo(_ image: CVPixelBuffer, pts: CMTime, duration: CMTime) {
        guard let out = convert(image) else { return }
        queue.async { [self] in
            guard !finished, !checkFailed(), writer.status == .writing else { return }
            if !started {
                writer.startSession(atSourceTime: pts)
                startTime = pts
                started = true
            }
            if lastVideoPTS.isValid, pts <= lastVideoPTS { return }
            guard videoInput.isReadyForMoreMediaData else {
                droppedVideo += 1
                return
            }
            if adaptor.append(out, withPresentationTime: pts) {
                lastVideoPTS = pts
                lock.withLock { _duration = pts + duration - startTime }
            } else {
                _ = checkFailed()
            }
        }
    }

    /// Audio buffers from the capture session, host-time stamped
    public func appendAudio(_ sample: CMSampleBuffer) {
        guard let audioInput else { return }
        nonisolated(unsafe) let sample = sample
        queue.async { [self] in
            guard started, !finished, writer.status == .writing else { return }
            let pts = CMSampleBufferGetPresentationTimeStamp(sample)
            let end = pts + CMSampleBufferGetDuration(sample)
            // nothing from before the first picture
            guard end > startTime else {
                audioEarly += 1
                return
            }
            guard audioInput.isReadyForMoreMediaData else {
                audioNotReady += 1
                return
            }
            if audioInput.append(sample) {
                if !firstAudioPTS.isValid { firstAudioPTS = pts }
                lastAudioEnd = end
                audioAppended += 1
            } else {
                _ = checkFailed()
            }
        }
    }

    /// Closes the file; returns it, or the writer's error
    public func finish() async throws -> URL {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<URL, Error>) in
            queue.async { [self] in
                finished = true
                guard started, writer.status == .writing else {
                    writer.cancelWriting()
                    cont.resume(throwing: writer.error ?? CocoaError(.fileWriteUnknown))
                    return
                }
                videoInput.markAsFinished()
                audioInput?.markAsFinished()
                writer.endSession(atSourceTime: lastVideoPTS.isValid ? lastVideoPTS : startTime)
                let writer = self.writer, url = self.url
                writer.finishWriting {
                    if writer.status == .completed {
                        cont.resume(returning: url)
                    } else {
                        cont.resume(throwing: writer.error ?? CocoaError(.fileWriteUnknown))
                    }
                }
            }
        }
    }

    /// Scales and converts to the encoder's 4:2:0 on the calling queue
    private func convert(_ image: CVPixelBuffer) -> CVPixelBuffer? {
        guard let pool = adaptor.pixelBufferPool, let scaler else { return nil }
        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let out else { return nil }
        guard VTPixelTransferSessionTransferImage(scaler, from: image, to: out) == noErr else { return nil }
        return out
    }
}
