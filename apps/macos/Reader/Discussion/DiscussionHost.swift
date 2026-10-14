import AppKit
import SwiftUI

/// Wraps a reader (or work detail) with the Discussion panel on the
/// trailing side. The host's `view` replaces the content's place in its
/// window; the content itself goes in `contentSlot`.
///
/// Layout, all drag-resizable:
///   [ contentSlot | handle | panel ]       — panel width (min 320pt)
///   panel = header / [ threads | composer ] — composer height (auto until dragged)
/// The outer row is laid out by hand (frames), not an NSSplitView: closed,
/// open and expanded are each one explicit frame set, and the resize handle
/// is a real view on top with a usable hit area. Expanded, the panel fills
/// the whole host and the content is hidden (not torn down — the reader
/// keeps its scroll position and chapter).
/// Width, composer height and expanded state persist as single prefs.
@MainActor
final class DiscussionHost: NSObject, NSSplitViewDelegate {
    let theme: AppTheme
    let appState: AppState
    let model: DiscussionModel

    let view = DiscussionHostView()
    let contentSlot = NSView()
    private let handle = DiscussionResizeHandle()
    private let panel = NSView()
    private let innerSplit = NSSplitView()
    private var headerHost: NSHostingView<AnyView>!
    private var thread: DiscussionThreadController!
    private var composerHost: NSHostingView<AnyView>!

    /// Whether this host's window context has a work to discuss (the pane
    /// in list/search modes doesn't). Gates the toggle and menu items.
    var isAvailable = true {
        didSet { if !isAvailable && isOpen { setOpen(false) } }
    }
    private(set) var isOpen = false
    private(set) var isExpanded = false
    /// Told whenever open/expanded changes — hosts restyle their toolbar
    /// button.
    var onStateChange: (() -> Void)?

    var actions = DiscussionActions(openAuthor: { _ in }, openURL: { _ in })
    var onSignIn: () -> Void = {}

    private var panelWidth: CGFloat = 380
    /// nil = auto (composer sizes to its text, 1→8 lines).
    private var composerHeight: CGFloat?
    private var autoComposerHeight: CGFloat = 96
    private var settingDivider = false
    private var prefSaveTasks: [String: Task<Void, Never>] = [:]
    /// The composer height still needs applying once the inner split has
    /// real bounds (first layout after opening/expanding).
    private var needsSizeApply = false

    static let minPanelWidth: CGFloat = 320
    static let minContentWidth: CGFloat = 360
    static let minThreadHeight: CGFloat = 120
    static let minComposerHeight: CGFloat = 80

    private enum Pref {
        static let width = "discussion_panel_width"
        static let composerHeight = "discussion_composer_height"
        static let expanded = "discussion_expanded"
    }

    /// Live hosts, for the View menu's commands (find the key window's).
    private static var registry: [WeakHost] = []
    private struct WeakHost { weak var host: DiscussionHost? }

    static func host(in window: NSWindow?) -> DiscussionHost? {
        guard let window else { return nil }
        registry.removeAll { $0.host == nil }
        return registry.compactMap(\.host).first { $0.view.window === window }
    }

    init(theme: AppTheme, appState: AppState) {
        self.theme = theme
        self.appState = appState
        self.model = DiscussionModel(appState: appState)
        super.init()
        loadPrefs()
        build()
        Self.registry.append(WeakHost(host: self))
        ObservationRelay.track { [weak self] in
            self?.applyTheme()
        }
    }

    // MARK: - Build

    private func build() {
        view.onLayout = { [weak self] in self?.hostDidLayout() }
        for v in [contentSlot, panel, handle] {
            v.translatesAutoresizingMaskIntoConstraints = true
            view.addSubview(v)
        }
        panel.isHidden = true
        handle.isHidden = true
        // Track the host's size in the constraint pass too: layoutPanes only
        // runs after it, and a zero-frame slot (first pass, or a first open
        // straight into expanded) squeezes the pinned reader to 0pt.
        contentSlot.autoresizingMask = [.width, .height]
        handle.onDrag = { [weak self] x in self?.dragPanelEdge(to: x) }
        handle.onDragEnd = { [weak self] in
            guard let self else { return }
            savePref(Pref.width, String(Int(panelWidth)))
        }

        headerHost = NSHostingView(rootView: AnyView(EmptyView()))
        // The header sizes itself (the find field adds a row); the split owns
        // the composer's frame, so it reports no size constraints — otherwise
        // every SwiftUI update re-solves the whole window's layout.
        headerHost.sizingOptions = [.intrinsicContentSize]
        thread = DiscussionThreadController(model: model, theme: theme, appState: appState)
        thread.actions = { [unowned self] in actions }
        composerHost = NSHostingView(rootView: AnyView(EmptyView()))
        composerHost.sizingOptions = []
        renderHeader()
        renderComposer()

        innerSplit.isVertical = false
        innerSplit.dividerStyle = .thin
        innerSplit.delegate = self
        innerSplit.addArrangedSubview(thread.view)
        innerSplit.addArrangedSubview(composerHost)
        innerSplit.setHoldingPriority(.init(250), forSubviewAt: 0)
        innerSplit.setHoldingPriority(.init(260), forSubviewAt: 1)

        for v in [headerHost!, innerSplit] as [NSView] {
            v.translatesAutoresizingMaskIntoConstraints = false
            panel.addSubview(v)
        }
        let divider = NSBox()
        divider.boxType = .separator
        divider.translatesAutoresizingMaskIntoConstraints = false
        panel.addSubview(divider)
        NSLayoutConstraint.activate([
            headerHost.topAnchor.constraint(equalTo: panel.topAnchor),
            headerHost.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            headerHost.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            divider.topAnchor.constraint(equalTo: headerHost.bottomAnchor),
            divider.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            divider.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            innerSplit.topAnchor.constraint(equalTo: divider.bottomAnchor),
            innerSplit.leadingAnchor.constraint(equalTo: panel.leadingAnchor),
            innerSplit.trailingAnchor.constraint(equalTo: panel.trailingAnchor),
            innerSplit.bottomAnchor.constraint(equalTo: panel.bottomAnchor),
        ])
        panel.wantsLayer = true
        applyTheme()
    }

