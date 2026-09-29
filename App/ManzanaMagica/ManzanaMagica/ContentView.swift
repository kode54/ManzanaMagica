// SPDX-License-Identifier: GPL-2.0-only
import MagicaCapture
import MagicaPlayback
import SwiftUI

struct ContentView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        ZStack {
            VideoLayerView(layer: model.layer)
                .ignoresSafeArea()
                .onTapGesture(count: 2) { NSApp.keyWindow?.toggleFullScreen(nil) }
            if let message = overlayMessage {
                VStack(spacing: 12) {
                    if model.phase == .opening { ProgressView() }
                    Text(message)
                        .font(.title3)
                        .multilineTextAlignment(.center)
                }
                .padding(24)
                .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
                .allowsHitTesting(false)
            }
            if model.showStats {
                StatsHUD()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(12)
            }
        }
        .background(.black)
        .navigationTitle("ManzanaMagica")
        .navigationSubtitle(model.statusText)
        .toolbar {
            ToolbarItemGroup {
                Picker("Input", selection: $model.input) {
                    ForEach(VideoInput.allCases) { Text($0.name).tag($0) }
                }
                .pickerStyle(.segmented)
                .help("Video input")
                Picker("Standard", selection: $model.standardChoice) {
                    ForEach(StandardChoice.allCases) { Text($0.name).tag($0) }
                }
                .help("Colour standard")
            }
            ToolbarItem {
                if model.recording != nil {
                    Button {
                        model.stopRecording()
                    } label: {
                        Label(Duration.seconds(model.recordingSeconds).formatted(.time(pattern: .hourMinuteSecond)),
                              systemImage: "stop.circle.fill")
                            .labelStyle(.titleAndIcon)
                            .foregroundStyle(.red)
                            .monospacedDigit()
                    }
                    .help("Stop recording")
                } else {
                    Button {
                        model.startRecording()
                    } label: {
                        Label("Record", systemImage: "record.circle")
                    }
                    .disabled(!model.canRecord)
                    .help("Record to Movies/ManzanaMagica")
                }
            }
        }
        .alert("ManzanaMagica", isPresented: Binding(get: { model.alert != nil }, set: { if !$0 { model.alert = nil } })) {
            Button("OK") { model.alert = nil }
        } message: {
            Text(model.alert ?? "")
        }
    }

    private var overlayMessage: String? {
        switch model.phase {
        case .running:
            model.status.locked ? nil : String(localized: "No signal on \(model.input.name)")
        default:
            model.statusText
        }
    }
}

struct StatsHUD: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.stats, st = model.status
        VStack(alignment: .leading, spacing: 3) {
            if let info = model.info {
                Text("\(info.board): \(info.bridge), \(info.decoder), \(info.audio)")
            }
            Text("Signal: \(st.locked ? "locked" : "no lock"), \(st.is50Hz ? "50" : "60") Hz, colour \(st.color ? "yes" : "no")")
            Text("Standard: \(model.standard.name), \(model.standard.height) lines")
            Text("Fields: \(st.fields), short \(st.shortFields), USB errors \(st.packetErrors)")
            Text("Frames: \(s.frames) in, \(s.output) out, \(s.dropped) dropped, \(s.incomplete) incomplete, \(s.rendererFlushes) renderer flushes")
            Text("Deinterlace: \(s.mode.name), GPU \(s.gpuTime * 1000, specifier: "%.2f") ms/field")
        }
        .font(.caption.monospaced())
        .padding(10)
        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
        .foregroundStyle(.white)
    }
}
