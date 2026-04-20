import AVFoundation
import Foundation
import QuartzCore

final class ClipRuntime {
    let format: AVAudioFormat
    let originalPlayer: AVAudioPlayerNode
    let originalBuffer: AVAudioPCMBuffer
    var stemPlayers: [String: AVAudioPlayerNode]
    var stemChunkBuffers: [String: [AVAudioPCMBuffer]] = [:]
    var stemFullBuffers: [String: AVAudioPCMBuffer] = [:]
    var scheduledChunkCount: Int = 0
    var stemsWereScheduled: Bool = false
    var stemsFullyReady: Bool = false

    init(format: AVAudioFormat,
         originalPlayer: AVAudioPlayerNode,
         originalBuffer: AVAudioPCMBuffer,
         stemPlayers: [String: AVAudioPlayerNode]) {
        self.format = format
        self.originalPlayer = originalPlayer
        self.originalBuffer = originalBuffer
        self.stemPlayers = stemPlayers
        for id in Clip.defaultStemIDs { self.stemChunkBuffers[id] = [] }
    }
}

@MainActor
class ArrangementEngine: ObservableObject {
    @Published var clips: [Clip] = []
    @Published var isPlaying = false
    @Published var currentTime: TimeInterval = 0
    /// When false, plain drags on a clip don't move it. Must be explicitly unlocked
    /// to prevent accidental timeline edits.
    @Published var editUnlocked: Bool = false

    var duration: TimeInterval {
        clips.map { $0.timelineEnd }.max() ?? 0
    }

    private let engine = AVAudioEngine()
    private var runtimes: [UUID: ClipRuntime] = [:]
    private var timer: Timer?

    private var playStartMediaTime: TimeInterval = 0
    private var playStartCurrentTime: TimeInterval = 0

    private static var _timebase: mach_timebase_info_data_t = {
        var t = mach_timebase_info_data_t()
        mach_timebase_info(&t)
        return t
    }()

    // MARK: - Clip lifecycle

    @discardableResult
    func addClip(url: URL) throws -> UUID {
        let fileHash = try FileHasher.hash(fileAt: url)
        let file = try AVAudioFile(forReading: url)
        let format = file.processingFormat
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(file.length)) else {
            throw NSError(domain: "ArrangementEngine", code: 1, userInfo: [NSLocalizedDescriptionKey: "buffer alloc failed"])
        }
        try file.read(into: buffer)

        let originalPlayer = AVAudioPlayerNode()
        engine.attach(originalPlayer)
        engine.connect(originalPlayer, to: engine.mainMixerNode, format: format)

        var stemPlayers: [String: AVAudioPlayerNode] = [:]
        for stemID in Clip.defaultStemIDs {
            let p = AVAudioPlayerNode()
            engine.attach(p)
            engine.connect(p, to: engine.mainMixerNode, format: format)
            p.volume = 0
            stemPlayers[stemID] = p
        }

        if !engine.isRunning {
            engine.prepare()
            try engine.start()
        }

