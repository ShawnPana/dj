import SwiftUI

struct TimelineRulerView: View {
    let pixelsPerSecond: Double
    let rulerWidth: CGFloat

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.white.opacity(0.05)
            ticksCanvas
        }
        .frame(width: rulerWidth, height: TrackLayout.rulerHeight)
    }

    private var ticksCanvas: some View {
        Canvas { context, size in
            let labelEvery = tickLabelInterval()
            let minorEvery = max(0.1, labelEvery / 5)
            let maxTime = Double(size.width) / pixelsPerSecond

            var t: Double = 0
            let epsilon = minorEvery / 2
            while t <= maxTime + 0.001 {
                let x = t * pixelsPerSecond
                let isLabel = t.truncatingRemainder(dividingBy: labelEvery) < epsilon ||
                              labelEvery - t.truncatingRemainder(dividingBy: labelEvery) < epsilon
                let tickH = isLabel ? size.height * 0.55 : size.height * 0.28
                var path = Path()
                path.move(to: CGPoint(x: x, y: size.height - tickH))
                path.addLine(to: CGPoint(x: x, y: size.height))
                context.stroke(path, with: .color(.white.opacity(isLabel ? 0.55 : 0.22)), lineWidth: 1)

                if isLabel {
                    let txt = Text(formatTime(t))
                        .font(.system(size: 9, design: .monospaced))
                        .foregroundColor(.white.opacity(0.65))
                    context.draw(txt, at: CGPoint(x: x + 3, y: 2), anchor: .topLeading)
                }
                t += minorEvery
            }
        }
        .allowsHitTesting(false)
    }

    private func tickLabelInterval() -> Double {
        if pixelsPerSecond >= 40 { return 1 }
        if pixelsPerSecond >= 15 { return 5 }
        if pixelsPerSecond >= 5 { return 10 }
        return 30
    }

    private func formatTime(_ t: Double) -> String {
        let m = Int(t) / 60
        let s = Int(t) % 60
        return String(format: "%d:%02d", m, s)
    }
}
