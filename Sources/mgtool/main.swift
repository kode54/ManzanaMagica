// SPDX-License-Identifier: GPL-2.0-only
// mgtool: records from the capture device through the app's pipeline
@preconcurrency import AVFoundation
import Foundation
import MagicaCapture
import MagicaPlayback

func usage() -> Never {
    FileHandle.standardError.write(Data("""
    usage: mgtool record OUT.mov [--seconds N] [--input composite|svideo] [--std ntsc|pal|…]
                                 [--codec h264|hevc] [--size native|hd720|hd720Pillarbox]
                                 [--deinterlace yadif|bob|off] [--scan auto|interlaced|progressive] [--no-audio] [--warmup S] [-v]

    """.utf8))
    exit(2)
}

setvbuf(stdout, nil, _IOLBF, 0)
var args = Array(CommandLine.arguments.dropFirst())
guard args.count >= 2, args.removeFirst() == "record" else { usage() }
let out = URL(fileURLWithPath: args.removeFirst())
var verbose = false, warmup = 0.0, seconds = 10.0, input = VideoInput.composite, std: VideoStandard?, audio = true
var options = RecordingOptions(), mode = DeinterlaceMode.yadif, scan = ScanMode.auto
while !args.isEmpty {
    let a = args.removeFirst()
    func value() -> String {
        if args.isEmpty { usage() }
        return args.removeFirst()
    }
    func parse<T: RawRepresentable<String>>(_: T.Type) -> T {
        guard let v = T(rawValue: value()) else { usage() }
        return v
    }
    switch a {
    case "--seconds": seconds = Double(value()) ?? seconds
    case "--input": input = value() == "svideo" ? .sVideo : .composite
    case "--std": std = parse(VideoStandard.self)
    case "--codec": options.codec = parse(RecordingOptions.Codec.self)
    case "--size": options.size = parse(RecordingOptions.Size.self)
    case "--deinterlace": mode = parse(DeinterlaceMode.self)
    case "--scan": scan = parse(ScanMode.self)
    case "--no-audio": audio = false
    case "--warmup": warmup = Double(value()) ?? warmup
    case "-v":
        verbose = true
        CaptureDevice.setVerbosity(1)
    default: usage()
    }
}

let device = try CaptureDevice()
print("\(device.info.board): \(device.info.bridge), \(device.info.decoder)")
try device.setInput(input)
try await Task.sleep(for: .milliseconds(300))
let standard = std ?? (device.detects50Hz() == true && device.status().locked ? .pal : .ntsc)
try device.setStandard(standard)
let first = device.status()
print("\(standard.name), \(first.locked ? "locked" : "NO SIGNAL"), decoder says \(first.interlaced ? "interlaced" : "progressive")")
device.progressive = scan == .progressive || (scan == .auto && first.locked && !first.interlaced)

var capture: AudioCapture?
if audio, await AudioCapture.requestAccess(),
   let dev = AudioCapture.findDevice(vendorID: device.info.vendorID, productID: device.info.productID) {
    capture = try AudioCapture(device: dev)
    capture?.volume = 0
}
let pipeline = VideoPipeline(layer: AVSampleBufferDisplayLayer(), mode: mode)
capture?.start()
try device.start { pipeline.push($0) }
// like the app: sound and pictures running for a while before recording starts
if warmup > 0 { try await Task.sleep(for: .seconds(warmup)) }
try? FileManager.default.removeItem(at: out)
let recorder = try Recorder(url: out, options: options, standard: standard, audio: capture != nil)
pipeline.recorder = recorder
capture?.sink = { recorder.appendAudio($0) }

let start = Date()
while Date().timeIntervalSince(start) < seconds {
    try await Task.sleep(for: .seconds(1))
    if let e = recorder.failure {
        print("writer failed: \(Recorder.describe(e))")
        break
    }
    if verbose { print("       " + recorder.diagnostics) }
    let s = pipeline.currentStats(), st = device.status()
    if scan == .auto, st.locked { device.progressive = !st.interlaced }
    print((s.progressiveSource ? "p " : "i ") + String(format: "%5.1fs  frames %d → %d pictures, dropped %d, incomplete %d, renderer flushes %d, GPU %.2f ms/field, fields %u short %u",
                 recorder.duration, s.frames, s.output, s.dropped, s.incomplete, s.rendererFlushes, s.gpuTime * 1000, st.fields, st.shortFields))
}
device.stop()
capture?.stop()
pipeline.recorder = nil
let url: URL
do {
    url = try await recorder.finish()
} catch {
    print("finish failed: \(Recorder.describe(recorder.failure ?? error))")
    exit(1)
}
print("wrote \(url.path), \(recorder.droppedVideo) pictures dropped by the encoder")
