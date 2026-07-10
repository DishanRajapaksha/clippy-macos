//
//  AgentPreviewViewController.swift
//  Clippy macOS
//
//  Agent browser with previews and management actions.
//

import Cocoa
import SpriteKit

protocol AgentPreviewViewControllerDelegate: AnyObject {
    func agentPreviewViewController(_ controller: AgentPreviewViewController, didSelectAgent name: String)
    func agentPreviewViewControllerDidChangeAgents(_ controller: AgentPreviewViewController)
}

class AgentPreviewViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    struct PreviewRow {
        let name: String
        var size: String
        var animations: String
        var status: String
        let url: URL
        let isSupported: Bool
        let reason: String?
    }

    weak var delegate: AgentPreviewViewControllerDelegate?

    private var rows: [PreviewRow] = []
    private var filteredRows: [PreviewRow] = []
    private var selectedAgent: Agent?
    private var agentCache: [URL: Agent] = [:]
    private var selectedLoadID = UUID()
    private var warmLoadID = UUID()
    private let searchField = NSSearchField()
    private let tableView = NSTableView()
    private let animationTableView = NSTableView()
    private let detailLabel = NSTextField(labelWithString: "Select an agent to inspect animations.")
    private let previewView = AgentView(frame: NSRect(x: 0, y: 0, width: 180, height: 180))
    private let loadButton = NSButton(title: "Load", target: nil, action: nil)
    private let revealButton = NSButton(title: "Reveal", target: nil, action: nil)
    private let deleteButton = NSButton(title: "Delete", target: nil, action: nil)
    private let loadingIndicator = NSProgressIndicator()
    private var previewPlaybackID = UUID()
    private var previewTextureCache: [Int: SKTexture] = [:]
    private let previewTextureCacheLock = NSLock()

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 900, height: 480))
        setupTable()
        loadRows()
    }

    private func setupTable() {
        let splitView = NSSplitView(frame: view.bounds)
        splitView.autoresizingMask = [.width, .height]
        splitView.dividerStyle = .thin
        splitView.isVertical = true

        let listContainer = NSView(frame: NSRect(x: 0, y: 0, width: 500, height: view.bounds.height))
        listContainer.autoresizingMask = [.width, .height]

        searchField.frame = NSRect(x: 12, y: listContainer.bounds.height - 36, width: 200, height: 24)
        searchField.autoresizingMask = [.minYMargin]
        searchField.placeholderString = "Search agents"
        searchField.target = self
        searchField.action = #selector(searchChanged(sender:))
        listContainer.addSubview(searchField)

        loadButton.target = self
        loadButton.action = #selector(loadSelectedAgent(sender:))
        loadButton.frame = NSRect(x: 224, y: listContainer.bounds.height - 38, width: 74, height: 28)
        loadButton.autoresizingMask = [.minYMargin]
        listContainer.addSubview(loadButton)

        revealButton.target = self
        revealButton.action = #selector(revealSelectedAgent(sender:))
        revealButton.frame = NSRect(x: 306, y: listContainer.bounds.height - 38, width: 74, height: 28)
        revealButton.autoresizingMask = [.minYMargin]
        listContainer.addSubview(revealButton)

        deleteButton.target = self
        deleteButton.action = #selector(deleteSelectedAgent(sender:))
        deleteButton.frame = NSRect(x: 388, y: listContainer.bounds.height - 38, width: 74, height: 28)
        deleteButton.autoresizingMask = [.minYMargin]
        listContainer.addSubview(deleteButton)

        loadingIndicator.frame = NSRect(x: 468, y: listContainer.bounds.height - 33, width: 20, height: 20)
        loadingIndicator.autoresizingMask = [.minYMargin]
        loadingIndicator.style = .spinning
        loadingIndicator.controlSize = .small
        loadingIndicator.isDisplayedWhenStopped = false
        listContainer.addSubview(loadingIndicator)

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 500, height: listContainer.bounds.height - 44))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true

        addColumn("name", title: "Name", width: 180, to: tableView)
        addColumn("size", title: "Size", width: 90, to: tableView)
        addColumn("animations", title: "Animations", width: 90, to: tableView)
        addColumn("status", title: "Status", width: 120, to: tableView)
        tableView.delegate = self
        tableView.dataSource = self
        tableView.usesAlternatingRowBackgroundColors = true

        scroll.documentView = tableView
        listContainer.addSubview(scroll)
        splitView.addArrangedSubview(listContainer)

        let detailView = NSView(frame: NSRect(x: 0, y: 0, width: 400, height: view.bounds.height))
        detailView.autoresizingMask = [.width, .height]
        detailLabel.frame = NSRect(x: 12, y: detailView.bounds.height - 34, width: 376, height: 18)
        detailLabel.autoresizingMask = [.width, .minYMargin]
        detailView.addSubview(detailLabel)

        previewView.frame = NSRect(x: 12, y: detailView.bounds.height - 222, width: 180, height: 180)
        previewView.autoresizingMask = [.maxXMargin, .minYMargin]
        previewView.agentSprite.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        previewView.agentSprite.position = CGPoint(x: previewView.bounds.midX, y: previewView.bounds.midY)
        detailView.addSubview(previewView)

        let animationScroll = NSScrollView(frame: NSRect(x: 12, y: 12, width: 376, height: detailView.bounds.height - 258))
        animationScroll.autoresizingMask = [.width, .height]
        animationScroll.hasVerticalScroller = true

        addColumn("animation", title: "Animation", width: 350, to: animationTableView)
        animationTableView.delegate = self
        animationTableView.dataSource = self
        animationTableView.usesAlternatingRowBackgroundColors = true
        animationTableView.target = self
        animationTableView.doubleAction = #selector(playSelectedAnimation(sender:))
        animationScroll.documentView = animationTableView
        detailView.addSubview(animationScroll)

        splitView.addArrangedSubview(detailView)
        view.addSubview(splitView)
        updateButtons()
    }

    private func addColumn(_ identifier: String, title: String, width: CGFloat, to tableView: NSTableView) {
        let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(identifier))
        column.title = title
        column.width = width
        tableView.addTableColumn(column)
    }

    private func loadRows() {
        rows = Agent.agentListings().map { listing in
            return PreviewRow(name: listing.name,
                              size: listing.isSupported ? "Select" : "-",
                              animations: listing.isSupported ? "Select" : "-",
                              status: listing.isSupported ? "Ready" : "Unsupported",
                              url: listing.url,
                              isSupported: listing.isSupported,
                              reason: listing.reason)
        }
        applyFilter()
    }

    private func applyFilter() {
        let query = searchField.stringValue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        filteredRows = query.isEmpty ? rows : rows.filter {
            $0.name.lowercased().contains(query) || $0.status.lowercased().contains(query)
        }
        tableView.reloadData()
        tableView.deselectAll(self)
        clearSelection()
    }

    @objc private func searchChanged(sender: NSSearchField) {
        applyFilter()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView == animationTableView {
            return selectedAgent?.animations.count ?? 0
        }
        return filteredRows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView == animationTableView {
            guard let animation = selectedAgent?.animations[safe: row] else { return nil }
            return textCell(animation.name, identifier: tableColumn?.identifier)
        }

        guard row < filteredRows.count else { return nil }
        let item = filteredRows[row]
        let value: String
        switch tableColumn?.identifier.rawValue {
        case "name": value = item.name
        case "size": value = item.size
        case "animations": value = item.animations
        case "status": value = item.status
        default: value = ""
        }
        return textCell(value, identifier: tableColumn?.identifier)
    }

    private func textCell(_ value: String, identifier: NSUserInterfaceItemIdentifier?) -> NSTextField {
        let cell = NSTextField(labelWithString: value)
        cell.identifier = identifier
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if notification.object as? NSTableView == animationTableView {
            playSelectedAnimation(sender: animationTableView)
            return
        }

        guard notification.object as? NSTableView == tableView else { return }
        let row = tableView.selectedRow
        guard row >= 0, row < filteredRows.count else {
            clearSelection()
            return
        }
        select(rowIndex: row)
    }

    private func select(rowIndex: Int) {
        let row = filteredRows[rowIndex]
        selectedLoadID = UUID()
        previewTextureCacheLock.lock()
        previewTextureCache.removeAll(keepingCapacity: true)
        previewTextureCacheLock.unlock()

        guard row.isSupported else {
            selectedAgent = nil
            detailLabel.stringValue = "\(row.name): \(row.reason ?? "unsupported")"
            animationTableView.reloadData()
            previewView.agentSprite.texture = nil
            setLoading(false)
            updateButtons()
            return
        }

        if let agent = agentCache[row.url] {
            showLoadedAgent(agent, for: row.url, warmAfter: rowIndex)
            return
        }

        let loadID = selectedLoadID
        selectedAgent = nil
        detailLabel.stringValue = "Loading \(row.name)..."
        animationTableView.reloadData()
        previewView.agentSprite.texture = nil
        setLoading(true)
        updateButtons()
        updateListing(for: row.url, size: "Loading", animations: "Loading", status: "Loading")

        DispatchQueue.global(qos: .userInitiated).async {
            let agent = Agent(agentURL: row.url)
            DispatchQueue.main.async {
                guard self.selectedLoadID == loadID else { return }
                self.setLoading(false)
                guard let agent = agent else {
                    self.detailLabel.stringValue = "\(row.name): could not load agent"
                    self.updateListing(for: row.url, size: "-", animations: "-", status: "Failed")
                    self.updateButtons()
                    return
                }
                self.agentCache[row.url] = agent
                self.showLoadedAgent(agent, for: row.url, warmAfter: rowIndex)
            }
        }
    }

    private func clearSelection() {
        selectedLoadID = UUID()
        warmLoadID = UUID()
        selectedAgent = nil
        detailLabel.stringValue = "Select an agent to inspect animations."
        animationTableView.reloadData()
        previewView.agentSprite.texture = nil
        setLoading(false)
        updateButtons()
    }

    private func updateButtons() {
        let hasRow = tableView.selectedRow >= 0 && tableView.selectedRow < filteredRows.count
        let row = hasRow ? filteredRows[tableView.selectedRow] : nil
        loadButton.isEnabled = row?.isSupported == true && selectedAgent != nil
        revealButton.isEnabled = row != nil
        deleteButton.isEnabled = row != nil
    }

    @objc private func loadSelectedAgent(sender: AnyObject) {
        let row = tableView.selectedRow
        guard row >= 0, row < filteredRows.count, filteredRows[row].isSupported else { return }
        delegate?.agentPreviewViewController(self, didSelectAgent: filteredRows[row].name)
    }

    @objc private func revealSelectedAgent(sender: AnyObject) {
        let row = tableView.selectedRow
        guard row >= 0, row < filteredRows.count else { return }
        NSWorkspace.shared.activateFileViewerSelecting([filteredRows[row].url])
    }

    @objc private func deleteSelectedAgent(sender: AnyObject) {
        let rowIndex = tableView.selectedRow
        guard rowIndex >= 0, rowIndex < filteredRows.count else { return }
        let row = filteredRows[rowIndex]

        let alert = NSAlert()
        alert.messageText = "Move \(row.name) to the Trash?"
        alert.informativeText = "The agent can be restored from the Trash until it is emptied."
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Cancel")
        alert.alertStyle = .warning
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let currentURL = AppDelegate.agentController?.agent?.agentURL.standardizedFileURL
        let deletingCurrentAgent = currentURL == row.url.standardizedFileURL
        deleteButton.isEnabled = false

        NSWorkspace.shared.recycle([row.url]) { [weak self] _, error in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.deleteButton.isEnabled = true
                if let error = error {
                    let errorAlert = NSAlert()
                    errorAlert.messageText = "Move to Trash Failed"
                    errorAlert.informativeText = error.localizedDescription
                    errorAlert.alertStyle = .warning
                    errorAlert.runModal()
                    return
                }

                self.agentCache[row.url] = nil
                self.loadRows()
                self.delegate?.agentPreviewViewControllerDidChangeAgents(self)

                guard deletingCurrentAgent, let controller = AppDelegate.agentController else { return }
                if let replacement = Agent.agentNames().first(where: {
                    $0.caseInsensitiveCompare(row.name) != .orderedSame
                }) {
                    try? controller.load(name: replacement)
                    controller.show()
                } else {
                    controller.cancelPlayback()
                    controller.agent = nil
                    controller.hide()
                }
            }
        }
    }

    private func warmNextAgent(after rowIndex: Int) {
        guard let nextIndex = ((rowIndex + 1)..<filteredRows.count)
            .first(where: { filteredRows[$0].isSupported }) else {
            return
        }

        let row = filteredRows[nextIndex]
        guard agentCache[row.url] == nil else { return }

        let loadID = UUID()
        warmLoadID = loadID
        updateListing(for: row.url, size: "Loading", animations: "Loading", status: "Loading")
        DispatchQueue.global(qos: .utility).async {
            let agent = Agent(agentURL: row.url)
            DispatchQueue.main.async {
                guard self.warmLoadID == loadID else { return }
                guard let agent = agent else {
                    self.updateListing(for: row.url, size: "-", animations: "-", status: "Failed")
                    return
                }
                self.agentCache[row.url] = agent
                self.updateListing(for: row.url, with: agent)
            }
        }
    }

    private func showLoadedAgent(_ agent: Agent, for url: URL, warmAfter rowIndex: Int) {
        agentCache[url] = agent
        updateListing(for: url, with: agent)
        selectedAgent = agent
        detailLabel.stringValue = "\(agent.resourceName.capitalized): \(agent.animations.count) animations"
        showPreviewInitialFrame(for: agent)
        animationTableView.reloadData()
        animationTableView.deselectAll(self)
        setLoading(false)
        updateButtons()
        warmNextAgent(after: rowIndex)
    }

    private func setLoading(_ isLoading: Bool) {
        if isLoading {
            loadingIndicator.startAnimation(self)
        } else {
            loadingIndicator.stopAnimation(self)
        }
    }

    private func updateListing(for url: URL, with agent: Agent) {
        updateListing(for: url,
                      size: "\(agent.character.width)x\(agent.character.height)",
                      animations: "\(agent.animations.count)",
                      status: "Loaded")
    }

    private func updateListing(for url: URL, size: String, animations: String, status: String) {
        updateRows(&rows, for: url, size: size, animations: animations, status: status)
        updateRows(&filteredRows, for: url, size: size, animations: animations, status: status)
        if let rowIndex = filteredRows.firstIndex(where: { $0.url == url }) {
            tableView.reloadData(forRowIndexes: IndexSet(integer: rowIndex),
                                 columnIndexes: IndexSet(integersIn: 0..<tableView.numberOfColumns))
        }
    }

    private func updateRows(_ rows: inout [PreviewRow], for url: URL, size: String, animations: String, status: String) {
        guard let index = rows.firstIndex(where: { $0.url == url }) else { return }
        rows[index].size = size
        rows[index].animations = animations
        rows[index].status = status
    }

    @objc private func playSelectedAnimation(sender: AnyObject) {
        guard let agent = selectedAgent else { return }
        let row = animationTableView.selectedRow
        guard row >= 0, let animation = agent.animations[safe: row] else { return }
        preview(animation: animation, for: agent)
    }

    private func showPreviewInitialFrame(for agent: Agent) {
        previewPlaybackID = UUID()
        previewView.agentSprite.removeAllActions()
        configurePreviewSize(for: agent)
        guard let texture = previewTexture(at: 0, for: agent) else {
            previewView.agentSprite.texture = nil
            return
        }
        previewView.agentSprite.texture = texture
    }

    private func preview(animation: AgentAnimation, for agent: Agent) {
        let playbackID = UUID()
        previewPlaybackID = playbackID

        DispatchQueue.global(qos: .userInitiated).async {
            let actions = animation.frames.compactMap { frame -> SKAction? in
                guard let texture = self.previewTexture(for: frame, in: agent) else { return nil }
                return SKAction.animate(with: [texture], timePerFrame: frame.durationInSeconds)
            }

            DispatchQueue.main.async {
                guard self.previewPlaybackID == playbackID, !actions.isEmpty else { return }
                self.configurePreviewSize(for: agent)
                self.previewView.agentSprite.removeAllActions()
                self.previewView.agentSprite.run(SKAction.sequence(actions)) {
                    guard self.previewPlaybackID == playbackID else { return }
                    self.showPreviewInitialFrame(for: agent)
                }
            }
        }
    }

    private func configurePreviewSize(for agent: Agent) {
        let maxWidth = max(previewView.bounds.width - 8, 1)
        let maxHeight = max(previewView.bounds.height - 8, 1)
        let scale = min(maxWidth / CGFloat(agent.character.width),
                        maxHeight / CGFloat(agent.character.height),
                        1.0)
        previewView.agentSprite.anchorPoint = CGPoint(x: 0.5, y: 0.5)
        previewView.agentSprite.position = CGPoint(x: previewView.bounds.midX, y: previewView.bounds.midY)
        previewView.agentSprite.size = CGSize(width: CGFloat(agent.character.width) * scale,
                                              height: CGFloat(agent.character.height) * scale)
    }

    private func previewTexture(for frame: AgentFrame, in agent: Agent) -> SKTexture? {
        if frame.images.count == 1, let imageNumber = frame.images.first?.imageNumber {
            return previewTexture(at: imageNumber, for: agent)
        }

        guard let image = agent.imageForFrame(frame) else { return previewTexture(at: 0, for: agent) }
        let texture = SKTexture(cgImage: image)
        texture.filteringMode = .nearest
        return texture
    }

    private func previewTexture(at index: Int, for agent: Agent) -> SKTexture? {
        previewTextureCacheLock.lock()
        if let texture = previewTextureCache[index] {
            previewTextureCacheLock.unlock()
            return texture
        }
        previewTextureCacheLock.unlock()

        guard let image = try? agent.textureAtIndex(index: index) else { return nil }
        let texture = SKTexture(cgImage: image)
        texture.filteringMode = .nearest
        previewTextureCacheLock.lock()
        previewTextureCache[index] = texture
        previewTextureCacheLock.unlock()
        return texture
    }
}

extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}
