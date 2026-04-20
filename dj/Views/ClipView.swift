import SwiftUI
import AppKit

/// Invisible overlay that forwards right-clicks to a callback while letting
/// all other mouse events pass through to SwiftUI underneath.
private struct RightClickCatcher: NSViewRepresentable {
    let onRightClick: () -> Void

    func makeNSView(context: Context) -> RightClickNSView {
        let v = RightClickNSView()
        v.onRightClick = onRightClick
        return v
    }
    func updateNSView(_ view: RightClickNSView, context: Context) {
        view.onRightClick = onRightClick
    }
}

private final class RightClickNSView: NSView {
    var onRightClick: (() -> Void)?

    override func hitTest(_ point: NSPoint) -> NSView? {
        // Only claim the hit for right-click events; pass everything else through.
        guard let event = NSApp.currentEvent else { return nil }
        switch event.type {
        case .rightMouseDown, .rightMouseUp, .rightMouseDragged:
            return super.hitTest(point)
        default:
            return nil
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        onRightClick?()
    }
}

struct ClipView: View {
    let clip: Clip
    let currentTime: TimeInterval
    let isPlaying: Bool
    let canMove: Bool
    let pixelsPerSecond: Double
    let onMoveBy: (TimeInterval) -> Void
    let onSetLoop: (TimeInterval, TimeInterval) -> Void
    let onSetAnchor: (TimeInterval) -> Void
    let onSeekLocal: (TimeInterval) -> Void
    let onToggleClipMute: () -> Void
    let onVolumeChange: (String, Float) -> Void
    let onMuteToggle: (String) -> Void
    let onSoloToggle: (String) -> Void

    @State private var showingPopover = false
    @State private var dragDelta: CGFloat = 0
    @State private var isLoopDrag: Bool = false
    @State private var loopDragStartX: CGFloat?
    @State private var loopDragCurrentX: CGFloat?

    @Environment(\.uiScale) private var uiScale

    var body: some View {
        let stemVolumes = effectiveVolumes()
        let isStemMix = clip.anyTweaked
        let accent = accentColor()

        ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: 4)
                .fill(accent.opacity(0.22))
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .strokeBorder(accent.opacity(0.6), lineWidth: 1)
                )

            OverviewWaveformCanvas(
                waveformData: clip.waveform,
                stemVolumes: stemVolumes,
                isUsingStemPlayback: isStemMix
            )
            .padding(.top, 14 * uiScale)
            .padding(.horizontal, 2 * uiScale)
            .padding(.bottom, 2 * uiScale)

            beatTicksOverlay
                .padding(.top, 14 * uiScale)
                .padding(.horizontal, 2 * uiScale)
                .padding(.bottom, 2 * uiScale)

            loopOverlay
                .padding(.horizontal, 2 * uiScale)

            playheadOverlay
                .padding(.horizontal, 2 * uiScale)

            separationOverlay

            HStack(spacing: 4 * uiScale) {
                Text(clip.name)
                    .font(.system(size: 10 * uiScale, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(.white.opacity(0.9))
                separationBadge
            }
            .padding(.horizontal, 5 * uiScale)
            .padding(.vertical, 1 * uiScale)
            .background(accent.opacity(0.75), in: RoundedRectangle(cornerRadius: 2))
            .padding(3 * uiScale)
        }
        .offset(x: dragDelta)
        .contentShape(Rectangle())
        .overlay(RightClickCatcher(onRightClick: { showingPopover = true }))
        .popover(isPresented: $showingPopover, arrowEdge: .bottom) {
            StemPopoverView(
                clip: clip,
                onToggleClipMute: onToggleClipMute,
                onVolumeChange: onVolumeChange,
                onMuteToggle: onMuteToggle,
                onSoloToggle: onSoloToggle
            )
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { value in
                    let dx = abs(value.translation.width)
                    let dy = abs(value.translation.height)
                    guard dx > 4 || dy > 4 else { return }
                    if loopDragStartX == nil && !isLoopDrag && NSEvent.modifierFlags.contains(.shift) {
                        isLoopDrag = true
                        loopDragStartX = value.startLocation.x
                    }
                    if isLoopDrag {
                        loopDragCurrentX = value.location.x
                    } else if canMove && !NSEvent.modifierFlags.contains(.option) {
                        dragDelta = value.translation.width
                    }
                }
                .onEnded { value in
                    defer {
                        isLoopDrag = false
                        loopDragStartX = nil
                        loopDragCurrentX = nil
                        dragDelta = 0
                    }
                    let dx = abs(value.translation.width)
                    let dy = abs(value.translation.height)
                    let isClick = dx < 4 && dy < 4

                    if isClick {
                        let local = Double(value.location.x - 2) / pixelsPerSecond
                        let clamped = max(0, min(clip.duration, local))
                        if NSEvent.modifierFlags.contains(.option) {
                            onSetAnchor(clamped)
                        } else {
                            onSeekLocal(clamped)
                        }
                        return
                    }

                    if isLoopDrag, let startX = loopDragStartX {
                        let endX = value.location.x
                        let startSec = Double(min(startX, endX) - 2) / pixelsPerSecond
                        let endSec = Double(max(startX, endX) - 2) / pixelsPerSecond
                        if endSec - startSec > 0.05 {
                            onSetLoop(max(0, startSec), min(clip.duration, endSec))
                        }
                    } else if canMove {
                        let deltaSeconds = Double(value.translation.width) / pixelsPerSecond
                        onMoveBy(deltaSeconds)
                    }
                }
        )
    }