        let rt = ClipRuntime(format: format, originalPlayer: originalPlayer, originalBuffer: buffer, stemPlayers: stemPlayers)
        let waveSamples = generateWaveform(from: buffer)
        let id = UUID()
        // Auto-mute if any existing clip is currently audible, so adding a track
        // doesn't suddenly crash a mix together.
        let anyAudible = clips.contains { !$0.isMuted }
        var clip = Clip(
            id: id,
            url: url,
            fileHash: fileHash,
            name: url.lastPathComponent,
            timelineStart: 0,
            duration: Double(file.length) / format.sampleRate,
            stemStates: Clip.freshStemStates(),
            separation: .pending,
            waveform: WaveformData(samples: waveSamples, stemSamples: [:])
        )
        clip.isMuted = anyAudible
        runtimes[id] = rt
        clips.append(clip)
        return id
    }

    func removeClip(id: UUID) {
        guard let rt = runtimes[id] else { return }
        rt.originalPlayer.stop()
        for p in rt.stemPlayers.values { p.stop() }
        engine.detach(rt.originalPlayer)
        for p in rt.stemPlayers.values { engine.detach(p) }
        runtimes.removeValue(forKey: id)
        clips.removeAll { $0.id == id }
    }

    func moveClip(id: UUID, to newStart: TimeInterval) {
        guard let idx = clips.firstIndex(where: { $0.id == id }) else { return }
        clips[idx].timelineStart = max(0, newStart)
        if isPlaying { restartFromCurrent() }
    }

    // MARK: - Separation progress ingestion

    func setSeparationProgress(clipID: UUID, progress: SeparationProgress) {
        guard let idx = clips.firstIndex(where: { $0.id == clipID }) else { return }
        clips[idx].separation = progress
    }

    func setBeatGrid(clipID: UUID, grid: BeatGrid) {
        guard let idx = clips.firstIndex(where: { $0.id == clipID }) else { return }
        clips[idx].beatGrid = grid
    }

    /// Re-phase the clip's beat grid so that `clipLocalTime` is a downbeat.
    /// Period is inferred from the current grid's median inter-beat interval;
    /// beats are extrapolated forward and backward across the whole clip.
    func setClipAnchor(clipID: UUID, clipLocalTime: TimeInterval) {
        guard let idx = clips.firstIndex(where: { $0.id == clipID }) else { return }
        let duration = clips[idx].duration
        guard duration > 0 else { return }

        // Period from existing grid, or fall back to bpm-derived if present.
        let period: TimeInterval
        if let grid = clips[idx].beatGrid {
            let sorted = grid.beats.sorted()
            if sorted.count >= 2 {
                var intervals = [TimeInterval]()
                intervals.reserveCapacity(sorted.count - 1)
                for i in 1..<sorted.count { intervals.append(sorted[i] - sorted[i - 1]) }
                intervals.sort()
                period = intervals[intervals.count / 2]
            } else if grid.bpm > 0 {
                period = 60.0 / grid.bpm
            } else {
                return
            }
        } else {
            return
        }
        guard period > 0 else { return }

        var beats = [TimeInterval]()
        var downbeats = [TimeInterval]()

        // Forward from anchor
        var k = 0
        while true {
            let t = clipLocalTime + Double(k) * period
            if t > duration + 0.001 { break }
            if t >= -0.001 {
                beats.append(t)
                if k % 4 == 0 { downbeats.append(t) }
            }
            k += 1
        }
        // Backward from anchor
        k = -1
        while true {
            let t = clipLocalTime + Double(k) * period
            if t < -0.001 { break }
            if t <= duration + 0.001 {
                beats.append(t)
                if k % 4 == 0 { downbeats.append(t) }
            }
            k -= 1
        }

        beats.sort()
        downbeats.sort()

        let bpm = round(60.0 / period * 100) / 100
        clips[idx].beatGrid = BeatGrid(bpm: bpm, beats: beats, downbeats: downbeats)

        // If this clip is currently looping, reschedule to keep audio consistent
        // with the new snap targets (loop bounds already-set are untouched, but
        // the audible phase relationship to the grid is now correct).
        if isPlaying && clips[idx].hasLoop { restartFromCurrent() }
    }

    func appendStemChunks(clipID: UUID, upToChunk: Int) {
        guard let idx = clips.firstIndex(where: { $0.id == clipID }),
              let rt = runtimes[clipID] else { return }
        let clip = clips[idx]
        let cache = CacheManager.shared
        let origFormat = rt.format

        for chunkIdx in rt.scheduledChunkCount..<upToChunk {
            for stemID in Clip.defaultStemIDs {
                let chunkURLs = cache.chunkURLs(for: clip.fileHash, stem: stemID)
                guard chunkIdx < chunkURLs.count else { continue }
                guard let file = try? AVAudioFile(forReading: chunkURLs[chunkIdx]) else { continue }
                let chunkFormat = file.processingFormat

                if chunkFormat.sampleRate == origFormat.sampleRate &&
                   chunkFormat.channelCount == origFormat.channelCount {
                    guard let buffer = AVAudioPCMBuffer(pcmFormat: chunkFormat, frameCapacity: AVAudioFrameCount(file.length)) else { continue }
                    do {
                        try file.read(into: buffer)
                        rt.stemChunkBuffers[stemID, default: []].append(buffer)
                    } catch {}
                } else if let converted = convertBuffer(from: file, sourceFormat: chunkFormat, targetFormat: origFormat) {
                    rt.stemChunkBuffers[stemID, default: []].append(converted)
                }
            }
        }
        rt.scheduledChunkCount = upToChunk

        let stemSamples = generateStemWaveformsFromChunks(rt: rt, clipDuration: clip.duration)
        clips[idx].waveform = WaveformData(samples: clips[idx].waveform.samples, stemSamples: stemSamples)

        if isPlaying && clip.anyTweaked && !rt.stemsWereScheduled {
            restartFromCurrent()
        }
    }

    func loadFullStems(clipID: UUID) {
        guard let idx = clips.firstIndex(where: { $0.id == clipID }),
              let rt = runtimes[clipID] else { return }
        let clip = clips[idx]
        guard let urls = CacheManager.shared.stemURLs(for: clip.fileHash) else { return }
        let origFormat = rt.format

        for (stemID, url) in urls {
            guard let file = try? AVAudioFile(forReading: url) else { continue }
            let stemFormat = file.processingFormat
            if stemFormat.sampleRate == origFormat.sampleRate &&
               stemFormat.channelCount == origFormat.channelCount {
                guard let buffer = AVAudioPCMBuffer(pcmFormat: stemFormat, frameCapacity: AVAudioFrameCount(file.length)) else { continue }
                do {
                    try file.read(into: buffer)
                    rt.stemFullBuffers[stemID] = buffer
                } catch {}
            } else if let converted = convertBuffer(from: file, sourceFormat: stemFormat, targetFormat: origFormat) {
                rt.stemFullBuffers[stemID] = converted
            }
        }
        rt.stemsFullyReady = true

        let stemSamples = generateStemWaveformsFromFull(rt: rt)
        clips[idx].waveform = WaveformData(samples: clips[idx].waveform.samples, stemSamples: stemSamples)
        clips[idx].separation = .ready

        if isPlaying { restartFromCurrent() }
    }

    private func convertBuffer(from file: AVAudioFile, sourceFormat: AVAudioFormat, targetFormat: AVAudioFormat) -> AVAudioPCMBuffer? {
        guard let converter = AVAudioConverter(from: sourceFormat, to: targetFormat),
              let inputBuffer = AVAudioPCMBuffer(pcmFormat: sourceFormat, frameCapacity: AVAudioFrameCount(file.length))
        else { return nil }
        do { try file.read(into: inputBuffer) } catch { return nil }
        let ratio = targetFormat.sampleRate / sourceFormat.sampleRate
        let outputFrames = AVAudioFrameCount(Double(inputBuffer.frameLength) * ratio)
        guard let outputBuffer = AVAudioPCMBuffer(pcmFormat: targetFormat, frameCapacity: outputFrames) else { return nil }
        var err: NSError?
        converter.convert(to: outputBuffer, error: &err) { _, outStatus in
            outStatus.pointee = .haveData
            return inputBuffer
        }
        return err == nil ? outputBuffer : nil
    }

    // MARK: - Transport

    func play() {
        guard !isPlaying, !clips.isEmpty else { return }
        if !engine.isRunning {
            do { try engine.start() } catch { return }
        }

        let leadSeconds = 0.05
        let anchorHost = mach_absolute_time() + hostTicks(forSeconds: leadSeconds)
        let anchor = AVAudioTime(hostTime: anchorHost)

        for clip in clips {
            guard let rt = runtimes[clip.id] else { continue }
            schedulePlaybackForClip(clip: clip, rt: rt, anchor: anchor, anchorHost: anchorHost)
        }

        playStartMediaTime = CACurrentMediaTime() + leadSeconds
        playStartCurrentTime = currentTime
        applyVolumes()
        isPlaying = true
        startTimer()
    }

    /// Schedule one clip's audio for playback, handling both linear and looping modes.
    private func schedulePlaybackForClip(clip: Clip, rt: ClipRuntime, anchor: AVAudioTime, anchorHost: UInt64) {
        let relTime = currentTime - clip.timelineStart

        if clip.hasLoop {
            scheduleLoopingClip(clip: clip, rt: rt, relTime: relTime, anchor: anchor, anchorHost: anchorHost)
        } else {
            scheduleLinearClip(clip: clip, rt: rt, relTime: relTime, anchor: anchor, anchorHost: anchorHost)
        }
    }

    private func scheduleLinearClip(clip: Clip, rt: ClipRuntime, relTime: TimeInterval, anchor: AVAudioTime, anchorHost: UInt64) {
        guard relTime < clip.duration else { return }
        let startAt: AVAudioTime
        let sliceFromSeconds: Double
        let lenSeconds: Double
        if relTime >= 0 {
            startAt = anchor
            sliceFromSeconds = relTime
            lenSeconds = clip.duration - relTime
        } else {
            startAt = AVAudioTime(hostTime: anchorHost + hostTicks(forSeconds: -relTime))
            sliceFromSeconds = 0
            lenSeconds = clip.duration
        }
        scheduleClipSlice(rt: rt, fromSeconds: sliceFromSeconds, lenSeconds: lenSeconds, atHost: startAt.hostTime)
        rt.originalPlayer.play(at: anchor)
        for p in rt.stemPlayers.values { p.play(at: anchor) }
        rt.stemsWereScheduled = rt.stemChunkBuffers.values.contains { !$0.isEmpty } || !rt.stemFullBuffers.isEmpty
    }

    private func scheduleLoopingClip(clip: Clip, rt: ClipRuntime, relTime: TimeInterval, anchor: AVAudioTime, anchorHost: UInt64) {
        let loopLen = clip.loopEnd - clip.loopStart
        guard loopLen > 0 else {
            scheduleLinearClip(clip: clip, rt: rt, relTime: relTime, anchor: anchor, anchorHost: anchorHost)
            return
        }

        // Where in the clip (clip-local seconds) the first audio slice starts.
        let startLocal: Double
        // The absolute host time at which that first slice begins.
        let firstHost: UInt64
        if relTime < 0 {
            startLocal = 0
            firstHost = anchorHost + hostTicks(forSeconds: -relTime)
        } else if relTime < clip.loopEnd {
            startLocal = max(0, relTime)
            firstHost = anchorHost
        } else {
            let phase = (relTime - clip.loopEnd).truncatingRemainder(dividingBy: loopLen)
            startLocal = clip.loopStart + phase
            firstHost = anchorHost
        }

        // First slice: from startLocal up to loopEnd.
        let firstLen = clip.loopEnd - startLocal
        if firstLen > 0 {
            scheduleClipSlice(rt: rt, fromSeconds: startLocal, lenSeconds: firstLen, atHost: firstHost)
        }

        // Then pre-queue many iterations of [loopStart, loopEnd] back-to-back.
        let iterations = 256
        var nextHost = firstHost + hostTicks(forSeconds: max(0, firstLen))
        for _ in 0..<iterations {
            scheduleClipSlice(rt: rt, fromSeconds: clip.loopStart, lenSeconds: loopLen, atHost: nextHost)
            nextHost += hostTicks(forSeconds: loopLen)
        }

        rt.originalPlayer.play(at: anchor)
        for p in rt.stemPlayers.values { p.play(at: anchor) }
        rt.stemsWereScheduled = rt.stemChunkBuffers.values.contains { !$0.isEmpty } || !rt.stemFullBuffers.isEmpty
    }

    func pause() {
        guard isPlaying else { return }
        updateCurrentTime()
        stopAllPlayers()
        isPlaying = false
        stopTimer()
        for (_, rt) in runtimes { rt.stemsWereScheduled = false }
    }

    func togglePlayPause() {
        if isPlaying { pause() } else { play() }
    }

    func stop() {
        stopAllPlayers()
        isPlaying = false
        currentTime = 0
        stopTimer()
        for (_, rt) in runtimes { rt.stemsWereScheduled = false }
    }

    func seek(to time: TimeInterval) {
        let wasPlaying = isPlaying
        if wasPlaying {
            stopAllPlayers()
            isPlaying = false
        }
        currentTime = max(0, min(time, max(duration, 0.001)))
        if wasPlaying { play() }
    }

    private func restartFromCurrent() {
        updateCurrentTime()
        let pos = currentTime
        stopAllPlayers()
        isPlaying = false
        currentTime = pos
        play()
    }

    private func stopAllPlayers() {
        for (_, rt) in runtimes {
            rt.originalPlayer.stop()
            for p in rt.stemPlayers.values { p.stop() }
        }
    }

    private func scheduleClipSlice(rt: ClipRuntime, fromSeconds: Double, lenSeconds: Double, atHost: UInt64) {
        let sr = rt.format.sampleRate
        let startFrame = AVAudioFrameCount(max(0, fromSeconds) * sr)
        let wantFrames = AVAudioFrameCount(max(0, lenSeconds) * sr)
        guard wantFrames > 0 else { return }
        let at = AVAudioTime(hostTime: atHost)

        let origAvail = AVAudioFrameCount(rt.originalBuffer.frameLength)
        if startFrame < origAvail {
            let count = min(wantFrames, origAvail - startFrame)
            if let partial = sliceBuffer(rt.originalBuffer, from: startFrame, count: count) {
                rt.originalPlayer.scheduleBuffer(partial, at: at, options: [], completionHandler: nil)
            }
        }

        for (stemID, player) in rt.stemPlayers {
            if rt.stemsFullyReady, let full = rt.stemFullBuffers[stemID] {
                let avail = AVAudioFrameCount(full.frameLength)
                if startFrame < avail {
                    let count = min(wantFrames, avail - startFrame)
                    if let partial = sliceBuffer(full, from: startFrame, count: count) {
                        player.scheduleBuffer(partial, at: at, options: [], completionHandler: nil)
                    }
                }
            } else {
                let chunks = rt.stemChunkBuffers[stemID] ?? []
                if let merged = mergeChunkBuffers(chunks) {
                    let avail = AVAudioFrameCount(merged.frameLength)
                    if startFrame < avail {
                        let count = min(wantFrames, avail - startFrame)
                        if let partial = sliceBuffer(merged, from: startFrame, count: count) {
                            player.scheduleBuffer(partial, at: at, options: [], completionHandler: nil)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Loop

    func setClipLoop(clipID: UUID, start: TimeInterval, end: TimeInterval) {
        guard let idx = clips.firstIndex(where: { $0.id == clipID }) else { return }
        let clip = clips[idx]
        let clampedStart = max(0, min(start, end, clip.duration))
        let clampedEnd = max(start, min(end, clip.duration))
        // Snap to the clip's own beat grid (clip-local coords).
        let snappedStart = snapInClip(clipID: clipID, clipLocalTime: clampedStart) ?? clampedStart
        let snappedEnd = snapInClip(clipID: clipID, clipLocalTime: clampedEnd) ?? clampedEnd
        if snappedEnd > snappedStart {
            clips[idx].loopStart = snappedStart
            clips[idx].loopEnd = snappedEnd
        } else {
            clips[idx].loopStart = clampedStart
            clips[idx].loopEnd = clampedEnd
        }
        clips[idx].loopEnabled = true
        if isPlaying { restartFromCurrent() }
    }

    func setClipLoopEnabled(clipID: UUID, enabled: Bool) {
        guard let idx = clips.firstIndex(where: { $0.id == clipID }) else { return }
        guard clips[idx].loopEnabled != enabled else { return }
        clips[idx].loopEnabled = enabled
        if isPlaying { restartFromCurrent() }
    }

    func toggleClipLoop(clipID: UUID) {
        guard let idx = clips.firstIndex(where: { $0.id == clipID }) else { return }
        setClipLoopEnabled(clipID: clipID, enabled: !clips[idx].loopEnabled)
    }

    func clearClipLoop(clipID: UUID) {
        guard let idx = clips.firstIndex(where: { $0.id == clipID }) else { return }
        let wasEnabled = clips[idx].loopEnabled
        clips[idx].loopStart = 0
        clips[idx].loopEnd = 0
        clips[idx].loopEnabled = false
        if isPlaying && wasEnabled { restartFromCurrent() }
    }

    /// Snap a clip-local time to the clip's own beat grid. Returns nil when no grid.
    func snapInClip(clipID: UUID, clipLocalTime: TimeInterval) -> TimeInterval? {
        guard let clip = clips.first(where: { $0.id == clipID }),
              let grid = clip.beatGrid
        else { return nil }
        return grid.snap(clipLocalTime)
    }

    // MARK: - Per-stem controls

    func setVolume(clipID: UUID, stemID: String, volume: Float) {
        guard let idx = clips.firstIndex(where: { $0.id == clipID }) else { return }
        clips[idx].stemStates[stemID]?.volume = volume
        applyVolumes()
    }

    func toggleMute(clipID: UUID, stemID: String) {
        guard let idx = clips.firstIndex(where: { $0.id == clipID }) else { return }
        clips[idx].stemStates[stemID]?.isMuted.toggle()
        applyVolumes()
    }

    func toggleSolo(clipID: UUID, stemID: String) {
        guard let idx = clips.firstIndex(where: { $0.id == clipID }) else { return }
        clips[idx].stemStates[stemID]?.isSoloed.toggle()
        applyVolumes()
    }

    func setClipMuted(clipID: UUID, muted: Bool) {
        guard let idx = clips.firstIndex(where: { $0.id == clipID }) else { return }
        guard clips[idx].isMuted != muted else { return }
        clips[idx].isMuted = muted
        applyVolumes()
    }

    func toggleClipMute(clipID: UUID) {
        guard let idx = clips.firstIndex(where: { $0.id == clipID }) else { return }
        setClipMuted(clipID: clipID, muted: !clips[idx].isMuted)
    }

    private func applyVolumes() {
        var needsReschedule = false
        for clip in clips {
            guard let rt = runtimes[clip.id] else { continue }
            let tweaked = clip.anyTweaked
            let anySoloed = clip.anySoloed
            let clipGain: Float = clip.isMuted ? 0 : 1
            rt.originalPlayer.volume = (tweaked ? 0 : 1) * clipGain

            for stemID in Clip.defaultStemIDs {
                guard let state = clip.stemStates[stemID],
                      let player = rt.stemPlayers[stemID] else { continue }
                let vol: Float
                if !tweaked { vol = 0 }
                else if state.isMuted { vol = 0 }
                else if anySoloed && !state.isSoloed { vol = 0 }
                else { vol = state.volume }
                player.volume = vol * clipGain
            }

            if isPlaying && tweaked && !rt.stemsWereScheduled {
                let hasStems = !rt.stemChunkBuffers.values.allSatisfy { $0.isEmpty } || !rt.stemFullBuffers.isEmpty
                if hasStems { needsReschedule = true }
            }
        }
        if needsReschedule { restartFromCurrent() }
    }

    // MARK: - Clock

    private func updateCurrentTime() {
        guard isPlaying else { return }
        let now = CACurrentMediaTime()
        let elapsed = max(0, now - playStartMediaTime)
        currentTime = playStartCurrentTime + elapsed
    }

    private func startTimer() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isPlaying else { return }
                self.updateCurrentTime()
                // Transport runs linearly. Per-clip loops handle their own audio wrap
                // via pre-scheduled iterations. Stop only when past the last clip AND
                // no clip is looping (looping clips effectively extend indefinitely).
                let anyLooping = self.clips.contains { $0.hasLoop }
                if !anyLooping, self.duration > 0, self.currentTime >= self.duration {
                    self.stop()
                }
            }
        }
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - Waveforms

    /// Target buckets per clip = 200 per second, clamped. Gives ~10 samples per display pixel
    /// at 20 px/sec, enough resolution for Ableton-like detail.
    private func bucketCount(forDuration d: TimeInterval) -> Int {
        let target = Int(max(1, d) * 200)
        return min(12000, max(800, target))
    }

    private func generateWaveform(from buffer: AVAudioPCMBuffer) -> [WaveformSample] {
        let frameCount = Int(buffer.frameLength)
        guard frameCount > 0 else { return [] }
        let duration = Double(frameCount) / buffer.format.sampleRate
        let buckets = bucketCount(forDuration: duration)
        return bucketize(buffer: buffer, frameRangeStart: 0, frameRangeCount: frameCount, buckets: buckets, globalFrameOffset: 0, totalFrames: frameCount)
    }

    private func generateStemWaveformsFromChunks(rt: ClipRuntime, clipDuration: TimeInterval) -> [String: [WaveformSample]] {
        var result: [String: [WaveformSample]] = [:]
        let totalFrames = Int(clipDuration * rt.format.sampleRate)
        guard totalFrames > 0 else { return [:] }
        let buckets = bucketCount(forDuration: clipDuration)

        for (stemID, buffers) in rt.stemChunkBuffers {
            var minVals = [Float](repeating: 0, count: buckets)
            var maxVals = [Float](repeating: 0, count: buckets)
            var globalFrame = 0
            for buffer in buffers {
                accumulate(buffer: buffer,
                           minVals: &minVals, maxVals: &maxVals,
                           globalFrameOffset: globalFrame,
                           totalFrames: totalFrames,
                           buckets: buckets)
                globalFrame += Int(buffer.frameLength)
            }
            result[stemID] = normalized(minVals: minVals, maxVals: maxVals)
        }
        return result
    }

    private func generateStemWaveformsFromFull(rt: ClipRuntime) -> [String: [WaveformSample]] {
        var result: [String: [WaveformSample]] = [:]
        for (stemID, buffer) in rt.stemFullBuffers {
            let frameCount = Int(buffer.frameLength)
            guard frameCount > 0 else { continue }
            let duration = Double(frameCount) / buffer.format.sampleRate
            let buckets = bucketCount(forDuration: duration)
            result[stemID] = bucketize(buffer: buffer, frameRangeStart: 0, frameRangeCount: frameCount, buckets: buckets, globalFrameOffset: 0, totalFrames: frameCount)
        }
        return result
    }

    private func bucketize(buffer: AVAudioPCMBuffer,
                           frameRangeStart: Int,
                           frameRangeCount: Int,
                           buckets: Int,
                           globalFrameOffset: Int,
                           totalFrames: Int) -> [WaveformSample] {
        var minVals = [Float](repeating: 0, count: buckets)
        var maxVals = [Float](repeating: 0, count: buckets)
        accumulate(buffer: buffer,
                   minVals: &minVals, maxVals: &maxVals,
                   globalFrameOffset: globalFrameOffset,
                   totalFrames: totalFrames,
                   buckets: buckets)
        return normalized(minVals: minVals, maxVals: maxVals)
    }

    private func accumulate(buffer: AVAudioPCMBuffer,
                            minVals: inout [Float],
                            maxVals: inout [Float],
                            globalFrameOffset: Int,
                            totalFrames: Int,
                            buckets: Int) {
        guard let chPtr = buffer.floatChannelData else { return }
        let channels = Int(buffer.format.channelCount)
        let frameCount = Int(buffer.frameLength)
        let framesPerBucket = max(1, totalFrames / buckets)
        let stride = max(1, framesPerBucket / 16)

        var f = 0
        while f < frameCount {
            let globalF = globalFrameOffset + f
            let bucket = globalF / framesPerBucket
            if bucket >= buckets { break }
            var v: Float = 0
            for ch in 0..<channels {
                v += chPtr[ch][f]
            }
            v /= Float(channels)
            if v > maxVals[bucket] { maxVals[bucket] = v }
            if v < minVals[bucket] { minVals[bucket] = v }
            f += stride
        }
    }

    private func normalized(minVals: [Float], maxVals: [Float]) -> [WaveformSample] {
        let peak = max(maxVals.max() ?? 0, -(minVals.min() ?? 0))
        let scale: Float = peak > 0.001 ? 1.0 / peak : 0
        var out = [WaveformSample]()
        out.reserveCapacity(maxVals.count)
        for i in 0..<maxVals.count {
            out.append(WaveformSample(min: minVals[i] * scale, max: maxVals[i] * scale))
        }
        return out
    }

    // MARK: - Utilities

    private func sliceBuffer(_ buffer: AVAudioPCMBuffer, from startFrame: AVAudioFrameCount, count: AVAudioFrameCount) -> AVAudioPCMBuffer? {
        guard count > 0, let slice = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: count) else { return nil }
        slice.frameLength = count
        let channels = Int(buffer.format.channelCount)
        for ch in 0..<channels {
            if let src = buffer.floatChannelData?[ch], let dst = slice.floatChannelData?[ch] {
                dst.update(from: src.advanced(by: Int(startFrame)), count: Int(count))
            }
        }
        return slice
    }

    private func mergeChunkBuffers(_ chunks: [AVAudioPCMBuffer]) -> AVAudioPCMBuffer? {
        guard let first = chunks.first else { return nil }
        if chunks.count == 1 { return first }
        let totalFrames = chunks.reduce(0) { $0 + Int($1.frameLength) }
        guard let merged = AVAudioPCMBuffer(pcmFormat: first.format, frameCapacity: AVAudioFrameCount(totalFrames)) else { return nil }
        merged.frameLength = AVAudioFrameCount(totalFrames)
        let channels = Int(first.format.channelCount)
        var offset = 0
        for chunk in chunks {
            let len = Int(chunk.frameLength)
            for ch in 0..<channels {
                if let src = chunk.floatChannelData?[ch], let dst = merged.floatChannelData?[ch] {
                    dst.advanced(by: offset).update(from: src, count: len)
                }
            }
            offset += len
        }
        return merged
    }

    private func hostTicks(forSeconds seconds: Double) -> UInt64 {
        let ns = seconds * 1_000_000_000
        return UInt64(ns * Double(Self._timebase.denom) / Double(Self._timebase.numer))
    }
}
