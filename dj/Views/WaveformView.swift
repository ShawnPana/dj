import SwiftUI
import AVFoundation

struct WaveformData: Equatable {
    let samples: [Float]  // original track waveform
    let stemSamples: [String: [Float]]  // per-stem waveforms

    static let empty = WaveformData(samples: [], stemSamples: [:])
}

// MARK: - Overview waveform

struct OverviewWaveformView: View {
    let waveformData: WaveformData
    let stemVolumes: [String: Float]  // effective volumes (0 = muted/not active)
    let isUsingStemPlayback: Bool
    let currentTime: TimeInterval
    let duration: TimeInterval
    let processedFraction: Double
    let isFullyLoaded: Bool
    let onSeek: (TimeInterval) -> Void

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height

            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.white.opacity(0.05))

                OverviewWaveformCanvas(
                    waveformData: waveformData,
                    stemVolumes: stemVolumes,
                    isUsingStemPlayback: isUsingStemPlayback
                )

                // Playhead
                if duration > 0 {
                    Rectangle()
                        .fill(Color.white)
                        .frame(width: 2, height: h)
                        .offset(x: w * (currentTime / duration))
                        .shadow(color: .white.opacity(0.4), radius: 2)
                        .allowsHitTesting(false)
                }

                // Processing frontier line
                if !isFullyLoaded {
                    Rectangle()
                        .fill(Color.orange.opacity(0.9))
                        .frame(width: 1.5, height: h)
                        .offset(x: w * processedFraction)
                        .allowsHitTesting(false)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { value in
                        let fraction = max(0, min(1, value.location.x / w))
                        onSeek(fraction * duration)
                    }
            )
        }
    }
}

struct OverviewWaveformCanvas: View {
    let waveformData: WaveformData
    let stemVolumes: [String: Float]
    let isUsingStemPlayback: Bool

    var body: some View {
        Canvas { context, size in
            let midY = size.height / 2

            if isUsingStemPlayback && !waveformData.stemSamples.isEmpty {
                // Stem mode — only draw stems that are actually playing
                let layers: [(String, Color, Double)] = [
                    ("other", .orange, 0.4),
                    ("bass", .blue, 0.5),
                    ("drums", .red, 0.6),
                    ("vocals", .green, 0.7),
                ]

                for (stemId, color, baseOpacity) in layers {
                    guard let samples = waveformData.stemSamples[stemId], !samples.isEmpty else { continue }
                    let vol = CGFloat(stemVolumes[stemId] ?? 0)
                    guard vol > 0.001 else { continue }

                    let count = samples.count
                    let barWidth = max(1, size.width / CGFloat(count))

                    var path = Path()
                    for i in 0..<count {
                        let amp = CGFloat(samples[i]) * vol
                        guard amp > 0.001 else { continue }
                        let x = CGFloat(i) / CGFloat(count) * size.width
                        let barHeight = amp * midY * 0.9
                        path.addRect(CGRect(x: x, y: midY - barHeight, width: barWidth, height: barHeight * 2))
                    }
                    context.fill(path, with: .color(color.opacity(baseOpacity)))
                }
            } else {
                // Original mode — show the full track waveform in white
                let samples = waveformData.samples
                guard !samples.isEmpty else { return }
                let count = samples.count
                let barWidth = max(1, size.width / CGFloat(count))

                var path = Path()
                for i in 0..<count {
                    let amp = CGFloat(samples[i])
                    guard amp > 0.001 else { continue }
                    let x = CGFloat(i) / CGFloat(count) * size.width
                    let barHeight = amp * midY * 0.9
                    path.addRect(CGRect(x: x, y: midY - barHeight, width: barWidth, height: barHeight * 2))
                }
                context.fill(path, with: .color(Color.white.opacity(0.4)))
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Per-stem mini waveform

struct StemWaveformView: View {
    let samples: [Float]
    let color: Color
    let volume: Float

    var body: some View {
        Canvas { context, size in
            let count = samples.count
            guard count > 0 else { return }

            let midY = size.height / 2
            let barWidth = max(0.5, size.width / CGFloat(count))
            let vol = CGFloat(volume)

            var path = Path()
            for i in 0..<count {
                let amp = CGFloat(samples[i]) * vol
                guard amp > 0.001 else { continue }
                let x = CGFloat(i) / CGFloat(count) * size.width
                let barHeight = amp * midY * 0.85
                path.addRect(CGRect(x: x, y: midY - barHeight, width: barWidth, height: barHeight * 2))
            }
            context.fill(path, with: .color(color.opacity(0.5)))
        }
        .allowsHitTesting(false)
    }
}
