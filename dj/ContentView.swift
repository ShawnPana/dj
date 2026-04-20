import SwiftUI

struct ContentView: View {
    @StateObject private var engine = ArrangementEngine()
    @StateObject private var separator = StemSeparator()
    @State private var serverReady = false
    @State private var wired = false
    @State private var uiScale: Double = 1.0

    private static let minScale: Double = 0.6
    private static let maxScale: Double = 2.0
    private static let scaleStep: Double = 0.1

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.opacity(0.95).ignoresSafeArea()

            GeometryReader { geo in
                Group {
                    if !serverReady {
                        launchingView
                    } else {
                        ArrangementView(engine: engine, onAddFile: addFile)
                    }
                }
                .frame(width: geo.size.width / uiScale,
                       height: geo.size.height / uiScale)
                .scaleEffect(uiScale, anchor: .topLeading)
            }

            // Invisible buttons capture Cmd+=, Cmd+-, Cmd+0 to drive uiScale.
            VStack(spacing: 0) {
                Button("") { uiScale = min(Self.maxScale, uiScale + Self.scaleStep) }
                    .keyboardShortcut("=", modifiers: .command)
                Button("") { uiScale = max(Self.minScale, uiScale - Self.scaleStep) }
                    .keyboardShortcut("-", modifiers: .command)
                Button("") { uiScale = 1.0 }
                    .keyboardShortcut("0", modifiers: .command)
            }
            .frame(width: 0, height: 0)
            .opacity(0)
        }
        .preferredColorScheme(.dark)
        .frame(minWidth: 720, minHeight: 440)
        .task {
            if !wired {
                wireCallbacks()
                wired = true
            }
            await separator.waitForServer()
            serverReady = separator.serverReady
        }
        .onChange(of: separator.progressByClip) {
            for (clipID, progress) in separator.progressByClip {
                engine.setSeparationProgress(clipID: clipID, progress: progress)
            }
        }
    }

    private var launchingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("starting stem engine…")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func wireCallbacks() {
        separator.onChunksDone = { clipID, chunksDone in
            engine.appendStemChunks(clipID: clipID, upToChunk: chunksDone)
        }
        separator.onFullStemsReady = { clipID in
            engine.loadFullStems(clipID: clipID)
            // Re-analyze beats on the drums stem for a sharper grid.
            if let clip = engine.clips.first(where: { $0.id == clipID }) {
                let drumsURL = CacheManager.shared.outputDir(for: clip.fileHash)
                    .appendingPathComponent("drums.wav")
                if FileManager.default.fileExists(atPath: drumsURL.path) {
                    Task {
                        if let grid = await separator.analyze(
                            fileURL: clip.url,
                            fileHash: clip.fileHash,
                            drumsURL: drumsURL
                        ) {
                            engine.setBeatGrid(clipID: clipID, grid: grid)
                        }
                    }
                }
            }
        }
    }

    private func addFile(url: URL) {
        do {
            let clipID = try engine.addClip(url: url)
            let hash = engine.clips.first(where: { $0.id == clipID })?.fileHash ?? ""
            separator.enqueue(clipID: clipID, fileURL: url, fileHash: hash)
            Task {
                if let grid = await separator.analyze(fileURL: url, fileHash: hash) {
                    engine.setBeatGrid(clipID: clipID, grid: grid)
                }
            }
        } catch {
            print("failed to add clip: \(error)")
        }
    }
}
