import AVFoundation
import Foundation

@MainActor
class AudioEngineManager: ObservableObject {
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    @Published var duration: TimeInterval = 0
    @Published var stems: [StemTrack] = StemTrack.allStems
    @Published var waveformData: WaveformData = .empty
    @Published var effectiveVolumes: [String: Float] = ["drums": 1, "bass": 1, "vocals": 1, "other": 1]
    @Published var stemsFullyReady = false
    @Published var stemsAvailable = false
    @Published var usingStemPlayback = false

    private let engine = AVAudioEngine()
    private var sampleRate: Double = 44100
    private var totalFrames: AVAudioFramePosition = 0
    private var seekFrame: AVAudioFramePosition = 0
    private var timer: Timer?

    // Original track — always playing
    private var originalPlayer: AVAudioPlayerNode?
    private var originalBuffer: AVAudioPCMBuffer?

    // Stem players — always playing alongside original
    private var stemPlayers: [String: AVAudioPlayerNode] = [:]
    private var stemChunkBuffers: [String: [AVAudioPCMBuffer]] = [:]
    private var stemFullBuffers: [String: AVAudioPCMBuffer] = [:]

    private var scheduledChunkCount = 0
    private var isEngineSetup = false

    var stemsTweaked: Bool {
        stems.contains { $0.isMuted || $0.isSoloed || $0.volume < 0.99 }
    }

    // MARK: - Load original (instant)

    func loadOriginal(url: URL) throws {
        reset()

        let file = try AVAudioFile(forReading: url)
        sampleRate = file.processingFormat.sampleRate
        totalFrames = file.length
        duration = Double(totalFrames) / sampleRate

        let player = AVAudioPlayerNode()
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: file.processingFormat)

        let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
        try file.read(into: buffer)

        originalPlayer = player
        originalBuffer = buffer

        // Pre-create stem players (silent until needed)
        let stemNames = ["drums", "bass", "vocals", "other"]
        for stemId in stemNames {
            let stemPlayer = AVAudioPlayerNode()
            engine.attach(stemPlayer)
            engine.connect(stemPlayer, to: engine.mainMixerNode, format: file.processingFormat)
            stemPlayer.volume = 0
            stemPlayers[stemId] = stemPlayer
            stemChunkBuffers[stemId] = []
        }

