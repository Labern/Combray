import SwiftUI
import CombrayCore

/// Combray's embedded natural voice: the **Piper** neural TTS engine plus British voice models,
/// downloaded once into `Application Support/Combray/NeuralVoice/` (~85 MB), then fully local and
/// offline. This exists because (a) Apple's stock voices are robotic compact models and the good
/// ones require a manual System Settings download, and (b) Anthropic exposes **no TTS API** — the
/// voice in the Claude apps is not available to third-party software. Piper is the way to a
/// genuinely natural voice with zero user setup: the app fetches it itself on first use.
@MainActor
final class NeuralVoice: ObservableObject {
    static let shared = NeuralVoice()

    @Published private(set) var installing = false
    @Published private(set) var progress: Double = 0      // 0…1 across engine + voice files
    @Published private(set) var lastError: String?

    let dir: URL
    init(root: URL = ImageStore.defaultRoot()) {
        dir = root.appendingPathComponent("NeuralVoice", isDirectory: true)
    }

    var engineDir: URL { dir.appendingPathComponent("piper", isDirectory: true) }
    var engineBinary: URL { engineDir.appendingPathComponent("piper") }
    func modelURL(female: Bool) -> URL {
        dir.appendingPathComponent(female ? "en_GB-cori-medium.onnx" : "en_GB-northern_english_male-medium.onnx")
    }

    private static let engineTar =
        "https://github.com/rhasspy/piper/releases/download/2023.11.14-2/piper_macos_aarch64.tar.gz"
    private static func voiceBase(female: Bool) -> String {
        female
            ? "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/cori/medium/en_GB-cori-medium.onnx"
            : "https://huggingface.co/rhasspy/piper-voices/resolve/main/en/en_GB/northern_english_male/medium/en_GB-northern_english_male-medium.onnx"
    }

    /// True when the engine and the requested voice are on disk, ready to speak.
    func isReady(female: Bool) -> Bool {
        FileManager.default.isExecutableFile(atPath: engineBinary.path)
            && FileManager.default.fileExists(atPath: modelURL(female: female).path)
            && FileManager.default.fileExists(atPath: modelURL(female: female).appendingPathExtension("json").path)
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

            // 1. engine (~60% of the bar)
            if !fm.isExecutableFile(atPath: engineBinary.path) {
                let tar = dir.appendingPathComponent("piper.tar.gz")
                try await download(Self.engineTar, to: tar) { [weak self] f in self?.progress = f * 0.45 }
                try run("/usr/bin/tar", ["xzf", tar.path, "-C", dir.path])
                try? fm.removeItem(at: tar)
                // Downloaded binaries must be runnable: strip quarantine, ensure an ad-hoc signature.
                try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", dir.path])
                try? run("/bin/chmod", ["+x", engineBinary.path])
                try? run("/usr/bin/codesign", ["--force", "--sign", "-", engineBinary.path])
                progress = 0.55
            } else { progress = 0.55 }

            // 2. voice model + config
            let model = modelURL(female: female)
            if !fm.fileExists(atPath: model.path) {
                try await download(Self.voiceBase(female: female), to: model) { [weak self] f in
                    self?.progress = 0.55 + f * 0.42
                }
            }
            let config = model.appendingPathExtension("json")
            if !fm.fileExists(atPath: config.path) {
                try await download(Self.voiceBase(female: female) + ".json", to: config) { _ in }
            }
            progress = 1
        } catch {
            lastError = "Couldn’t fetch the natural voice — check the internet connection."
        }
    }

    /// Render `text` to a WAV with the neural voice. Blocking (runs the engine) — call detached.
    nonisolated static func render(text: String, engineBinary: URL, engineDir: URL, model: URL) -> URL? {
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("combray-neural-\(UUID().uuidString).wav")
        let p = Process()
        p.executableURL = engineBinary
        p.currentDirectoryURL = engineDir      // piper finds espeak-ng-data beside the binary
        p.arguments = ["--model", model.path,
                       "--config", model.appendingPathExtension("json").path,
                       "--output_file", out.path]
        let stdin = Pipe()
        p.standardInput = stdin
        p.standardOutput = Pipe()
        p.standardError = Pipe()
        do {
            try p.run()
            stdin.fileHandleForWriting.write(Data(text.utf8))
            stdin.fileHandleForWriting.closeFile()
            p.waitUntilExit()
        } catch { return nil }
        guard p.terminationStatus == 0,
              (try? out.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0) ?? 0 > 44
        else { try? FileManager.default.removeItem(at: out); return nil }
        return out
    }

    // MARK: plumbing

    private func download(_ urlString: String, to dest: URL,
                          onProgress: @escaping @MainActor (Double) -> Void) async throws {
        guard let url = URL(string: urlString) else { throw URLError(.badURL) }
        let (tmp, response) = try await URLSession.shared.download(from: url)
        guard (response as? HTTPURLResponse).map({ (200..<300).contains($0.statusCode) }) ?? false else {
            try? FileManager.default.removeItem(at: tmp)
            throw URLError(.badServerResponse)
        }
        try? FileManager.default.removeItem(at: dest)
        try FileManager.default.moveItem(at: tmp, to: dest)
        onProgress(1)
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