    private func renderHeader() {
        headerHost.rootView = AnyView(DiscussionHeaderView(
            theme: theme, model: model, isExpanded: isExpanded,
            onToggleExpand: { [weak self] in self?.toggleExpanded() },
            onClose: { [weak self] in self?.setOpen(false) }))
    }

    private func renderComposer() {
        composerHost.rootView = AnyView(DiscussionComposerView(
            theme: theme, model: model, autoHeight: composerHeight == nil,
            onPreferredHeight: { [weak self] h in self?.composerWantsHeight(h) },
            onSignIn: { [weak self] in self?.onSignIn() }))
    }

    private func applyTheme() {
        _ = theme.uiFontScale
        panel.layer?.backgroundColor = theme.nsBg.cgColor
        handle.lineColor = theme.nsLine
    }

    /// Whether keyboard focus is inside the panel (hosts let it keep its
    /// own arrow keys).
    func ownsResponder(_ responder: NSResponder?) -> Bool {
        guard isOpen, let view = responder as? NSView else { return false }
        return view.isDescendant(of: panel)
    }

    // MARK: - Open / expand

    func toggleOpen() { setOpen(!isOpen) }

    func setOpen(_ open: Bool, focusComposer: Bool = false) {
        guard open != isOpen || focusComposer else { return }
        if open && !isAvailable { return }
        // Closing: hand keyboard focus back to the window rather than
        // leaving it in a hidden panel.
        if !open, ownsResponder(view.window?.firstResponder) {
            view.window?.makeFirstResponder(nil)
        }
        isOpen = open
        model.setVisible(open)
        if open { thread.panelShown() } else { thread.panelHidden() }
        layoutPanes()
        if open {
            needsSizeApply = true
            view.needsLayout = true
            if focusComposer { model.requestComposerFocus() }
        }
        onStateChange?()
    }

    func toggleExpanded() {
        if !isOpen {
            isExpanded = true
            setOpen(true)
        } else {
            isExpanded.toggle()
            layoutPanes()
            needsSizeApply = true
            view.needsLayout = true
        }
        renderHeader()
        savePref(Pref.expanded, isExpanded ? "1" : "0")
        onStateChange?()
    }

    /// The one place the outer row's frames are set: closed, expanded and
    /// side-by-side are each a complete frame set for the current bounds.
    private func layoutPanes() {
        let bounds = view.bounds
        contentSlot.isHidden = isOpen && isExpanded
        panel.isHidden = !isOpen
        handle.isHidden = !isOpen || isExpanded
        if !isOpen {
            contentSlot.frame = bounds
        } else if isExpanded {
            // The reader keeps its last frame while hidden, so it doesn't
            // re-lay out (and lose its place) behind the panel.
            panel.frame = bounds
        } else {
            let width = clampedPanelWidth(panelWidth)
            let edge = bounds.width - width
            contentSlot.frame = NSRect(x: 0, y: 0, width: max(0, edge - 1), height: bounds.height)
            panel.frame = NSRect(x: edge, y: 0, width: width, height: bounds.height)
            handle.frame = NSRect(x: edge - DiscussionResizeHandle.hitWidth / 2, y: 0,
                                  width: DiscussionResizeHandle.hitWidth, height: bounds.height)
            if view.subviews.last !== handle {
                view.addSubview(handle, positioned: .above, relativeTo: nil)
            }
        }
    }

    /// Panel width within the host: at least its minimum, and leaving the
    /// content its minimum when there's room for both.
    private func clampedPanelWidth(_ width: CGFloat) -> CGFloat {
        let maxWidth = max(Self.minPanelWidth, view.bounds.width - Self.minContentWidth - 1)
        return min(max(width, Self.minPanelWidth), maxWidth)
    }

