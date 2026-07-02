import SwiftUI
import AVFoundation
import CombrayCore

/// Reads a transcription aloud. Two engines, one transport:
///
///  • **Neural (preferred)** — Combray's embedded Kokoro voice (see `NeuralVoice`). It renders at
///    ~2× realtime, so the text is split into chunks (`SpeechSupport.chunkRanges`: small first
///    chunk, then larger) and rendered **ahead of playback**: chunk 1 plays within a few seconds
///    while the renderer keeps working ahead. Word highlight uses character-proportional timings.
///
///  • **System (fallback)** — `AVSpeechSynthesizer.write` to a single file (~50× realtime), with
///    exact per-word timestamps from the render-time delegate. Used until the neural voice is
///    installed, or if it fails.
///
/// Playback is always a real `AVAudioPlayer` — live `AVSpeechSynthesizer` playback proved silently
/// broken on macOS 26 (play/pause/skip dead), whereas rendered audio gives instant pause, true
/// seeking, and an exact timer.
@MainActor
final class SpeechController: NSObject, ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var isPreparing = false       // rendering / buffering (spinner on play)
    @Published private(set) var spokenRange: NSRange?     // word being read, in `text` coordinates
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var total: TimeInterval = 0
    @Published private(set) var voiceIsRobotic = false    // best available voice is the compact tier

    private var text = ""
    private var gender: String?
    private var player: AVAudioPlayer?
    private var tick: Timer?

    // Neural chunked mode
    private struct Chunk {
        let range: NSRange                                     // absolute, in `text`
        var url: URL?
        var duration: TimeInterval = 0
        var words: [(time: TimeInterval, range: NSRange)] = [] // times relative to chunk start
    }
    private var chunks: [Chunk] = []
    private var currentChunk = 0
    private var pendingChunkStart: Int?                    // waiting for this chunk to finish rendering
    private var renderGeneration = 0                       // bumped on stop/configure → stale renders discarded
    private var neuralFailed = false                       // engine broke → stick to system voice this session

    // System single-file mode
    private var systemRendering = false
    private var systemAudioURL: URL?
    private var systemWords: [(time: TimeInterval, range: NSRange)] = []
    private var usingSystemFile = false

    override init() { super.init() }

    var progress: Double { total > 0 ? min(1, elapsed / total) : 0 }
    var hasText: Bool { !text.isEmpty }
    var prefersFemaleVoice: Bool { SpeechSupport.wantsFemale(gender) }

    /// Point the reader at a transcription. Resets playback; audio renders on first play.
    func configure(text newText: String, gender newGender: String?) {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != text || newGender != gender else { return }
        stop()
        text = trimmed
        gender = newGender
        let sys = SpeechController.voice(forGender: newGender)
        voiceIsRobotic = !NeuralVoice.shared.isReady()
            && SpeechSupport.voiceIsRobotic(qualityTier: SpeechController.tier(sys))
        total = SpeechSupport.estimateDuration(trimmed, wpm: 165)   // placeholder until rendered
    }

    func toggle() { isPlaying ? pause() : play() }

    func play() {
        guard hasText else { return }
        if let p = player, !p.isPlaying { p.play(); isPlaying = true; startTick(); return }
        guard player == nil, !isPreparing else { return }

        if NeuralVoice.shared.isReady(), !neuralFailed {
            startNeural()
        } else {
            if voiceIsRobotic, !NeuralVoice.shared.installing {
                // Quietly fetch the natural voice for next time; play with the system voice now.
                Task { await NeuralVoice.shared.install(); self.adoptNeuralIfReady() }
            }
            startSystem()
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTick()
        syncNow()
    }

    func stop() {
        renderGeneration += 1
        player?.stop()
        player = nil
        isPlaying = false
        isPreparing = false
        stopTick()
        spokenRange = nil
        elapsed = 0
        for c in chunks { if let u = c.url { try? FileManager.default.removeItem(at: u) } }
        chunks = []
        currentChunk = 0
        pendingChunkStart = nil
        systemRendering = false
        usingSystemFile = false
        systemWords = []
        if let u = systemAudioURL { try? FileManager.default.removeItem(at: u) }
        systemAudioURL = nil
    }

    /// Jump forward/back by `seconds` — a true seek within the rendered audio.
    func skip(by seconds: TimeInterval) {
        guard player != nil || !chunks.isEmpty else { if hasText { play() }; return }
        seek(toTime: currentTime() + seconds)
    }

    /// Seek to a fraction of the letter (tap/drag on the progress bar).
    func seek(toFraction f: Double) {
        guard total > 0 else { return }
        seek(toTime: total * max(0, min(1, f)))
    }

    /// Explicit "get the natural voice" action from the playback bar.
    func upgradeVoice() {
        Task { await NeuralVoice.shared.install(); self.adoptNeuralIfReady() }
    }

    // MARK: - Neural chunked engine

    private func startNeural() {
        isPreparing = true
        usingSystemFile = false
        renderGeneration += 1
        let gen = renderGeneration
        let ranges = SpeechSupport.chunkRanges(text: text)
        guard !ranges.isEmpty else { isPreparing = false; return }
        chunks = ranges.map { Chunk(range: $0) }
        currentChunk = 0
        pendingChunkStart = 0
        let t = text as NSString
        let female = prefersFemaleVoice
        let bin = NeuralVoice.shared.engineBinary
        let mdir = NeuralVoice.shared.modelDir
        Task.detached(priority: .userInitiated) { [weak self] in
            for (i, r) in ranges.enumerated() {
                let alive = await MainActor.run { [weak self] in self?.renderGeneration == gen }
                guard alive else { return }
                let url = NeuralVoice.render(text: t.substring(with: r), female: female,
                                             engineBinary: bin, modelDir: mdir)
                let keepGoing = await MainActor.run { [weak self] in
                    self?.commitChunkRender(index: i, url: url, generation: gen) ?? false
                }
                guard keepGoing else { return }
            }
        }
    }

    /// Store a finished chunk render; start playback if it's the one we're waiting on.
    /// Returns false when the loop should stop (stale generation or engine failure).
    private func commitChunkRender(index: Int, url: URL?, generation: Int) -> Bool {
        guard generation == renderGeneration, index < chunks.count else {
            if let url { try? FileManager.default.removeItem(at: url) }
            return false
        }
        guard let url, let probe = try? AVAudioPlayer(contentsOf: url) else {
            // Engine failed. If nothing has played yet, fall back to the system voice seamlessly.
            neuralFailed = true
            if index == 0 {
                chunks = []
                pendingChunkStart = nil
                isPreparing = false
                startSystem()
            } else {
                pendingChunkStart = nil     // play what we have; stop advancing at the gap
            }
            return false
        }
        chunks[index].url = url
        chunks[index].duration = probe.duration
        let ns = text as NSString
        let sub = ns.substring(with: chunks[index].range)
        chunks[index].words = SpeechSupport.proportionalWordTimes(text: sub, duration: probe.duration)
            .map { (time: $0.time, range: NSRange(location: chunks[index].range.location + $0.range.location,
                                                  length: $0.range.length)) }
        refreshTotal()
        if pendingChunkStart == index {
            pendingChunkStart = nil
            startChunk(index, at: 0)
        }
        return true
    }

    private func startChunk(_ i: Int, at offset: TimeInterval) {
        guard i < chunks.count, let url = chunks[i].url, let p = try? AVAudioPlayer(contentsOf: url) else { return }
        currentChunk = i
        p.delegate = self
        p.prepareToPlay()
        p.currentTime = max(0, min(offset, max(0, p.duration - 0.05)))
        player = p
        p.play()
        isPlaying = true
        isPreparing = false
        startTick()
    }

    private func advancePastCurrentChunk() {
        let next = currentChunk + 1
        player = nil
        if usingSystemFile || chunks.isEmpty || next >= chunks.count {
            // Finished the letter (or the single system file): rest at the start, ready to replay.
            isPlaying = false
            stopTick()
            spokenRange = nil
            elapsed = 0
            currentChunk = 0
            if !chunks.isEmpty, chunks[0].url != nil {
                // keep renders — replay is instant via play()
                if let u = chunks[0].url, let p = try? AVAudioPlayer(contentsOf: u) {
                    p.delegate = self; p.prepareToPlay(); player = p; player?.pause()
                }
            } else if let u = systemAudioURL, let p = try? AVAudioPlayer(contentsOf: u) {
                p.delegate = self; p.prepareToPlay(); player = p; player?.pause()
            }
            return
        }
        if chunks[next].url != nil {
            startChunk(next, at: 0)
        } else {
            // Renderer hasn't caught up — buffer.
            isPlaying = true                 // conceptually still playing; spinner shows
            isPreparing = true
            pendingChunkStart = next
        }
    }

    // MARK: - System single-file engine (fallback)

    private func startSystem() {
        guard !systemRendering else { return }
        if let u = systemAudioURL, let p = try? AVAudioPlayer(contentsOf: u) {
            usingSystemFile = true
            p.delegate = self; p.prepareToPlay(); player = p
            p.play(); isPlaying = true; startTick()
            return
        }
        systemRendering = true
        isPreparing = true
        let t = text
        let voice = SpeechController.voice(forGender: gender)
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = SpeechController.renderSystem(text: t, voice: voice)
            await MainActor.run { self?.systemRenderDidFinish(result, forText: t) }
        }
    }

    private func systemRenderDidFinish(_ result: SystemRender?, forText t: String) {
        systemRendering = false
        isPreparing = false
        guard text == t else {
            if let url = result?.url { try? FileManager.default.removeItem(at: url) }
            return
        }
        guard let r = result, let p = try? AVAudioPlayer(contentsOf: r.url) else { return }
        systemAudioURL = r.url
        systemWords = r.words
        usingSystemFile = true
        total = r.duration
        p.delegate = self
        p.prepareToPlay()
        player = p
        p.play()
        isPlaying = true
        startTick()
    }

    private struct SystemRender {
        let url: URL
        let words: [(time: TimeInterval, range: NSRange)]
        let duration: TimeInterval
    }

    /// Render with `AVSpeechSynthesizer.write` off the main thread, capturing per-word timestamps
    /// (the delegate fires during the render; frames-written at each callback = the word's time).
    nonisolated private static func renderSystem(text: String, voice: AVSpeechSynthesisVoice?) -> SystemRender? {
        final class Box: NSObject, AVSpeechSynthesizerDelegate, @unchecked Sendable {
            let lock = NSLock()
            var frames = 0
            var rate: Double = 0
            var words: [(Int, NSRange)] = []
            let done = DispatchSemaphore(value: 0)
            func speechSynthesizer(_ s: AVSpeechSynthesizer, willSpeakRangeOfSpeechString r: NSRange,
                                   utterance: AVSpeechUtterance) {
                lock.lock(); words.append((frames, r)); lock.unlock()
            }
            func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish u: AVSpeechUtterance) { done.signal() }
            func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel u: AVSpeechUtterance) { done.signal() }
        }
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("combray-readaloud-\(UUID().uuidString).caf")
        let synth = AVSpeechSynthesizer()
        let box = Box()
        synth.delegate = box
        let u = AVSpeechUtterance(string: text)
        u.voice = voice
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        var file: AVAudioFile?
        synth.write(u) { buffer in
            guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else { return }
            box.lock.lock()
            if file == nil {
                box.rate = pcm.format.sampleRate
                file = try? AVAudioFile(forWriting: url, settings: pcm.format.settings)
            }
            try? file?.write(from: pcm)
            box.frames += Int(pcm.frameLength)
            box.lock.unlock()
        }
        guard box.done.wait(timeout: .now() + 300) == .success else {
            try? FileManager.default.removeItem(at: url); return nil
        }
        box.lock.lock()
        let frames = box.frames
        let rate = box.rate
        let words = box.words.map { (time: Double($0.0) / max(rate, 1), range: $0.1) }
        box.lock.unlock()
        file = nil
        guard frames > 0, rate > 0 else { try? FileManager.default.removeItem(at: url); return nil }
        return SystemRender(url: url, words: words, duration: Double(frames) / rate)
    }

    // MARK: - Shared transport

    /// Absolute position across chunks (or within the single system file).
    private func currentTime() -> TimeInterval {
        let inChunk = player?.currentTime ?? 0
        guard !usingSystemFile, !chunks.isEmpty else { return inChunk }
        return chunks.prefix(currentChunk).reduce(0) { $0 + $1.duration } + inChunk
    }

    private func seek(toTime target: TimeInterval) {
        if usingSystemFile || chunks.isEmpty {
            guard let p = player, p.duration > 0 else { return }
            p.currentTime = max(0, min(p.duration - 0.05, target))
            syncNow()
            return
        }
        // Across chunks: clamp into the rendered region, find (chunk, offset).
        var renderedEnd: TimeInterval = 0
        for c in chunks { guard c.url != nil else { break }; renderedEnd += c.duration }
        let t = max(0, min(max(0, renderedEnd - 0.1), target))
        var acc: TimeInterval = 0
        for (i, c) in chunks.enumerated() {
            guard c.url != nil else { break }
            if t < acc + c.duration || i == chunks.count - 1 {
                let wasPlaying = isPlaying
                player?.stop()
                startChunk(i, at: t - acc)
                if !wasPlaying { player?.pause(); isPlaying = false; stopTick() }
                syncNow()
                return
            }
            acc += c.duration
        }
    }

    /// Total = rendered durations + a character-proportional estimate for the unrendered tail.
    private func refreshTotal() {
        guard !chunks.isEmpty else { return }
        var rendered: TimeInterval = 0
        var renderedChars = 0
        var remainingChars = 0
        for c in chunks {
            if c.url != nil { rendered += c.duration; renderedChars += c.range.length }
            else { remainingChars += c.range.length }
        }
        if renderedChars > 0 {
            total = rendered + rendered / Double(renderedChars) * Double(remainingChars)
        }
    }

    private func startTick() {
        stopTick()
        tick = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.syncNow() }
        }
    }
    private func stopTick() { tick?.invalidate(); tick = nil }

    private func syncNow() {
        guard let p = player else { return }
        elapsed = currentTime()
        let words = usingSystemFile || chunks.isEmpty
            ? systemWords
            : (currentChunk < chunks.count ? chunks[currentChunk].words : [])
        spokenRange = words.last(where: { $0.time <= p.currentTime + 0.05 })?.range ?? spokenRange
    }

    /// Once the natural voice is installed, drop any robotic render so the next play uses it.
    private func adoptNeuralIfReady() {
        guard NeuralVoice.shared.isReady() else { return }
        voiceIsRobotic = false
        if usingSystemFile, !isPlaying {
            player = nil
            usingSystemFile = false
            systemWords = []
            if let u = systemAudioURL { try? FileManager.default.removeItem(at: u) }
            systemAudioURL = nil
            elapsed = 0
            spokenRange = nil
        }
    }

    // MARK: - System voice selection

    /// The best installed Apple voice for the writer's sex (fallback engine only).
    static func voice(forGender gender: String?) -> AVSpeechSynthesisVoice? {
        let want: AVSpeechSynthesisVoiceGender = SpeechSupport.wantsFemale(gender) ? .female : .male
        let english = AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .filter { !$0.identifier.hasPrefix("com.apple.speech.synthesis.voice") }  // drop legacy/novelty voices
        func rank(_ v: AVSpeechSynthesisVoice) -> Int {
            SpeechSupport.voiceRank(qualityTier: tier(v), language: v.language, name: v.name,
                                    superCompact: v.identifier.contains("super-compact"))
        }
        let matching = english.filter { $0.gender == want }
        let pool = matching.isEmpty ? english : matching
        return pool.max { rank($0) < rank($1) }
            ?? AVSpeechSynthesisVoice(language: "en-GB")
            ?? AVSpeechSynthesisVoice(language: "en-US")
    }

    /// Voice-quality tier (2 premium / 1 enhanced / 0 default), for ranking and the robotic hint.
    static func tier(_ v: AVSpeechSynthesisVoice?) -> Int {
        switch v?.quality { case .premium: return 2; case .enhanced: return 1; default: return 0 }
    }
}

