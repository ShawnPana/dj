import SwiftUI

enum TrackLayout {
    static let headerWidth: CGFloat = 140
    static let rowHeight: CGFloat = 56
    static let rulerHeight: CGFloat = 28
}

struct TrackHeaderView: View {
    let clip: Clip
    let onRemove: () -> Void
    let onToggleLoop: () -> Void
    let onClearLoop: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 4) {
                Text(clip.name)
                    .font(.system(.caption2, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                loopButton
                Button(action: onRemove) {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }

            HStack(spacing: 6) {
                Text(formatDuration(clip.duration))
                    .font(.system(size: 9, design: .monospaced))
                    .foregroundStyle(.tertiary)
                if let bpm = clip.beatGrid?.bpm, bpm > 0 {
                    Text(String(format: "%.0f BPM", bpm))
                        .font(.system(size: 9, weight: .semibold, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.75))
                }
                separationBadge
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(width: TrackLayout.headerWidth, height: TrackLayout.rowHeight, alignment: .leading)
        .background(Color.white.opacity(0.04))
        .overlay(alignment: .trailing) {
            Divider().opacity(0.25)
        }
        .overlay(alignment: .bottom) {
            Divider().opacity(0.25)
        }
    }

    @ViewBuilder
    private var loopButton: some View {
        let hasRegion = clip.loopEnd > clip.loopStart
        if hasRegion {
            HStack(spacing: 2) {
                Button(action: onToggleLoop) {
                    Image(systemName: "repeat")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 18, height: 16)
                        .foregroundStyle(clip.loopEnabled ? .black : .secondary)
                        .background(
                            clip.loopEnabled ? Color.orange.opacity(0.85) : Color.secondary.opacity(0.18),
                            in: RoundedRectangle(cornerRadius: 3)
                        )
                }
                .buttonStyle(.plain)
                Button(action: onClearLoop) {
                    Image(systemName: "xmark")
                        .font(.system(size: 9))
                        .frame(width: 14, height: 16)
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
        }
    }

    @ViewBuilder
    private var separationBadge: some View {
        switch clip.separation {
        case .processing(let done, let total) where total > 0:
            Text("\(done)/\(total)")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.orange)
        case .preparing:
            Text("prep")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.orange)
        case .ready:
            HStack(spacing: 3) {
                Circle().fill(Color.green).frame(width: 5, height: 5)
                Text("stems")
                    .font(.system(size: 9, weight: .semibold, design: .monospaced))
                    .foregroundStyle(.green.opacity(0.8))
            }
        case .error:
            Text("error")
                .font(.system(size: 9, weight: .bold, design: .monospaced))
                .foregroundStyle(.red)
        default:
            EmptyView()
        }
    }

    private func formatDuration(_ d: TimeInterval) -> String {
        let m = Int(d) / 60
        let s = Int(d) % 60
        return String(format: "%d:%02d", m, s)
    }
}

struct TrackLaneView: View {
    let clip: Clip
    let currentTime: TimeInterval
    let isPlaying: Bool
    let canMove: Bool
    let pixelsPerSecond: Double
    let laneWidth: CGFloat

    let onMove: (TimeInterval) -> Void
    let onSetLoop: (TimeInterval, TimeInterval) -> Void
    let onSetAnchor: (TimeInterval) -> Void
    let onVolumeChange: (String, Float) -> Void
    let onMuteToggle: (String) -> Void
    let onSoloToggle: (String) -> Void

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.white.opacity(0.015)

            ClipView(
                clip: clip,
                currentTime: currentTime,
                isPlaying: isPlaying,
                canMove: canMove,
                pixelsPerSecond: pixelsPerSecond,
                onMoveBy: { delta in
                    onMove(max(0, clip.timelineStart + delta))
                },
                onSetLoop: onSetLoop,
                onSetAnchor: onSetAnchor,
                onVolumeChange: onVolumeChange,
                onMuteToggle: onMuteToggle,
                onSoloToggle: onSoloToggle
            )
            .frame(width: max(40, CGFloat(clip.duration * pixelsPerSecond)),
                   height: TrackLayout.rowHeight - 8)
            .offset(x: CGFloat(clip.timelineStart * pixelsPerSecond), y: 4)
        }
        .frame(width: laneWidth, height: TrackLayout.rowHeight, alignment: .leading)
        .overlay(alignment: .bottom) {
            Divider().opacity(0.15)
        }
    }
}
