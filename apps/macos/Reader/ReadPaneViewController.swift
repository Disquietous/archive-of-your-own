import AppKit
import SwiftUI

/// Right pane shell: 52px toolbar + either the work detail or the in-place
/// reader, with the privacy dot, reading-settings popover, and the floating
/// immersive exit button.
final class ReadPaneViewController: NSViewController {
    private let theme: AppTheme
    private let appState: AppState
    private let model: MacAppModel

    private let toolbar: PaneToolbarView
    private let container = NSView()
    private let privacyDot = NSView()
    private let immersiveExit = NSButton()

    private var backButton: ToolButton!
    private var settingsButton: ToolButton!
    private var immersiveButton: ToolButton!
    private var bookmarkButton: ToolButton!

    private let readerController: ReaderViewController
    private var detailHost: NSHostingView<AnyView>?
    private var emptyHost: NSHostingView<AnyView>?
    private var settingsPopover: NSPopover?

    private enum Mode: Equatable {
        case empty, detail(String), reading(String, Int)
    }

    private var renderedMode: Mode?

    init(theme: AppTheme, appState: AppState, model: MacAppModel) {
        self.theme = theme
        self.appState = appState
        self.model = model
        self.toolbar = PaneToolbarView(theme: theme)
        self.readerController = ReaderViewController(theme: theme, model: model)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not supported")
    }

    override func loadView() {
        let root = NSView()
        root.wantsLayer = true

        backButton = ToolButton(theme: theme, symbol: "arrow.left", tooltip: "Back to details") { [weak self] in
            self?.model.closeReader()
        }
        settingsButton = ToolButton(theme: theme, symbol: "textformat.size", tooltip: "Reading settings") { [weak self] in
            self?.toggleSettingsPopover()
        }
        immersiveButton = ToolButton(theme: theme, symbol: "safari", tooltip: "Immersive reading") { [weak self] in
            self?.model.immersive.toggle()
        }
        bookmarkButton = ToolButton(theme: theme, symbol: "bookmark", tooltip: "Bookmark") { [weak self] in
            guard let self, let id = model.selectedWorkID else { return }
            model.toggle(id, in: &model.bookmarks)
        }

        addChild(readerController)

        toolbar.translatesAutoresizingMaskIntoConstraints = false
        container.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(toolbar)
        root.addSubview(container)

        privacyDot.wantsLayer = true
        privacyDot.layer?.cornerRadius = 4
        privacyDot.toolTip = "Private connection"
        privacyDot.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(privacyDot)

        immersiveExit.isBordered = false
        immersiveExit.wantsLayer = true
        immersiveExit.layer?.cornerRadius = 9
        immersiveExit.layer?.borderWidth = 1
        immersiveExit.image = NSImage(systemSymbolName: "chevron.left", accessibilityDescription: "Exit immersive")?
            .withSymbolConfiguration(.init(pointSize: 13, weight: .semibold))
        immersiveExit.toolTip = "Exit immersive (Esc)"
        immersiveExit.target = self
        immersiveExit.action = #selector(exitImmersive)
        immersiveExit.translatesAutoresizingMaskIntoConstraints = false
        root.addSubview(immersiveExit)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.topAnchor.constraint(equalTo: toolbar.bottomAnchor),
            container.leadingAnchor.constraint(equalTo: root.leadingAnchor),
            container.trailingAnchor.constraint(equalTo: root.trailingAnchor),
            container.bottomAnchor.constraint(equalTo: root.bottomAnchor),
            privacyDot.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 10),
            privacyDot.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -18),
            privacyDot.widthAnchor.constraint(equalToConstant: 8),
            privacyDot.heightAnchor.constraint(equalToConstant: 8),
            immersiveExit.topAnchor.constraint(equalTo: root.topAnchor, constant: 14),
            immersiveExit.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 14),
            immersiveExit.widthAnchor.constraint(equalToConstant: 34),
            immersiveExit.heightAnchor.constraint(equalToConstant: 34),
        ])
        view = root

        ObservationRelay.track { [weak self] in
            self?.render()
        }
    }

    // MARK: - Render

    private func render() {
        view.layer?.backgroundColor = theme.nsBg.cgColor
        toolbar.applyTheme()
        privacyDot.layer?.backgroundColor = theme.nsSage.cgColor
        immersiveExit.layer?.backgroundColor = theme.nsSurface.cgColor
        immersiveExit.layer?.borderColor = theme.nsLine.cgColor
        immersiveExit.contentTintColor = theme.nsInk2
        immersiveExit.isHidden = !model.immersive

        guard let work = model.selectedWork else {
            toolbar.configure(title: "", sub: nil)
            toolbar.setLeading([])
            toolbar.setTrailing([])
            show(mode: .empty)
            return
        }

        let reading = model.readerOpen
        toolbar.configure(title: reading ? work.title : "Details", sub: nil)
        toolbar.setLeading(reading ? [backButton] : [])
        immersiveButton.isOn = model.immersive
        bookmarkButton.setSymbol(model.bookmarks.contains(work.id) ? "bookmark.fill" : "bookmark")
        bookmarkButton.tintOverride = model.bookmarks.contains(work.id) ? theme.nsAccent : nil
        toolbar.setTrailing(reading ? [settingsButton, immersiveButton, bookmarkButton]
                                    : [settingsButton, bookmarkButton])

        show(mode: reading ? .reading(work.id, model.readerChapter) : .detail(work.id))

        // Detail is SwiftUI and re-renders itself; only rebuild on identity change.
        if case .detail = renderedMode, let host = detailHost {
            host.rootView = AnyView(DetailView(theme: theme, model: model, work: work))
        }
    }

    private func show(mode: Mode) {
        guard mode != renderedMode else { return }

        switch mode {
        case .empty:
            readerController.view.removeFromSuperview()
            detailHost?.removeFromSuperview()
            detailHost = nil
            if emptyHost == nil {
                let host = NSHostingView(rootView: AnyView(
                    EmptyStateMac(theme: theme, icon: "book",
                                  title: "Select a work to begin",
                                  message: "Choose something from the list, or browse the archive. Everything you read stays private.")))
                emptyHost = host
            }
            pin(emptyHost!)

        case .detail(let workID):
            readerController.view.removeFromSuperview()
            emptyHost?.removeFromSuperview()
            if let work = model.works.first(where: { $0.id == workID }) {
                let host = detailHost ?? NSHostingView(rootView: AnyView(EmptyView()))
                host.rootView = AnyView(DetailView(theme: theme, model: model, work: work))
                detailHost = host
                pin(host)
            }

        case .reading(let workID, let chapter):
            detailHost?.removeFromSuperview()
            detailHost = nil
            emptyHost?.removeFromSuperview()
            if let work = model.works.first(where: { $0.id == workID }) {
                pin(readerController.view)
                readerController.show(work: work, chapterIndex: chapter)
            }
        }
        renderedMode = mode
    }

    private func pin(_ subview: NSView) {
        guard subview.superview != container else { return }
        subview.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(subview)
        NSLayoutConstraint.activate([
            subview.topAnchor.constraint(equalTo: container.topAnchor),
            subview.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            subview.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            subview.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
    }

    // MARK: - Actions

    private func toggleSettingsPopover() {
        if let popover = settingsPopover, popover.isShown {
            popover.close()
            settingsPopover = nil
            return
        }
        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = NSHostingController(rootView: ReadingSettingsView(theme: theme))
        popover.show(relativeTo: settingsButton.bounds, of: settingsButton, preferredEdge: .maxY)
        settingsPopover = popover
    }

    @objc private func exitImmersive() {
        model.immersive = false
    }
}
