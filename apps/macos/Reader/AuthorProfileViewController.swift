import AppKit

/// The drilled-in author's full profile, shown in the reading pane in
/// place of their works list (toggled by the header's person button).
/// Pure AppKit: a scrolling centered column with the identity header,
/// counts, bio (TextKit via ContentBlockRenderer), and the AO3
/// relationship actions. Re-renders through ObservationRelay whenever
/// the profile cache, subscription list, or theme changes.
final class AuthorProfileViewController: NSViewController {
    private let theme: AppTheme
    private let appState: AppState
    private var username = ""

    private let scrollView = NSScrollView()
    private let documentView = FlippedView()
    private let column = NSStackView()

    private let avatarView = NSImageView()
    private let nameLabel = NSTextField(wrappingLabelWithString: "")
    private let metaLabel = NSTextField(wrappingLabelWithString: "")
    private let pseudsLabel = NSTextField(wrappingLabelWithString: "")
    private let statsLabel = NSTextField(wrappingLabelWithString: "")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let bioView = SelfSizingTextView()
    private let subscribeButton = NSButton(title: "Subscribe", target: nil, action: nil)
    private let blockButton = NSButton(title: "Block…", target: nil, action: nil)
    private let muteButton = NSButton(title: "Mute…", target: nil, action: nil)
    private let actionsRow = NSStackView()
    private let spinner = NSProgressIndicator()

    private var loadedAvatarFor: String?
    private var renderedBioKey: String?

    init(theme: AppTheme, appState: AppState) {
        self.theme = theme
        self.appState = appState
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true

        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.drawsBackground = false
        scrollView.documentView = documentView
        root.addSubview(scrollView)
        NSLayoutConstraint.activate([
            scrollView.topAnchor.constraint(equalTo: root.topAnchor),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: root.bottomAnchor),
        ])

