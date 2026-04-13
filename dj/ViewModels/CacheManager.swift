import Foundation

final class CacheManager: Sendable {
    static let shared = CacheManager()

    let cacheDir: URL

    private init() {
        let musicDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Music/dj/cache")
        try? FileManager.default.createDirectory(at: musicDir, withIntermediateDirectories: true)
        self.cacheDir = musicDir
    }

    func outputDir(for fileHash: String) -> URL {
        cacheDir.appendingPathComponent(fileHash)
    }

    func isCached(fileHash: String) -> Bool {
        let metadataPath = outputDir(for: fileHash)
            .appendingPathComponent("metadata.json")
        return FileManager.default.fileExists(atPath: metadataPath.path)
    }

    func stemURLs(for fileHash: String) -> [String: URL]? {
        let dir = outputDir(for: fileHash)
        let stems = ["drums", "bass", "vocals", "other"]
        var urls: [String: URL] = [:]

        for stem in stems {
            let url = dir.appendingPathComponent("\(stem).wav")
            guard FileManager.default.fileExists(atPath: url.path) else { return nil }
            urls[stem] = url
        }

        return urls
    }

    func chunkURLs(for fileHash: String, stem: String) -> [URL] {
        let chunksDir = outputDir(for: fileHash).appendingPathComponent("chunks")
        guard let contents = try? FileManager.default.contentsOfDirectory(
            at: chunksDir, includingPropertiesForKeys: nil
        ) else { return [] }

        return contents
            .filter { $0.lastPathComponent.hasPrefix("\(stem)_") && $0.pathExtension == "wav" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }
}
