import Foundation

struct StemState: Equatable {
    var volume: Float = 1.0
    var isMuted: Bool = false
    var isSoloed: Bool = false
}

enum SeparationProgress: Equatable {
    case pending
    case preparing
    case processing(done: Int, total: Int)
    case ready
    case error(String)

    var isActive: Bool {
        switch self {
        case .preparing, .processing: return true
        default: return false
        }
    }

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }
}

struct BeatGrid: Equatable {
    let bpm: Double
    /// Beats sorted ascending in seconds. Each position is the actual drum
    /// transient location — positions are NOT forced onto a uniform grid.
    let beats: [TimeInterval]
    /// Subset of `beats` that the tracker labeled as bar-ones (downbeats).
    let downbeats: [TimeInterval]

    /// Snap a time to the nearest beat in the list. O(log n) via binary search.
    /// Returns nil when the grid is empty.
    func snap(_ time: TimeInterval) -> TimeInterval? {
        guard !beats.isEmpty else { return nil }
        var lo = 0
        var hi = beats.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if beats[mid] < time { lo = mid + 1 } else { hi = mid }
        }
        var best = beats[lo]
        var bestD = abs(best - time)
        if lo > 0 {
            let d = abs(beats[lo - 1] - time)
            if d < bestD { best = beats[lo - 1]; bestD = d }
        }
        return best
    }
}

struct Clip: Identifiable, Equatable {
    let id: UUID
    let url: URL
    let fileHash: String
    let name: String
    var timelineStart: TimeInterval
    var duration: TimeInterval
    var stemStates: [String: StemState]
    var separation: SeparationProgress
    var waveform: WaveformData
    var beatGrid: BeatGrid?

    /// Clip-local loop bounds in seconds. When `loopEnabled` is true and
    /// `loopEnd > loopStart`, the clip's audio wraps from `loopEnd` back to
    /// `loopStart` indefinitely. Independent per clip.
    var loopStart: TimeInterval = 0
    var loopEnd: TimeInterval = 0
    var loopEnabled: Bool = false

    var timelineEnd: TimeInterval { timelineStart + duration }
    var hasLoop: Bool { loopEnabled && loopEnd > loopStart }

    var anyTweaked: Bool {
        stemStates.values.contains { $0.isMuted || $0.isSoloed || $0.volume < 0.99 }
    }

    var anySoloed: Bool {
        stemStates.values.contains { $0.isSoloed }
    }

    static let defaultStemIDs = ["drums", "bass", "vocals", "other"]

    static func freshStemStates() -> [String: StemState] {
        Dictionary(uniqueKeysWithValues: defaultStemIDs.map { ($0, StemState()) })
    }
}
