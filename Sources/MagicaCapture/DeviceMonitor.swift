// SPDX-License-Identifier: GPL-2.0-only
import Foundation
import IOKit
import IOKit.usb

/// Watches for a supported em28xx capture device coming and going
public final class DeviceMonitor: @unchecked Sendable {
    public enum Event: Sendable, Equatable { case arrived, removed }

    /// The IDs libmagica opens (see boards[] in src/core/em28xx.c)
    public static let supported: [(vendor: Int, product: Int)] = [
        (0x1f4d, 0x1abe),  // MyGica iGrabber
        (0xeb1a, 0x2860),
        (0xeb1a, 0x2861),
    ]

    public let events: AsyncStream<Event>
    private let continuation: AsyncStream<Event>.Continuation
    private let queue = DispatchQueue(label: "mzv.devicemonitor")
    private var port: IONotificationPortRef?
    private var iterators: [io_iterator_t] = []

    public init() {
        (events, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingNewest(8))
        queue.sync { start() }
    }

    deinit {
        for it in iterators { IOObjectRelease(it) }
        if let port { IONotificationPortDestroy(port) }
        continuation.finish()
    }

    /// Whether a device is connected right now (not just the last event)
    public static var isPresent: Bool {
        supported.contains { id in
            let service = IOServiceGetMatchingService(kIOMainPortDefault, matching(id))
            defer { if service != 0 { IOObjectRelease(service) } }
            return service != 0
        }
    }

    /// Returns once a device is connected, checking the real state first so
    /// stale buffered events don't count
    public func waitForArrival() async {
        while !Task.isCancelled {
            if Self.isPresent { return }
            var it = events.makeAsyncIterator()
            guard let e = await it.next() else { return }
            if e == .arrived, Self.isPresent { return }
        }
    }

    private static func matching(_ id: (vendor: Int, product: Int)) -> CFDictionary {
        let dict = IOServiceMatching("IOUSBHostDevice") as NSMutableDictionary
        dict[kUSBVendorID] = id.vendor
        dict[kUSBProductID] = id.product
        return dict
    }

    private func start() {
        guard let port = IONotificationPortCreate(kIOMainPortDefault) else { return }
        self.port = port
        IONotificationPortSetDispatchQueue(port, queue)
        let ctx = Unmanaged.passUnretained(self).toOpaque()
        for id in Self.supported {
            for (type, event) in [(kIOFirstMatchNotification, Event.arrived), (kIOTerminatedNotification, Event.removed)] {
                var it: io_iterator_t = 0
                let callback: IOServiceMatchingCallback = event == .arrived
                    ? { ctx, it in Unmanaged<DeviceMonitor>.fromOpaque(ctx!).takeUnretainedValue().drain(it, .arrived) }
                    : { ctx, it in Unmanaged<DeviceMonitor>.fromOpaque(ctx!).takeUnretainedValue().drain(it, .removed) }
                IOServiceAddMatchingNotification(port, type, Self.matching(id), callback, ctx, &it)
                iterators.append(it)
                // arms the notification; for first-match it also reports a device already plugged in
                drain(it, event)
            }
        }
    }

    private func drain(_ it: io_iterator_t, _ event: Event) {
        var any = false
        while case let service = IOIteratorNext(it), service != 0 {
            IOObjectRelease(service)
            any = true
        }
        if any { continuation.yield(event) }
    }
}
