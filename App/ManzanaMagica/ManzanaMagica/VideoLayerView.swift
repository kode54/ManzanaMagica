// SPDX-License-Identifier: GPL-2.0-only
@preconcurrency import AVFoundation
import AVKit
import SwiftUI

/// Hosts the engine's display layer. The layer is created once by the model
/// and must stay the same instance and keeps showing the last picture.
struct VideoLayerView: NSViewRepresentable {
    let layer: AVSampleBufferDisplayLayer

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.wantsLayer = true
        let root = CALayer()
        root.backgroundColor = NSColor.black.cgColor
        view.layer = root
        layer.frame = view.bounds
        layer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        root.addSublayer(layer)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {}
}

/// Picture in Picture for a live sample-buffer layer
