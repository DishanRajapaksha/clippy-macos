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

struct AgentSessionSettings: Codable, Equatable {
    let id: UUID
    var agentName: String?
    var windowFrame: String?
    var isMuted: Bool
    var speechBubblesEnabled: Bool
    var autoAnimateInterval: TimeInterval
    var alwaysOnTop: Bool
    var joinAllSpaces: Bool
    var throwInertiaEnabled: Bool
    var edgeSnapEnabled: Bool
    var proximityReactionsEnabled: Bool
}

final class AgentSession {
    let id: UUID
    var settings: AgentSessionSettings
    let window: AgentWindow
    let viewController: AgentViewController

    var controller: AgentController {
        viewController.agentController
    }

    var displayName: String {
        if let agent = controller.agent,
           let name = agent.character.infos.first(where: { $0.language == "0x0009" })?.name {
            return name
        }
        return settings.agentName?.capitalized ?? "Agent"
    }

    init(settings: AgentSessionSettings) {
        id = settings.id
        self.settings = settings
        window = AgentWindow(contentRect: .zero, styleMask: [], backing: .buffered, defer: true)
        viewController = AgentViewController(sessionID: settings.id)
        window.sessionID = settings.id
        window.contentViewController = viewController
        window.title = "Clippy"
    }
}

final class AgentSessionManager: NSObject, AgentWindowSessionDelegate {
    private static let sessionsDefaultsKey = "AgentSessionsV1"
    private weak var appDelegate: AppDelegate?
    private(set) var sessions: [AgentSession] = []
    private(set) var activeSessionID: UUID?
    private var proximityTimer: Timer?
    private var activeProximityPairs: Set<String> = []

    var activeSession: AgentSession? {
        if let keyWindow = NSApp.keyWindow as? AgentWindow,
           let sessionID = keyWindow.sessionID,
           let session = session(for: sessionID) {
            return session
        }
        if let activeSessionID, let session = session(for: activeSessionID) {
            return session
        }
        return sessions.last
    }

    init(appDelegate: AppDelegate) {
        self.appDelegate = appDelegate
        super.init()
    }

    deinit {
        proximityTimer?.invalidate()
    }

    func restoreSessions() {
        let restoredSettings: [AgentSessionSettings]
        if let data = UserDefaults.standard.data(forKey: Self.sessionsDefaultsKey),
           let decoded = try? JSONDecoder().decode([AgentSessionSettings].self, from: data) {
            restoredSettings = decoded
        } else {
            restoredSettings = []
        }

        if restoredSettings.isEmpty {
            _ = createSession(agentName: appDelegate?.lastUsedAgent, activate: true)
        } else {
            for settings in restoredSettings {
                _ = createSession(settings: settings, activate: false)
            }
            if let last = sessions.last {
                activeSessionID = last.id
                last.window.makeKeyAndOrderFront(nil)
            }
        }
        startProximityMonitoring()
        appDelegate?.refreshDynamicMenus()
    }

    @discardableResult
    func createSession(agentName: String? = nil, activate: Bool = true) -> AgentSession {
        var settings = defaultSettings(agentName: agentName)
        if settings.agentName == nil {
            settings.agentName = Agent.randomAgentName()
        }
        return createSession(settings: settings, activate: activate)
    }

    @discardableResult
    private func createSession(settings: AgentSessionSettings, activate: Bool) -> AgentSession {
        let session = AgentSession(settings: settings)
        session.window.sessionDelegate = self
        sessions.append(session)
        activeSessionID = session.id
        applySettings(to: session)
        positionWindow(for: session)

        if activate {
            NSApp.unhide(nil)
            session.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        } else {
            session.window.orderFront(nil)
        }

        persistSessions()
        appDelegate?.refreshDynamicMenus()
        return session
    }

    func session(for id: UUID) -> AgentSession? {
        sessions.first(where: { $0.id == id })
    }

    func settings(for id: UUID) -> AgentSessionSettings? {
        session(for: id)?.settings
    }

    func updateSettings(for id: UUID, _ change: (inout AgentSessionSettings) -> Void) {
        guard let session = session(for: id) else { return }
        change(&session.settings)
        applySettings(to: session)
        persistSessions()
        appDelegate?.refreshDynamicMenus()
    }

