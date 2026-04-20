import Foundation

@MainActor
class StemSeparator: ObservableObject {
    @Published private(set) var serverReady = false
    @Published private(set) var progressByClip: [UUID: SeparationProgress] = [:]

    var onChunksDone: ((UUID, Int) -> Void)?
    var onFullStemsReady: ((UUID) -> Void)?

    private let serverURL = "http://127.0.0.1:8089"
    private let cache = CacheManager.shared

    private struct QueuedJob {
        let clipID: UUID
        let fileURL: URL
        let fileHash: String
    }

    private var queue: [QueuedJob] = []
    private var activeJob: QueuedJob?
    private var pollingTask: Task<Void, Never>?
    private var lastDoneChunks: Int = 0

    // MARK: - Beat analysis

    func analyze(fileURL: URL, fileHash: String, drumsURL: URL? = nil) async -> BeatGrid? {
        let cacheDir = cache.outputDir(for: fileHash).path
        var body: [String: Any] = [
            "input_path": fileURL.path,
            "cache_dir": cacheDir
        ]
        if let drumsURL { body["drums_path"] = drumsURL.path }
        guard let url = URL(string: "\(serverURL)/analyze"),
              let httpBody = try? JSONSerialization.data(withJSONObject: body)
        else { return nil }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = httpBody
        request.timeoutInterval = 300

        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200,
                  let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let bpm = json["bpm"] as? Double,
                  let beats = json["beats"] as? [Double],
                  let downbeats = json["downbeats"] as? [Double]
            else { return nil }
            return BeatGrid(bpm: bpm, beats: beats, downbeats: downbeats)
        } catch {
            return nil
        }
    }

    // MARK: - Server readiness

    func checkServerHealth() async -> Bool {
        guard let url = URL(string: "\(serverURL)/health") else { return false }
        do {
            let (data, response) = try await URLSession.shared.data(from: url)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else { return false }
            let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
            return json?["status"] as? String == "ok"
        } catch {
            return false
        }
    }

    func waitForServer() async {
        for _ in 0..<30 {
            if await checkServerHealth() {
                serverReady = true
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    // MARK: - Queue

    func enqueue(clipID: UUID, fileURL: URL, fileHash: String) {
        if cache.isCached(fileHash: fileHash) {
            progressByClip[clipID] = .ready
            onFullStemsReady?(clipID)
            return
        }
        progressByClip[clipID] = .pending
        queue.append(QueuedJob(clipID: clipID, fileURL: fileURL, fileHash: fileHash))
        processQueueIfIdle()
    }

    func cancel(clipID: UUID) {
        queue.removeAll { $0.clipID == clipID }
        if activeJob?.clipID == clipID {
            pollingTask?.cancel()
            activeJob = nil
            progressByClip.removeValue(forKey: clipID)
            processQueueIfIdle()
        } else {
            progressByClip.removeValue(forKey: clipID)
        }
    }

    private func processQueueIfIdle() {
        guard activeJob == nil, !queue.isEmpty else { return }
        let job = queue.removeFirst()
        activeJob = job
        lastDoneChunks = 0
        Task { await startJob(job) }
    }

    private func startJob(_ job: QueuedJob) async {
        progressByClip[job.clipID] = .preparing

        let outputDir = cache.outputDir(for: job.fileHash)
        try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

        let body: [String: Any] = [
            "input_path": job.fileURL.path,
            "output_dir": outputDir.path,
            "chunk_seconds": 10
        ]

        guard let url = URL(string: "\(serverURL)/separate"),
              let httpBody = try? JSONSerialization.data(withJSONObject: body) else {
            progressByClip[job.clipID] = .error("bad request")
            finishJob()
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = httpBody

        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                progressByClip[job.clipID] = .error("server returned error")
                finishJob()
                return
            }
        } catch {
            progressByClip[job.clipID] = .error(error.localizedDescription)
            finishJob()
            return
        }

        progressByClip[job.clipID] = .processing(done: 0, total: 0)
        pollingTask = Task { await pollStatus(job: job) }
    }

    private func pollStatus(job: QueuedJob) async {
        while !Task.isCancelled {
            try? await Task.sleep(nanoseconds: 200_000_000)

            guard let statusURL = URL(string: "\(serverURL)/status") else { continue }
            guard let (data, _) = try? await URLSession.shared.data(from: statusURL),
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }

            let status = json["status"] as? String ?? ""
            let done = json["chunks_done"] as? Int ?? 0
            let total = json["chunks_total"] as? Int ?? 0

            if done > lastDoneChunks {
                lastDoneChunks = done
                onChunksDone?(job.clipID, done)
            }

            if status == "done" {
                progressByClip[job.clipID] = .ready
                onFullStemsReady?(job.clipID)
                finishJob()
                return
            } else if status == "error" {
                progressByClip[job.clipID] = .error(json["error"] as? String ?? "unknown")
                finishJob()
                return
            } else {
                progressByClip[job.clipID] = .processing(done: done, total: total)
            }
        }
    }

    private func finishJob() {
        activeJob = nil
        pollingTask = nil
        processQueueIfIdle()
    }
}
