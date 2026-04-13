import SwiftUI

struct ContentView: View {
    @StateObject private var separator = StemSeparator()
    @StateObject private var engine = AudioEngineManager()
    @State private var serverReady = false
    @State private var loadedFileName: String?
    @State private var loadedFileURL: URL?
    @State private var lastAppendedChunk = 0

    var body: some View {
        ZStack {
            Color.black.opacity(0.95)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                if !serverReady {
                    launchingView
                } else if loadedFileName != nil {
                    playerView
                } else {
                    DropZoneView { url in
                        loadFile(url: url)
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .task {
            await separator.waitForServer()
            serverReady = true
        }
        // Append stem chunks as they arrive
        .onChange(of: separator.chunksDone) {
            guard let hash = separator.currentFileHash else { return }
            let newChunks = separator.chunksDone
            if newChunks > lastAppendedChunk {
                engine.appendStemChunks(fileHash: hash, upToChunk: newChunks)
                lastAppendedChunk = newChunks
            }
        }
        // When fully done, load concatenated stems
        .onChange(of: separator.allDone) {
            guard separator.allDone, let hash = separator.currentFileHash else { return }
            engine.loadFullStems(fileHash: hash)
        }
    }

    // MARK: - Views

    private var launchingView: some View {
        VStack(spacing: 12) {
            ProgressView()
            Text("Starting stem engine...")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var playerView: some View {
        VStack(spacing: 0) {
            headerBar
                .padding(.top, 8)
                .padding(.bottom, 4)

            // Overview waveform
            OverviewWaveformView(
                waveformData: engine.waveformData,
                stemVolumes: engine.effectiveVolumes,
                isUsingStemPlayback: engine.usingStemPlayback,
                currentTime: engine.currentTime,
                duration: engine.duration,
                processedFraction: stemProcessedFraction,
                isFullyLoaded: separator.allDone,
                onSeek: { engine.seek(to: $0) }
            )
            .frame(height: 80)
            .padding(.horizontal, 16)
            .padding(.vertical, 6)

            // Transport
            transportBar
                .padding(.horizontal, 16)
                .padding(.bottom, 6)

            Divider().padding(.horizontal, 16)

            // Stem controls
            VStack(spacing: 0) {
                ForEach(engine.stems) { stem in
                    StemControlView(
                        stem: stem,
                        waveformSamples: engine.waveformData.stemSamples[stem.id] ?? [],
                        effectiveVolume: engine.effectiveVolumes[stem.id] ?? 1.0,
                        playbackFraction: engine.duration > 0 ? engine.currentTime / engine.duration : 0,
                        onVolumeChange: { engine.setVolume(for: stem.id, volume: $0) },
                        onMuteToggle: { engine.toggleMute(for: stem.id) },
                        onSoloToggle: { engine.toggleSolo(for: stem.id) }
                    )
                }
            }
            .padding(.vertical, 8)

            Spacer()

            bottomBar
        }
    }

    private var headerBar: some View {
        HStack(spacing: 8) {
            if let name = loadedFileName {
                Text(name)
                    .font(.system(.subheadline, weight: .semibold))
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            Spacer()

            // Status
            if engine.stemsFullyReady {
                HStack(spacing: 4) {
                    Circle().fill(Color.green).frame(width: 6, height: 6)
                    Text("Stems Ready")
                        .font(.system(.caption2, weight: .medium))
                        .foregroundStyle(.green)
                }
            } else if separator.state == .processing || separator.state == .preparing {
                HStack(spacing: 4) {
                    ProgressView().controlSize(.mini)
                    if separator.chunksTotal > 0 {
                        Text("Stems \(separator.chunksDone)/\(separator.chunksTotal)")
                            .font(.system(.caption2, design: .monospaced, weight: .medium))
                            .foregroundStyle(.orange)
                    } else {
                        Text("Preparing stems...")
                            .font(.system(.caption2, weight: .medium))
                            .foregroundStyle(.orange)
                    }
                }
            }

            Button {
                engine.stop()
                loadedFileName = nil
                loadedFileURL = nil
                separator.cancel()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 16)
    }

    private var transportBar: some View {
        HStack(spacing: 12) {
            Button(action: engine.togglePlayPause) {
                Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                    .font(.system(size: 18))
                    .frame(width: 32, height: 32)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.space, modifiers: [])

            Button(action: engine.stop) {
                Image(systemName: "stop.fill")
                    .font(.system(size: 14))
                    .frame(width: 28, height: 28)
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)

            Spacer()

            // Playback mode indicator
            if engine.usingStemPlayback {
                Text("STEMS")
                    .font(.system(.caption2, design: .monospaced, weight: .bold))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.orange.opacity(0.15), in: RoundedRectangle(cornerRadius: 3))
            }

            HStack(spacing: 2) {
                Text(formatTime(engine.currentTime))
                    .foregroundStyle(.white)
                Text("/")
                    .foregroundStyle(.secondary)
                Text(formatTime(engine.duration))
                    .foregroundStyle(.secondary)
            }
            .font(.system(.caption, design: .monospaced, weight: .medium))
        }
    }

    private var bottomBar: some View {
        HStack {
            Spacer()
            Button {
                exportStems()
            } label: {
                Label("Export", systemImage: "square.and.arrow.up")
                    .font(.caption)
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .disabled(!engine.stemsFullyReady)
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    // MARK: - Computed

    private var stemProcessedFraction: Double {
        guard separator.chunksTotal > 0 else { return separator.allDone ? 1.0 : 0.0 }
        return Double(separator.chunksDone) / Double(separator.chunksTotal)
    }

    // MARK: - Actions

    private func loadFile(url: URL) {
        loadedFileName = url.lastPathComponent
        loadedFileURL = url
        lastAppendedChunk = 0

        // Load original track immediately — instant playback
        do {
            try engine.loadOriginal(url: url)
        } catch {
            print("Failed to load original: \(error)")
            return
        }

        // Kick off stem separation in background
        Task { await separator.separate(fileURL: url) }
    }

    private func exportStems() {
        guard let hash = separator.currentFileHash,
              let urls = CacheManager.shared.stemURLs(for: hash)
        else { return }

        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.prompt = "Export Here"

        guard panel.runModal() == .OK, let exportDir = panel.url else { return }

        for (stem, sourceURL) in urls {
            let destURL = exportDir.appendingPathComponent("\(stem).wav")
            try? FileManager.default.copyItem(at: sourceURL, to: destURL)
        }
    }

    private func formatTime(_ time: TimeInterval) -> String {
        let minutes = Int(time) / 60
        let seconds = Int(time) % 60
        return String(format: "%d:%02d", minutes, seconds)
    }
}
