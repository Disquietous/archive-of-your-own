import SwiftUI

struct ContentBlockView: View {
    @Environment(AppTheme.self) private var theme

    let blocks: [ParsedContentBlock]
    var compact: Bool = false
    var highlightedIndex: Int?

    var body: some View {
        ForEach(Array(blocks.enumerated()), id: \.offset) { index, block in
            blockView(block, isFirst: index == 0, previousBlock: index > 0 ? blocks[index - 1] : nil)
                .padding(.vertical, highlightedIndex == index ? 2 : 0)
                .background(
                    highlightedIndex == index
                        ? RoundedRectangle(cornerRadius: 4).fill(theme.accentSoft)
                        : RoundedRectangle(cornerRadius: 4).fill(.clear)
                )
                .id("block-\(index)")
        }
    }

    private func previousBlockAddsSpace(_ block: ParsedContentBlock?) -> Bool {
        guard let block else { return false }
        switch block {
        case .paragraph(let inlines):
            return trimmedInlines(inlines).isEmpty
        case .horizontalRule:
            return true
        default:
            return false
        }
    }

    @ViewBuilder
    private func blockView(_ block: ParsedContentBlock, isFirst: Bool, previousBlock: ParsedContentBlock? = nil) -> some View {
        switch block {
        case .paragraph(let inlines):
            if trimmedInlines(inlines).isEmpty {
                // Whitespace-only paragraphs are intentional blank space —
                // <p><br><br></p> scene breaks, <p>&nbsp;</p> spacers. One
                // empty line per <br> (at least one). Genuinely empty
                // <p></p> never gets here: the parser emits no block for a
                // paragraph with no inline content at all.
                let blankLines = max(lineBreakCount(inlines), 1)
                Text(String(repeating: "\n", count: blankLines - 1))
                    .font(compact ? Typography.uiBody() : theme.readingBodyFont)
                    .lineSpacing(compact ? 4 : theme.readingLineSpacing)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text(buildAttributedInlines(inlines))
                    .font(compact ? Typography.uiBody() : theme.readingBodyFont)
                    .lineSpacing(compact ? 4 : theme.readingLineSpacing)
                    .foregroundStyle(theme.ink)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.top, !compact && !isFirst && !previousBlockAddsSpace(previousBlock) ? theme.readingLineSpacing * 1.0 : 0)
            }

        case .heading(let level, let text):
            Text(text)
                .font(headingFont(level))
                .foregroundStyle(theme.ink)
                .padding(.top, level <= 2 ? 16 : 10)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .blockquote(let inner):
            VStack(alignment: .leading, spacing: 8) {
                ContentBlockView(blocks: inner)
            }
            .padding(.leading, 16)
            .overlay(alignment: .leading) {
                Rectangle()
                    .fill(theme.line2)
                    .frame(width: 3)
            }
            .padding(.vertical, 4)

        case .horizontalRule:
            Rectangle()
                .fill(theme.ink)
                .frame(height: 1)
                .padding(.vertical, 12)

        case .list(let ordered, let items):
            VStack(alignment: .leading, spacing: 6) {
                ForEach(Array(items.enumerated()), id: \.offset) { i, itemBlocks in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        if ordered {
                            Text("\(i + 1).")
                                .font(theme.readingBodyFont)
                                .foregroundStyle(theme.ink3)
                                .frame(width: 24, alignment: .trailing)
                        } else {
                            Text("•")
                                .font(theme.readingBodyFont)
                                .foregroundStyle(theme.ink3)
                                .frame(width: 16)
                        }
                        VStack(alignment: .leading, spacing: 4) {
                            ContentBlockView(blocks: itemBlocks)
                        }
                    }
                }
            }

        case .preFormatted(let text):
            Text(text)
                .font(.system(.body, design: .monospaced))
                .foregroundStyle(theme.ink2)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(theme.surface2)
                .clipShape(RoundedRectangle(cornerRadius: 8))

