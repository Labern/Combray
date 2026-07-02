import SwiftUI
import CombrayCore

/// Combray's embedded natural voice: the **sherpa-onnx** TTS engine running the **Kokoro** model
/// (with real British voices), downloaded once into `Application Support/Combray/NeuralVoice/`
/// (~120 MB), then fully local and offline. This exists because (a) Apple's stock voices are
/// robotic compact models and the good ones need a manual System Settings download, and
/// (b) Anthropic exposes **no TTS API** — the Claude apps' voice isn't available to third parties.
///
/// Engine notes, verified end-to-end on this machine:
///  • rhasspy/piper's own macOS tarballs are broken (x86_64 binaries in the "aarch64" tarball,
///    missing dylibs) — k2-fsa/sherpa-onnx ships correct arm64 binaries.
///  • Kokoro int8 renders ~1.9× realtime with 8 threads — fine for chunked render-ahead
///    (the SpeechController streams chunks), not for whole-letter pre-render.
///  • Speaker ids (Kokoro v0.19, documented order): 7 = bf_emma (British female),
///    9 = bm_george (British male).
@MainActor
final class NeuralVoice: ObservableObject {
    static let shared = NeuralVoice()

    @Published private(set) var installing = false
    @Published private(set) var progress: Double = 0      // coarse: per completed file
    @Published private(set) var lastError: String?

    let dir: URL
    init(root: URL = ImageStore.defaultRoot()) {
        dir = root.appendingPathComponent("NeuralVoice", isDirectory: true)
    }

    private static let engineVersion = "1.13.3"
    private static var engineDirName: String { "sherpa-onnx-v\(engineVersion)-osx-arm64-shared" }
    private static var engineTarURL: String {
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/v\(engineVersion)/\(engineDirName).tar.bz2"
    }
    private static let modelDirName = "kokoro-int8-en-v0_19"
    private static var modelTarURL: String {
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/\(modelDirName).tar.bz2"
    }

    var engineBinary: URL {
        dir.appendingPathComponent("\(Self.engineDirName)/bin/sherpa-onnx-offline-tts")
    }
    var modelDir: URL { dir.appendingPathComponent(Self.modelDirName, isDirectory: true) }

    /// Kokoro speaker for the writer's sex — British voices.
    nonisolated static func speakerID(female: Bool) -> Int { female ? 7 : 9 }   // bf_emma / bm_george

    /// True when the engine and the Kokoro model are on disk, ready to speak (either sex).
    func isReady() -> Bool {
        let fm = FileManager.default
        return fm.isExecutableFile(atPath: engineBinary.path)
            && fm.fileExists(atPath: modelDir.appendingPathComponent("model.int8.onnx").path)
            && fm.fileExists(atPath: modelDir.appendingPathComponent("voices.bin").path)
            && fm.fileExists(atPath: modelDir.appendingPathComponent("tokens.txt").path)
    }

    /// Fetch the engine + model (once, ~120 MB total). Safe to re-call.
    func install() async {
        guard !installing else { return }
        installing = true
        progress = 0
        lastError = nil
        defer { installing = false }
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            if !fm.isExecutableFile(atPath: engineBinary.path) {
                try await fetchAndUntar(Self.engineTarURL, tarName: "engine.tar.bz2")
                try? run("/bin/chmod", ["-R", "+x", dir.appendingPathComponent("\(Self.engineDirName)/bin").path])
            }
            progress = 0.3
            if !fm.fileExists(atPath: modelDir.appendingPathComponent("model.int8.onnx").path) {
                try await fetchAndUntar(Self.modelTarURL, tarName: "model.tar.bz2")
            }
            // Downloaded executables must be runnable: strip any quarantine flags in one pass.
            try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", dir.path])
            progress = 1
        } catch {
            lastError = "Couldn’t fetch the natural voice — check the internet connection."
        }
    }

    /// Render `text` to a WAV with the neural voice. Blocking (runs the engine) — call detached.
    nonisolated static func render(text: String, female: Bool, engineBinary: URL, modelDir: URL) -> URL? {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("combray-neural-\(UUID().uuidString).wav")
        let threads = max(2, min(8, ProcessInfo.processInfo.activeProcessorCount - 2))
        let p = Process()
        p.executableURL = engineBinary
        p.arguments = ["--num-threads=\(threads)",
                       "--kokoro-model=\(modelDir.appendingPathComponent("model.int8.onnx").path)",
                       "--kokoro-voices=\(modelDir.appendingPathComponent("voices.bin").path)",
                       "--kokoro-tokens=\(modelDir.appendingPathComponent("tokens.txt").path)",
                       "--kokoro-data-dir=\(modelDir.appendingPathComponent("espeak-ng-data").path)",
                       "--sid=\(speakerID(female: female))",
                       "--output-filename=\(out.path)",
                       text]
        p.standardOutput = Pipe(); p.standardError = Pipe()
        do { try p.run(); p.waitUntilExit() } catch { return nil }
        guard p.terminationStatus == 0,
              ((try? out.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) ?? 0 > 44
        else { try? FileManager.default.removeItem(at: out); return nil }
        return out
    }

    // MARK: plumbing

    private func fetchAndUntar(_ urlString: String, tarName: String) async throws {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        let (tmp, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else {
            try? FileManager.default.removeItem(at: tmp)
            throw URLError(.badServerResponse)
        }
        let tar = dir.appendingPathComponent(tarName)
        try? FileManager.default.removeItem(at: tar)
        try FileManager.default.moveItem(at: tmp, to: tar)
        defer { try? FileManager.default.removeItem(at: tar) }
        try run("/usr/bin/tar", ["xjf", tar.path, "-C", dir.path])
    }

    private func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        p.standardOutput = Pipe(); p.standardError = Pipe()
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw URLError(.cannotParseResponse) }
    }
}
