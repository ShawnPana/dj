import SwiftUI

struct StemPopoverView: View {
    let clip: Clip
    let onToggleClipMute: () -> Void
    let onVolumeChange: (String, Float) -> Void
    let onMuteToggle: (String) -> Void
    let onSoloToggle: (String) -> Void

    @Environment(\.uiScale) private var uiScale

    var body: some View {
        VStack(alignment: .leading, spacing: 10 * uiScale) {
            HStack(spacing: 8 * uiScale) {
                Text(clip.name)
                    .font(.system(size: 11 * uiScale, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4 * uiScale)
                Button(action: onToggleClipMute) {
                    HStack(spacing: 3 * uiScale) {
                        Image(systemName: clip.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                            .font(.system(size: 10 * uiScale))
                        Text(clip.isMuted ? "MUTED" : "MUTE")
                            .font(.system(size: 10 * uiScale, weight: .bold, design: .monospaced))
                    }
                    .padding(.horizontal, 8 * uiScale)
                    .padding(.vertical, 3 * uiScale)
                    .background(
                        clip.isMuted ? Color.red.opacity(0.85) : Color.secondary.opacity(0.18),
                        in: RoundedRectangle(cornerRadius: 3)
                    )
                    .foregroundStyle(clip.isMuted ? .white : .primary)
                }
                .buttonStyle(.plain)
            }

            Divider()

            ForEach(StemTrack.allStems) { stem in
                let state = clip.stemStates[stem.id] ?? StemState()
                stemRow(stem: stem, state: state)
            }
        }
        .padding(14 * uiScale)
        .frame(width: 300 * uiScale)
    }

    @ViewBuilder
    private func stemRow(stem: StemTrack, state: StemState) -> some View {
        HStack(spacing: 8 * uiScale) {
            Circle().fill(stem.color).frame(width: 8 * uiScale, height: 8 * uiScale)

            Text(stem.name)
                .font(.system(size: 11 * uiScale, weight: .semibold, design: .rounded))
                .frame(width: 52 * uiScale, alignment: .leading)
                .foregroundStyle(state.isMuted ? .secondary : .primary)

            Slider(
                value: Binding(
                    get: { state.volume },
                    set: { onVolumeChange(stem.id, $0) }
                ),
                in: 0...1
            )
            .tint(stem.color)
            .disabled(state.isMuted)

            Button(action: { onMuteToggle(stem.id) }) {
                Text("M")
                    .font(.system(size: 10 * uiScale, weight: .bold, design: .monospaced))
                    .frame(width: 22 * uiScale, height: 22 * uiScale)
                    .background(state.isMuted ? Color.red.opacity(0.8) : Color.secondary.opacity(0.15))
                    .foregroundStyle(state.isMuted ? .white : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)

            Button(action: { onSoloToggle(stem.id) }) {
                Text("S")
                    .font(.system(size: 10 * uiScale, weight: .bold, design: .monospaced))
                    .frame(width: 22 * uiScale, height: 22 * uiScale)
                    .background(state.isSoloed ? Color.yellow.opacity(0.85) : Color.secondary.opacity(0.15))
                    .foregroundStyle(state.isSoloed ? .black : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
        }
    }
}
