// SPDX-License-Identifier: GPL-2.0-only
import MagicaCapture
import MagicaPlayback
import SwiftUI

struct SettingsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        TabView {
            Form {
                Picker("Deinterlacing", selection: $model.deinterlace) {
                    ForEach(DeinterlaceMode.allCases) { Text($0.name).tag($0) }
                }
                Section("Picture") {
                    Slider(value: $model.picture.brightness, in: 0...255, step: 1) { Text("Brightness") }
                    Slider(value: $model.picture.contrast, in: 0...127, step: 1) { Text("Contrast") }
                    Slider(value: $model.picture.saturation, in: 0...127, step: 1) { Text("Saturation") }
                    Slider(value: $model.picture.hue, in: -128...127, step: 1) { Text("Hue") }
                    Button("Reset Picture") { model.picture = .defaults }
                }
                Section("Sound") {
                    Slider(value: $model.monitorVolume, in: 0...1) { Text("Monitor volume") }
                }
            }
            .formStyle(.grouped)
            .tabItem { Label("Video", systemImage: "tv") }

            Form {
                Picker("Codec", selection: $model.recordingOptions.codec) {
                    ForEach(RecordingOptions.Codec.allCases) { Text($0.name).tag($0) }
                }
                Picker("Size", selection: $model.recordingOptions.size) {
                    ForEach(RecordingOptions.Size.allCases) { Text($0.name).tag($0) }
                }
                LabeledContent("Bit rate") {
                    HStack {
                        Slider(value: $model.recordingOptions.videoMbps, in: 2...20, step: 1)
                        Text("\(Int(model.recordingOptions.videoMbps)) Mbit/s")
                            .monospacedDigit()
                            .frame(width: 80, alignment: .trailing)
                    }
                }
                Text("Recordings are deinterlaced to 60 (or 50) frames per second, with AAC sound, and saved as QuickTime movies in Movies/ManzanaMagica. 720p recordings use square pixels and BT.709 colour, ready to upload.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Button("Show Recordings") { model.showRecordings() }
            }
            .formStyle(.grouped)
            .tabItem { Label("Recording", systemImage: "record.circle") }
        }
        .frame(width: 480, height: 420)
    }
}
