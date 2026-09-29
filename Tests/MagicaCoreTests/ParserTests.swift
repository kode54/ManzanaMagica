// SPDX-License-Identifier: GPL-2.0-only
import MagicaCore
import Testing

/// Builds isochronous packets the way the em2860 sends them: a 4-byte header
/// on every packet, VBI rows first, then the field's picture rows
private func packets(top: Bool, width: Int, lines: Int, vbiLines: Int, fill: (Int) -> UInt8,
                     payload: Int = 2888 - 4, missingLines: Int = 0) -> [[UInt8]] {
    let body = [UInt8](repeating: 0x10, count: width * vbiLines)
        + (0..<(width * 2 * (lines - missingLines))).map(fill)
    var out: [[UInt8]] = []
    var i = 0
    while i < body.count {
        let header: [UInt8] = out.isEmpty ? [0x33, 0x95, top ? 0 : 1, 0] : [0x88, 0x88, 0x88, 0x88]
        out.append(header + body[i..<min(i + payload, body.count)])
        i += payload
    }
    return out
}

private final class Collector {
    var fields: [(top: Bool, complete: Bool, bytes: [UInt8])] = []
}

private func parse(_ pkts: [[UInt8]], width: Int = 720, height: Int = 480, vbi: Int = 12) -> Collector {
    let c = Collector()
    let ctx = Unmanaged.passUnretained(c).toOpaque()
    let p = magica_parser_new(Int32(width), Int32(height), Int32(vbi), { ctx, f in
        let c = Unmanaged<Collector>.fromOpaque(ctx!).takeUnretainedValue()
        let f = f!.pointee
        let bytes = Array(UnsafeBufferPointer(start: f.data, count: Int(f.stride * f.lines)))
        c.fields.append((f.top != 0, f.complete != 0, bytes))
    }, ctx)!
    defer { magica_parser_free(p) }
    for pkt in pkts {
        pkt.withUnsafeBufferPointer { magica_parser_feed(p, $0.baseAddress, Int32($0.count), 0) }
    }
    return withExtendedLifetime(c) { c }
}

@Test func fullFieldsComeOutAtTheirLastPacket() {
    let top = packets(top: true, width: 720, lines: 240, vbiLines: 12) { UInt8($0 % 251) }
    let bottom = packets(top: false, width: 720, lines: 240, vbiLines: 12) { UInt8($0 % 13) }
    let c = parse(top + bottom)
    #expect(c.fields.count == 2)
    #expect(c.fields[0].top && !c.fields[1].top)
    #expect(c.fields[0].complete && c.fields[1].complete)
    // VBI is skipped: the picture starts right after it
    #expect(c.fields[0].bytes[0..<1000] == ArraySlice((0..<1000).map { UInt8($0 % 251) }))
    #expect(c.fields[1].bytes.last == UInt8((720 * 2 * 240 - 1) % 13))
}

@Test func fieldsTwoLinesShortArePaddedWithTheirLastLine() {
    // what the em2860 really sends: the capture window starts 2 lines down
    let top = packets(top: true, width: 720, lines: 240, vbiLines: 12, fill: { UInt8($0 / 1440 % 256) }, missingLines: 2)
    let next = packets(top: false, width: 720, lines: 240, vbiLines: 12, fill: { _ in 0 })
    let c = parse(top + next.prefix(1))
    #expect(c.fields.count == 1)
    #expect(c.fields[0].complete)
    let lastReal = c.fields[0].bytes[(237 * 1440)..<(238 * 1440)]
    #expect(c.fields[0].bytes[(239 * 1440)..<(240 * 1440)] == lastReal)
}

@Test func aFieldCutInHalfIsMarkedIncomplete() {
    let top = packets(top: true, width: 720, lines: 240, vbiLines: 12, fill: { _ in 1 }, missingLines: 120)
    let next = packets(top: false, width: 720, lines: 240, vbiLines: 12, fill: { _ in 0 })
    let c = parse(top + next.prefix(1))
    #expect(c.fields.count == 1)
    #expect(!c.fields[0].complete)
}

@Test func weavingSplitsLumaAndChroma() {
    let yuyv: [UInt8] = [10, 20, 11, 30, 12, 21, 13, 31]  // Y0 Cb Y1 Cr, two pixel pairs
    var y = [UInt8](repeating: 0, count: 4 * 2), c = [UInt8](repeating: 0, count: 4 * 2)
    yuyv.withUnsafeBufferPointer { src in
        var f = magica_field(data: src.baseAddress, width: 4, lines: 1, stride: 8, top: 0, complete: 1, seq: 0, time_ns: 0)
        magica_weave_field(&f, 1, &y, 4, &c, 4)
    }
    #expect(y == [0, 0, 0, 0, 10, 11, 12, 13])
    #expect(c == [0, 0, 0, 0, 20, 30, 21, 31])
}