    func activate(sessionID: UUID, bringForward: Bool = true) {
        guard let session = session(for: sessionID) else { return }
        activeSessionID = sessionID
        if bringForward {
            NSApp.unhide(nil)
            if session.controller.isHidden {
                session.controller.show()
            }
            session.window.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
        appDelegate?.refreshDynamicMenus()
    }

    func showActive() {
        guard let session = activeSession ?? sessions.last else { return }
        activeSessionID = session.id
        NSApp.unhide(nil)
        session.controller.show()
        session.window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func hideActive() {
        activeSession?.controller.hide()
    }

    func showAll() {
        guard !sessions.isEmpty else { return }
        NSApp.unhide(nil)
        for session in sessions {
            session.controller.show()
        }
        if let active = activeSession ?? sessions.last {
            activeSessionID = active.id
            active.window.makeKeyAndOrderFront(nil)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    func hideAll() {
        for session in sessions {
            session.controller.hide()
        }
    }

    func closeActive() {
        guard let activeSession else { return }
        close(sessionID: activeSession.id)
    }

    func close(sessionID: UUID) {
        guard let index = sessions.firstIndex(where: { $0.id == sessionID }) else { return }
        let session = sessions.remove(at: index)
        session.controller.autoAnimateTimer?.invalidate()
        session.controller.autoAnimateTimer = nil
        session.controller.cancelPlayback()
        session.window.orderOut(nil)
        session.window.contentViewController = nil
        activeProximityPairs = activeProximityPairs.filter { !$0.contains(sessionID.uuidString) }

        if activeSessionID == sessionID {
            activeSessionID = sessions.last?.id
        }
        persistSessions()
        appDelegate?.refreshDynamicMenus()
    }

    func selectAgent(_ name: String, for sessionID: UUID) {
        guard let session = session(for: sessionID) else { return }
        do {
            try session.controller.load(name: name)
            updateSettings(for: sessionID) { $0.agentName = name }
            session.controller.show()
        } catch {
            appDelegate?.presentAlert(title: "Agent Could Not Load", message: error.localizedDescription)
        }
    }

    func updateWindowFrame(for sessionID: UUID, frame: CGRect) {
        guard let session = session(for: sessionID) else { return }
        session.settings.windowFrame = NSStringFromRect(frame)
        persistSessions()
    }

    func savedWindowFrame(for sessionID: UUID) -> CGRect? {
        guard let value = session(for: sessionID)?.settings.windowFrame else { return nil }
        let frame = NSRectFromString(value)
        guard frame.width > 0, frame.height > 0 else { return nil }
        return frame
    }

    func agentWindowDidBecomeKey(_ window: AgentWindow) {
        guard let sessionID = window.sessionID else { return }
        activeSessionID = sessionID
        appDelegate?.refreshDynamicMenus()
    }

    func agentWindowDidMove(_ window: AgentWindow) {
        guard let sessionID = window.sessionID else { return }
        updateWindowFrame(for: sessionID, frame: window.frame)
        evaluateProximity()
    }

    func persistSessions() {
        let settings = sessions.map { $0.settings }
        guard let data = try? JSONEncoder().encode(settings) else { return }
        UserDefaults.standard.set(data, forKey: Self.sessionsDefaultsKey)
    }

    private func defaultSettings(agentName: String?) -> AgentSessionSettings {
        let defaults = UserDefaults.standard
        let configuredInterval = defaults.double(forKey: AgentController.autoAnimateIntervalDefaultsKey)
        return AgentSessionSettings(
            id: UUID(),
            agentName: agentName,
            windowFrame: nil,
            isMuted: defaults.bool(forKey: AgentController.muteDefaultsKey),
            speechBubblesEnabled: defaults.bool(forKey: AppDelegate.speechBubblesEnabledDefaultsKey),
            autoAnimateInterval: configuredInterval,
            alwaysOnTop: defaults.bool(forKey: AppDelegate.alwaysOnTopDefaultsKey),
            joinAllSpaces: defaults.bool(forKey: AppDelegate.joinAllSpacesDefaultsKey),
            throwInertiaEnabled: defaults.bool(forKey: AppDelegate.throwInertiaEnabledDefaultsKey),
            edgeSnapEnabled: defaults.bool(forKey: AppDelegate.edgeSnapEnabledDefaultsKey),
            proximityReactionsEnabled: true
        )
    }

    private func applySettings(to session: AgentSession) {
        session.controller.isMuted = session.settings.isMuted
        session.controller.configuredAutoAnimateInterval = session.settings.autoAnimateInterval
        if session.controller.agent != nil {
            session.controller.restartAutoAnimateTimer()
        }
        session.window.level = session.settings.alwaysOnTop ? .floating : .normal
        session.window.collectionBehavior = session.settings.joinAllSpaces
            ? [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
            : [.fullScreenAuxiliary, .stationary]
    }

    private func positionWindow(for session: AgentSession) {
        if let saved = savedWindowFrame(for: session.id) {
            session.window.setFrameOrigin(saved.origin)
            return
        }

        if sessions.count > 1, let previous = sessions.dropLast().last {
            var origin = previous.window.frame.origin
            origin.x += 36
            origin.y -= 36
            session.window.setFrameOrigin(origin)
        } else {
            session.window.center()
        }
    }

    private func startProximityMonitoring() {
        proximityTimer?.invalidate()
        proximityTimer = Timer.scheduledTimer(withTimeInterval: 0.65, repeats: true) { [weak self] _ in
            self?.evaluateProximity()
        }
    }

    private func evaluateProximity() {
        let visibleSessions = sessions.filter {
            $0.window.isVisible && !$0.controller.isHidden && $0.settings.proximityReactionsEnabled
        }
        guard visibleSessions.count >= 2 else {
            activeProximityPairs.removeAll()
            return
        }

        var pairsStillNearby: Set<String> = []
        for firstIndex in 0..<(visibleSessions.count - 1) {
            for secondIndex in (firstIndex + 1)..<visibleSessions.count {
                let first = visibleSessions[firstIndex]
                let second = visibleSessions[secondIndex]
                let key = proximityKey(first.id, second.id)
                let distance = frameDistance(first.window.frame, second.window.frame)

                if distance <= 140 {
                    pairsStillNearby.insert(key)
                }
                if distance <= 48, !activeProximityPairs.contains(key) {
                    activeProximityPairs.insert(key)
                    triggerPairedReaction(first, second)
                }
            }
        }
        activeProximityPairs.formIntersection(pairsStillNearby)
    }

    private func triggerPairedReaction(_ first: AgentSession, _ second: AgentSession) {
        let firstDirection: AgentReactionDirection = second.window.frame.midX >= first.window.frame.midX ? .right : .left
        let secondDirection: AgentReactionDirection = firstDirection == .right ? .left : .right
        first.viewController.reactToNearbyAgent(named: second.displayName, direction: firstDirection, isReply: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.45) { [weak second] in
            second?.viewController.reactToNearbyAgent(named: first.displayName, direction: secondDirection, isReply: true)
        }
    }

    private func proximityKey(_ lhs: UUID, _ rhs: UUID) -> String {
        [lhs.uuidString, rhs.uuidString].sorted().joined(separator: ":")
    }

    private func frameDistance(_ lhs: CGRect, _ rhs: CGRect) -> CGFloat {
        let dx = max(lhs.minX - rhs.maxX, rhs.minX - lhs.maxX, 0)
        let dy = max(lhs.minY - rhs.maxY, rhs.minY - lhs.maxY, 0)
        return hypot(dx, dy)
    }
}

class AppDelegate: NSObject, NSApplicationDelegate, AgentPreviewViewControllerDelegate, NSMenuDelegate {
    let applicationName = "Clippy"
    static let lastUsedAgentDefaultsKey = "LastUsedAgent"
    static let speechBubblesEnabledDefaultsKey = "SpeechBubblesEnabled"
    static let alwaysOnTopDefaultsKey = "AlwaysOnTop"
    static let joinAllSpacesDefaultsKey = "JoinAllSpaces"
    static let throwInertiaEnabledDefaultsKey = "ThrowInertiaEnabled"
    static let edgeSnapEnabledDefaultsKey = "EdgeSnapEnabled"
    static let lastWindowFrameDefaultsKey = "LastWindowFrame"

    var statusItem: NSStatusItem?
    var agentsMenuItem: NSMenuItem?
    var animationsMenuItem: NSMenuItem?
    var autoAnimateMenuItem: NSMenuItem?
    var behaviorMenuItem: NSMenuItem?
    var agentWindowsMenuItem: NSMenuItem?
    var muteMenuItem: NSMenuItem?
    var speechBubblesMenuItem: NSMenuItem?
    var previewWindowController: NSWindowController?
    private let agentImporter = AgentImporter()
    lazy var sessionManager = AgentSessionManager(appDelegate: self)

    var window: NSWindow? {
        sessionManager.activeSession?.window
    }

    var agentController: AgentController? {
        sessionManager.activeSession?.controller
    }

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

        setupStatusBar()
        sessionManager.restoreSessions()
    }

    func applicationWillTerminate(_ aNotification: Notification) {
        sessionManager.persistSessions()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        return false
    }

    func setupStatusBar() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem?.button?.title = "📎"
        setupStatusBarMenu()
    }

    func setupStatusBarMenu() {
        let menu = createMainMenu(registerMenuItems: true)
        menu.delegate = self
        statusItem?.menu = menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === statusItem?.menu {
            refreshDynamicMenus()
        }
    }

    func createMainMenu(registerMenuItems: Bool = false) -> NSMenu {
        let menu = NSMenu(title: "Clippy")
        let hasActiveSession = sessionManager.activeSession != nil

        let showItem = addMenuItem(to: menu, title: "Show Current", action: #selector(showAction(sender:)))
        showItem.isEnabled = hasActiveSession
        let hideItem = addMenuItem(to: menu, title: "Hide Current", action: #selector(hideAction(sender:)))
        hideItem.isEnabled = hasActiveSession
        addMenuItem(to: menu, title: "Show All", action: #selector(showAllAction(sender:))).isEnabled = !sessionManager.sessions.isEmpty
        addMenuItem(to: menu, title: "Hide All", action: #selector(hideAllAction(sender:))).isEnabled = !sessionManager.sessions.isEmpty

        menu.addItem(NSMenuItem.separator())
        let newAgentItem = NSMenuItem(title: "New Agent", action: nil, keyEquivalent: "")
        menu.addItem(newAgentItem)
        menu.setSubmenu(createNewAgentMenu(), for: newAgentItem)

        let windowsItem = NSMenuItem(title: "Agent Windows", action: nil, keyEquivalent: "")
        menu.addItem(windowsItem)
        menu.setSubmenu(createAgentWindowsMenu(), for: windowsItem)
        addMenuItem(to: menu, title: "Close Current Agent", action: #selector(closeCurrentAgentAction(sender:))).isEnabled = hasActiveSession

        menu.addItem(NSMenuItem.separator())
        let muteItem = NSMenuItem(title: "Mute Current", action: #selector(toggleMuteAction(sender:)), keyEquivalent: "")
        muteItem.target = self
        muteItem.state = isMuted() ? .on : .off
        muteItem.isEnabled = hasActiveSession
        menu.addItem(muteItem)

        let speechItem = NSMenuItem(title: "Speech Bubbles", action: #selector(toggleSpeechBubblesAction(sender:)), keyEquivalent: "")
        speechItem.target = self
        speechItem.state = isSpeechBubblesEnabled() ? .on : .off
        speechItem.isEnabled = hasActiveSession
        menu.addItem(speechItem)

        let autoItem = NSMenuItem(title: "Auto Animate", action: nil, keyEquivalent: "")
        autoItem.isEnabled = hasActiveSession
        menu.addItem(autoItem)
        menu.setSubmenu(createAutoAnimateMenu(), for: autoItem)

        let behaviorItem = NSMenuItem(title: "Behavior", action: nil, keyEquivalent: "")
        menu.addItem(behaviorItem)
        menu.setSubmenu(createBehaviorMenu(), for: behaviorItem)

        menu.addItem(NSMenuItem.separator())
        let agentsItem = NSMenuItem(title: "Change Current Agent", action: nil, keyEquivalent: "")
        agentsItem.isEnabled = hasActiveSession
        menu.addItem(agentsItem)
        menu.setSubmenu(createAgentsMenu(), for: agentsItem)

        let animationsItem = NSMenuItem(title: "Animations", action: nil, keyEquivalent: "")
        animationsItem.isEnabled = hasActiveSession
        menu.addItem(animationsItem)
        menu.setSubmenu(createAnimationsMenu(), for: animationsItem)

        addMenuItem(to: menu, title: "Show in Finder", action: #selector(openFolderAction(sender:)))
        addMenuItem(to: menu, title: "Import Agent…", action: #selector(importAgentAction(sender:)))
        addMenuItem(to: menu, title: "Agent Previews…", action: #selector(showAgentPreviewsAction(sender:)))
        menu.addItem(NSMenuItem.separator())
        addMenuItem(to: menu, title: "Quit \(applicationName)", action: #selector(quitAction(sender:)))

        if registerMenuItems {
            agentsMenuItem = agentsItem
            animationsMenuItem = animationsItem
            autoAnimateMenuItem = autoItem
            behaviorMenuItem = behaviorItem
            agentWindowsMenuItem = windowsItem
            muteMenuItem = muteItem
            speechBubblesMenuItem = speechItem
        }
        return menu
    }

    func createNewAgentMenu() -> NSMenu {
        let menu = NSMenu(title: "New Agent")
        addMenuItem(to: menu, title: "Random Agent", action: #selector(newRandomAgentAction(sender:)))
        menu.addItem(NSMenuItem.separator())
        let names = Agent.agentNames()
        if names.isEmpty {
            menu.addItem(withTitle: "No Agents found.", action: nil, keyEquivalent: "")
        }
        for name in names {
            let item = NSMenuItem(title: name.capitalized, action: #selector(newNamedAgentAction(sender:)), keyEquivalent: "")
            item.target = self
            item.representedObject = name
            menu.addItem(item)
        }
        return menu
    }

    func createAgentWindowsMenu() -> NSMenu {
        let menu = NSMenu(title: "Agent Windows")
        if sessionManager.sessions.isEmpty {
            menu.addItem(withTitle: "No Agent Windows", action: nil, keyEquivalent: "")
            return menu
        }
        for (index, session) in sessionManager.sessions.enumerated() {
            let item = NSMenuItem(
                title: "\(index + 1). \(session.displayName)",
                action: #selector(selectAgentWindowAction(sender:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = session.id.uuidString
            item.state = sessionManager.activeSession?.id == session.id ? .on : .off
            menu.addItem(item)
        }
        return menu
    }

    func createAgentsMenu() -> NSMenu {
        let menu = NSMenu(title: "Change Current Agent")
        let names = Agent.agentNames()
        if names.isEmpty {
            menu.addItem(withTitle: "No Agents found.", action: nil, keyEquivalent: "")
        }
        for name in names {
            let item = NSMenuItem(title: name.capitalized, action: #selector(selectAgent(sender:)), keyEquivalent: "")
            item.target = self
            item.representedObject = name
            item.state = sessionManager.activeSession?.settings.agentName == name ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(NSMenuItem.separator())
        addMenuItem(to: menu, title: "Reload", action: #selector(reloadAction(sender:)))
        return menu
    }

    func createAnimationsMenu() -> NSMenu {
        let menu = NSMenu(title: "Animations")
        guard let agent = agentController?.agent else {
            menu.addItem(withTitle: "No Agent loaded.", action: nil, keyEquivalent: "")
            return menu
        }
        if agent.animations.isEmpty {
            menu.addItem(withTitle: "No Animations found.", action: nil, keyEquivalent: "")
            return menu
        }
        for animation in agent.animations {
            let item = NSMenuItem(title: animation.name, action: #selector(playAnimationAction(sender:)), keyEquivalent: "")
            item.target = self
            item.representedObject = animation.name
            menu.addItem(item)
        }
        return menu
    }

    func createAutoAnimateMenu() -> NSMenu {
        let menu = NSMenu(title: "Auto Animate")
        guard let session = sessionManager.activeSession else {
            menu.addItem(withTitle: "No Active Agent", action: nil, keyEquivalent: "")
            return menu
        }
        let configured = session.settings.autoAnimateInterval
        let current = configured > 0 ? configured : AgentController.defaultAutoAnimateInterval
        for interval in [5.0, 10.0, 15.0, 30.0, 60.0] {
            let item = NSMenuItem(title: "Every \(Int(interval))s", action: #selector(selectAutoAnimateInterval(sender:)), keyEquivalent: "")
            item.target = self
            item.representedObject = interval
            item.state = abs(current - interval) < 0.001 ? .on : .off
            menu.addItem(item)
        }
        let randomItem = NSMenuItem(title: "Random (5–60s)", action: #selector(selectRandomAutoAnimateInterval(sender:)), keyEquivalent: "")
        randomItem.target = self
        randomItem.state = configured == AgentController.randomAutoAnimateInterval ? .on : .off
        menu.addItem(randomItem)
        menu.addItem(NSMenuItem.separator())
        let offItem = NSMenuItem(title: "Off", action: #selector(disableAutoAnimate(sender:)), keyEquivalent: "")
        offItem.target = self
        offItem.state = configured == 0 ? .on : .off
        menu.addItem(offItem)
        return menu
    }

    func createBehaviorMenu() -> NSMenu {
        let menu = NSMenu(title: "Behavior")
        let launchItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLoginAction(sender:)), keyEquivalent: "")
        launchItem.target = self
        launchItem.state = isLaunchAtLoginEnabled() ? .on : .off
        menu.addItem(launchItem)

        guard sessionManager.activeSession != nil else {
            menu.addItem(NSMenuItem.separator())
            let item = menu.addItem(withTitle: "No Active Agent", action: nil, keyEquivalent: "")
            item.isEnabled = false
            return menu
        }

        let alwaysItem = NSMenuItem(title: "Always on Top", action: #selector(toggleAlwaysOnTopAction(sender:)), keyEquivalent: "")
        alwaysItem.target = self
        alwaysItem.state = isAlwaysOnTopEnabled() ? .on : .off
        menu.addItem(alwaysItem)

        let spacesItem = NSMenuItem(title: "Join All Spaces", action: #selector(toggleJoinAllSpacesAction(sender:)), keyEquivalent: "")
        spacesItem.target = self
        spacesItem.state = isJoinAllSpacesEnabled() ? .on : .off
        menu.addItem(spacesItem)
        menu.addItem(NSMenuItem.separator())

        let inertiaItem = NSMenuItem(title: "Throw Inertia", action: #selector(toggleThrowInertiaAction(sender:)), keyEquivalent: "")
        inertiaItem.target = self
        inertiaItem.state = isThrowInertiaEnabled() ? .on : .off
        menu.addItem(inertiaItem)

        let snapItem = NSMenuItem(title: "Edge Snap", action: #selector(toggleEdgeSnapAction(sender:)), keyEquivalent: "")
        snapItem.target = self
        snapItem.state = isEdgeSnapEnabled() ? .on : .off
        menu.addItem(snapItem)

        let reactionItem = NSMenuItem(title: "Paired Reactions", action: #selector(togglePairedReactionsAction(sender:)), keyEquivalent: "")
        reactionItem.target = self
        reactionItem.state = arePairedReactionsEnabled() ? .on : .off
        menu.addItem(reactionItem)
        return menu
    }

    func refreshDynamicMenus() {
        agentsMenuItem?.submenu = createAgentsMenu()
        animationsMenuItem?.submenu = createAnimationsMenu()
        autoAnimateMenuItem?.submenu = createAutoAnimateMenu()
        behaviorMenuItem?.submenu = createBehaviorMenu()
        agentWindowsMenuItem?.submenu = createAgentWindowsMenu()
        muteMenuItem?.state = isMuted() ? .on : .off
        speechBubblesMenuItem?.state = isSpeechBubblesEnabled() ? .on : .off
    }

    @discardableResult
    private func addMenuItem(to menu: NSMenu, title: String, action: Selector?) -> NSMenuItem {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc func newRandomAgentAction(sender: AnyObject) {
        _ = sessionManager.createSession(agentName: Agent.randomAgentName())
    }

    @objc func newNamedAgentAction(sender: AnyObject) {
        guard let item = sender as? NSMenuItem, let name = item.representedObject as? String else { return }
        _ = sessionManager.createSession(agentName: name)
    }

    @objc func selectAgentWindowAction(sender: AnyObject) {
        guard let item = sender as? NSMenuItem,
              let value = item.representedObject as? String,
              let id = UUID(uuidString: value) else { return }
        sessionManager.activate(sessionID: id)
    }

    @objc func closeCurrentAgentAction(sender: AnyObject) {
        sessionManager.closeActive()
    }

    @objc func showAction(sender: AnyObject) {
        sessionManager.showActive()
    }

    @objc func hideAction(sender: AnyObject) {
        sessionManager.hideActive()
    }

    @objc func showAllAction(sender: AnyObject) {
        sessionManager.showAll()
    }

    @objc func hideAllAction(sender: AnyObject) {
        sessionManager.hideAll()
    }

    @objc func quitAction(sender: AnyObject) {
        NSApplication.shared.terminate(self)
    }

    @objc func reloadAction(sender: AnyObject) {
        refreshDynamicMenus()
    }

    @objc func selectAutoAnimateInterval(sender: AnyObject) {
        guard let item = sender as? NSMenuItem,
              let interval = item.representedObject as? TimeInterval,
              let session = sessionManager.activeSession else { return }
        sessionManager.updateSettings(for: session.id) { $0.autoAnimateInterval = interval }
    }

    @objc func selectRandomAutoAnimateInterval(sender: AnyObject) {
        guard let session = sessionManager.activeSession else { return }
        sessionManager.updateSettings(for: session.id) {
            $0.autoAnimateInterval = AgentController.randomAutoAnimateInterval
        }
    }

    @objc func disableAutoAnimate(sender: AnyObject) {
        guard let session = sessionManager.activeSession else { return }
        sessionManager.updateSettings(for: session.id) { $0.autoAnimateInterval = 0 }
    }

    @objc func playAnimationAction(sender: AnyObject) {
        guard let item = sender as? NSMenuItem,
              let name = item.representedObject as? String,
              let animation = agentController?.agent?.findAnimation(name) else { return }
        agentController?.play(animation: animation)
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
        refreshDynamicMenus()
        presentImportResult(imported: outcome.imported, failures: outcome.failures)
    }

    @objc func showAgentPreviewsAction(sender: AnyObject) {
        let vc = AgentPreviewViewController()
        vc.delegate = self
        let previewWindow = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 480),
            styleMask: [.titled, .closable, .resizable],
            backing: .buffered,
            defer: false
        )
        previewWindow.title = "Agent Previews"
        previewWindow.contentViewController = vc
        previewWindow.level = .floating
        previewWindow.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        previewWindow.isReleasedWhenClosed = false
        previewWindow.center()
        let controller = NSWindowController(window: previewWindow)
        previewWindowController = controller
        controller.showWindow(self)
        previewWindow.makeKeyAndOrderFront(self)
        previewWindow.orderFrontRegardless()
        NSApp.activate(ignoringOtherApps: true)
    }

    func agentPreviewViewController(_ controller: AgentPreviewViewController, didSelectAgent name: String) {
        if let active = sessionManager.activeSession {
            sessionManager.selectAgent(name, for: active.id)
            sessionManager.activate(sessionID: active.id)
        } else {
            _ = sessionManager.createSession(agentName: name)
        }
        lastUsedAgent = name
        refreshDynamicMenus()
    }

    func agentPreviewViewControllerDidChangeAgents(_ controller: AgentPreviewViewController) {
        refreshDynamicMenus()
    }

    @objc func toggleMuteAction(sender: AnyObject) {
        setMuted(!isMuted())
    }

    @objc func toggleSpeechBubblesAction(sender: AnyObject) {
        setSpeechBubblesEnabled(!isSpeechBubblesEnabled())
    }

    @objc func toggleLaunchAtLoginAction(sender: AnyObject) {
        setLaunchAtLoginEnabled(!isLaunchAtLoginEnabled())
        refreshDynamicMenus()
    }

    @objc func toggleAlwaysOnTopAction(sender: AnyObject) {
        guard let session = sessionManager.activeSession else { return }
        sessionManager.updateSettings(for: session.id) { $0.alwaysOnTop.toggle() }
    }

    @objc func toggleJoinAllSpacesAction(sender: AnyObject) {
        guard let session = sessionManager.activeSession else { return }
        sessionManager.updateSettings(for: session.id) { $0.joinAllSpaces.toggle() }
    }

    @objc func toggleThrowInertiaAction(sender: AnyObject) {
        guard let session = sessionManager.activeSession else { return }
        sessionManager.updateSettings(for: session.id) { $0.throwInertiaEnabled.toggle() }
    }

    @objc func toggleEdgeSnapAction(sender: AnyObject) {
        guard let session = sessionManager.activeSession else { return }
        sessionManager.updateSettings(for: session.id) { $0.edgeSnapEnabled.toggle() }
    }

    @objc func togglePairedReactionsAction(sender: AnyObject) {
        guard let session = sessionManager.activeSession else { return }
        sessionManager.updateSettings(for: session.id) { $0.proximityReactionsEnabled.toggle() }
    }

    func isMuted() -> Bool {
        sessionManager.activeSession?.settings.isMuted
            ?? UserDefaults.standard.bool(forKey: AgentController.muteDefaultsKey)
    }

    func setMuted(_ value: Bool) {
        guard let session = sessionManager.activeSession else { return }
        sessionManager.updateSettings(for: session.id) { $0.isMuted = value }
    }

    func isSpeechBubblesEnabled() -> Bool {
        sessionManager.activeSession?.settings.speechBubblesEnabled
            ?? UserDefaults.standard.bool(forKey: Self.speechBubblesEnabledDefaultsKey)
    }

    func setSpeechBubblesEnabled(_ value: Bool) {
        guard let session = sessionManager.activeSession else { return }
        sessionManager.updateSettings(for: session.id) { $0.speechBubblesEnabled = value }
    }

    func isAlwaysOnTopEnabled() -> Bool {
        sessionManager.activeSession?.settings.alwaysOnTop
            ?? UserDefaults.standard.bool(forKey: Self.alwaysOnTopDefaultsKey)
    }

    func isJoinAllSpacesEnabled() -> Bool {
        sessionManager.activeSession?.settings.joinAllSpaces
            ?? UserDefaults.standard.bool(forKey: Self.joinAllSpacesDefaultsKey)
    }

    func isThrowInertiaEnabled() -> Bool {
        sessionManager.activeSession?.settings.throwInertiaEnabled
            ?? UserDefaults.standard.bool(forKey: Self.throwInertiaEnabledDefaultsKey)
    }

    func isEdgeSnapEnabled() -> Bool {
        sessionManager.activeSession?.settings.edgeSnapEnabled
            ?? UserDefaults.standard.bool(forKey: Self.edgeSnapEnabledDefaultsKey)
    }

    func arePairedReactionsEnabled() -> Bool {
        sessionManager.activeSession?.settings.proximityReactionsEnabled ?? true
    }

    func saveWindowFrame(_ frame: CGRect) {
        guard let session = sessionManager.activeSession else { return }
        sessionManager.updateWindowFrame(for: session.id, frame: frame)
    }

    func savedWindowFrame() -> CGRect? {
        guard let session = sessionManager.activeSession else { return nil }
        return sessionManager.savedWindowFrame(for: session.id)
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
        guard let item = sender as? NSMenuItem,
              let name = item.representedObject as? String else { return }
        if let session = sessionManager.activeSession {
            sessionManager.selectAgent(name, for: session.id)
            lastUsedAgent = name
        } else {
            _ = sessionManager.createSession(agentName: name)
        }
        refreshDynamicMenus()
    }
}
