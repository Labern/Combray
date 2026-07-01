import SwiftUI
import AVFoundation
import CombrayCore

/// Reads a transcription aloud with `AVSpeechSynthesizer`: play/pause, ±15s skip, a position/total
/// timer, the word currently being spoken (for highlighting), and a male/female voice chosen from
/// the writer's detected sex (defaulting to male).
@MainActor
final class SpeechController: NSObject, ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var spokenRange: NSRange?     // word being read, in `text` coordinates
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var total: TimeInterval = 0
    @Published private(set) var voiceIsRobotic = false    // no natural voice installed → offer a download

    private let synth = AVSpeechSynthesizer()
    private var text = ""
    private var voice: AVSpeechSynthesisVoice?
    private var charOffset = 0                              // where the current utterance starts in `text`
    private let wpm = 165.0                                 // words/min at the default rate (for the estimate)

    override init() { super.init(); synth.delegate = self }

    var progress: Double { total > 0 ? min(1, elapsed / total) : 0 }
    var hasText: Bool { !text.isEmpty }

    /// Point the reader at a transcription. Resets playback.
    func configure(text newText: String, gender: String?) {
        let trimmed = newText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed != text else { return }
        synth.stopSpeaking(at: .immediate)
        text = trimmed
        voice = SpeechController.voice(forGender: gender)
        voiceIsRobotic = SpeechSupport.voiceIsRobotic(qualityTier: SpeechController.tier(voice))
        total = SpeechSupport.estimateDuration(trimmed, wpm: wpm)
        charOffset = 0; elapsed = 0; spokenRange = nil; isPlaying = false
    }

    /// Open macOS's Spoken Content settings so the user can download a natural (enhanced/premium)
    /// voice — the only way off the robotic compact voices. The app auto-adopts it once installed.
    static func openVoiceSettings() {
        let candidates = [
            "x-apple.systempreferences:com.apple.Accessibility-Settings.extension?SpokenContent",
            "x-apple.systempreferences:com.apple.preference.universalaccess?SpokenContent",
            "x-apple.systempreferences:com.apple.preference.universalaccess",
        ]
        for s in candidates { if let u = URL(string: s), NSWorkspace.shared.open(u) { return } }
    }

    func toggle() { isPlaying ? pause() : play() }

    func play() {
        guard hasText else { return }
        if synth.isPaused { synth.continueSpeaking(); isPlaying = true; return }
        speak(from: charOffset)
    }

    func pause() { synth.pauseSpeaking(at: .word); isPlaying = false }

    func stop() {
        synth.stopSpeaking(at: .immediate)
        isPlaying = false; spokenRange = nil; elapsed = 0; charOffset = 0
    }

    /// Jump forward/back by `seconds` (re-speaks from the nearest word — AVSpeech has no seek).
    func skip(by seconds: TimeInterval) {
        guard hasText, total > 0 else { return }
        let frac = max(0, min(1, (elapsed + seconds) / total))
        let ns = text as NSString
        let target = Int(Double(ns.length) * frac)
        charOffset = SpeechSupport.wordStart(in: text, at: min(target, ns.length))
        elapsed = Double(charOffset) / Double(max(1, ns.length)) * total
        let wasActive = isPlaying || synth.isSpeaking || synth.isPaused
        synth.stopSpeaking(at: .immediate)
        if wasActive && charOffset < ns.length { speak(from: charOffset) }
        else { spokenRange = nil; isPlaying = false }
    }

    private func speak(from offset: Int) {
        let ns = text as NSString
        guard offset < ns.length else { stop(); return }
        let u = AVSpeechUtterance(string: ns.substring(from: offset))
        u.voice = voice
        u.rate = AVSpeechUtteranceDefaultSpeechRate
        synth.stopSpeaking(at: .immediate)
        synth.speak(u)
        isPlaying = true
    }

    // MARK: voice selection

    /// Pick the most natural English voice for the writer's sex (defaults to male). We rank the
    /// *installed* voices by quality (premium > enhanced > default) and prefer a UK accent, rather
    /// than grabbing the first match — which is the tinny compact system default. Voice ranking is
    /// the unit-tested `SpeechSupport.voiceRank`; note the enhanced/premium voices only appear here
    /// once the user has downloaded them (System Settings → Accessibility → Spoken Content).
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
}

extension SpeechController: AVSpeechSynthesizerDelegate {
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer,
                                       willSpeakRangeOfSpeechString characterRange: NSRange,
                                       utterance: AVSpeechUtterance) {
        Task { @MainActor in
            let abs = NSRange(location: charOffset + characterRange.location, length: characterRange.length)
            spokenRange = abs
            elapsed = Double(abs.location) / Double(max(1, (text as NSString).length)) * total
        }
    }
    nonisolated func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in isPlaying = false; spokenRange = nil; elapsed = total; charOffset = 0 }
    }
}

/// The read-aloud control strip: play/pause, ±15s, a progress bar, and a **position / total timer**
/// that is always visible. Shown full-width beneath the "Transcription" header.
struct PlaybackBar: View {
    @ObservedObject var controller: SpeechController

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 16) {
                ctl(controller.isPlaying ? "pause.circle.fill" : "play.circle.fill", size: 28) { controller.toggle() }
                ctl("gobackward.15", size: 19) { controller.skip(by: -15) }
                ctl("goforward.15", size: 19) { controller.skip(by: 15) }

                GeometryReader { g in
                    ZStack(alignment: .leading) {
                        Capsule().fill(Theme.line)
                        Capsule().fill(Theme.accent).frame(width: max(3, g.size.width * controller.progress))
                    }
                }
                .frame(height: 5)
                .frame(maxWidth: .infinity)

                // position / total — fixedSize so it can never be clipped away
                Text("\(SpeechSupport.clock(controller.elapsed)) / \(SpeechSupport.clock(controller.total))")
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .foregroundStyle(Theme.ink)
                    .fixedSize()
            }
            .foregroundStyle(Theme.accentDeep)

            // Only surfaces when there's no natural voice installed — the real fix for "the voice is awful".
            if controller.voiceIsRobotic {
                Button { SpeechController.openVoiceSettings() } label: {
                    Label("The Mac's built-in voices sound robotic — click to install a natural one (free)",
                          systemImage: "waveform.badge.plus")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(TapStyle())
                .foregroundStyle(Theme.faint)
                .help("Opens System Settings → Spoken Content. Download an English voice; the app uses it automatically.")
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