        isEngineSetup = true
        engine.prepare()
        try engine.start()
        generateOriginalWaveform(buffer: buffer)
    }

    // MARK: - Append stem chunks

    func appendStemChunks(fileHash: String, upToChunk: Int) {
        let cache = CacheManager.shared
        let stemNames = ["drums", "bass", "vocals", "other"]

        guard let origFormat = originalBuffer?.format else { return }

        for chunkIdx in scheduledChunkCount..<upToChunk {
            for stemId in stemNames {
                let chunkURLs = cache.chunkURLs(for: fileHash, stem: stemId)
                guard chunkIdx < chunkURLs.count else { continue }

                guard let file = try? AVAudioFile(forReading: chunkURLs[chunkIdx]) else { continue }
                let chunkFormat = file.processingFormat

                if chunkFormat.sampleRate == origFormat.sampleRate &&
                   chunkFormat.channelCount == origFormat.channelCount {
                    // Formats match — read directly
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: chunkFormat, frameCapacity: AVAudioFrameCount(file.length))
                    else { continue }
                    do {
                        try file.read(into: buffer)
                        stemChunkBuffers[stemId, default: []].append(buffer)
                    } catch {
                        print("Failed to load chunk \(chunkIdx) for \(stemId): \(error)")
                    }
                } else {
                    // Convert to match original
                    guard let converter = AVAudioConverter(from: chunkFormat, to: origFormat),
                          let inputBuffer = AVAudioPCMBuffer(pcmFormat: chunkFormat, frameCapacity: AVAudioFrameCount(file.length))
                    else { continue }
                    do {
                        try file.read(into: inputBuffer)
                    } catch { continue }

                    let ratio = origFormat.sampleRate / chunkFormat.sampleRate
                    let outputFrames = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio)
                    guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: origFormat, frameCapacity: outputFrames)
                    else { continue }

                    var convError: NSError?
                    converter.convert(to: outputBuffer, error: &convError) { _, outStatus in
                        outStatus.pointee = .haveData
                        return inputBuffer
                    }
                    if convError == nil {
                        stemChunkBuffers[stemId, default: []].append(outputBuffer)
                    }
                }
            }
        }

        scheduledChunkCount = upToChunk
        if !stemsAvailable { stemsAvailable = true }
        generateStemWaveformsFromChunks()

        // If playing and stems are tweaked but weren't scheduled, restart to include them
        if isPlaying && stemsTweaked && !stemsWereScheduled {
            seekFrame = currentFrame()
            stopAllPlayers()
            isPlaying = false
            play()
        }
    }

    // MARK: - Load full stems

    func loadFullStems(fileHash: String) {
        guard let urls = CacheManager.shared.stemURLs(for: fileHash),
              let origBuffer = originalBuffer
        else { return }

        let origFormat = origBuffer.format

        for (stemId, url) in urls {
            guard let file = try? AVAudioFile(forReading: url) else { continue }

            let stemFormat = file.processingFormat

            // If formats match, read directly
            if stemFormat.sampleRate == origFormat.sampleRate &&
               stemFormat.channelCount == origFormat.channelCount {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: stemFormat, frameCapacity: AVAudioFrameCount(file.length))
                else { continue }
                do {
                    try file.read(into: buffer)
                    stemFullBuffers[stemId] = buffer
                } catch {
                    print("Failed to load full stem \(stemId): \(error)")
                }
            } else {
                // Convert to match original format
                guard let converter = AVAudioConverter(from: stemFormat, to: origFormat) else {
                    print("Cannot create converter for \(stemId): \(stemFormat) -> \(origFormat)")
                    continue
                }

                guard let inputBuffer = AVAudioPCMBuffer(pcmFormat: stemFormat, frameCapacity: AVAudioFrameCount(file.length))
                else { continue }

                do {
                    try file.read(into: inputBuffer)
                } catch {
                    print("Failed to read stem \(stemId): \(error)")
                    continue
                }

                let ratio = origFormat.sampleRate / stemFormat.sampleRate
                let outputFrames = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio)
                guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: origFormat, frameCapacity: outputFrames)
                else { continue }

                var error: NSError?
                converter.convert(to: outputBuffer, error: &error) { _, outStatus in
                    outStatus.pointee = .haveData
                    return inputBuffer
                }

                if let error {
                    print("Conversion failed for \(stemId): \(error)")
                    continue
                }

                print("[stems] Converted \(stemId): \(stemFormat.sampleRate)Hz -> \(origFormat.sampleRate)Hz")
                stemFullBuffers[stemId] = outputBuffer
            }
        }

        stemsFullyReady = true

        // Reconnect stem players with correct format
        for (stemId, player) in stemPlayers {
            engine.disconnectNodeOutput(player)
            engine.connect(player, to: engine.mainMixerNode, format: origFormat)
        }

        // Reschedule with full buffers if playing
        if isPlaying {
            let pos = currentTime
            stopAllPlayers()
            isPlaying = false
            seekFrame = AVAudioFramePosition(pos * sampleRate)
            play()
        }

        generateStemWaveformsFromFull()
    }

    // MARK: - Playback (always all 5 players together)

    func play() {
        guard !isPlaying, isEngineSetup else { return }

        let startFrame = seekFrame
        let frameCount = AVAudioFrameCount(totalFrames - startFrame)
        guard frameCount > 0 else { return }

        print("[play] startFrame=\(startFrame) frameCount=\(frameCount) stemsFullyReady=\(stemsFullyReady)")
        for (stemId, chunks) in stemChunkBuffers {
            let totalChunkFrames = chunks.reduce(0) { $0 + Int($1.frameLength) }
            print("[play] \(stemId) chunks: \(chunks.count), frames: \(totalChunkFrames)")
        }
        for (stemId, buf) in stemFullBuffers {
            print("[play] \(stemId) full: \(buf.frameLength)")
        }

        // Schedule original from startFrame
        if let player = originalPlayer, let buffer = originalBuffer {
            if let partial = sliceBuffer(buffer, from: AVAudioFrameCount(startFrame), count: frameCount) {
                player.scheduleBuffer(partial)
            }
        }

        // Schedule stems — build one contiguous slice from the same startFrame
        for (stemId, player) in stemPlayers {
            if stemsFullyReady, let full = stemFullBuffers[stemId] {
                // Full buffer available — slice identically to original
                let stemFrames = min(frameCount, AVAudioFrameCount(full.frameLength) - AVAudioFrameCount(startFrame))
                if stemFrames > 0, let partial = sliceBuffer(full, from: AVAudioFrameCount(startFrame), count: stemFrames) {
                    player.scheduleBuffer(partial)
                }
            } else {
                // Chunks — concatenate into one contiguous buffer, then slice
                let chunks = stemChunkBuffers[stemId] ?? []
                if let merged = mergeChunkBuffers(chunks) {
                    let available = AVAudioFramePosition(merged.frameLength)
                    if startFrame < available {
                        let stemFrames = AVAudioFrameCount(available - startFrame)
                        if let partial = sliceBuffer(merged, from: AVAudioFrameCount(startFrame), count: stemFrames) {
                            player.scheduleBuffer(partial)
                        }
                    }
                }
            }
        }

        // Start all at the exact same time
        let now = AVAudioTime(hostTime: mach_absolute_time())
        originalPlayer?.play(at: now)
        for player in stemPlayers.values {
            player.play(at: now)
        }

        // Track whether stems actually had data to schedule
        stemsWereScheduled = stemChunkBuffers.values.contains { !$0.isEmpty } || !stemFullBuffers.isEmpty

        applyVolumes()
        isPlaying = true
        startTimer()
    }

    /// Merge chunk buffers into one contiguous buffer
    private func mergeChunkBuffers(_ chunks: [AVAudioPCMBuffer]) -> AVAudioPCMBuffer? {
        guard let first = chunks.first else { return nil }
        if chunks.count == 1 { return first }

        let totalFrames = chunks.reduce(0) { $0 + Int($1.frameLength) }
        guard let merged = AVAudioPCMBuffer(pcmFormat: first.format, frameCapacity: AVAudioFrameCount(totalFrames))
        else { return nil }

        merged.frameLength = AVAudioFrameCount(totalFrames)
        let channels = Int(first.format.channelCount)
        var offset = 0

        for chunk in chunks {
            let len = Int(chunk.frameLength)
            for ch in 0..<channels {
                if let src = chunk.floatChannelData?[ch],
                   let dst = merged.floatChannelData?[ch] {
                    dst.advanced(by: offset).update(from: src, count: len)
                }
            }
            offset += len
        }

        return merged
    }

    func pause() {
        guard isPlaying else { return }
        seekFrame = currentFrame()
        stopAllPlayers()
        isPlaying = false
        stemsWereScheduled = false
        stopTimer()
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    func seek(to time: TimeInterval) {
        let wasPlaying = isPlaying
        seekFrame = AVAudioFramePosition(max(0, min(time, duration)) * sampleRate)
        currentTime = time
        stopAllPlayers()
        if wasPlaying {
            isPlaying = false
            play()
        }
    }

    func stop() {
        stopAllPlayers()
        isPlaying = false
        seekFrame = 0
        currentTime = 0
        stemsWereScheduled = false
        stopTimer()
    }

    private func stopAllPlayers() {
        originalPlayer?.stop()
        for player in stemPlayers.values { player.stop() }
    }

    // MARK: - Volume / Mute / Solo

    func setVolume(for stemId: String, volume: Float) {
        if let idx = stems.firstIndex(where: { $0.id == stemId }) {
            stems[idx].volume = volume
        }
        applyVolumes()
    }

    func toggleMute(for stemId: String) {
        if let idx = stems.firstIndex(where: { $0.id == stemId }) {
            stems[idx].isMuted.toggle()
        }
        applyVolumes()
    }

    func toggleSolo(for stemId: String) {
        if let idx = stems.firstIndex(where: { $0.id == stemId }) {
            stems[idx].isSoloed.toggle()
        }
        applyVolumes()
    }

    /// Whether stems were included in the current play() scheduling
    private var stemsWereScheduled = false

    /// The core volume logic
    private func applyVolumes() {
        let tweaked = stemsTweaked
        let anySoloed = stems.contains { $0.isSoloed }

        // If we need stems but they weren't scheduled in current playback, restart all players
        let needsRestart = isPlaying && tweaked && !stemsWereScheduled && stemsAvailable
        if needsRestart {
            seekFrame = currentFrame()
            stopAllPlayers()
            isPlaying = false
        }

        // Original: full volume when untweaked, silent when stems are active
        originalPlayer?.volume = tweaked ? 0 : 1

        // Stems
        var newVolumes: [String: Float] = [:]
        for stem in stems {
            let vol: Float
            if !tweaked {
                vol = 0
            } else if stem.isMuted {
                vol = 0
            } else if anySoloed && !stem.isSoloed {
                vol = 0
            } else {
                vol = stem.volume
            }
            newVolumes[stem.id] = vol
            stemPlayers[stem.id]?.volume = vol
        }

        effectiveVolumes = newVolumes
        usingStemPlayback = tweaked

        if needsRestart {
            play()
        }
    }

    // MARK: - Waveform

    private let waveformWidth = 400

    private func generateOriginalWaveform(buffer: AVAudioPCMBuffer) {
        guard let ptr = buffer.floatChannelData?[0], buffer.frameLength > 0 else { return }
        let frameCount = Int(buffer.frameLength)
        let samplesPerPixel = max(1, frameCount / waveformWidth)
        let stride = max(1, samplesPerPixel / 8)

        var samples = [Float](repeating: 0, count: waveformWidth)
        var f = 0
        while f < frameCount {
            let pixelIdx = f / samplesPerPixel
            guard pixelIdx < waveformWidth else { break }
            let amp = abs(ptr[f])
            if amp > samples[pixelIdx] { samples[pixelIdx] = amp }
            f += stride
        }

        let peak = samples.max() ?? 1.0
        if peak > 0 {
            let scale = 1.0 / peak
            for i in 0..<waveformWidth { samples[i] *= scale }
        }

        waveformData = WaveformData(samples: samples, stemSamples: [:])
    }

    private func generateStemWaveformsFromChunks() {
        var stemSamples: [String: [Float]] = [:]
        var combinedSamples = [Float](repeating: 0, count: waveformWidth)
        let fullFrames = Int(duration * sampleRate)
        guard fullFrames > 0 else { return }
        let samplesPerPixel = max(1, fullFrames / waveformWidth)
        let stride = max(1, samplesPerPixel / 8)

        for (stemId, buffers) in stemChunkBuffers {
            var raw = [Float](repeating: 0, count: waveformWidth)
            var globalFrame = 0
            for buffer in buffers {
                guard let ptr = buffer.floatChannelData?[0] else { continue }
                let bufferFrames = Int(buffer.frameLength)
                var f = 0
                while f < bufferFrames {
                    let pixelIdx = (globalFrame + f) / samplesPerPixel
                    guard pixelIdx < waveformWidth else { break }
                    let amp = abs(ptr[f])
                    if amp > raw[pixelIdx] { raw[pixelIdx] = amp }
                    f += stride
                }
                globalFrame += bufferFrames
            }

            let peak = raw.max() ?? 1.0
            let scale: Float = peak > 0 ? 1.0 / peak : 0
            stemSamples[stemId] = raw.map { $0 * scale }
            for i in 0..<waveformWidth {
                combinedSamples[i] = max(combinedSamples[i], raw[i])
            }
        }

        let combinedPeak = combinedSamples.max() ?? 1.0
        if combinedPeak > 0 {
            let scale = 1.0 / combinedPeak
            for i in 0..<waveformWidth { combinedSamples[i] *= scale }
        }

        waveformData = WaveformData(samples: combinedSamples, stemSamples: stemSamples)
    }

    private func generateStemWaveformsFromFull() {
        var stemSamples: [String: [Float]] = [:]
        var combinedSamples = [Float](repeating: 0, count: waveformWidth)

        for (stemId, buffer) in stemFullBuffers {
            guard let ptr = buffer.floatChannelData?[0], buffer.frameLength > 0 else { continue }
            let frameCount = Int(buffer.frameLength)
            let samplesPerPixel = max(1, frameCount / waveformWidth)
            let stride = max(1, samplesPerPixel / 8)

            var raw = [Float](repeating: 0, count: waveformWidth)
            var f = 0
            while f < frameCount {
                let pixelIdx = f / samplesPerPixel
                guard pixelIdx < waveformWidth else { break }
                let amp = abs(ptr[f])
                if amp > raw[pixelIdx] { raw[pixelIdx] = amp }
                f += stride
            }

            let peak = raw.max() ?? 1.0
            let scale: Float = peak > 0 ? 1.0 / peak : 0
            stemSamples[stemId] = raw.map { $0 * scale }
            for i in 0..<waveformWidth {
                combinedSamples[i] = max(combinedSamples[i], raw[i])
            }
        }

        let combinedPeak = combinedSamples.max() ?? 1.0
        if combinedPeak > 0 {
            let scale = 1.0 / combinedPeak
            for i in 0..<waveformWidth { combinedSamples[i] *= scale }
        }

        waveformData = WaveformData(samples: combinedSamples, stemSamples: stemSamples)
    }

    // MARK: - Private

    private func reset() {
        stop()
        engine.stop()
        if let p = originalPlayer { engine.detach(p) }
        for node in stemPlayers.values { engine.detach(node) }
        originalPlayer = nil
        originalBuffer = nil
        stemPlayers.removeAll()
        stemChunkBuffers.removeAll()
        stemFullBuffers.removeAll()
        scheduledChunkCount = 0
        totalFrames = 0
        isEngineSetup = false
        stemsFullyReady = false
        stemsAvailable = false
        usingStemPlayback = false
        waveformData = .empty
    }

    private func currentFrame() -> AVAudioFramePosition {
        // Original player always has full track — best for time tracking
        if let p = originalPlayer,
           let nodeTime = p.lastRenderTime,
           let playerTime = p.playerTime(forNodeTime: nodeTime) {
            return seekFrame + playerTime.sampleTime
        }
        return seekFrame
    }

    private func sliceBuffer(_ buffer: AVAudioPCMBuffer, from startFrame: AVAudioFrameCount, count: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard let fmt = buffer.format as AVAudioFormat?,
              count > 0,
              let slice = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: count)
        else { return nil }
        slice.frameLength = count
        let channels = Int(fmt.channelCount)
        for ch in 0..<channels {
            if let src = buffer.floatChannelData?[ch],
               let dst = slice.floatChannelData?[ch] {
                dst.update(from: src.advanced(by: Int(startFrame)), count: Int(count))
            }
        }
        return slice
    }

    private func startTimer() {
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isPlaying else { return }
                let frame = self.currentFrame()
                self.currentTime = Double(frame) / self.sampleRate
                if frame >= self.totalFrames { self.stop() }
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }
}
