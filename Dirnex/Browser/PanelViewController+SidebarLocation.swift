import DirnexCore

extension PanelViewController {
    /// What this pane is showing, in the terms the sidebar needs to find the place it is in
    /// (`SidebarPlaceLocator`): the path, the query behind a results tab, and the archive file when
    /// the pane is inside one.
    ///
    /// The archive is the **outermost** one — for a nested archive the path is a temp extraction
    /// nobody pinned, while the file the chain started from is where the user left it.
    var sidebarLocation: SidebarPaneLocation {
        let tab = tabs[activeTabIndex]
        return SidebarPaneLocation(
            path: panel.path,
            searchQuery: tab.searchQuery,
            searchScope: tab.searchScope,
            archiveFile: outermostArchiveFile
        )
    }

    private var outermostArchiveFile: VFSPath? {
        guard let archivePath = panel.path.backend.archivePath else { return nil }
        let outermost = archiveBreadcrumbAncestry().first?.backend.archivePath ?? archivePath
        return .local(outermost)
    }
}
