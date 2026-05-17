//
//  AppDelegate.swift
//  Clippy macOS
//
//  Created by Devran on 03.09.19.
//  Copyright © 2019 Devran. All rights reserved.
//

import Cocoa
import ServiceManagement
import SpriteKit
import UniformTypeIdentifiers

class AgentPreviewViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    struct PreviewRow {
        let name: String
        let size: String
        let animations: String
    }

    private var rows: [PreviewRow] = []
    private var selectedAgent: Agent?
    private let tableView = NSTableView()
    private let animationTableView = NSTableView()
    private let detailLabel = NSTextField(labelWithString: "Select an agent to inspect animations.")
    private let previewView = AgentView(frame: NSRect(x: 0, y: 0, width: 140, height: 140))
    private var previewPlaybackID = UUID()

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 820, height: 460))
        setupTable()
        loadRows()
    }

    private func setupTable() {
        let splitView = NSSplitView(frame: view.bounds)
        splitView.autoresizingMask = [.width, .height]
        splitView.dividerStyle = .thin
        splitView.isVertical = true

        let scroll = NSScrollView(frame: NSRect(x: 0, y: 0, width: 430, height: view.bounds.height))
        scroll.autoresizingMask = [.width, .height]
        scroll.hasVerticalScroller = true

        let nameColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("name"))
        nameColumn.title = "Name"
        nameColumn.width = 220

        let sizeColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("size"))
        sizeColumn.title = "Size"
        sizeColumn.width = 120

        let animColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("animations"))
        animColumn.title = "Animations"
        animColumn.width = 140

        tableView.addTableColumn(nameColumn)
        tableView.addTableColumn(sizeColumn)
        tableView.addTableColumn(animColumn)
        tableView.delegate = self
        tableView.dataSource = self
        tableView.usesAlternatingRowBackgroundColors = true

        scroll.documentView = tableView
        splitView.addArrangedSubview(scroll)

        let detailView = NSView(frame: NSRect(x: 0, y: 0, width: 390, height: view.bounds.height))
        detailView.autoresizingMask = [.width, .height]
        detailLabel.frame = NSRect(x: 12, y: detailView.bounds.height - 34, width: 366, height: 18)
        detailLabel.autoresizingMask = [.width, .minYMargin]
        detailView.addSubview(detailLabel)

        previewView.frame = NSRect(x: 12, y: detailView.bounds.height - 186, width: 140, height: 140)
        previewView.autoresizingMask = [.maxXMargin, .minYMargin]
        detailView.addSubview(previewView)

        let animationScroll = NSScrollView(frame: NSRect(x: 12, y: 12, width: 366, height: detailView.bounds.height - 222))
        animationScroll.autoresizingMask = [.width, .height]
        animationScroll.hasVerticalScroller = true

        let animationColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("animation"))
        animationColumn.title = "Animation"
        animationColumn.width = 340
        animationTableView.addTableColumn(animationColumn)
        animationTableView.delegate = self
        animationTableView.dataSource = self
        animationTableView.usesAlternatingRowBackgroundColors = true
        animationTableView.target = self
        animationTableView.doubleAction = #selector(playSelectedAnimation(sender:))
        animationScroll.documentView = animationTableView
        detailView.addSubview(animationScroll)

        splitView.addArrangedSubview(detailView)
        view.addSubview(splitView)
    }

    private func loadRows() {
        rows = Agent.agentNames().compactMap { name in
            guard let agent = Agent(resourceName: name) else { return nil }
            let size = "\(agent.character.width)x\(agent.character.height)"
            return PreviewRow(name: name, size: size, animations: "\(agent.animations.count)")
        }
        tableView.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView == animationTableView {
            return selectedAgent?.animations.count ?? 0
        }
        return rows.count
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView == animationTableView {
            guard let animation = selectedAgent?.animations[safe: row] else { return nil }
            let cell = NSTextField(labelWithString: animation.name)
            cell.identifier = tableColumn?.identifier
            return cell
        }

        guard row < rows.count else { return nil }
        let item = rows[row]
        let identifier = tableColumn?.identifier ?? NSUserInterfaceItemIdentifier("col")
        let cell = NSTextField(labelWithString: "")
        cell.identifier = identifier
        switch identifier.rawValue {
        case "name": cell.stringValue = item.name
        case "size": cell.stringValue = item.size
        case "animations": cell.stringValue = item.animations
        default: cell.stringValue = ""
        }
        return cell
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        if notification.object as? NSTableView == animationTableView {
            playSelectedAnimation(sender: animationTableView)
            return
        }

        guard notification.object as? NSTableView == tableView else { return }
        let row = tableView.selectedRow
        guard row >= 0, row < rows.count, let agent = Agent(resourceName: rows[row].name) else {
            selectedAgent = nil
            detailLabel.stringValue = "Select an agent to inspect animations."
            animationTableView.reloadData()
            previewView.agentSprite.texture = nil
            return
        }
        selectedAgent = agent
        detailLabel.stringValue = "\(agent.resourceName.capitalized): \(agent.animations.count) animations"
        showPreviewInitialFrame(for: agent)
        animationTableView.reloadData()
        animationTableView.deselectAll(self)
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
        previewView.frame.size = CGSize(width: agent.character.width, height: agent.character.height)
        previewView.agentSprite.size = previewView.frame.size
        guard let image = try? agent.textureAtIndex(index: 0) else {
            previewView.agentSprite.texture = nil
            return
        }
        previewView.agentSprite.texture = SKTexture(cgImage: image)
    }

    private func preview(animation: AgentAnimation, for agent: Agent) {
        let playbackID = UUID()
        previewPlaybackID = playbackID

        DispatchQueue.global(qos: .userInitiated).async {
            let actions = animation.frames.compactMap { frame -> SKAction? in
                guard let image = agent.imageForFrame(frame) else { return nil }
                let texture = SKTexture(cgImage: image)
                texture.filteringMode = .nearest
                return SKAction.animate(with: [texture], timePerFrame: frame.durationInSeconds)
            }

            DispatchQueue.main.async {
                guard self.previewPlaybackID == playbackID, !actions.isEmpty else { return }
                self.previewView.frame.size = CGSize(width: agent.character.width, height: agent.character.height)
                self.previewView.agentSprite.size = self.previewView.frame.size
                self.previewView.agentSprite.removeAllActions()
                self.previewView.agentSprite.run(SKAction.sequence(actions)) {
                    guard self.previewPlaybackID == playbackID else { return }
                    self.showPreviewInitialFrame(for: agent)
                }
            }
        }
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        guard indices.contains(index) else { return nil }
        return self[index]
    }
}

