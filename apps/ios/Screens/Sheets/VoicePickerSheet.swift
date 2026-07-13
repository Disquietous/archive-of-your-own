import SwiftUI
import AVFoundation

struct VoicePickerSheet: View {
    @Environment(AppTheme.self) private var theme
    @Environment(\.dismiss) private var dismiss

    let tts: TTSController

    @State private var searchText = ""

    private var voices: [AVSpeechSynthesisVoice] {
        let all = TTSController.availableVoices
        if searchText.isEmpty { return all }
        let query = searchText.lowercased()
        return all.filter {
            $0.name.lowercased().contains(query) ||
            $0.language.lowercased().contains(query) ||
            languageDisplayName($0.language).lowercased().contains(query)
        }
    }

    private var groupedVoices: [(String, [AVSpeechSynthesisVoice])] {
        Dictionary(grouping: voices) { languageDisplayName($0.language) }
            .sorted { $0.key < $1.key }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    Button {
                        tts.setVoice("")
                        dismiss()
                    } label: {
                        HStack {
                            Text("System Default")
                                .foregroundStyle(theme.ink)
                            Spacer()
                            if tts.selectedVoiceId == nil || tts.selectedVoiceId?.isEmpty == true {
                                Image(systemName: "checkmark")
                                    .foregroundStyle(theme.accent)
                            }
                        }
                    }
                }

                ForEach(groupedVoices, id: \.0) { language, languageVoices in
                    Section(header: Text(language)) {
                        ForEach(languageVoices, id: \.identifier) { voice in
                            Button {
                                tts.setVoice(voice.identifier)
                                dismiss()
                            } label: {
                                HStack {
                                    VStack(alignment: .leading, spacing: 2) {
                                        Text(voice.name)
                                            .font(.custom("HankenGrotesk", size: 15).weight(.medium))
                                            .foregroundStyle(theme.ink)
                                        Text(qualityLabel(voice.quality))
                                            .font(.custom("HankenGrotesk", size: 12).weight(.medium))
                                            .foregroundStyle(theme.ink3)
                                    }
                                    Spacer()
                                    if tts.selectedVoiceId == voice.identifier {
                                        Image(systemName: "checkmark")
                                            .foregroundStyle(theme.accent)
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $searchText, prompt: "Search voices")
            .navigationTitle("Voice")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.large])
    }

    private func languageDisplayName(_ code: String) -> String {
        Locale.current.localizedString(forIdentifier: code) ?? code
    }

    private func qualityLabel(_ quality: AVSpeechSynthesisVoiceQuality) -> String {
        switch quality {
        case .enhanced: "Enhanced"
        case .premium: "Premium"
        default: "Default"
        }
    }
}
