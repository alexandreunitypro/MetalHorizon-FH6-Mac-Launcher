import CoreGraphics
import SwiftUI

/// Settings › Graphics › Frame generation (MetalDuck).
struct FrameGenerationSection: View {
    @ObservedObject private var engine = FrameGeneration.shared
    @State private var settings = FrameGenerationSettings.load()
    @State private var allowed = FrameGeneration.screenRecordingAllowed
    private let supported = FrameGeneration.supported

    var body: some View {
        Section {
            Picker("Frame generation", selection: $settings.mode) {
                ForEach(FrameGenerationMode.allCases) { Text(tr($0.title)).tag($0) }
            }
            .disabled(!supported)
            if !supported {
                Text("Needs macOS 26 or later on Apple silicon: Apple's frame interpolation model comes with it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if settings.enabled {
                Picker("Interpolated at", selection: $settings.quality) {
                    ForEach(FrameGenerationQuality.allCases) { Text(tr($0.title)).tag($0) }
                }
                Toggle("Show the frame rates on the game", isOn: $settings.showStats)
                if !allowed {
                    LabeledContent("Screen Recording permission") {
                        Button("Allow…") {
                            FrameGeneration.requestScreenRecording()
                            allowed = FrameGeneration.screenRecordingAllowed
                        }
                    }
                }
                LabeledContent("Now") {
                    Text(tr(engine.status)).foregroundStyle(.secondary)
                }
                if let cap = suggestedCap {
                    Text(tr("With Frame cap on None, the game is capped at %@ fps so its frames come evenly; set a cap to choose another.", String(cap)))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Text("MetalDuck's frame generation, built in: the game's window is captured, Apple's on-device model (VideoToolbox) makes the frames in between, and they are shown over the game. Smoother motion for about one frame of latency, with every engine. From MetalDuck by Roberto Camargo (GPL-3.0).")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        } header: {
            Text("Frame generation (MetalDuck)")
        }
        .onChange(of: settings) { _, new in
            new.save()
            FrameGeneration.shared.settingsChanged()
        }
        .onAppear { allowed = FrameGeneration.screenRecordingAllowed }
    }

    /// The cap the game gets with frame generation on and no cap of the player's.
    private var suggestedCap: Int? {
        let player = settingsStore().integer(forKey: SettingKey.maxFPS)
        guard settings.enabled, player == 0 else { return nil }
        return FrameGenerationSettings.gameFrameCap(playerCap: 0, multiplier: settings.mode.multiplier, refresh: mainDisplayRefreshRate())
    }
}
