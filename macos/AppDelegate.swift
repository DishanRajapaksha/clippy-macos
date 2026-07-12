//
//  AppDelegate.swift
//  Clippy macOS
//
//  Created by Devran on 03.09.19.
//  Copyright © 2019 Devran. All rights reserved.
//

import Cocoa
import ServiceManagement
import UniformTypeIdentifiers

class AppDelegate: NSObject, NSApplicationDelegate, AgentPreviewViewControllerDelegate {
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
    private let agentImporter = AgentImporter()
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
            item.representedObject = agentName
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

        let randomItem = NSMenuItem(
            title: "Random (5–60s)",
            action: #selector(selectRandomAutoAnimateInterval(sender:)),
            keyEquivalent: ""
        )
        randomItem.target = self
        randomItem.state = configured == AgentController.randomAutoAnimateInterval ? .on : .off
        menu.addItem(randomItem)

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

    @objc func selectRandomAutoAnimateInterval(sender: AnyObject) {
        UserDefaults.standard.set(AgentController.randomAutoAnimateInterval, forKey: AgentController.autoAnimateIntervalDefaultsKey)
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
        panel.allowedContentTypes = [.zip, UTType(filenameExtension: "agent"), UTType(filenameExtension: "acs")].compactMap { $0 }
        panel.prompt = "Import"

        guard panel.runModal() == .OK else { return }
        let outcome = agentImporter.importAgents(from: panel.urls)
        reloadAction(sender: self)
        presentImportResult(imported: outcome.imported, failures: outcome.failures)
    }

    @objc func showAgentPreviewsAction(sender: AnyObject) {
        let vc = AgentPreviewViewController()
        vc.delegate = self
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 480),
                              styleMask: [.titled, .closable, .resizable],
                              backing: .buffered,
                              defer: false)
        window.title = "Agent Previews"
        window.contentViewController = vc
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.isReleasedWhenClosed = false
        window.center()
        let controller = NSWindowController(window: window)
        previewWindowController = controller
        controller.showWindow(self)
        window.makeKeyAndOrderFront(self)
        window.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    func agentPreviewViewController(_ controller: AgentPreviewViewController, didSelectAgent name: String) {
        try? AppDelegate.agentController?.load(name: name)
        if let animation = AppDelegate.agentController?.agent?.findAnimation("Show") {
            AppDelegate.agentController?.play(animation: animation)
        }
        lastUsedAgent = name
        window?.makeKeyAndOrderFront(self)
        refreshDynamicMenus()
    }

    func agentPreviewViewControllerDidChangeAgents(_ controller: AgentPreviewViewController) {
        refreshDynamicMenus()
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
        let name = (menuItem.representedObject as? String) ?? menuItem.title.lowercased()
        
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
