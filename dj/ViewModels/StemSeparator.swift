import Foundation

@MainActor
class StemSeparator: ObservableObject {
    @Published var state: SeparationState = .idle
    @Published var chunksTotal: Int = 0
    @Published var chunksDone: Int = 0
    @Published var currentFileHash: String?
    @Published var firstChunkReady = false
    @Published var allDone = false
    @Published var duration: TimeInterval = 0

    enum SeparationState: Equatable {
        case idle
        case preparing
        case processing
        case done
        case error(String)
    }

    private let serverURL = "http://127.0.0.1:8089"
    private let cache = CacheManager.shared
    private var pollingTask: Task<Void, Never>?

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
            if await checkServerHealth() { return }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    func separate(fileURL: URL) async {
        state = .preparing
        chunksDone = 0
        chunksTotal = 0
        firstChunkReady = false
        allDone = false
        duration = 0

        do {
            let fileHash = try FileHasher.hash(fileAt: fileURL)
            currentFileHash = fileHash

            // Check cache — full stems already exist
            if cache.isCached(fileHash: fileHash) {
                firstChunkReady = true
                allDone = true
                state = .done
                return
            }

            // Start separation
            let outputDir = cache.outputDir(for: fileHash)
            try FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)

            let body: [String: Any] = [
                "input_path": fileURL.path,
                "output_dir": outputDir.path,
                "chunk_seconds": 10
            ]

            var request = URLRequest(url: URL(string: "\(serverURL)/separate")!)
            request.httpMethod = "POST"
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.httpBody = try JSONSerialization.data(withJSONObject: body)

            let (_, response) = try await URLSession.shared.data(for: request)
            guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                state = .error("Server returned error")
                return
            }

            state = .processing
            startPolling(fileHash: fileHash)

        } catch {
            state = .error(error.localizedDescription)
        }
    }

    private func startPolling(fileHash: String) {
        pollingTask?.cancel()
        pollingTask = Task {
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 200_000_000) // 0.2s — poll fast

                guard let url = URL(string: "\(serverURL)/status") else { continue }
                guard let (data, _) = try? await URLSession.shared.data(from: url),
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
                else { continue }

                let status = json["status"] as? String ?? ""
                let done = json["chunks_done"] as? Int ?? 0
                let total = json["chunks_total"] as? Int ?? 0
                let dur = json["duration"] as? Double ?? 0

                self.chunksDone = done
                self.chunksTotal = total
                self.duration = dur

                // Signal first chunk ready as soon as chunk 1 is done
                if done >= 1 && !self.firstChunkReady {
                    self.firstChunkReady = true
                }

                if status == "done" {
                    self.allDone = true
                    self.state = .done
                    break
                } else if status == "error" {
                    self.state = .error(json["error"] as? String ?? "Unknown error")
                    break
                }
            }
        }
    }

    func cancel() {
        pollingTask?.cancel()
        state = .idle
        firstChunkReady = false
        allDone = false
    }
}