    /// Where, in clip-local seconds, the audio on this clip is currently rendering.
    /// Accounts for per-clip loop wrap. Returns nil if clip hasn't started or has ended.
    private var clipLocalPlayhead: TimeInterval? {
        guard clip.duration > 0 else { return nil }
        let rel = currentTime - clip.timelineStart
        guard rel >= 0 else { return nil }
        if clip.hasLoop {
            let loopLen = clip.loopEnd - clip.loopStart
            guard loopLen > 0 else { return nil }
            if rel < clip.loopEnd {
                return rel
            } else {
                let phase = (rel - clip.loopEnd).truncatingRemainder(dividingBy: loopLen)
                return clip.loopStart + phase
            }
        } else {
            return rel < clip.duration ? rel : nil
        }
    }

    @ViewBuilder
    private var playheadOverlay: some View {
        GeometryReader { geo in
            if let t = clipLocalPlayhead {
                let x = geo.size.width * CGFloat(t / clip.duration)
                Rectangle()
                    .fill(Color.white.opacity(isPlaying ? 0.95 : 0.5))
                    .frame(width: 2, height: geo.size.height)
                    .offset(x: x)
                    .shadow(color: .white.opacity(0.4), radius: 1)
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var loopOverlay: some View {
        GeometryReader { geo in
            ZStack(alignment: .topLeading) {
                if clip.duration > 0 && clip.loopEnd > clip.loopStart {
                    let xStart = geo.size.width * CGFloat(clip.loopStart / clip.duration)
                    let xEnd = geo.size.width * CGFloat(clip.loopEnd / clip.duration)
                    let bandColor: Color = clip.loopEnabled ? .orange : .white
                    Rectangle()
                        .fill(bandColor.opacity(clip.loopEnabled ? 0.18 : 0.08))
                        .frame(width: max(1, xEnd - xStart), height: geo.size.height)
                        .offset(x: xStart)
                    Rectangle()
                        .fill(bandColor.opacity(0.85))
                        .frame(width: 1.5, height: geo.size.height)
                        .offset(x: xStart)
                    Rectangle()
                        .fill(bandColor.opacity(0.85))
                        .frame(width: 1.5, height: geo.size.height)
                        .offset(x: xEnd - 1.5)
                }

                if let startX = loopDragStartX, let curX = loopDragCurrentX {
                    let lo = min(startX, curX) - 2
                    let hi = max(startX, curX) - 2
                    Rectangle()
                        .fill(Color.orange.opacity(0.3))
                        .frame(width: max(1, hi - lo), height: geo.size.height)
                        .offset(x: lo)
                }
            }
        }
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var beatTicksOverlay: some View {
        if let grid = clip.beatGrid, clip.duration > 0, !grid.beats.isEmpty {
            Canvas { context, size in
                let d = clip.duration
                let downbeatKeys = Set(grid.downbeats.map { ($0 * 1000).rounded() })

                for t in grid.beats {
                    guard t >= 0, t <= d else { continue }
                    let x = size.width * CGFloat(t / d)
                    let isDownbeat = downbeatKeys.contains((t * 1000).rounded())
                    var path = Path()
                    let topY: CGFloat = isDownbeat ? 0 : size.height * 0.3
                    path.move(to: CGPoint(x: x, y: topY))
                    path.addLine(to: CGPoint(x: x, y: size.height))
                    let color: Color = isDownbeat ? .white.opacity(0.85) : .white.opacity(0.3)
                    context.stroke(path,
                                   with: .color(color),
                                   lineWidth: isDownbeat ? 1.2 : 0.6)
                }
            }
            .allowsHitTesting(false)
        }
    }

    @ViewBuilder
    private var separationOverlay: some View {
        switch clip.separation {
        case .processing(let done, let total) where total > 0:
            GeometryReader { geo in
                HStack(spacing: 0) {
                    Rectangle()
                        .fill(Color.orange.opacity(0.12))
                        .frame(width: geo.size.width * Double(done) / Double(total))
                    Spacer(minLength: 0)
                }
            }
            .allowsHitTesting(false)
        case .preparing:
            Rectangle()
                .fill(Color.orange.opacity(0.08))
                .allowsHitTesting(false)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var separationBadge: some View {
        switch clip.separation {
        case .processing(let done, let total) where total > 0:
            Text("\(done)/\(total)")
                .font(.system(size: 9 * uiScale, weight: .bold, design: .monospaced))
                .foregroundStyle(.orange)
        case .preparing:
            Text("prep")
                .font(.system(size: 9 * uiScale, weight: .bold, design: .monospaced))
                .foregroundStyle(.orange)
        case .error:
            Text("!")
                .font(.system(size: 9 * uiScale, weight: .bold, design: .monospaced))
                .foregroundStyle(.red)
        default:
            EmptyView()
        }
    }

    private func effectiveVolumes() -> [String: Float] {
        let tweaked = clip.anyTweaked
        let anySoloed = clip.anySoloed
        var out: [String: Float] = [:]
        for id in Clip.defaultStemIDs {
            let s = clip.stemStates[id] ?? StemState()
            let v: Float
            if !tweaked { v = 0 }
            else if s.isMuted { v = 0 }
            else if anySoloed && !s.isSoloed { v = 0 }
            else { v = s.volume }
            out[id] = v
        }
        return out
    }

    private func accentColor() -> Color {
        if !clip.anyTweaked { return Color.accentColor }
        let anySoloed = clip.anySoloed
        for stem in StemTrack.allStems {
            guard let s = clip.stemStates[stem.id] else { continue }
            let active = !s.isMuted && (!anySoloed || s.isSoloed) && s.volume > 0.01
            if active { return stem.color }
        }
        return Color.accentColor
    }
}