class AppDelegate: NSObject, NSApplicationDelegate {
    let applicationName = "Clippy"
    static let lastUsedAgentDefaultsKey = "LastUsedAgent"
    static let speechBubblesEnabledDefaultsKey = "SpeechBubblesEnabled"
    static let alwaysOnTopDefaultsKey = "AlwaysOnTop"
    static let joinAllSpacesDefaultsKey = "JoinAllSpaces"
    static let throwInertiaEnabledDefaultsKey = "ThrowInertiaEnabled"
    static let edgeSnapEnabledDefaultsKey = "EdgeSnapEnabled"
    static let lastWindowFrameDefaultsKey = "LastWindowFrame"
    var window: NSWindow?
    var statusItem: NSStatusItem?
    var agentsMenuItem: NSMenuItem?
    var animationsMenuItem: NSMenuItem?
    var autoAnimateMenuItem: NSMenuItem?
    var behaviorMenuItem: NSMenuItem?
    var muteMenuItem: NSMenuItem?
    var speechBubblesMenuItem: NSMenuItem?
    var previewWindowController: NSWindowController?
    static var agentController: AgentController?
    var lastUsedAgent: String? {
        get {
            UserDefaults.standard.string(forKey: Self.lastUsedAgentDefaultsKey)
        }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.lastUsedAgentDefaultsKey)
        }
    }
    
    func applicationDidFinishLaunching(_ aNotification: Notification) {
        UserDefaults.standard.register(defaults: [
            AgentController.autoAnimateIntervalDefaultsKey: AgentController.defaultAutoAnimateInterval,
            AgentController.muteDefaultsKey: false,
            Self.speechBubblesEnabledDefaultsKey: true,
            Self.alwaysOnTopDefaultsKey: true,
            Self.joinAllSpacesDefaultsKey: true,
            Self.throwInertiaEnabledDefaultsKey: true,
            Self.edgeSnapEnabledDefaultsKey: true
        ])
        
        window = AgentWindow(contentRect: CGRect.zero, styleMask: [], backing: .buffered, defer: true)
        window?.title = applicationName
        window?.contentViewController = AgentViewController()
        applyWindowBehavior()
        if !Agent.agentNames().isEmpty {
            window?.makeKeyAndOrderFront(self)
        }
        if let frame = savedWindowFrame(), let window = window {
            window.setFrame(clampedWindowFrame(frame, for: window), display: true)
        } else {
            window?.center()
        }
        
        setupStatusBar()
    }
    
    func applicationWillTerminate(_ aNotification: Notification) {
        // Insert code here to tear down your application
    }
    
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return true
    }
    
    func setupStatusBar() {
        let statusBar = NSStatusBar.system
        statusItem = statusBar.statusItem(withLength: NSStatusItem.squareLength)
        if let button = statusItem?.button {
            button.title = "📎"
        }
        
        setupStatusBarMenu()
    }
    
    func createAgentsMenu() -> NSMenu {
        let agentsMenu = NSMenu(title: "Agents")
        let agentNames = Agent.agentNames()
        
        if agentNames.isEmpty {
            agentsMenu.addItem(withTitle: "No Agents found.",
                               action: nil,
                               keyEquivalent: "")
        }
        for agentName in agentNames {
            let item = NSMenuItem(title: agentName.capitalized,
                                  action: #selector(selectAgent(sender:)),
                                  keyEquivalent: "")
            item.target = self
            if lastUsedAgent == agentName {
                item.state = .on
            }
            agentsMenu.addItem(item)
        }
        agentsMenu.addItem(NSMenuItem.separator())
        addMenuItem(to: agentsMenu, title: "Reload", action: #selector(reloadAction(sender:)))
        return agentsMenu
    }
    
    func setupStatusBarMenu() {
        statusItem?.menu = createMainMenu(registerMenuItems: true)
    }

    func createMainMenu(registerMenuItems: Bool = false) -> NSMenu {
        let statusBarMenu = NSMenu(title: "Clippy")
        let agentsItem = NSMenuItem(title: "Agents", action: nil, keyEquivalent: "")
        let animationsItem = NSMenuItem(title: "Animations", action: nil, keyEquivalent: "")
        let autoAnimateItem = NSMenuItem(title: "Auto Animate", action: nil, keyEquivalent: "")
        let behaviorItem = NSMenuItem(title: "Behavior", action: nil, keyEquivalent: "")
        let muteItem = NSMenuItem(title: "Mute", action: #selector(toggleMuteAction(sender:)), keyEquivalent: "")
        let speechBubblesItem = NSMenuItem(title: "Speech Bubbles", action: #selector(toggleSpeechBubblesAction(sender:)), keyEquivalent: "")
        
        if registerMenuItems {
            agentsMenuItem = agentsItem
            animationsMenuItem = animationsItem
            autoAnimateMenuItem = autoAnimateItem
            behaviorMenuItem = behaviorItem
            muteMenuItem = muteItem
            speechBubblesMenuItem = speechBubblesItem
        }

        addMenuItem(to: statusBarMenu, title: "Show", action: #selector(showAction(sender:)))
        addMenuItem(to: statusBarMenu, title: "Hide", action: #selector(hideAction(sender:)))

        muteItem.target = self
        muteItem.state = isMuted() ? .on : .off
        statusBarMenu.addItem(muteItem)

        speechBubblesItem.target = self
        speechBubblesItem.state = isSpeechBubblesEnabled() ? .on : .off
        statusBarMenu.addItem(speechBubblesItem)

        statusBarMenu.addItem(autoAnimateItem)
        statusBarMenu.setSubmenu(createAutoAnimateMenu(), for: autoAnimateItem)

        statusBarMenu.addItem(behaviorItem)
        statusBarMenu.setSubmenu(createBehaviorMenu(), for: behaviorItem)

        statusBarMenu.addItem(NSMenuItem.separator())
        statusBarMenu.addItem(agentsItem)
        statusBarMenu.setSubmenu(createAgentsMenu(), for: agentsItem)
        statusBarMenu.addItem(animationsItem)
        statusBarMenu.setSubmenu(createAnimationsMenu(), for: animationsItem)
        addMenuItem(to: statusBarMenu, title: "Show in Finder", action: #selector(openFolderAction(sender:)))
        addMenuItem(to: statusBarMenu, title: "Import Agent…", action: #selector(importAgentAction(sender:)))
        addMenuItem(to: statusBarMenu, title: "Agent Previews…", action: #selector(showAgentPreviewsAction(sender:)))
        statusBarMenu.addItem(NSMenuItem.separator())
        addMenuItem(to: statusBarMenu, title: "Quit \(applicationName)", action: #selector(quitAction(sender:)))

        return statusBarMenu
    }

    func createAnimationsMenu() -> NSMenu {
        let menu = NSMenu(title: "Animations")
        guard let agent = AppDelegate.agentController?.agent else {
            menu.addItem(withTitle: "No Agent loaded.", action: nil, keyEquivalent: "")
            return menu
        }

        if agent.animations.isEmpty {
            menu.addItem(withTitle: "No Animations found.", action: nil, keyEquivalent: "")
            return menu
        }

        for animation in agent.animations {
            let item = NSMenuItem(title: animation.name,
                                  action: #selector(playAnimationAction(sender:)),
                                  keyEquivalent: "")
            item.target = self
            item.representedObject = animation.name
            menu.addItem(item)
        }
        return menu
    }

    func refreshDynamicMenus() {
        agentsMenuItem?.submenu = createAgentsMenu()
        animationsMenuItem?.submenu = createAnimationsMenu()
        autoAnimateMenuItem?.submenu = createAutoAnimateMenu()
        behaviorMenuItem?.submenu = createBehaviorMenu()
    }

    @discardableResult
    private func addMenuItem(to menu: NSMenu, title: String, action: Selector?) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    func createAutoAnimateMenu() -> NSMenu {
        let menu = NSMenu(title: "Auto Animate")
        let configured = UserDefaults.standard.double(forKey: AgentController.autoAnimateIntervalDefaultsKey)
        let current = configured > 0 ? configured : AgentController.defaultAutoAnimateInterval

        let options: [TimeInterval] = [5, 10, 15, 30, 60]
        for interval in options {
            let item = NSMenuItem(
                title: "Every \(Int(interval))s",
                action: #selector(selectAutoAnimateInterval(sender:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = interval
            item.state = abs(current - interval) < 0.001 ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())
        let disableItem = NSMenuItem(title: "Off", action: #selector(disableAutoAnimate(sender:)), keyEquivalent: "")
        disableItem.target = self
        disableItem.state = configured == 0 ? .on : .off
        menu.addItem(disableItem)
        return menu
    }

    func createBehaviorMenu() -> NSMenu {
        let menu = NSMenu(title: "Behavior")
        let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLoginAction(sender:)), keyEquivalent: "")
        launchItem.target = self
        launchItem.state = isLaunchAtLoginEnabled() ? .on : .off
        menu.addItem(launchItem)

        let alwaysOnTopItem = NSMenuItem(title: "Always on Top", action: #selector(toggleAlwaysOnTopAction(sender:)), keyEquivalent: "")
        alwaysOnTopItem.target = self
        alwaysOnTopItem.state = isAlwaysOnTopEnabled() ? .on : .off
        menu.addItem(alwaysOnTopItem)

        let allSpacesItem = NSMenuItem(title: "Join All Spaces", action: #selector(toggleJoinAllSpacesAction(sender:)), keyEquivalent: "")
        allSpacesItem.target = self
        allSpacesItem.state = isJoinAllSpacesEnabled() ? .on : .off
        menu.addItem(allSpacesItem)

        menu.addItem(NSMenuItem.separator())

        let inertiaItem = NSMenuItem(title: "Throw Inertia", action: #selector(toggleThrowInertiaAction(sender:)), keyEquivalent: "")
        inertiaItem.target = self
        inertiaItem.state = isThrowInertiaEnabled() ? .on : .off
        menu.addItem(inertiaItem)

        let snapItem = NSMenuItem(title: "Edge Snap", action: #selector(toggleEdgeSnapAction(sender:)), keyEquivalent: "")
        snapItem.target = self
        snapItem.state = isEdgeSnapEnabled() ? .on : .off
        menu.addItem(snapItem)
        return menu
    }
    
    @objc func quitAction(sender: AnyObject) {
        NSApplication.shared.terminate(self)
    }
    
    @objc func reloadAction(sender: AnyObject) {
        refreshDynamicMenus()
    }

    @objc func selectAutoAnimateInterval(sender: AnyObject) {
        guard let menuItem = sender as? NSMenuItem,
              let interval = menuItem.representedObject as? TimeInterval else { return }
        UserDefaults.standard.set(interval, forKey: AgentController.autoAnimateIntervalDefaultsKey)
        AppDelegate.agentController?.restartAutoAnimateTimer()
        autoAnimateMenuItem?.submenu = createAutoAnimateMenu()
    }

    @objc func disableAutoAnimate(sender: AnyObject) {
        UserDefaults.standard.set(0, forKey: AgentController.autoAnimateIntervalDefaultsKey)
        AppDelegate.agentController?.autoAnimateTimer?.invalidate()
        AppDelegate.agentController?.autoAnimateTimer = nil
        autoAnimateMenuItem?.submenu = createAutoAnimateMenu()
    }

    @objc func playAnimationAction(sender: AnyObject) {
        guard let menuItem = sender as? NSMenuItem,
              let name = menuItem.representedObject as? String,
              let animation = AppDelegate.agentController?.agent?.findAnimation(name) else { return }
        AppDelegate.agentController?.play(animation: animation)
    }
    
    @objc func openFolderAction(sender: AnyObject) {
        NSWorkspace.shared.open(Agent.agentsURL())
    }

    @objc func importAgentAction(sender: AnyObject) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.zip, UTType(filenameExtension: "agent")].compactMap { $0 }
        panel.prompt = "Import"

        guard panel.runModal() == .OK else { return }
        var imported: [String] = []
        var failures: [String] = []

        for url in panel.urls {
            do {
                let name = try importAgent(from: url)
                imported.append(name)
            } catch {
                failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        reloadAction(sender: self)
        presentImportResult(imported: imported, failures: failures)
    }

    @objc func showAgentPreviewsAction(sender: AnyObject) {
        let vc = AgentPreviewViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 760, height: 360),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered,
                              defer: false)
        window.title = "Agent Previews"
        window.contentViewController = vc
        let controller = NSWindowController(window: window)
        previewWindowController = controller
        controller.showWindow(self)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    @objc func hideAction(sender: AnyObject) {
        AppDelegate.agentController?.hide()
    }
    
    @objc func showAction(sender: AnyObject) {
        NSApp.unhide(self)
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(self)
    }
    
    @objc func toggleMuteAction(sender: AnyObject) {
        setMuted(!isMuted())
    }

    @objc func toggleSpeechBubblesAction(sender: AnyObject) {
        setSpeechBubblesEnabled(!isSpeechBubblesEnabled())
    }

    @objc func toggleLaunchAtLoginAction(sender: AnyObject) {
        setLaunchAtLoginEnabled(!isLaunchAtLoginEnabled())
        behaviorMenuItem?.submenu = createBehaviorMenu()
    }

    @objc func toggleAlwaysOnTopAction(sender: AnyObject) {
        UserDefaults.standard.set(!isAlwaysOnTopEnabled(), forKey: Self.alwaysOnTopDefaultsKey)
        applyWindowBehavior()
        behaviorMenuItem?.submenu = createBehaviorMenu()
    }

    @objc func toggleJoinAllSpacesAction(sender: AnyObject) {
        UserDefaults.standard.set(!isJoinAllSpacesEnabled(), forKey: Self.joinAllSpacesDefaultsKey)
        applyWindowBehavior()
        behaviorMenuItem?.submenu = createBehaviorMenu()
    }

    @objc func toggleThrowInertiaAction(sender: AnyObject) {
        UserDefaults.standard.set(!isThrowInertiaEnabled(), forKey: Self.throwInertiaEnabledDefaultsKey)
        behaviorMenuItem?.submenu = createBehaviorMenu()
    }

    @objc func toggleEdgeSnapAction(sender: AnyObject) {
        UserDefaults.standard.set(!isEdgeSnapEnabled(), forKey: Self.edgeSnapEnabledDefaultsKey)
        behaviorMenuItem?.submenu = createBehaviorMenu()
    }

    func isMuted() -> Bool {
        return UserDefaults.standard.bool(forKey: AgentController.muteDefaultsKey)
    }

    func setMuted(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: AgentController.muteDefaultsKey)
        AppDelegate.agentController?.isMuted = value
        muteMenuItem?.state = value ? .on : .off
    }

    func isSpeechBubblesEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: Self.speechBubblesEnabledDefaultsKey)
    }

    func setSpeechBubblesEnabled(_ value: Bool) {
        UserDefaults.standard.set(value, forKey: Self.speechBubblesEnabledDefaultsKey)
        speechBubblesMenuItem?.state = value ? .on : .off
    }

    func isAlwaysOnTopEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: Self.alwaysOnTopDefaultsKey)
    }

    func isJoinAllSpacesEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: Self.joinAllSpacesDefaultsKey)
    }

    func isThrowInertiaEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: Self.throwInertiaEnabledDefaultsKey)
    }

    func isEdgeSnapEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: Self.edgeSnapEnabledDefaultsKey)
    }

    func applyWindowBehavior() {
        window?.level = isAlwaysOnTopEnabled() ? .floating : .normal
        window?.collectionBehavior = isJoinAllSpacesEnabled()
            ? [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            : [.fullScreenAuxiliary, .stationary]
    }

    func saveWindowFrame(_ frame: CGRect) {
        UserDefaults.standard.set(NSStringFromRect(frame), forKey: Self.lastWindowFrameDefaultsKey)
    }

    func savedWindowFrame() -> CGRect? {
        guard let value = UserDefaults.standard.string(forKey: Self.lastWindowFrameDefaultsKey) else { return nil }
        let frame = NSRectFromString(value)
        guard frame.width > 0, frame.height > 0 else { return nil }
        return frame
    }

    func clampedWindowFrame(_ frame: CGRect, for window: NSWindow? = nil) -> CGRect {
        guard let screen = window?.screen ?? NSScreen.main ?? NSScreen.screens.first else { return frame }
        let visible = screen.visibleFrame
        var clamped = frame
        clamped.origin.x = max(visible.minX, min(clamped.origin.x, visible.maxX - clamped.width))
        clamped.origin.y = max(visible.minY, min(clamped.origin.y, visible.maxY - clamped.height))
        return clamped
    }

    private func importAgent(from url: URL) throws -> String {
        let fm = FileManager.default
        let agentsURL = Agent.agentsURL()
        let destination = agentsURL.appendingPathComponent(url.lastPathComponent)

        try? fm.removeItem(at: destination)
        try fm.copyItem(at: url, to: destination)

        if url.pathExtension == "zip" {
            let process = try Process.run(URL(fileURLWithPath: "/usr/bin/unzip"),
                                          arguments: ["-o", destination.path, "-d", agentsURL.path])
            process.waitUntilExit()
            guard process.terminationStatus == 0 else {
                throw NSError(domain: "ClippyImport", code: Int(process.terminationStatus), userInfo: [
                    NSLocalizedDescriptionKey: "unzip failed with status \(process.terminationStatus)"
                ])
            }
        } else if !(url.pathExtension == "agent" || url.hasDirectoryPath) {
            throw NSError(domain: "ClippyImport", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "unsupported file type"
            ])
        }

        let name = normalizedAgentName(from: url)
        guard Agent(resourceName: name) != nil else {
            throw NSError(domain: "ClippyImport", code: 2, userInfo: [
                NSLocalizedDescriptionKey: "agent files were copied but could not be loaded"
            ])
        }
        return name
    }

    private func normalizedAgentName(from url: URL) -> String {
        var name = url.deletingPathExtension().lastPathComponent
        if name.hasSuffix(".agent") {
            name = String(name.dropLast(".agent".count))
        }
        return name
    }

    private func presentImportResult(imported: [String], failures: [String]) {
        guard !imported.isEmpty || !failures.isEmpty else { return }
        let title = failures.isEmpty ? "Import Complete" : "Import Finished With Issues"
        var lines: [String] = []
        if !imported.isEmpty {
            lines.append("Imported: \(imported.sorted().joined(separator: ", "))")
        }
        if !failures.isEmpty {
            lines.append("Failed:\n\(failures.joined(separator: "\n"))")
        }
        presentAlert(title: title, message: lines.joined(separator: "\n\n"))
    }

    func isLaunchAtLoginEnabled() -> Bool {
        if #available(macOS 13.0, *) {
            return SMAppService.mainApp.status == .enabled
        }
        return false
    }

    func setLaunchAtLoginEnabled(_ enabled: Bool) {
        guard #available(macOS 13.0, *) else { return }
        do {
            if enabled {
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            presentAlert(title: "Launch at Login", message: error.localizedDescription)
        }
    }

    func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .informational
        alert.runModal()
    }
    
    @objc func selectAgent(sender: AnyObject) {
        guard let menuItem = sender as? NSMenuItem else { return }
        let name = menuItem.title.lowercased()
        
        if let isVisible = window?.isVisible, isVisible == true {
            try? AppDelegate.agentController?.load(name: name)
            if let animation = AppDelegate.agentController?.agent?.findAnimation("Show") {
                AppDelegate.agentController?.play(animation: animation)
            }
        } else {
            lastUsedAgent = name
            window?.makeKeyAndOrderFront(self)
        }
        
        refreshDynamicMenus()
    }
}
