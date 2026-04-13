import SwiftUI

struct StemControlView: View {
    let stem: StemTrack
    let waveformSamples: [Float]
    let effectiveVolume: Float  // 0..1, accounts for mute/solo
    let playbackFraction: Double  // 0..1
    let onVolumeChange: (Float) -> Void
    let onMuteToggle: () -> Void
    let onSoloToggle: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            // Stem name
            Text(stem.name)
                .font(.system(.caption, design: .rounded, weight: .semibold))
                .frame(width: 48, alignment: .leading)
                .foregroundStyle(stem.isMuted ? .secondary : stem.color)

            // Mini waveform with playhead overlay
            ZStack(alignment: .leading) {
                // Waveform scaled by effective volume
                StemWaveformView(samples: waveformSamples, color: stem.color, volume: 1.0)

                // Played portion tint overlay (cheap — just a colored rectangle)
                GeometryReader { geo in
                    stem.color.opacity(0.2)
                        .frame(width: geo.size.width * playbackFraction)
                        .allowsHitTesting(false)

                    // Playhead line
                    Rectangle()
                        .fill(stem.color.opacity(0.9))
                        .frame(width: 1.5)
                        .offset(x: geo.size.width * playbackFraction)
                        .allowsHitTesting(false)
                }
            }
            .frame(height: 32)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .opacity(stem.isMuted ? 0.2 : 1.0)

            // Volume slider
            Slider(
                value: Binding(
                    get: { stem.volume },
                    set: { onVolumeChange($0) }
                ),
                in: 0...1
            )
            .tint(stem.color)
            .frame(width: 80)
            .opacity(stem.isMuted ? 0.4 : 1.0)

            // Mute button
            Button(action: onMuteToggle) {
                Text("M")
                    .font(.system(.caption2, design: .monospaced, weight: .bold))
                    .frame(width: 24, height: 24)
                    .background(stem.isMuted ? Color.red.opacity(0.8) : Color.secondary.opacity(0.15))
                    .foregroundStyle(stem.isMuted ? .white : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)

            // Solo button
            Button(action: onSoloToggle) {
                Text("S")
                    .font(.system(.caption2, design: .monospaced, weight: .bold))
                    .frame(width: 24, height: 24)
                    .background(stem.isSoloed ? Color.yellow.opacity(0.8) : Color.secondary.opacity(0.15))
                    .foregroundStyle(stem.isSoloed ? .black : .primary)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 2)
    }
}