        case .image(let src, let alt):
            ChapterImageView(src: src, alt: alt)
        }
    }

    private func headingFont(_ level: Int) -> Font {
        switch level {
        case 1: .custom("Newsreader", size: 26).weight(.semibold)
        case 2: .custom("Newsreader", size: 22).weight(.semibold)
        case 3: .custom("Newsreader", size: 19).weight(.semibold)
        default: .custom("HankenGrotesk", size: 16).weight(.bold)
        }
    }

    private func trimmedInlines(_ inlines: [ParsedInlineContent]) -> [ParsedInlineContent] {
        var result = inlines
        while let first = result.first, case .text(let v) = first, v.allSatisfy({ $0.isWhitespace || $0.isNewline }) {
            result.removeFirst()
        }
        while let last = result.last, case .text(let v) = last, v.allSatisfy({ $0.isWhitespace || $0.isNewline }) {
            result.removeLast()
        }
        return result
    }

    /// Recursive count of explicit line breaks in an inline tree.
    private func lineBreakCount(_ inlines: [ParsedInlineContent]) -> Int {
        inlines.reduce(0) { total, inline in
            switch inline {
            case .lineBreak:
                return total + 1
            case .bold(let content), .italic(let content), .strikethrough(let content),
                 .superscript(let content), .link(_, let content):
                return total + lineBreakCount(content)
            case .text:
                return total
            }
        }
    }

    /// AO3 authors separate lines with <br><br>; a browser shows that as a
    /// single blank line. Each run of 2+ breaks (whitespace-only text
    /// between them is invisible) collapses to exactly one blank line.
    private func collapseDoubleBreaks(_ inlines: [ParsedInlineContent]) -> [ParsedInlineContent] {
        var out: [ParsedInlineContent] = []
        var i = 0
        while i < inlines.count {
            guard case .lineBreak = inlines[i] else {
                out.append(inlines[i])
                i += 1
                continue
            }
            var breaks = 1
            var lastBreak = i
            var j = i + 1
            scan: while j < inlines.count {
                switch inlines[j] {
                case .lineBreak:
                    breaks += 1
                    lastBreak = j
                    j += 1
                case .text(let value) where value.trimmingCharacters(in: .whitespaces).isEmpty:
                    j += 1
                default:
                    break scan
                }
            }
            out.append(.lineBreak)
            if breaks >= 2 {
                out.append(.lineBreak)
            }
            i = lastBreak + 1
        }
        return out
    }

    private func buildAttributedInlines(_ inlines: [ParsedInlineContent]) -> AttributedString {
        var result = AttributedString()
        if !compact {
            result.append(AttributedString("\u{2002}\u{2002}\u{2002}\u{2002}"))
        }
        for inline in collapseDoubleBreaks(trimmedInlines(inlines)) {
            result.append(attributedString(for: inline))
        }
        return result
    }

    private func attributedString(for inline: ParsedInlineContent) -> AttributedString {
        switch inline {
        case .text(let value):
            return AttributedString(value)

        case .bold(let content):
            var s = AttributedString()
            for c in content { s.append(attributedString(for: c)) }
            s.inlinePresentationIntent = .stronglyEmphasized
            return s

        case .italic(let content):
            var s = AttributedString()
            for c in content { s.append(attributedString(for: c)) }
            s.inlinePresentationIntent = .emphasized
            return s

        case .link(let href, let content):
            var s = AttributedString()
            for c in content { s.append(attributedString(for: c)) }
            if let url = URL(string: href) {
                s.link = url
            }
            return s

        case .strikethrough(let content):
            var s = AttributedString()
            for c in content { s.append(attributedString(for: c)) }
            s.strikethroughStyle = .single
            return s

        case .superscript(let content):
            // Raised and reduced, like the macOS renderer's baseline offset.
            var s = AttributedString()
            for c in content { s.append(attributedString(for: c)) }
            let size = compact ? 11.0 : CGFloat(theme.fontSize) * 0.7
            s.font = compact ? .system(size: size) : .custom(theme.readingFont.fontName, size: size)
            s.baselineOffset = size * 0.45
            return s

        case .lineBreak:
            return AttributedString("\n")
        }
    }
}

/// A chapter-embedded image: cache-first, tap-to-load by default (auto-load
/// honors the shared setting). Bytes always travel over the private
/// connection and land in the encrypted image cache.
struct ChapterImageView: View {
    @Environment(AppTheme.self) private var theme
    @Environment(AppState.self) private var state

    let src: String
    let alt: String

    @State private var image: UIImage?
    @State private var loading = false
    @State private var error: String?

    var body: some View {
        Group {
            if let image {
                VStack(spacing: 4) {
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFit()
                        .clipShape(RoundedRectangle(cornerRadius: 6))
                    if !alt.isEmpty {
                        Text(alt)
                            .font(Typography.uiCaption())
                            .foregroundStyle(theme.ink3)
                            .multilineTextAlignment(.center)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            } else {
                Button {
                    load()
                } label: {
                    HStack(spacing: 8) {
                        if loading {
                            ProgressView().controlSize(.small)
                        } else {
                            Image(systemName: "photo")
                        }
                        Text(placeholderLabel)
                            .lineLimit(2)
                    }
                    .font(Typography.uiBody())
                    .foregroundStyle(error == nil ? theme.accent : theme.ink3)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(theme.surface2)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .buttonStyle(.plain)
                .disabled(loading)
            }
        }
        .onAppear {
            if let data = state.bridge.cachedChapterImage(url: src) {
                image = UIImage(data: data)
            } else if theme.imageAutoLoad {
                load()
            }
        }
    }

    private var placeholderLabel: String {
        if loading { return "Loading image…" }
        if let error { return "\(error) — tap to retry" }
        return alt.isEmpty ? "Tap to load image" : "Tap to load image — \(alt)"
    }

    private func load() {
        guard !loading else { return }
        loading = true
        error = nil
        Task { @MainActor in
            do {
                let data = try await state.bridge.fetchChapterImage(url: src, maxBytes: theme.imageMaxBytes)
                if let decoded = UIImage(data: data) {
                    image = decoded
                } else {
                    let head = data.prefix(16).map { String(format: "%02x", $0) }.joined(separator: " ")
                    state.bridge.writeLog(level: "ERROR", tag: "image",
                        message: "UIImage decode failed for \(src): \(data.count) bytes, head [\(head)]")
                    error = "Couldn’t decode image"
                }
            } catch let fetchError {
                state.bridge.writeLog(level: "ERROR", tag: "image",
                    message: "Fetch failed for \(src): \(fetchError.localizedDescription)")
                error = fetchError.localizedDescription
            }
            loading = false
        }
    }
}
