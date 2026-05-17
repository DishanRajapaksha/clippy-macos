//
//  AppDelegate.swift
//  Clippy macOS
//
//  Created by Devran on 03.09.19.
//  Copyright © 2019 Devran. All rights reserved.
//

import Cocoa

class AgentPreviewViewController: NSViewController, NSTableViewDataSource, NSTableViewDelegate {
    struct PreviewRow {
        let name: String
        let size: String
        let animations: String
    }

    private var rows: [PreviewRow] = []
    private let tableView = NSTableView()

    override func loadView() {
        view = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 320))
        setupTable()
        loadRows()
    }

    private func setupTable() {
        let scroll = NSScrollView(frame: view.bounds)
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
        view.addSubview(scroll)
    }

    private func loadRows() {
        rows = Agent.agentNames().compactMap { name in
            guard let agent = Agent(resourceName: name) else { return nil }
            let size = "\(agent.character.width)x\(agent.character.height)"
            return PreviewRow(name: name, size: size, animations: "\(agent.animations.count)")
        }
        tableView.reloadData()
    }

    func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
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
}

class AppDelegate: NSObject, NSApplicationDelegate {
    let applicationName = "Clippy"
    static let lastUsedAgentDefaultsKey = "LastUsedAgent"
    static let speechBubblesEnabledDefaultsKey = "SpeechBubblesEnabled"
    var window: NSWindow?
    var statusItem: NSStatusItem?
    var agentsMenuItem: NSMenuItem?
    var autoAnimateMenuItem: NSMenuItem?
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
            AgentController.idleCursorProximityDefaultsKey: AgentController.defaultIdleCursorProximity,
            AgentController.muteDefaultsKey: false,
            Self.speechBubblesEnabledDefaultsKey: true
        ])
        
        window = AgentWindow(contentRect: CGRect.zero, styleMask: [], backing: .buffered, defer: true)
        window?.title = applicationName
        window?.contentViewController = AgentViewController()
        if !Agent.agentNames().isEmpty {
            window?.makeKeyAndOrderFront(self)
        }
        window?.center()
        
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
            if lastUsedAgent == agentName {
                item.state = .on
            }
            agentsMenu.addItem(item)
        }
        agentsMenu.addItem(NSMenuItem.separator())
        agentsMenu.addItem(withTitle: "Reload",
                           action: #selector(reloadAction(sender:)),
                           keyEquivalent: "")
        return agentsMenu
    }
    
    func setupStatusBarMenu() {
        // Status bar menu
        let statusBarMenu = NSMenu(title: "Clippy")
        agentsMenuItem = NSMenuItem(title: "Agents", action: nil, keyEquivalent: "")
        autoAnimateMenuItem = NSMenuItem(title: "Auto Animate", action: nil, keyEquivalent: "")
        muteMenuItem = NSMenuItem(title: "Mute", action: #selector(toggleMuteAction(sender:)), keyEquivalent: "")
        speechBubblesMenuItem = NSMenuItem(title: "Speech Bubbles", action: #selector(toggleSpeechBubblesAction(sender:)), keyEquivalent: "")
        
        statusBarMenu.addItem(withTitle: "Show", action: #selector(showAction(sender:)), keyEquivalent: "")
        statusBarMenu.addItem(withTitle: "Hide", action: #selector(hideAction(sender:)), keyEquivalent: "")
        if let muteItem = muteMenuItem {
            muteItem.state = isMuted() ? .on : .off
            statusBarMenu.addItem(muteItem)
        }
        if let speechItem = speechBubblesMenuItem {
            speechItem.state = isSpeechBubblesEnabled() ? .on : .off
            statusBarMenu.addItem(speechItem)
        }
        if let autoAnimateItem = autoAnimateMenuItem {
            statusBarMenu.addItem(autoAnimateItem)
            statusBarMenu.setSubmenu(createAutoAnimateMenu(), for: autoAnimateItem)
        }
        statusBarMenu.addItem(NSMenuItem.separator())
        guard let menuItem = agentsMenuItem else  { return }
        statusBarMenu.addItem(menuItem)
        statusBarMenu.addItem(withTitle: "Show in Finder",
                           action: #selector(openFolderAction(sender:)),
                           keyEquivalent: "")
        statusBarMenu.addItem(withTitle: "Import Agent…",
                              action: #selector(importAgentAction(sender:)),
                              keyEquivalent: "")
        statusBarMenu.addItem(withTitle: "Agent Previews…",
                              action: #selector(showAgentPreviewsAction(sender:)),
                              keyEquivalent: "")
        statusBarMenu.addItem(NSMenuItem.separator())
        statusBarMenu.addItem(withTitle: "Quit \(applicationName)", action: #selector(quitAction(sender:)), keyEquivalent: "")
        
        // Agents menu
        statusBarMenu.setSubmenu(createAgentsMenu(), for: menuItem)
        
        statusItem?.menu = statusBarMenu
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
            item.representedObject = interval
            item.state = abs(current - interval) < 0.001 ? .on : .off
            menu.addItem(item)
        }

        menu.addItem(NSMenuItem.separator())
        let disableItem = NSMenuItem(title: "Off", action: #selector(disableAutoAnimate(sender:)), keyEquivalent: "")
        disableItem.state = configured == 0 ? .on : .off
        menu.addItem(disableItem)
        return menu
    }
    
    @objc func quitAction(sender: AnyObject) {
        NSApplication.shared.terminate(self)
    }
    
    @objc func reloadAction(sender: AnyObject) {
        agentsMenuItem?.submenu = createAgentsMenu()
        autoAnimateMenuItem?.submenu = createAutoAnimateMenu()
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
    
    @objc func openFolderAction(sender: AnyObject) {
        NSWorkspace.shared.open(Agent.agentsURL())
    }

    @objc func importAgentAction(sender: AnyObject) {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedFileTypes = ["zip", "agent"]
        panel.prompt = "Import"

        guard panel.runModal() == .OK else { return }
        let fm = FileManager.default
        let agentsURL = Agent.agentsURL()

        for url in panel.urls {
            if url.pathExtension == "zip" {
                let destination = agentsURL.appendingPathComponent(url.lastPathComponent)
                try? fm.removeItem(at: destination)
                try? fm.copyItem(at: url, to: destination)
                _ = try? Process.run(URL(fileURLWithPath: "/usr/bin/unzip"),
                                     arguments: ["-o", destination.path, "-d", agentsURL.path])
            } else if url.pathExtension == "agent" || url.hasDirectoryPath {
                let destination = agentsURL.appendingPathComponent(url.lastPathComponent)
                try? fm.removeItem(at: destination)
                try? fm.copyItem(at: url, to: destination)
            }
        }
        reloadAction(sender: self)
    }

    @objc func showAgentPreviewsAction(sender: AnyObject) {
        let vc = AgentPreviewViewController()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 520, height: 320),
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
        
        agentsMenuItem?.submenu = createAgentsMenu()
    }
}
