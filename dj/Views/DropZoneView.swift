import SwiftUI
import UniformTypeIdentifiers

struct DropZoneView: View {
    let onDrop: (URL) -> Void
    @State private var isTargeted = false
    @Environment(\.uiScale) private var uiScale

    var body: some View {
        VStack(spacing: 16 * uiScale) {
            Image(systemName: "waveform.badge.plus")
                .font(.system(size: 48 * uiScale))
                .foregroundStyle(.secondary)

            Text("Drop an audio file")
                .font(.system(size: 20 * uiScale))
                .foregroundStyle(.secondary)

            Text("mp3, wav, m4a, flac, aiff")
                .font(.system(size: 11 * uiScale))
                .foregroundStyle(.tertiary)

            Button("Browse...") {
                let panel = NSOpenPanel()
                panel.allowedContentTypes = [.audio, .mp3, .wav, .aiff]
                panel.allowsMultipleSelection = false
                if panel.runModal() == .OK, let url = panel.url {
                    onDrop(url)
                }
            }
            .buttonStyle(.bordered)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .strokeBorder(
                    isTargeted ? Color.accentColor : Color.secondary.opacity(0.3),
                    style: StrokeStyle(lineWidth: 2, dash: [8])
                )
                .padding(20)
        )
        .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                if let url {
                    DispatchQueue.main.async { onDrop(url) }
                }
            }
            return true
        }
    }
}