        documentView.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            documentView.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            documentView.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor),
            documentView.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
        ])

        column.translatesAutoresizingMaskIntoConstraints = false
        column.orientation = .vertical
        column.alignment = .leading
        column.spacing = 14
        documentView.addSubview(column)
        NSLayoutConstraint.activate([
            column.topAnchor.constraint(equalTo: documentView.topAnchor, constant: 28),
            column.centerXAnchor.constraint(equalTo: documentView.centerXAnchor),
            column.widthAnchor.constraint(lessThanOrEqualToConstant: 620),
            column.leadingAnchor.constraint(greaterThanOrEqualTo: documentView.leadingAnchor, constant: 28),
            column.bottomAnchor.constraint(equalTo: documentView.bottomAnchor, constant: -28),
        ])
        // Prefer the full 620 width when the pane allows it.
        let preferred = column.widthAnchor.constraint(equalToConstant: 620)
        preferred.priority = .defaultHigh
        preferred.isActive = true

        // Identity header: avatar beside name + meta lines.
        avatarView.translatesAutoresizingMaskIntoConstraints = false
        avatarView.wantsLayer = true
        avatarView.layer?.cornerRadius = 32
        avatarView.layer?.masksToBounds = true
        avatarView.imageScaling = .scaleProportionallyUpOrDown
        NSLayoutConstraint.activate([
            avatarView.widthAnchor.constraint(equalToConstant: 64),
            avatarView.heightAnchor.constraint(equalToConstant: 64),
        ])

        let nameStack = NSStackView(views: [nameLabel, metaLabel, pseudsLabel])
        nameStack.orientation = .vertical
        nameStack.alignment = .leading
        nameStack.spacing = 3

        let headerRow = NSStackView(views: [avatarView, nameStack])
        headerRow.orientation = .horizontal
        headerRow.alignment = .centerY
        headerRow.spacing = 14

        spinner.style = .spinning
        spinner.controlSize = .small
        spinner.isDisplayedWhenStopped = false

        let statusRow = NSStackView(views: [spinner, statusLabel])
        statusRow.orientation = .horizontal
        statusRow.alignment = .firstBaseline
        statusRow.spacing = 6

        bioView.isEditable = false
        bioView.isSelectable = true
        bioView.drawsBackground = false
        bioView.textContainerInset = .zero
        bioView.textContainer?.lineFragmentPadding = 0
        bioView.textContainer?.widthTracksTextView = true
        bioView.isVerticallyResizable = false
        bioView.isHorizontallyResizable = false
        bioView.translatesAutoresizingMaskIntoConstraints = false
        bioView.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)

        subscribeButton.target = self
        subscribeButton.action = #selector(subscribeTapped)
        subscribeButton.bezelStyle = .rounded
        blockButton.target = self
        blockButton.action = #selector(blockTapped)
        blockButton.bezelStyle = .rounded
        muteButton.target = self
        muteButton.action = #selector(muteTapped)
        muteButton.bezelStyle = .rounded

        actionsRow.orientation = .horizontal
        actionsRow.spacing = 8
        actionsRow.setViews([subscribeButton, blockButton, muteButton], in: .leading)

        let separator = NSBox()
        separator.boxType = .separator

        for view in [headerRow, statsLabel, statusRow, bioView, separator, actionsRow] {
            column.addArrangedSubview(view)
        }
        NSLayoutConstraint.activate([
            bioView.widthAnchor.constraint(equalTo: column.widthAnchor),
            separator.widthAnchor.constraint(equalTo: column.widthAnchor),
        ])

        view = root

        ObservationRelay.track { [weak self] in
            self?.render()
        }
    }

    /// Point the pane at an author. Kicks the cached-then-network profile
    /// load; re-invocation with the same author is free.
    func configure(username: String) {
        let canonical = AppState.canonicalAuthorUsername(username)
        if self.username != canonical {
            self.username = canonical
            renderedBioKey = nil
            avatarView.image = nil
            Task { @MainActor in
                await appState.loadUserProfile(canonical)
            }
        }
        if loadedAvatarFor != canonical {
            loadedAvatarFor = canonical
            Task { @MainActor in
                if let data = try? await appState.bridge.fetchAuthorAvatar(canonical),
                   let image = NSImage(data: data), self.username == canonical {
                    avatarView.image = image
                }
            }
        }
        render()
    }

    // MARK: - Render

    private func render() {
        view.layer?.backgroundColor = theme.nsBg.cgColor
        guard !username.isEmpty else { return }

        let profile = appState.userProfile(username)

        nameLabel.font = MacFont.serif(24, weight: .semibold)
        nameLabel.textColor = theme.nsInk
        nameLabel.stringValue = profile?.username ?? username

        metaLabel.font = MacFont.ui(12)
        metaLabel.textColor = theme.nsInk3
        if let profile, !profile.joined.isEmpty {
            metaLabel.stringValue = profile.location.isEmpty
                ? "Joined \(profile.joined)"
                : "Joined \(profile.joined) · \(profile.location)"
            metaLabel.isHidden = false
        } else {
            metaLabel.isHidden = true
        }

        pseudsLabel.font = MacFont.ui(12)
        pseudsLabel.textColor = theme.nsInk3
        if let profile, profile.pseuds.count > 1 {
            pseudsLabel.stringValue = "Pseuds: \(profile.pseuds.joined(separator: ", "))"
            pseudsLabel.isHidden = false
        } else {
            pseudsLabel.isHidden = true
        }

        statsLabel.font = MacFont.ui(12.5, weight: .medium)
        statsLabel.textColor = theme.nsInk2
        if let profile {
            statsLabel.stringValue = [
                ("Works", profile.worksCount),
                ("Series", profile.seriesCount),
                ("Bookmarks", profile.bookmarksCount),
                ("Collections", profile.collectionsCount),
                ("Gifts", profile.giftsCount),
            ].map { "\($0.0) \($0.1)" }.joined(separator: "   ·   ")
            statsLabel.isHidden = false
        } else {
            statsLabel.isHidden = true
        }

        statusLabel.font = MacFont.ui(12)
        let loading = appState.isLoadingUserProfile(username)
        if loading, profile == nil {
            spinner.startAnimation(nil)
            statusLabel.textColor = theme.nsInk3
            statusLabel.stringValue = "Fetching profile from AO3…"
            statusLabel.isHidden = false
        } else if let error = appState.userProfileError(username), profile == nil {
            spinner.stopAnimation(nil)
            statusLabel.textColor = theme.nsInk3
            statusLabel.stringValue = "Couldn’t load profile: \(error)"
            statusLabel.isHidden = false
        } else {
            spinner.stopAnimation(nil)
            var flags: [String] = []
            if profile?.blocked == true { flags.append("Blocked") }
            if profile?.muted == true { flags.append("Muted") }
            statusLabel.textColor = theme.nsAccent
            statusLabel.stringValue = flags.joined(separator: " · ")
            statusLabel.isHidden = flags.isEmpty
        }

        renderBio(profile)
        renderActions(profile)
    }

    private func renderBio(_ profile: UUserProfile?) {
        let blocks = profile.map { ParsedContentBlock.fromJSON($0.bioJson) } ?? []
        let key = "\(username):\(profile?.bioJson.hashValue ?? 0):\(theme.fontSize):\(theme.readingFont.fontName)"
        if blocks.isEmpty {
            bioView.isHidden = true
            renderedBioKey = key
            return
        }
        bioView.isHidden = false
        guard renderedBioKey != key else { return }
        renderedBioKey = key
        let renderer = ContentBlockRenderer(theme: theme, paragraphStyle: .macReading)
        bioView.textStorage?.setAttributedString(renderer.render(blocks: blocks))
        bioView.invalidateIntrinsicContentSize()
    }

    private func renderActions(_ profile: UUserProfile?) {
        let signedIn = appState.ao3Username != nil
        actionsRow.isHidden = !signedIn
        guard signedIn else { return }

        let subscribed = appState.isSubscribedToAuthor(username)
        subscribeButton.title = subscribed ? "Unsubscribe" : "Subscribe"
        subscribeButton.isEnabled = !appState.isUserActionBusy("sub", username)
        subscribeButton.toolTip = subscribed
            ? "Stop receiving updates when \(username) posts"
            : "Get updates when \(username) posts a new work"

        // Block/mute need the live state before they can flip it.
        let haveState = profile != nil
        blockButton.title = profile?.blocked == true ? "Unblock" : "Block…"
        blockButton.isEnabled = haveState && !appState.isUserActionBusy("block", username)
        muteButton.title = profile?.muted == true ? "Unmute" : "Mute…"
        muteButton.isEnabled = haveState && !appState.isUserActionBusy("mute", username)
    }

    // MARK: - Actions

    @objc private func subscribeTapped() {
        appState.toggleAuthorSubscription(username)
    }

    @objc private func blockTapped() {
        if appState.userProfile(username)?.blocked == true {
            appState.toggleAuthorBlock(username)
        } else {
            confirmModeration(
                verb: "Block",
                detail: "\(username) won’t be able to comment on your works or reply to your comments on AO3."
            ) { [weak self] in
                guard let self else { return }
                appState.toggleAuthorBlock(username)
            }
        }
    }

    @objc private func muteTapped() {
        if appState.userProfile(username)?.muted == true {
            appState.toggleAuthorMute(username)
        } else {
            confirmModeration(
                verb: "Mute",
                detail: "You won’t see \(username)’s works, bookmarks, or comments while browsing AO3 signed in."
            ) { [weak self] in
                guard let self else { return }
                appState.toggleAuthorMute(username)
            }
        }
    }

    private func confirmModeration(verb: String, detail: String, confirmed: @escaping () -> Void) {
        guard let window = view.window else { return }
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = "\(verb) \(username)?"
        alert.informativeText = detail
        alert.addButton(withTitle: verb)
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn {
                confirmed()
            }
        }
    }
}
