import SwiftUI
import CombrayCore

/// Combray's embedded natural voice: the **sherpa-onnx** TTS engine plus British Piper voice
/// models, downloaded once into `Application Support/Combray/NeuralVoice/` (~90 MB), then fully
/// local and offline. This exists because (a) Apple's stock voices are robotic compact models and
/// the good ones require a manual System Settings download, and (b) Anthropic exposes **no TTS
/// API** — the voice in the Claude apps is not available to third-party software.
///
/// Why sherpa-onnx and not Piper's own binaries: rhasspy's macOS release tarballs are broken
/// (x86_64 binaries in the "aarch64" tarball, referencing dylibs that aren't shipped). k2-fsa's
/// sherpa-onnx ships correct arm64 binaries and runs the same Piper voices — verified end-to-end
/// on this machine (9.5s of speech rendered in 1.7s).
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
    /// Package names differ per voice (and so do the .onnx filenames inside — located dynamically).
    private static func voicePackage(female: Bool) -> String {
        female ? "vits-piper-en_GB-southern_english_female_medium"
               : "vits-piper-en_GB-northern_english_male-medium"
    }
    private static func voiceTarURL(female: Bool) -> String {
        "https://github.com/k2-fsa/sherpa-onnx/releases/download/tts-models/\(voicePackage(female: female)).tar.bz2"
    }

    var engineBinary: URL {
        dir.appendingPathComponent("\(Self.engineDirName)/bin/sherpa-onnx-offline-tts")
    }
    func voiceDir(female: Bool) -> URL {
        dir.appendingPathComponent(Self.voicePackage(female: female), isDirectory: true)
    }
    nonisolated static func modelFile(inVoiceDir d: URL) -> URL? {
        (try? FileManager.default.contentsOfDirectory(at: d, includingPropertiesForKeys: nil))?
            .first { $0.pathExtension == "onnx" }
    }

    /// True when the engine and the requested voice are on disk, ready to speak.
    func isReady(female: Bool) -> Bool {
        let d = voiceDir(female: female)
        return FileManager.default.isExecutableFile(atPath: engineBinary.path)
            && Self.modelFile(inVoiceDir: d) != nil
            && FileManager.default.fileExists(atPath: d.appendingPathComponent("tokens.txt").path)
    }

    /// Fetch the engine (once) and the voice for this writer (once per sex). Safe to re-call.
    func install(female: Bool) async {
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
            progress = 0.5
            if Self.modelFile(inVoiceDir: voiceDir(female: female)) == nil {
                try await fetchAndUntar(Self.voiceTarURL(female: female), tarName: "voice.tar.bz2")
            }
            // Downloaded executables must be runnable: strip any quarantine flags in one pass.
            try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", dir.path])
            progress = 1
        } catch {
            lastError = "Couldn’t fetch the natural voice — check the internet connection."
        }
    }

    /// Render `text` to a WAV with the neural voice. Blocking (runs the engine) — call detached.
    nonisolated static func render(text: String, engineBinary: URL, voiceDir: URL) -> URL? {
        guard let model = modelFile(inVoiceDir: voiceDir) else { return nil }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("combray-neural-\(UUID().uuidString).wav")
        let p = Process()
        p.executableURL = engineBinary
        p.arguments = ["--vits-model=\(model.path)",
                       "--vits-tokens=\(voiceDir.appendingPathComponent("tokens.txt").path)",
                       "--vits-data-dir=\(voiceDir.appendingPathComponent("espeak-ng-data").path)",
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
