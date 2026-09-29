// SPDX-License-Identifier: GPL-2.0-only
import CoreVideo
import Foundation
@testable import MagicaCapture
import MagicaCore
import Testing

private final class Frames: @unchecked Sendable {
    private let lock = NSLock()
    private var _all: [VideoFrame] = []
    func add(_ f: VideoFrame) { lock.withLock { _all.append(f) } }
    var all: [VideoFrame] { lock.withLock { _all } }
}

/// Feeds fields of a flat grey level per field (`value`) through a weaver
private func feed(_ w: FieldWeaver, tops: [Bool], width: Int = 16, lines: Int = 4) {
    for (i, top) in tops.enumerated() {
        let value = UInt8(16 + i)
        var yuyv = [UInt8](repeating: 128, count: width * 2 * lines)
        for p in stride(from: 0, to: yuyv.count, by: 2) { yuyv[p] = value }
        yuyv.withUnsafeBufferPointer { buf in
            w.field(magica_field(data: buf.baseAddress, width: Int32(width), lines: Int32(lines), stride: Int32(width * 2),
                                 top: top ? 1 : 0, complete: 1, seq: UInt32(i), time_ns: UInt64(i) * 16_683_333))
        }
    }
}

private func lumaRows(_ pb: CVPixelBuffer) -> [UInt8] {
    CVPixelBufferLockBaseAddress(pb, .readOnly)
    defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
    let base = CVPixelBufferGetBaseAddressOfPlane(pb, 0)!.assumingMemoryBound(to: UInt8.self)
    let stride = CVPixelBufferGetBytesPerRowOfPlane(pb, 0)
    return (0..<CVPixelBufferGetHeight(pb)).map { base[$0 * stride] }
}

@Test func alternatingFieldsWeaveIntoInterlacedFrames() {
    let out = Frames()
    let w = FieldWeaver(width: 16, height: 8, standard: .ntsc) { out.add($0) }
    feed(w, tops: [true, false, true, false])
    #expect(out.all.count == 2)
    #expect(out.all.allSatisfy { $0.interlaced })
    // top field on even lines, bottom on odd
    #expect(lumaRows(out.all[0].image) == [16, 17, 16, 17, 16, 17, 16, 17])
}

@Test func progressiveSourcesLineDoubleEveryField() {
    let out = Frames()
    let w = FieldWeaver(width: 16, height: 8, standard: .ntsc) { out.add($0) }
    w.progressive = true
    feed(w, tops: [true, false, true])
    #expect(out.all.count == 3)
    #expect(out.all.allSatisfy { !$0.interlaced })
    #expect(lumaRows(out.all[1].image) == [17, 17, 17, 17, 17, 17, 17, 17])
    #expect(out.all[0].duration == VideoStandard.ntsc.fieldDuration)
}

@Test func fieldsThatStopAlternatingAreTakenAsProgressive() {
    // a 240p source whose fields all carry the same parity: pairing would never finish a frame
    let out = Frames()
    let w = FieldWeaver(width: 16, height: 8, standard: .ntsc) { out.add($0) }
    feed(w, tops: [true, true, true, true, true])
    #expect(out.all.count == 3)  // from the third same-parity field on
    #expect(out.all.allSatisfy { !$0.interlaced })
}

@Test func aSingleDroppedFieldDoesNotSwitchModes() {
    let out = Frames()
    let w = FieldWeaver(width: 16, height: 8, standard: .ntsc) { out.add($0) }
    feed(w, tops: [true, false, true, true, false, true, false])
    #expect(out.all.allSatisfy { $0.interlaced })
    #expect(out.all.count == 3)
}