    /// Live drag of the panel's leading edge (`x` in host coordinates).
    private func dragPanelEdge(to x: CGFloat) {
        panelWidth = clampedPanelWidth(view.bounds.width - x)
        layoutPanes()
    }

    private func composerWantsHeight(_ height: CGFloat) {
        guard height > 0, abs(height - autoComposerHeight) > 0.5 else { return }
        autoComposerHeight = height
        if composerHeight == nil { applyComposerHeight() }
    }

    private func applyComposerHeight() {
        let total = innerSplit.bounds.height
        guard isOpen, total > 0 else { return }
        let wanted = composerHeight ?? autoComposerHeight
        let height = min(max(wanted, Self.minComposerHeight),
                         max(Self.minComposerHeight, total - Self.minThreadHeight - innerSplit.dividerThickness))
        settingDivider = true
        innerSplit.setPosition(total - height - innerSplit.dividerThickness, ofDividerAt: 0)
        settingDivider = false
    }

    /// Re-frame the panes on every host layout (window resizes, immersive
    /// transitions); apply the remembered composer height once the inner
    /// split has real bounds.
    private func hostDidLayout() {
        layoutPanes()
        guard needsSizeApply, isOpen, innerSplit.bounds.height > 0 else { return }
        needsSizeApply = false
        applyComposerHeight()
    }

    // MARK: - NSSplitViewDelegate (the inner threads / composer split)

    func splitView(_ splitView: NSSplitView, constrainMinCoordinate proposedMinimumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        Self.minThreadHeight
    }

    func splitView(_ splitView: NSSplitView, constrainMaxCoordinate proposedMaximumPosition: CGFloat,
                   ofSubviewAt dividerIndex: Int) -> CGFloat {
        splitView.bounds.height - Self.minComposerHeight - splitView.dividerThickness
    }

    func splitView(_ splitView: NSSplitView, canCollapseSubview subview: NSView) -> Bool { false }

    /// Double-click the composer divider: back to auto height.
    func splitView(_ splitView: NSSplitView, shouldCollapseSubview subview: NSView,
                   forDoubleClickOnDividerAt dividerIndex: Int) -> Bool {
        if composerHeight != nil {
            composerHeight = nil
            savePref(Pref.composerHeight, "")
            renderComposer()
            applyComposerHeight()
        }
        return false
    }

    func splitViewDidResizeSubviews(_ notification: Notification) {
        guard isOpen, !settingDivider, notification.userInfo?["NSSplitViewDividerIndex"] != nil else { return }
        let wasAuto = composerHeight == nil
        composerHeight = composerHost.frame.height
        savePref(Pref.composerHeight, String(Int(composerHeight!)))
        if wasAuto { renderComposer() }
    }

    // MARK: - Prefs

    private func loadPrefs() {
        let bridge = appState.bridge
        if let w = bridge.getPref(key: Pref.width).flatMap(Double.init), w > 0 {
            panelWidth = CGFloat(w)
        }
        if let h = bridge.getPref(key: Pref.composerHeight).flatMap(Double.init), h > 0 {
            composerHeight = CGFloat(h)
        }
        isExpanded = bridge.getPref(key: Pref.expanded) == "1"
    }

    /// Debounced per key: a divider drag reports every frame.
    private func savePref(_ key: String, _ value: String) {
        prefSaveTasks[key]?.cancel()
        prefSaveTasks[key] = Task { [appState] in
            try? await Task.sleep(for: .milliseconds(400))
            guard !Task.isCancelled else { return }
            appState.bridge.setPref(key: key, value: value)
        }
    }
}

/// The host's root view: frames its panes on every layout pass.
final class DiscussionHostView: NSView {
    var onLayout: (() -> Void)?

    override func layout() {
        super.layout()
        onLayout?()
    }
}

/// The panel's leading edge: draws the 1pt rule and owns a wider strip
/// around it for dragging, above both panes so nothing beneath (e.g. the
/// reader's scroller) swallows the grab.
final class DiscussionResizeHandle: NSView {
    static let hitWidth: CGFloat = 9
    var onDrag: ((CGFloat) -> Void)?
    var onDragEnd: (() -> Void)?
    var lineColor: NSColor = .separatorColor { didSet { needsDisplay = true } }
    /// Pointer offset from the rule when the drag began, so the edge
    /// doesn't jump to the pointer.
    private var grabOffset: CGFloat = 0

    override func draw(_ dirtyRect: NSRect) {
        lineColor.setFill()
        NSRect(x: floor(bounds.midX), y: 0, width: 1, height: bounds.height).fill()
    }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .resizeLeftRight)
    }

    override func mouseDown(with event: NSEvent) {
        guard let host = superview else { return }
        let x = host.convert(event.locationInWindow, from: nil).x
        grabOffset = x - (frame.minX + Self.hitWidth / 2)
    }

    override func mouseDragged(with event: NSEvent) {
        guard let host = superview else { return }
        onDrag?(host.convert(event.locationInWindow, from: nil).x - grabOffset)
    }

    override func mouseUp(with event: NSEvent) { onDragEnd?() }
}
