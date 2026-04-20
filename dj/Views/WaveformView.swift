import SwiftUI
import AVFoundation

struct WaveformSample: Equatable {
    let min: Float
    let max: Float
}

struct WaveformData: Equatable {
    let samples: [WaveformSample]
    let stemSamples: [String: [WaveformSample]]

    static let empty = WaveformData(samples: [], stemSamples: [:])
}

struct OverviewWaveformCanvas: View {
    let waveformData: WaveformData
    let stemVolumes: [String: Float]
    let isUsingStemPlayback: Bool

    var body: some View {
        Canvas { context, size in
            if isUsingStemPlayback && !waveformData.stemSamples.isEmpty {
                let layers: [(String, Color, Double)] = [
                    ("other", .orange, 0.55),
                    ("bass", .blue, 0.6),
                    ("drums", .red, 0.65),
                    ("vocals", .green, 0.7),
                ]
                for (stemId, color, baseOpacity) in layers {
                    guard let samples = waveformData.stemSamples[stemId], !samples.isEmpty else { continue }
                    let vol = CGFloat(stemVolumes[stemId] ?? 0)
                    guard vol > 0.001 else { continue }
                    if let path = filledPath(for: samples, size: size, scale: vol) {
                        context.fill(path, with: .color(color.opacity(baseOpacity)))
                    }
                }
            } else {
                guard !waveformData.samples.isEmpty else { return }
                if let path = filledPath(for: waveformData.samples, size: size, scale: 1.0) {
                    context.fill(path, with: .color(Color.white.opacity(0.55)))
                }
            }
        }
        .allowsHitTesting(false)
    }

    private func filledPath(for samples: [WaveformSample], size: CGSize, scale: CGFloat) -> Path? {
        let count = samples.count
        guard count > 1 else { return nil }
        let midY = size.height / 2
        let halfH = midY * 0.95

        var path = Path()
        path.move(to: CGPoint(x: 0, y: midY - CGFloat(samples[0].max) * halfH * scale))
        for i in 1..<count {
            let x = size.width * CGFloat(i) / CGFloat(count - 1)
            let y = midY - CGFloat(samples[i].max) * halfH * scale
            path.addLine(to: CGPoint(x: x, y: y))
        }
        for i in stride(from: count - 1, through: 0, by: -1) {
            let x = size.width * CGFloat(i) / CGFloat(count - 1)
            let y = midY - CGFloat(samples[i].min) * halfH * scale
            path.addLine(to: CGPoint(x: x, y: y))
        }
        path.closeSubpath()
        return path
    }
}
