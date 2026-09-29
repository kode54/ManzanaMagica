// SPDX-License-Identifier: GPL-2.0-only
@preconcurrency import AVFoundation
import Foundation

/// The device's sound. The iGrabber's line input is a USB Audio Class
/// interface that macOS drives itself, so this is an ordinary capture
/// session: a preview output plays it live, and the samples (host-time
/// stamped, like the video) go to `sink` for recording.
public final class AudioCapture: NSObject, AVCaptureAudioDataOutputSampleBufferDelegate, @unchecked Sendable {
    public enum Failure: Error, Sendable { case notFound, notAuthorized, cannotAdd }

    private let session = AVCaptureSession()
    private let preview = AVCaptureAudioPreviewOutput()
    private let data = AVCaptureAudioDataOutput()
    private let queue = DispatchQueue(label: "magica.audio", qos: .userInteractive)
    private let lock = NSLock()
    private var _sink: (@Sendable (CMSampleBuffer) -> Void)?

    /// Finds the capture device's audio input by its USB IDs
    public static func findDevice(vendorID: Int, productID: Int) -> AVCaptureDevice? {
        let tag = String(format: "%04X:%04X", vendorID, productID)
        let found = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone, .external], mediaType: .audio,
                                                      position: .unspecified).devices
        return found.first { $0.modelID.uppercased().hasSuffix(tag) }
    }

    public static func requestAccess() async -> Bool {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: true
        case .notDetermined: await AVCaptureDevice.requestAccess(for: .audio)
        default: false
        }
    }

    public init(device: AVCaptureDevice) throws {
        super.init()
        let input = try AVCaptureDeviceInput(device: device)
        session.beginConfiguration()
        defer { session.commitConfiguration() }
        guard session.canAddInput(input), session.canAddOutput(preview), session.canAddOutput(data) else {
            throw Failure.cannotAdd
        }
        session.addInput(input)
        session.addOutput(preview)
        session.addOutput(data)
        preview.volume = 1
        data.setSampleBufferDelegate(self, queue: queue)
    }

    /// Playback volume of the live monitor, 0…1
    public var volume: Float {
        get { preview.volume }
        set { preview.volume = newValue }
    }

    /// Receives every audio buffer while set (for the recorder)
    public var sink: (@Sendable (CMSampleBuffer) -> Void)? {
        get { lock.withLock { _sink } }
        set { lock.withLock { _sink = newValue } }
    }

    public var isRunning: Bool { session.isRunning }

    public func start() {
        queue.async { self.session.startRunning() }
    }

    public func stop() {
        queue.async { self.session.stopRunning() }
    }

    public func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                              from connection: AVCaptureConnection) {
        sink?(sampleBuffer)
    }
}
