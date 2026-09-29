// SPDX-License-Identifier: GPL-2.0-only
@preconcurrency import AVFoundation
import AppKit
import MagicaCapture
import MagicaPlayback
import Observation
import SwiftUI
import os

let log = Logger(subsystem: "net.kode54.ManzanaMagica", category: "app")

enum StandardChoice: String, CaseIterable, Identifiable {
    case auto, ntsc, ntscJ, palM, pal60, ntsc443, pal, palN, secam
    var id: String { rawValue }
    var standard: VideoStandard? { VideoStandard(rawValue: rawValue) }
    var name: String { standard?.name ?? String(localized: "Automatic") }
}

@MainActor
@Observable
final class AppModel {
    enum Phase: Equatable {
        case waiting            // no device plugged in
        case opening
        case running
        case failed(String)     // busy, unsupported…
    }

    let layer = AVSampleBufferDisplayLayer()
    @ObservationIgnored private(set) var pipeline: VideoPipeline!

    var phase: Phase = .waiting
    var info: DeviceInfo?
    var status = DeviceStatus()
    var standard: VideoStandard = .ntsc
    var stats = VideoPipeline.Stats()
    var showStats = false
    var recording: Recorder?
    var recordingSeconds: Double = 0
    var lastRecording: URL?
    var lastScreenshot: URL?
    var alert: String?
    /// A short confirmation shown over the picture
    var notice: String?
    @ObservationIgnored private var noticeTask: Task<Void, Never>?

    // settings
    @ObservationIgnored private let defaults = UserDefaults.standard
    @ObservationIgnored private var storedInput: Int {
        get { defaults.object(forKey: "input") as? Int ?? VideoInput.composite.rawValue }
        set { defaults.set(newValue, forKey: "input") }
    }
    @ObservationIgnored private var storedStandard: String {
        get { defaults.string(forKey: "standard") ?? StandardChoice.auto.rawValue }
        set { defaults.set(newValue, forKey: "standard") }
    }
    @ObservationIgnored private var storedScan: String {
        get { defaults.string(forKey: "scan") ?? ScanMode.auto.rawValue }
        set { defaults.set(newValue, forKey: "scan") }
    }
    @ObservationIgnored private var storedDeinterlace: String {
        get { defaults.string(forKey: "deinterlace") ?? DeinterlaceMode.yadif.rawValue }
        set { defaults.set(newValue, forKey: "deinterlace") }
    }
    @ObservationIgnored private var storedCodec: String {
        get { defaults.string(forKey: "codec") ?? RecordingOptions.Codec.h264.rawValue }
        set { defaults.set(newValue, forKey: "codec") }
    }
    @ObservationIgnored private var storedSize: String {
        get { defaults.string(forKey: "size") ?? RecordingOptions.Size.hd720.rawValue }
        set { defaults.set(newValue, forKey: "size") }
    }
    private func double(_ key: String, _ fallback: Double) -> Double {
        defaults.object(forKey: key) as? Double ?? fallback
    }
    @ObservationIgnored private var storedMbps: Double {
        get { double("videoMbps", 8) }
        set { defaults.set(newValue, forKey: "videoMbps") }
    }
    @ObservationIgnored private var storedVolume: Double {
        get { double("monitorVolume", 1) }
        set { defaults.set(newValue, forKey: "monitorVolume") }
    }
    @ObservationIgnored private var storedBrightness: Double {
        get { double("brightness", 128) }
        set { defaults.set(newValue, forKey: "brightness") }
    }
    @ObservationIgnored private var storedContrast: Double {
        get { double("contrast", 64) }
        set { defaults.set(newValue, forKey: "contrast") }
    }
    @ObservationIgnored private var storedSaturation: Double {
        get { double("saturation", 64) }
        set { defaults.set(newValue, forKey: "saturation") }
    }
    @ObservationIgnored private var storedHue: Double {
        get { double("hue", 0) }
        set { defaults.set(newValue, forKey: "hue") }
    }

    var input: VideoInput {
        get { access(keyPath: \.input); return VideoInput(rawValue: storedInput) ?? .composite }
        set {
            withMutation(keyPath: \.input) { storedInput = newValue.rawValue }
            let device = self.device
            control.async { try? device?.setInput(newValue) }
        }
    }

