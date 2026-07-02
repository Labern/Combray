import SwiftUI
import AVFoundation
import CombrayCore

/// Reads a transcription aloud. The audio is **pre-rendered to a file** (`AVSpeechSynthesizer.write`)
/// and played with `AVAudioPlayer` — live `AVSpeechSynthesizer` playback proved unreliable on macOS 26
/// (play/pause/skip silently doing nothing), whereas a rendered file gives bulletproof transport:
/// instant play/pause, *true* seeking for ±15s, and an exact duration for the position timer.
/// Word timings for the on-screen highlight are captured during the render — the synthesizer's
/// `willSpeakRangeOfSpeechString` delegate fires as it writes, and the frames written so far give
/// each word's timestamp. Rendering is ~50× realtime with system voices (a 3-minute letter ≈ 1s).
@MainActor
final class SpeechController: NSObject, ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var isPreparing = false       // rendering the audio (spinner on play)
    @Published private(set) var spokenRange: NSRange?     // word being read, in `text` coordinates
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var total: TimeInterval = 0
    @Published private(set) var voiceIsRobotic = false    // no natural voice installed → offer a download

    private var text = ""
    private var gender: String?
    private var player: AVAudioPlayer?
    private var wordTimes: [(time: TimeInterval, range: NSRange)] = []
    private var tick: Timer?
    private var rendering = false
    private var audioURL: URL?
    private var renderedVoiceID: String?
    private var neuralFailed = false      // engine broke once → stick to the system voice this session

    override init() {
        super.init()
        // If the user downloads a natural voice (Settings opens from the hint below) and comes back,
        // adopt it: drop the old render so the next play uses the better voice.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification,
                                               object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.adoptBetterVoiceIfAvailable() }
        }
    }

    var progress: Double { total > 0 ? min(1, elapsed / total) : 0 }
    var hasText: Bool { !text.isEmpty }

    /// Point the reader at a transcription. Resets playback; the audio renders on first play.
    func configure(text newText: String, gender newGender: String?) {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != text || newGender != gender else { return }
        stop()
        text = trimmed
        gender = newGender
        let voice = SpeechController.voice(forGender: newGender)
        voiceIsRobotic = !NeuralVoice.shared.isReady(female: prefersFemaleVoice)
            && SpeechSupport.voiceIsRobotic(qualityTier: SpeechController.tier(voice))
        total = SpeechSupport.estimateDuration(trimmed, wpm: 165)   // placeholder until rendered
    }

    /// Whether this letter's writer reads as female (drives which voice is used/downloaded).
    var prefersFemaleVoice: Bool { SpeechSupport.wantsFemale(gender) }

    func toggle() { isPlaying ? pause() : play() }

    func play() {
        guard hasText else { return }
        if let p = player { p.play(); isPlaying = true; startTick(); return }
        guard !rendering else { return }
        rendering = true
        isPreparing = true
        let t = text
        let female = prefersFemaleVoice
        let neural = NeuralVoice.shared
        if neural.isReady(female: female), !neuralFailed {
            // Combray's own natural voice — render the WAV off-main, then play.
            let bin = neural.engineBinary, vdir = neural.voiceDir(female: female)
            Task.detached(priority: .userInitiated) { [weak self] in
                let url = NeuralVoice.render(text: t, engineBinary: bin, voiceDir: vdir)
                await MainActor.run { self?.neuralRenderDidFinish(url, forText: t) }
            }
            return
        }
        // System voice. If it's the robotic compact tier, quietly fetch the natural voice for next time.
        if voiceIsRobotic && !neural.installing {
            Task { await neural.install(female: female); self.adoptNeuralIfReady() }
        }
        let voice = SpeechController.voice(forGender: gender)
        Task.detached(priority: .userInitiated) { [weak self] in
            let result = SpeechController.render(text: t, voice: voice)
            await MainActor.run { self?.renderDidFinish(result, forText: t, voiceID: voice?.identifier) }
        }
    }

    /// Explicit "get the natural voice" action from the playback bar.
    func upgradeVoice() {
        let female = prefersFemaleVoice
        Task { await NeuralVoice.shared.install(female: female); self.adoptNeuralIfReady() }
    }

    /// Once the natural voice is installed, drop any robotic render so the next play uses it.
    private func adoptNeuralIfReady() {
        guard NeuralVoice.shared.isReady(female: prefersFemaleVoice) else { return }
        voiceIsRobotic = false
        if renderedVoiceID != "neural", !isPlaying, !rendering {
            player = nil
            removeAudioFile()
            wordTimes = []
            elapsed = 0
            spokenRange = nil
            renderedVoiceID = nil
        }
    }

    func pause() {
        player?.pause()
        isPlaying = false
        stopTick()
        syncNow()
    }

    func stop() {
        player?.stop()
        player = nil
        isPlaying = false
        isPreparing = false
        rendering = false
        stopTick()
        spokenRange = nil
        elapsed = 0
        wordTimes = []
        removeAudioFile()
    }

    /// Jump forward/back by `seconds` — a real seek on the rendered audio.
    func skip(by seconds: TimeInterval) {
        guard let p = player else { if hasText { play() }; return }   // not rendered yet → start it
        p.currentTime = max(0, min(max(0, p.duration - 0.05), p.currentTime + seconds))
        syncNow()
    }

    /// Seek to a fraction of the letter (tap/drag on the progress bar).
    func seek(toFraction f: Double) {
        guard let p = player, p.duration > 0 else { return }
        p.currentTime = max(0, min(p.duration - 0.05, p.duration * max(0, min(1, f))))
        syncNow()
    }

    // MARK: render

    private func renderDidFinish(_ result: RenderResult?, forText t: String, voiceID: String?) {
        rendering = false
        isPreparing = false
        guard text == t else {                       // letter changed while rendering → discard
            if let url = result?.url { try? FileManager.default.removeItem(at: url) }
            return
        }
        guard let r = result, let p = try? AVAudioPlayer(contentsOf: r.url) else { return }
        removeAudioFile()
        audioURL = r.url
        wordTimes = r.words
        total = r.duration
        renderedVoiceID = voiceID
        p.delegate = self
        p.prepareToPlay()
        player = p
        p.play()
        isPlaying = true
        startTick()
    }

    /// Completion for the neural (Piper) render: word highlight uses character-proportional
    /// timings (the engine gives no per-word callbacks); on failure, fall back to the system voice.
    private func neuralRenderDidFinish(_ url: URL?, forText t: String) {
        rendering = false
        isPreparing = false
        guard text == t else {
            if let url { try? FileManager.default.removeItem(at: url) }
            return
        }
        guard let url, let p = try? AVAudioPlayer(contentsOf: url) else {
            neuralFailed = true
            play()                        // retry via the system-voice path
            return
        }
        removeAudioFile()
        audioURL = url
        wordTimes = SpeechSupport.proportionalWordTimes(text: t, duration: p.duration)
        total = p.duration
        renderedVoiceID = "neural"
        voiceIsRobotic = false
        p.delegate = self
        p.prepareToPlay()
        player = p
        p.play()
        isPlaying = true
        startTick()
    }

    private struct RenderResult {
        let url: URL
        let words: [(time: TimeInterval, range: NSRange)]
        let duration: TimeInterval
    }

    /// Render `text` to a CAF file off the main thread, capturing (timestamp, word-range) pairs.
    /// Blocking — call from a detached task. Verified on macOS 26: ~50× realtime, delegate fires.
    nonisolated private static func render(text: String, voice: AVSpeechSynthesisVoice?) -> RenderResult? {
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
        guard box.done.wait(timeout: .now() + 300) == .success else {   // cap: ~4h of audio headroom
            try? FileManager.default.removeItem(at: url); return nil
        }
        box.lock.lock()
        let frames = box.frames
        let rate = box.rate
        let words = box.words.map { (time: Double($0.0) / max(rate, 1), range: $0.1) }
        box.lock.unlock()
        file = nil                                    // close the file before playback opens it
        guard frames > 0, rate > 0 else { try? FileManager.default.removeItem(at: url); return nil }
        return RenderResult(url: url, words: words, duration: Double(frames) / rate)
    }

    private func removeAudioFile() {
        if let u = audioURL { try? FileManager.default.removeItem(at: u) }
        audioURL = nil
    }

    // MARK: position tick (drives the timer + word highlight from true playback time)

    private func startTick() {
        stopTick()
        tick = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.syncNow() }
        }
    }

    private func stopTick() { tick?.invalidate(); tick = nil }

    private func syncNow() {
        guard let p = player else { return }
        elapsed = p.currentTime
        spokenRange = isPlaying || p.isPlaying
            ? wordTimes.last(where: { $0.time <= elapsed + 0.05 })?.range
            : spokenRange
    }

    // MARK: voice selection

    /// Pick the most natural English voice for the writer's sex (defaults to male). We rank the
    /// *installed* voices by quality (premium > enhanced > default) and prefer a UK accent —
    /// the stock Mac only has robotic compact voices, so the hint below guides a one-time download
    /// (System Settings → Accessibility → Spoken Content) and the app adopts it automatically.
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

    /// Voice-quality tier (2 premium / 1 enhanced / 0 default), for ranking and the robotic-voice hint.
    static func tier(_ v: AVSpeechSynthesisVoice?) -> Int {
        switch v?.quality { case .premium: return 2; case .enhanced: return 1; default: return 0 }
    }

    /// On returning to the app (e.g. after downloading a system voice): re-evaluate the best voice;
    /// if a better one is available, drop the old render so the next play uses it.
    private func adoptBetterVoiceIfAvailable() {
        guard hasText else { return }
        if NeuralVoice.shared.isReady(female: prefersFemaleVoice) { adoptNeuralIfReady(); return }
        let best = SpeechController.voice(forGender: gender)
        voiceIsRobotic = SpeechSupport.voiceIsRobotic(qualityTier: SpeechController.tier(best))
        if let id = renderedVoiceID, id != "neural", let newID = best?.identifier, id != newID,
           !isPlaying, !rendering {
            player = nil
            removeAudioFile()
            wordTimes = []
            elapsed = 0
            spokenRange = nil
            renderedVoiceID = nil
        }
    }
}

extension SpeechController: AVAudioPlayerDelegate {
    nonisolated func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        Task { @MainActor in
            self.isPlaying = false
            self.stopTick()
            self.spokenRange = nil
            self.elapsed = 0
            self.player?.currentTime = 0        // keep the render — replay is instant
        }
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
                    Text("Getting Combray’s natural voice — one-time, ~85 MB. It’ll be used automatically.")
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
                .help("Downloads a natural neural voice (~85 MB) into Combray itself — no system settings, used automatically from then on.")
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
