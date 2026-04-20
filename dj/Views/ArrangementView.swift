import SwiftUI
import UniformTypeIdentifiers

struct ArrangementView: View {
    @ObservedObject var engine: ArrangementEngine
    let onAddFile: (URL) -> Void

    @State private var pixelsPerSecond: Double = 20
    @State private var zoomBase: Double?
    @Environment(\.uiScale) private var uiScale

    private static let minPPS: Double = 4
    private static let maxPPS: Double = 400

    private var timelineWidth: CGFloat {
        let minWidth: Double = 1200
        let contentWidth = engine.duration * pixelsPerSecond + 80
        return CGFloat(max(minWidth, contentWidth))
    }

    var body: some View {
        VStack(spacing: 0) {
            transportBar
            Divider()

            if engine.clips.isEmpty {
                DropZoneView(onDrop: onAddFile)
            } else {
                arrangementLayout
            }
        }
        .background(Color.black.opacity(0.95))
    }

    // MARK: - Transport

    private var transportBar: some View {
        HStack(spacing: 10 * uiScale) {
            Button(action: engine.togglePlayPause) {
                Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 16 * uiScale))
                    .frame(width: 30 * uiScale, height: 26 * uiScale)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])

            Button(action: engine.stop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 12 * uiScale))
                    .frame(width: 24 * uiScale, height: 22 * uiScale)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            timeReadout

            Spacer()

            editLockButton

            Text(engine.editUnlocked
                 ? "click = seek · right-click = menu · shift+drag = loop · opt+click = anchor · drag = move"
                 : "click = seek · right-click = menu · shift+drag = loop · opt+click = anchor · unlock to move")
                .font(.system(size: 10 * uiScale))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, 12 * uiScale)
        .padding(.vertical, 8 * uiScale)
    }

    private var editLockButton: some View {
        Button {
            engine.editUnlocked.toggle()
        } label: {
            HStack(spacing: 4 * uiScale) {
                Image(systemName: engine.editUnlocked ? "lock.open.fill" : "lock.fill")
                    .font(.system(size: 11 * uiScale))
                Text(engine.editUnlocked ? "EDIT" : "LOCKED")
                    .font(.system(size: 10 * uiScale, weight: .bold, design: .monospaced))
            }
            .padding(.horizontal, 8 * uiScale)
            .padding(.vertical, 4 * uiScale)
            .background(
                engine.editUnlocked ? Color.yellow.opacity(0.85) : Color.secondary.opacity(0.15),
                in: RoundedRectangle(cornerRadius: 3)
            )
            .foregroundStyle(engine.editUnlocked ? .black : .primary)
        }
        .buttonStyle(.plain)
    }

    private var timeReadout: some View {
        HStack(spacing: 2 * uiScale) {
            Text(formatTime(engine.currentTime))
                .foregroundStyle(.white)
            Text("/")
                .foregroundStyle(.secondary)
            Text(formatTime(engine.duration))
                .foregroundStyle(.secondary)
        }
        .font(.system(size: 12 * uiScale, weight: .medium, design: .monospaced))
    }

    // MARK: - Arrangement

    private var arrangementLayout: some View {
        HStack(alignment: .top, spacing: 0) {
            // Left: fixed header column
            VStack(spacing: 0) {
                Color.clear
                    .frame(width: TrackLayout.headerWidth(uiScale),
                           height: TrackLayout.rulerHeight(uiScale))
                    .overlay(alignment: .trailing) { Divider().opacity(0.25) }
                    .overlay(alignment: .bottom) { Divider().opacity(0.25) }

                ForEach(engine.clips) { clip in
                    TrackHeaderView(
                        clip: clip,
                        onRemove: { engine.removeClip(id: clip.id) },
                        onToggleLoop: { engine.toggleClipLoop(clipID: clip.id) },
                        onClearLoop: { engine.clearClipLoop(clipID: clip.id) }
                    )
                }

                addTrackHeader
                Spacer(minLength: 0)
            }

            // Right: scrollable timeline column.
            // Pinch to zoom the timeline horizontally — pixelsPerSecond scales from the
            // baseline captured at gesture start, clamped to [minPPS, maxPPS].
            ScrollView(.horizontal, showsIndicators: true) {
                VStack(alignment: .leading, spacing: 0) {
                    TimelineRulerView(
                        pixelsPerSecond: pixelsPerSecond,
                        rulerWidth: timelineWidth
                    )
                    .overlay(alignment: .bottom) { Divider().opacity(0.25) }

                    ForEach(engine.clips) { clip in
                        TrackLaneView(
                            clip: clip,
                            currentTime: engine.currentTime,
                            isPlaying: engine.isPlaying,
                            canMove: engine.editUnlocked,
                            pixelsPerSecond: pixelsPerSecond,
                            laneWidth: timelineWidth,
                            onMove: { engine.moveClip(id: clip.id, to: $0) },
                            onSetLoop: { engine.setClipLoop(clipID: clip.id, start: $0, end: $1) },
                            onSetAnchor: { engine.setClipAnchor(clipID: clip.id, clipLocalTime: $0) },
                            onSeekLocal: { engine.seek(to: clip.timelineStart + $0) },
                            onToggleClipMute: { engine.toggleClipMute(clipID: clip.id) },
                            onVolumeChange: { engine.setVolume(clipID: clip.id, stemID: $0, volume: $1) },
                            onMuteToggle: { engine.toggleMute(clipID: clip.id, stemID: $0) },
                            onSoloToggle: { engine.toggleSolo(clipID: clip.id, stemID: $0) }
                        )
                    }

                    addTrackLane
                }
            }
            .onDrop(of: [.fileURL], isTargeted: nil) { providers in
                handleDrop(providers: providers)
            }
            .gesture(
                MagnifyGesture()
                    .onChanged { value in
                        if zoomBase == nil { zoomBase = pixelsPerSecond }
                        let base = zoomBase ?? pixelsPerSecond
                        pixelsPerSecond = max(Self.minPPS, min(Self.maxPPS, base * value.magnification))
                    }
                    .onEnded { _ in zoomBase = nil }
            )
        }
    }

    private var addTrackHeader: some View {
        Button {
            let panel = NSOpenPanel()
            panel.allowedContentTypes = [.audio, .mp3, .wav, .aiff]
            panel.allowsMultipleSelection = false
            if panel.runModal() == .OK, let url = panel.url {
                onAddFile(url)
            }
        } label: {
            VStack(spacing: 2 * uiScale) {
                Image(systemName: "plus")
                    .font(.system(size: 14 * uiScale, weight: .semibold))
                    .foregroundStyle(.secondary)
                Text("add track")
                    .font(.system(size: 9 * uiScale))
                    .foregroundStyle(.tertiary)
            }
            .frame(width: TrackLayout.headerWidth(uiScale),
                   height: TrackLayout.rowHeight(uiScale))
            .background(Color.white.opacity(0.02))
            .overlay(alignment: .trailing) { Divider().opacity(0.25) }
            .overlay(alignment: .bottom) { Divider().opacity(0.25) }
        }
        .buttonStyle(.plain)
    }

    private var addTrackLane: some View {
        Rectangle()
            .fill(Color.white.opacity(0.015))
            .frame(width: timelineWidth, height: TrackLayout.rowHeight(uiScale))
            .overlay(
                Text("drop audio anywhere to add a track")
                    .font(.system(size: 10 * uiScale))
                    .foregroundStyle(.tertiary)
            )
            .overlay(alignment: .bottom) { Divider().opacity(0.15) }
    }

    private func handleDrop(providers: [NSItemProvider]) -> Bool {
        guard let provider = providers.first else { return false }
        _ = provider.loadObject(ofClass: URL.self) { url, _ in
            if let url {
                DispatchQueue.main.async { onAddFile(url) }
            }
        }
        return true
    }

    private func formatTime(_ t: Double) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }
}
