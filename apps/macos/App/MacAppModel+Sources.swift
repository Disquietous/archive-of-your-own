import Foundation

// MARK: - Sources area: one tab per source, each with its own options

extension MacAppModel {
    /// One entry of a source's sidebar: the section its content panel shows.
    struct SourceOption: Identifiable {
        let section: Section
        let icon: String
        let label: String
        var id: Section { section }
    }

    /// The sources that get a tab: every one with a site, in the
    /// registry's order. (Imported files have no site and no tab.)
    var sourceTabs: [SourceCapabilities] {
        appState.bridge.listSources().filter { !$0.host.isEmpty }
    }

    /// A source's sidebar options, decided by what the source declares it
    /// offers — never by which source it is.
    func sourceOptions(for sourceID: String) -> [SourceOption] {
        guard let caps = appState.bridge.sourceCapabilities(sourceID) else { return [] }
        var options: [SourceOption] = []
        if caps.tagListings {
            options.append(SourceOption(section: .fandoms, icon: "flame", label: "Fandoms"))
        }
        if caps.subscriptions {
            options.append(SourceOption(section: .subscriptions, icon: "bell", label: "Subscriptions"))
        }
        if caps.inbox {
            options.append(SourceOption(section: .inbox, icon: "tray", label: "Inbox"))
        }
        return options
    }

    /// The source whose sidebar holds a section; nil for a section of the
    /// main sidebar.
    func sourceOwning(_ section: Section) -> String? {
        sourceTabs.first { source in
            sourceOptions(for: source.id).contains { $0.section == section }
        }?.id
    }

    /// Keep the area in step with the section being shown.
    func noteSourcesArea(for section: Section) {
        if let source = sourceOwning(section) {
            sourcesShown = true
            sourceTab = source
            sourceOptionMemory[source] = section
        } else {
            sourcesShown = false
        }
    }

    /// The selected tab has something to show in the content panel.
    var sourceTabHasContent: Bool {
        sourceOptions(for: sourceTab).contains { $0.section == section }
    }

    /// The main sidebar's Sources item: open the area on the tab it last
    /// showed (the first source to begin with).
    func showSources() {
        let tabs = sourceTabs
        let tab = tabs.contains { $0.id == sourceTab } ? sourceTab : (tabs.first?.id ?? "")
        selectSourceTab(tab)
    }

    /// Switch tabs: the tab reopens on the option it last showed, or its
    /// first one. A source with no options yet shows an empty panel.
    func selectSourceTab(_ sourceID: String) {
        let options = sourceOptions(for: sourceID)
        let remembered = sourceOptionMemory[sourceID].flatMap { last in
            options.first { $0.section == last }?.section
        }
        if let target = remembered ?? options.first?.section {
            goSection(target)
        }
        sourcesShown = true
        sourceTab = sourceID
    }
}
