import Foundation
import CryptoKit

enum FileHasher {
    static func hash(fileAt url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { handle.closeFile() }

        let fileSize = handle.seekToEndOfFile()
        var hasher = SHA256()

        // Hash first 1MB
        handle.seek(toFileOffset: 0)
        let headSize = min(fileSize, 1_048_576)
        let headData = handle.readData(ofLength: Int(headSize))
        hasher.update(data: headData)

        // Hash last 1MB if file > 2MB
        if fileSize > 2_097_152 {
            handle.seek(toFileOffset: fileSize - 1_048_576)
            let tailData = handle.readData(ofLength: 1_048_576)
            hasher.update(data: tailData)
        }

        // Include file size
        withUnsafeBytes(of: fileSize) { hasher.update(bufferPointer: $0) }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
