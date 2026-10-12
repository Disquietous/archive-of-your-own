import SwiftUI
import AVFoundation
#if os(iOS)
import MediaPlayer
#endif

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

    /// What is being read: the work and 0-based chapter the paragraphs came
    /// from. In memory only, never shown outside the app — the lock screen
    /// entry is anonymous (`nowPlayingTitle`).
    private(set) var source: (workID: String, chapter: Int)?
    /// The reader that started (or re-adopted) playback. Leaving that
    /// reader stops speech; a reader torn down by the app locking does not.
    var owner: UUID?

    /// The only thing the system Now Playing surfaces (lock screen, Control
    /// Center, headphones) ever show — nothing derived from the work.
    static let nowPlayingTitle = "AOYO - Reading Work"

    private static let rates: [Float] = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0]

    override init() {
        super.init()
        synthesizer.delegate = self
        selectedVoiceId = UserDefaults.standard.string(forKey: "ttsVoiceId")
        if let savedRate = UserDefaults.standard.object(forKey: "ttsRate") as? Float {
            rate = savedRate
        }
        #if os(iOS)
        observeAudioSession()
        #endif
    }

    /// Start reading a chapter for a reader: replaces whatever was playing.
    func start(_ blocks: [ParsedContentBlock], workID: String, chapter: Int, owner: UUID) {
        self.owner = owner
        source = (workID, chapter)
        setContent(blocks)
        play()
    }

    /// True while this work's speech is the active session.
    func isReading(workID: String) -> Bool {
        isActive && source?.workID == workID
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
            updateNowPlaying()
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
        updateNowPlaying()
    }

    func stop() {
        synthesizer.stopSpeaking(at: .immediate)
        isPlaying = false
        isPaused = false
        isActive = false
        currentParagraphIndex = 0
        source = nil
        owner = nil
        #if os(iOS)
        clearNowPlaying()
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
            finish()
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
        updateNowPlaying()
    }

    /// Reached the end of the chapter's paragraphs.
    private func finish() {
        isPlaying = false
        isActive = false
        #if os(iOS)
        clearNowPlaying()
        #endif
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
        case .image(_, let alt):
            // Speak the alt text when the author provided one.
            return alt.isEmpty ? nil : "Image: \(alt)"
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
                finish()
            }
        }
    }

    nonisolated func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    }

    // MARK: - System Now Playing (iOS)

    /// Keeps the lock screen / Control Center entry in step with playback.
    /// Only `nowPlayingTitle` and the play state are published: no artist,
    /// artwork, chapter, progress or duration.
    private func updateNowPlaying() {
        #if os(iOS)
        guard isActive else { return }
        installRemoteCommands()
        MPNowPlayingInfoCenter.default().nowPlayingInfo = [
            MPMediaItemPropertyTitle: Self.nowPlayingTitle,
            MPNowPlayingInfoPropertyPlaybackRate: isPlaying ? 1.0 : 0.0,
        ]
        MPNowPlayingInfoCenter.default().playbackState = isPlaying ? .playing : .paused
        #endif
    }

    #if os(iOS)
    private var remoteCommandsInstalled = false

    private func clearNowPlaying() {
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
        MPNowPlayingInfoCenter.default().playbackState = .stopped
    }

    /// Play/pause and paragraph skip from the lock screen, Control Center
    /// and headphones. Installed once; handlers act on whatever is loaded.
    private func installRemoteCommands() {
        guard !remoteCommandsInstalled else { return }
        remoteCommandsInstalled = true
        let center = MPRemoteCommandCenter.shared()
        center.playCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.remotePlay() ?? .noActionableNowPlayingItem }
        }
        center.pauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated { self?.remotePause() ?? .noActionableNowPlayingItem }
        }
        center.togglePlayPauseCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return .noActionableNowPlayingItem }
                return self.isPlaying ? self.remotePause() : self.remotePlay()
            }
        }
        center.nextTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isActive else { return .noActionableNowPlayingItem }
                self.skipForward()
                return .success
            }
        }
        center.previousTrackCommand.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isActive else { return .noActionableNowPlayingItem }
                self.skipBack()
                return .success
            }
        }
    }

    private func remotePlay() -> MPRemoteCommandHandlerStatus {
        guard isActive, !paragraphs.isEmpty else { return .noActionableNowPlayingItem }
        play()
        return .success
    }

    private func remotePause() -> MPRemoteCommandHandlerStatus {
        guard isPlaying else { return .commandFailed }
        pause()
        return .success
    }

    /// Calls, Siri and other audio pause speech; it resumes when the system
    /// says so. Unplugging headphones pauses rather than moving to the
    /// speaker.
    private func observeAudioSession() {
        let center = NotificationCenter.default
        center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init)
            let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt)
                .map(AVAudioSession.InterruptionOptions.init) ?? []
            MainActor.assumeIsolated {
                guard let self, self.isActive else { return }
                switch type {
                case .began:
                    if self.isPlaying { self.pause() }
                case .ended:
                    if options.contains(.shouldResume), self.isPaused { self.play() }
                default:
                    break
                }
            }
        }
        center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt)
                .flatMap(AVAudioSession.RouteChangeReason.init)
            MainActor.assumeIsolated {
                guard let self, reason == .oldDeviceUnavailable, self.isPlaying else { return }
                self.pause()
            }
        }
    }
    #endif
}
