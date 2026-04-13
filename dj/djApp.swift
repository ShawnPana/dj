import SwiftUI

@main
struct djApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
        .defaultSize(width: 750, height: 520)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    private var serverProcess: Process?

    func applicationDidFinishLaunching(_ notification: Notification) {
        startStemServer()
    }

    func applicationWillTerminate(_ notification: Notification) {
        stopStemServer()
    }

    private func startStemServer() {
        let scriptPath = Bundle.main.path(forResource: "stem_server", ofType: "py")
            ?? findStemServerScript()

        guard let path = scriptPath else {
            print("stem_server.py not found")
            return
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/Library/Frameworks/Python.framework/Versions/3.12/bin/python3")
        process.arguments = [path]
        process.environment = ProcessInfo.processInfo.environment
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            serverProcess = process
            print("Stem server started (PID: \(process.processIdentifier))")
        } catch {
            print("Failed to start stem server: \(error)")
        }
    }

    private func stopStemServer() {
        if let process = serverProcess, process.isRunning {
            process.terminate()
            print("Stem server stopped")
        }
    }

    private func findStemServerScript() -> String? {
        // Look relative to the app/project
        let candidates = [
            // Development: relative to project
            URL(fileURLWithPath: #file)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("scripts/stem_server.py").path,
            // Fallback: hardcoded project path
            NSString("~/Projects/dj/scripts/stem_server.py").expandingTildeInPath
        ]
        return candidates.first { FileManager.default.fileExists(atPath: $0) }
    }
}
