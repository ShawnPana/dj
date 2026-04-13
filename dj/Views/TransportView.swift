import SwiftUI

struct TransportView: View {
    @ObservedObject var engine: AudioEngineManager

    var body: some View {
        VStack(spacing: 8) {
            // Seek bar
            Slider(
                value: Binding(
                    get: { engine.currentTime },
                    set: { engine.seek(to: $0) }
                ),
                in: 0...max(engine.duration, 0.01)
            )
            .tint(.white.opacity(0.7))

            HStack {
                // Play/Pause
                Button(action: engine.togglePlayPause) {
                    Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                        .font(.title2)
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.space, modifiers: [])

                Spacer()

                // Time display
                Text("\(formatTime(engine.currentTime)) / \(formatTime(engine.duration))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
