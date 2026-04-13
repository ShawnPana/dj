import SwiftUI

struct ProgressOverlayView: View {
    let chunksDone: Int
    let chunksTotal: Int
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            if chunksTotal > 0 {
                ProgressView(value: Double(chunksDone), total: Double(chunksTotal))
                    .frame(width: 200)

                Text("Separating stems... \(chunksDone)/\(chunksTotal)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                Text("Preparing...")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Cancel", action: onCancel)
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(32)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }
}