    var standardChoice: StandardChoice {
        get { access(keyPath: \.standardChoice); return StandardChoice(rawValue: storedStandard) ?? .auto }
        set {
            withMutation(keyPath: \.standardChoice) { storedStandard = newValue.rawValue }
            if let s = newValue.standard { apply(standard: s) }
        }
    }

    var scanMode: ScanMode {
        get { access(keyPath: \.scanMode); return ScanMode(rawValue: storedScan) ?? .auto }
        set {
            withMutation(keyPath: \.scanMode) { storedScan = newValue.rawValue }
            interlacedReadings = 0
            progressiveReadings = 0
            switch newValue {
            case .auto: break  // the next status poll decides
            case .interlaced: device?.progressive = false
            case .progressive: device?.progressive = true
            }
        }
    }

    var deinterlace: DeinterlaceMode {
        get { access(keyPath: \.deinterlace); return DeinterlaceMode(rawValue: storedDeinterlace) ?? .yadif }
        set {
            withMutation(keyPath: \.deinterlace) { storedDeinterlace = newValue.rawValue }
            pipeline.mode = newValue
        }
    }

    var recordingOptions: RecordingOptions {
        get {
            access(keyPath: \.recordingOptions)
            var o = RecordingOptions()
            o.codec = .init(rawValue: storedCodec) ?? .h264
            o.size = .init(rawValue: storedSize) ?? .hd720
            o.videoMbps = storedMbps
            return o
        }
        set {
            withMutation(keyPath: \.recordingOptions) {
                storedCodec = newValue.codec.rawValue
                storedSize = newValue.size.rawValue
                storedMbps = newValue.videoMbps
            }
        }
    }

    var monitorVolume: Double {
        get { access(keyPath: \.monitorVolume); return storedVolume }
        set {
            withMutation(keyPath: \.monitorVolume) { storedVolume = newValue }
            audio?.volume = Float(newValue)
        }
    }

    struct Picture: Equatable {
        var brightness: Double, contrast: Double, saturation: Double, hue: Double
        static let defaults = Picture(brightness: 128, contrast: 64, saturation: 64, hue: 0)
    }

    var picture: Picture {
        get {
            access(keyPath: \.picture)
            return Picture(brightness: storedBrightness, contrast: storedContrast, saturation: storedSaturation, hue: storedHue)
        }
        set {
            withMutation(keyPath: \.picture) {
                storedBrightness = newValue.brightness
                storedContrast = newValue.contrast
                storedSaturation = newValue.saturation
                storedHue = newValue.hue
            }
            applyPicture()
        }
    }

    @ObservationIgnored private var device: CaptureDevice?
    @ObservationIgnored private var audio: AudioCapture?
    @ObservationIgnored private let monitor = DeviceMonitor()
    /// USB control transfers take milliseconds each: keep them off the main thread
    @ObservationIgnored private let control = DispatchQueue(label: "magica.control", qos: .userInitiated)
    @ObservationIgnored private var tasks: [Task<Void, Never>] = []
    /// Consecutive status polls disagreeing with the current standard / scan
    @ObservationIgnored private var rateMismatches = 0
    @ObservationIgnored private var interlacedReadings = 0
    @ObservationIgnored private var progressiveReadings = 0

