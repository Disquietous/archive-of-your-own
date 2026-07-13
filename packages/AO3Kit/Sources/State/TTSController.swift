import SwiftUI
import AVFoundation

@MainActor
@Observable
final class TTSController: NSObject, AVSpeechSynthesizerDelegate {
    private let synthesizer = AVSpeechSynthesizer()
    private var paragraphs: [(index: Int, text: String)] = []

    var isPlaying = false
    var isPaused = false
    var isActive = false
    var currentParagraphIndex = 0
    var totalParagraphs = 0
    var rate: Float = 1.0
    var selectedVoiceId: String?

    private static let rates: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    override init() {
        super.init()
        synthesizer.delegate = self
        selectedVoiceId = UserDefaults.standard.string(forKey: "ttsVoiceId")
        if let savedRate = UserDefaults.standard.object(forKey: "ttsRate") as? Float {
            rate = savedRate
        }
    }

    func setContent(_ blocks: [ParsedContentBlock]) {
        let wasPlaying = isPlaying
        if isPlaying || isPaused {
            synthesizer.stopSpeaking(at: .immediate)
        }
        paragraphs = extractParagraphs(from: blocks)
        totalParagraphs = paragraphs.count
        currentParagraphIndex = 0
        isPlaying = false
        isPaused = false
        if wasPlaying && !paragraphs.isEmpty {
            play()
        }
    }

    func play() {
        guard !paragraphs.isEmpty else { return }
        configureAudioSession()
        isActive = true
        if isPaused {
            synthesizer.continueSpeaking()
            isPlaying = true
            isPaused = false
            return
        }
        speakCurrent()
    }

    private func configureAudioSession() {
        // AVAudioSession is iOS-only; macOS routes audio without session categories.
        #if os(iOS)
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio)
            try session.setActive(true)
        } catch {
            // Best effort — synthesizer may still work without it
        }
        #endif
    }

    func pause() {
        synthesizer.pauseSpeaking(at: .word)
        isPlaying = false
        isPaused = true
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        isPlaying = false
        isPaused = false
        isActive = false
        currentParagraphIndex = 0
        #if os(iOS)
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        #endif
    }

    func skipForward() {
        guard currentParagraphIndex < paragraphs.count - 1 else { return }
        synthesizer.stopSpeaking(at: .immediate)
        currentParagraphIndex += 1
        isPaused = false
        speakCurrent()
    }

    func skipBack() {
        guard currentParagraphIndex > 0 else { return }
        synthesizer.stopSpeaking(at: .immediate)
        currentParagraphIndex -= 1
        isPaused = false
        speakCurrent()
    }

    func cycleRate() {
        guard let idx = Self.rates.firstIndex(of: rate) else {
            rate = 1.0
            return
        }
        rate = Self.rates[(idx + 1) % Self.rates.count]
        UserDefaults.standard.set(rate, forKey: "ttsRate")
        if isPlaying {
            let pos = currentParagraphIndex
            synthesizer.stopSpeaking(at: .immediate)
            currentParagraphIndex = pos
            isPaused = false
            speakCurrent()
        }
    }

    func setVoice(_ voiceId: String) {
        selectedVoiceId = voiceId
        UserDefaults.standard.set(voiceId, forKey: "ttsVoiceId")
        if isPlaying {
            let pos = currentParagraphIndex
            synthesizer.stopSpeaking(at: .immediate)
            currentParagraphIndex = pos
            isPaused = false
            speakCurrent()
        }
    }

    var highlightedBlockIndex: Int? {
        guard isActive, currentParagraphIndex < paragraphs.count else { return nil }
        return paragraphs[currentParagraphIndex].index
    }

    var rateLabel: String {
        rate == Float(Int(rate)) ? "\(Int(rate))x" : String(format: "%.1fx", rate)
    }

    static var availableVoices: [AVSpeechSynthesisVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .sorted { a, b in
                if a.language == b.language { return a.name < b.name }
                return a.language < b.language
            }
    }

    var currentVoiceName: String {
        if let id = selectedVoiceId, let voice = AVSpeechSynthesisVoice(identifier: id) {
            return voice.name
        }
        return "Default"
    }

    // MARK: - Private

    private func speakCurrent() {
        guard currentParagraphIndex < paragraphs.count else {
            isPlaying = false
            isActive = false
            return
        }
        let text = paragraphs[currentParagraphIndex].text
        let utterance = AVSpeechUtterance(string: text)
        utterance.rate = avRate()
        utterance.pitchMultiplier = 1.0
        utterance.preUtteranceDelay = 0.1
        utterance.postUtteranceDelay = 0.2
        if let id = selectedVoiceId {
            utterance.voice = AVSpeechSynthesisVoice(identifier: id)
        }
        isPlaying = true
        synthesizer.speak(utterance)
    }

    private func avRate() -> Float {
        AVSpeechUtteranceDefaultSpeechRate * rate
    }

    private func extractParagraphs(from blocks: [ParsedContentBlock]) -> [(index: Int, text: String)] {
        var result: [(Int, String)] = []
        for (i, block) in blocks.enumerated() {
            if let text = plainText(from: block), !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result.append((i, text))
            }
        }
        return result
    }

    private func plainText(from block: ParsedContentBlock) -> String? {
        switch block {
        case .paragraph(let inlines):
            return inlines.map { inlineText($0) }.joined()
        case .heading(_, let text):
            return text
        case .blockquote(let blocks):
            return blocks.compactMap { plainText(from: $0) }.joined(separator: "\n")
        case .preFormatted(let text):
            return text
        case .list(_, let items):
            return items.map { item in
                item.compactMap { plainText(from: $0) }.joined()
            }.joined(separator: "\n")
        case .horizontalRule:
            return nil
        }
    }

    private func inlineText(_ inline: ParsedInlineContent) -> String {
        switch inline {
        case .text(let value):
            return value
        case .bold(let content), .italic(let content), .strikethrough(let content), .superscript(let content):
            return content.map { inlineText($0) }.joined()
        case .link(_, let content):
            return content.map { inlineText($0) }.joined()
        case .lineBreak:
            return "\n"
        }
    }

    // MARK: - AVSpeechSynthesizerDelegate

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
        Task { @MainActor in
            guard isPlaying else { return }
            if currentParagraphIndex < paragraphs.count - 1 {
                currentParagraphIndex += 1
                speakCurrent()
            } else {
                isPlaying = false
                isActive = false
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    }
}