extension SpeechController: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in self.advancePastCurrentChunk() }
    }
}

/// The read-aloud control strip: play/pause · position / total timer · progress (tap to seek) ·
/// ±15s. Shown full-width beneath the "Transcription" header.
struct PlaybackBar: View {
    @ObservedObject var controller: SpeechController
    @ObservedObject private var neural = NeuralVoice.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                if controller.isPreparing {
                    ProgressView().controlSize(.small).frame(width: 28, height: 28)
                } else {
                    ctl(controller.isPlaying ? "pause.circle.fill" : "play.circle.fill", size: 28) { controller.toggle() }
                }

                // position / total — left of the progress bar; fixedSize so it's never clipped
                Text("\(SpeechSupport.clock(controller.elapsed)) / \(SpeechSupport.clock(controller.total))")
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.ink)
                    .fixedSize()

                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.line)
                        Capsule().fill(Theme.accent).frame(width: max(3, g.size.width * controller.progress))
                    }
                    .contentShape(Rectangle())
                    .gesture(DragGesture(minimumDistance: 0).onChanged { v in
                        controller.seek(toFraction: v.location.x / max(1, g.size.width))
                    })
                }
                .frame(height: 5)
                .frame(maxWidth: .infinity)

                // skip controls after the progress bar
                ctl("gobackward.15", size: 19) { controller.skip(by: -15) }
                ctl("goforward.15", size: 19) { controller.skip(by: 15) }
            }
            .foregroundStyle(Theme.accentDeep)

            // Voice-quality strip: only surfaces while Combray's natural voice isn't in place yet.
            if neural.installing {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("Getting Combray’s natural voice — one-time, ~120 MB. It’ll be used automatically.")
                        .font(.system(size: 12, weight: .medium))
                }
                .foregroundStyle(Theme.faint)
            } else if controller.voiceIsRobotic {
                Button { controller.upgradeVoice() } label: {
                    Label(neural.lastError == nil
                            ? "This voice sounds robotic — get Combray’s natural voice (free, one-time)"
                            : "Natural voice download failed — click to retry",
                          systemImage: "waveform.badge.plus")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(TapStyle())
                .foregroundStyle(Theme.faint)
                .help("Downloads a natural neural voice (~120 MB) into Combray itself — no system settings, used automatically from then on.")
            }
        }
    }

    private func ctl(_ icon: String, size: CGFloat = 15, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: size, weight: .semibold))
        }
        .buttonStyle(TapStyle())
    }
}