    init() {
        pipeline = VideoPipeline(layer: layer, mode: deinterlace)
        tasks.append(Task { [weak self] in
            guard let events = self?.monitor.events else { return }
            for await event in events {
                guard let self else { return }
                switch event {
                case .arrived: if phase == .waiting || phase.isFailure { connect() }
                case .removed: if !DeviceMonitor.isPresent { disconnect(unplugged: true) }
                }
            }
        })
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(500))
                await self?.poll()
            }
        })
        if DeviceMonitor.isPresent { connect() }
    }

    var canRecord: Bool { phase == .running && recording == nil }

    var statusText: String {
        switch phase {
        case .waiting: String(localized: "Plug in the capture device")
        case .opening: String(localized: "Starting…")
        case .failed(let why): why
        case .running: status.locked ? "\(standard.name) \(scanLabel)" : String(localized: "No signal")
        }
    }

    // MARK: - device

    func connect() {
        guard phase != .opening, device == nil else { return }
        phase = .opening
        let input = self.input
        let choice = standardChoice
        let scan = scanMode
        let pipeline = self.pipeline!
        control.async {
            let result: Result<(CaptureDevice, VideoStandard), Error> = Result {
                let d = try CaptureDevice()
                try d.setInput(input)
                if case .progressive = scan { d.progressive = true }
                var std = choice.standard ?? .ntsc
                if choice == .auto {
                    // the decoder needs a moment to lock before it knows the field rate
                    Thread.sleep(forTimeInterval: 0.3)
                    if d.status().locked, d.detects50Hz() == true { std = .pal }
                }
                try d.setStandard(std)
                try d.start { pipeline.push($0) }
                return (d, std)
            }
            Task { @MainActor in self.opened(result) }
        }
    }

    private func opened(_ result: Result<(CaptureDevice, VideoStandard), Error>) {
        switch result {
        case .success(let (d, std)):
            device = d
            info = d.info
            standard = std
            phase = .running
            applyPicture()
            startAudio(for: d.info)
        case .failure(let error):
            if (error as? CaptureError) == .noDevice {
                phase = .waiting
            } else {
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func startAudio(for info: DeviceInfo) {
        Task {
            guard await AudioCapture.requestAccess() else {
                alert = String(localized: "ManzanaMagica needs microphone access to play and record the device's sound. Allow it in System Settings → Privacy & Security → Microphone.")
                return
            }
            // the USB audio interface can show up a moment after the device
            for _ in 0..<10 {
                if let dev = AudioCapture.findDevice(vendorID: info.vendorID, productID: info.productID),
                   let a = try? AudioCapture(device: dev) {
                    a.volume = Float(monitorVolume)
                    a.sink = recording.map { r in { r.appendAudio($0) } }
                    a.start()
                    audio = a
                    return
                }
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
    }

    func disconnect(unplugged: Bool) {
        stopRecording()
        audio?.stop()
        audio = nil
        let d = device
        device = nil
        control.async { d?.stop() }
        pipeline.reset()
        phase = .waiting
        status = DeviceStatus()
    }

    private func apply(standard s: VideoStandard) {
        guard let device, s != standard else { return }
        standard = s
        pipeline.reset()
        control.async { try? device.setStandard(s) }
    }

    private func applyPicture() {
        guard let device else { return }
        let p = picture
        control.async {
            try? device.setPicture(brightness: Int(p.brightness), contrast: Int(p.contrast),
                                   saturation: Int(p.saturation), hue: Int(p.hue))
        }
    }

    private func poll() async {
        stats = pipeline.currentStats()
        if let recording {
            recordingSeconds = recording.duration
            if let failure = recording.failure {
                let why = Recorder.describe(failure)
                log.error("recording failed: \(why, privacy: .public)")
                stopRecording()
                alert = String(localized: "Recording stopped: \(why)")
            }
        }
        guard let device, phase == .running else { return }
        let s = await withCheckedContinuation { cont in
            control.async { cont.resume(returning: device.status()) }
        }
        guard self.device === device else { return }
        if s.locked != status.locked { log.info("signal: \(s.locked ? "locked" : "lost", privacy: .public)") }
        status = s
        if s.unplugged {
            disconnect(unplugged: true)
            return
        }
        guard s.locked else {
            rateMismatches = 0
            return
        }
        // follow the source between 525/60 and 625/50 once it reads the same for 1.5 s
        // (a console's mode switch can make one reading wrong)
        if standardChoice == .auto, s.is50Hz != standard.is50Hz {
            rateMismatches += 1
            if rateMismatches >= 3 {
                rateMismatches = 0
                log.info("standard: source is \(s.is50Hz ? 50 : 60, privacy: .public) Hz, switching")
                apply(standard: s.is50Hz ? .pal : .ntsc)
            }
        } else {
            rateMismatches = 0
        }
        // 240p/288p or interlaced, from two readings in a row
        if scanMode == .auto {
            if s.interlaced {
                interlacedReadings += 1
                progressiveReadings = 0
            } else {
                progressiveReadings += 1
                interlacedReadings = 0
            }
            if interlacedReadings == 2, device.progressive {
                device.progressive = false
                log.info("scan: interlaced (decoder status)")
            }
            if progressiveReadings == 2, !device.progressive {
                device.progressive = true
                log.info("scan: progressive (decoder status)")
            }
        }
    }

    /// "240p", "480i"…, from what's on screen
    var scanLabel: String {
        let progressive = stats.progressiveSource
        return standard.is50Hz ? (progressive ? "288p" : "576i") : (progressive ? "240p" : "480i")
    }

    // MARK: - screenshots

    static var screenshotsFolder: URL {
        let pictures = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask).first!
        return pictures.appending(path: "ManzanaMagica", directoryHint: .isDirectory)
    }

    var canTakeScreenshot: Bool { phase == .running && status.locked }

    /// Saves the picture on screen as a PNG
    func takeScreenshot() {
        guard canTakeScreenshot, let picture = pipeline.currentPicture() else { return }
        let folder = Self.screenshotsFolder
        let url = folder.appending(path: "Screenshot \(Self.stamp()).png")
        nonisolated(unsafe) let owned = picture
        Task.detached(priority: .userInitiated) {
            do {
                try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
                try Screenshot.writePNG(owned, to: url)
                await MainActor.run {
                    self.lastScreenshot = url
                    self.show(notice: String(localized: "Screenshot saved"))
                    log.info("screenshot: \(url.path, privacy: .public)")
                }
            } catch {
                await MainActor.run { self.alert = String(localized: "The screenshot couldn't be saved: \(error.localizedDescription)") }
            }
        }
    }

    func showScreenshots() {
        try? FileManager.default.createDirectory(at: Self.screenshotsFolder, withIntermediateDirectories: true)
        if let lastScreenshot {
            NSWorkspace.shared.activateFileViewerSelecting([lastScreenshot])
        } else {
            NSWorkspace.shared.open(Self.screenshotsFolder)
        }
    }

    private func show(notice: String) {
        self.notice = notice
        noticeTask?.cancel()
        noticeTask = Task {
            try? await Task.sleep(for: .seconds(1.5))
            if !Task.isCancelled { self.notice = nil }
        }
    }

    /// Local date and time for file names
    static func stamp() -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HH.mm.ss"
        return f.string(from: .now)
    }

    // MARK: - recording

    static var recordingsFolder: URL {
        let movies = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask).first!
        return movies.appending(path: "ManzanaMagica", directoryHint: .isDirectory)
    }

    func startRecording() {
        guard canRecord else { return }
        do {
            try FileManager.default.createDirectory(at: Self.recordingsFolder, withIntermediateDirectories: true)
            let url = Self.recordingsFolder.appending(path: "Capture \(Self.stamp()).mov")
            let r = try Recorder(url: url, options: recordingOptions, standard: standard, audio: audio != nil)
            recording = r
            recordingSeconds = 0
            log.info("recording to \(url.path, privacy: .public)")
            pipeline.recorder = r
            audio?.sink = { r.appendAudio($0) }
        } catch {
            alert = String(localized: "Couldn't start recording: \(error.localizedDescription)")
        }
    }

    func stopRecording() {
        guard let r = recording else { return }
        pipeline.recorder = nil
        audio?.sink = nil
        recording = nil
        Task {
            do {
                lastRecording = try await r.finish()
                log.info("recording saved: \(r.url.path, privacy: .public)")
            } catch {
                let why = Recorder.describe(r.failure ?? error)
                log.error("finishing the recording failed: \(why, privacy: .public)")
                alert = String(localized: "The recording couldn't be saved: \(why)")
            }
        }
    }

    func showRecordings() {
        try? FileManager.default.createDirectory(at: Self.recordingsFolder, withIntermediateDirectories: true)
        if let lastRecording {
            NSWorkspace.shared.activateFileViewerSelecting([lastRecording])
        } else {
            NSWorkspace.shared.open(Self.recordingsFolder)
        }
    }

    func applicationWillTerminate() {
        if let r = recording {
            pipeline.recorder = nil
            audio?.sink = nil
            recording = nil
            // finish synchronously enough that the file is closed before exit
            let done = DispatchSemaphore(value: 0)
            Task.detached {
                _ = try? await r.finish()
                done.signal()
            }
            _ = done.wait(timeout: .now() + 5)
        }
        device?.stop()
    }
}

extension AppModel.Phase {
    var isFailure: Bool {
        if case .failed = self { return true }
        return false
    }
}
