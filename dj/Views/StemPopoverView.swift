import SwiftUI

struct StemPopoverView: View {
    let clip: Clip
    let onVolumeChange: (String, Float) -> Void
    let onMuteToggle: (String) -> Void
    let onSoloToggle: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(clip.name)
                .font(.system(.caption, weight: .semibold))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)

            Divider()

            ForEach(StemTrack.allStems) { stem in
                let state = clip.stemStates[stem.id] ?? StemState()
                stemRow(stem: stem, state: state)
            }
        }
        .padding(14)
        .frame(width: 280)
    }

    @ViewBuilder
    private func stemRow(stem: StemTrack, state: StemState) -> some View {
        HStack(spacing: 8) {
            Circle().fill(stem.color).frame(width: 8, height: 8)

            Text(stem.name)
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .frame(width: 52, alignment: .leading)
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
                    .font(.system(.caption2, design: .monospaced, weight: .bold))
                    .frame(width: 22, height: 22)
                    .background(state.isMuted ? Color.red.opacity(0.8) : Color.secondary.opacity(0.15))
                    .foregroundStyle(state.isMuted ? .white : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)

            Button(action: { onSoloToggle(stem.id) }) {
                Text("S")
                    .font(.system(.caption2, design: .monospaced, weight: .bold))
                    .frame(width: 22, height: 22)
                    .background(state.isSoloed ? Color.yellow.opacity(0.85) : Color.secondary.opacity(0.15))
                    .foregroundStyle(state.isSoloed ? .black : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
        }
    }
}
