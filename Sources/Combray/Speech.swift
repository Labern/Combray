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
        total = SpeechSupport.estimateDuration(trimmed, wpm: wpm)
        charOffset = 0; elapsed = 0; spokenRange = nil; isPlaying = false
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

    /// Pick an English voice for the writer's sex (defaults to male). Gender parsing lives in
    /// `SpeechSupport.wantsFemale` (unit-tested).
    static func voice(forGender gender: String?) -> AVSpeechSynthesisVoice? {
        let want: AVSpeechSynthesisVoiceGender = SpeechSupport.wantsFemale(gender) ? .female : .male
        let english = AVSpeechSynthesisVoice.speechVoices().filter { $0.language.hasPrefix("en") }
        return english.first { $0.gender == want } ?? english.first ?? AVSpeechSynthesisVoice(language: "en-US")
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

/// The little play / skip / timer strip shown by the "Transcription" header.
struct PlaybackBar: View {
    @ObservedObject var controller: SpeechController

    var body: some View {
        HStack(spacing: 12) {
            ctl("gobackward.15") { controller.skip(by: -15) }
            ctl(controller.isPlaying ? "pause.fill" : "play.fill", size: 20) { controller.toggle() }
            ctl("goforward.15") { controller.skip(by: 15) }
            GeometryReader { g in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.line)
                    Capsule().fill(Theme.accent).frame(width: max(0, g.size.width * controller.progress))
                }
            }
            .frame(width: 90, height: 4)
            Text("\(SpeechSupport.clock(controller.elapsed)) / \(SpeechSupport.clock(controller.total))")
                .font(.system(size: 13, weight: .medium).monospacedDigit())
                .foregroundStyle(Theme.faint)
        }
        .foregroundStyle(Theme.accentDeep)
    }

    private func ctl(_ icon: String, size: CGFloat = 15, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: size, weight: .semibold))
        }
        .buttonStyle(TapStyle())
    }
}
