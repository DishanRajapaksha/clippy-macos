//
//  AgentViewController+AgentDelegate.swift
//  Clippy macOS
//
//  Created by Devran on 08.09.19.
//  Copyright © 2019 Devran. All rights reserved.
//

import Cocoa

extension AgentViewController: AgentControllerDelegate {
    func willLoadAgent(agent: Agent) {
        guard let window = view.superview?.window else { return }
        let oldRect = window.frame

        var agentName = agent.resourceName
        if let name = agent.character.infos.first(where: { $0.language == "0x0009" })?.name {
            agentName = name
        }
        window.title = agentName

        let newSize = CGSize(width: agent.character.width, height: agent.character.height)
        var rect = CGRect(origin: oldRect.origin, size: newSize)

        if let appDelegate = NSApplication.shared.delegate as? AppDelegate,
           let savedFrame = appDelegate.sessionManager.savedWindowFrame(for: sessionID) {
            rect.origin = savedFrame.origin
            rect = appDelegate.clampedWindowFrame(rect, for: window)
        } else if oldRect.origin.x > 0 || oldRect.origin.y > 0 {
            rect = (NSApplication.shared.delegate as? AppDelegate)?.clampedWindowFrame(rect, for: window) ?? rect
        } else if let screen = window.screen ?? NSScreen.main ?? NSScreen.screens.first {
            let visible = screen.visibleFrame
            let x = visible.maxX - newSize.width - 24
            let y = visible.minY + 24
            rect.origin = CGPoint(x: max(visible.minX, x), y: max(visible.minY, y))
        }

        let animated = oldRect.origin.x > 0 && oldRect.origin.y > 0
        window.setFrame(rect, display: true, animate: animated)
    }

    func didLoadAgent(agent: Agent) {
        guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else { return }
        appDelegate.lastUsedAgent = agent.resourceName
        appDelegate.sessionManager.updateSettings(for: sessionID) {
            $0.agentName = agent.resourceName
        }
        appDelegate.refreshDynamicMenus()
        AgentLayoutMenuInstaller.installWhenReady()
    }

    func handleHide() {
        let finishHide = { [weak self] in
            guard let self else { return }
            self.agentController.isHidden = true
            self.view.window?.orderOut(self)
        }

        if let animation = agentController.agent?.findAnimation("Hide") {
            agentController.play(animation: animation, completion: finishHide)
        } else {
            agentController.cancelPlayback()
            finishHide()
        }
    }

    func handleShow() {
        view.window?.orderFront(nil)
        agentController.isHidden = false
        if let animation = agentController.agent?.findAnimation("Show") {
            agentController.play(animation: animation)
        }
    }
}

private enum AgentLayoutMenuInstaller {
    private static let marker = "ClippyArrangeAgentsMenuItem"

    static func installWhenReady() {
        DispatchQueue.main.async {
            guard let appDelegate = NSApplication.shared.delegate as? AppDelegate,
                  let menu = appDelegate.statusItem?.menu,
                  !menu.items.contains(where: { $0.identifier?.rawValue == marker }) else { return }

            let item = NSMenuItem(title: "Arrange Agents", action: nil, keyEquivalent: "")
            item.identifier = NSUserInterfaceItemIdentifier(marker)
            item.submenu = AgentLayoutController.shared.makeMenu()

            if let managerIndex = menu.items.firstIndex(where: { $0.title == "Agent Manager…" }) {
                menu.insertItem(item, at: managerIndex + 1)
            } else if let windowsIndex = menu.items.firstIndex(where: { $0.title == "Agent Windows" }) {
                menu.insertItem(item, at: windowsIndex + 1)
            } else {
                menu.insertItem(item, at: min(5, menu.numberOfItems))
            }
        }
    }
}

private final class AgentScreenMenuItem: NSMenuItem {
    var screenIndex: Int = 0
}

private final class AgentLayoutController: NSObject, NSMenuDelegate {
    static let shared = AgentLayoutController()

    private static let followCursorDefaultsKey = "FollowCursorSessionIDs"
    private let followInterval: TimeInterval = 1.0 / 60.0
    private let followSmoothing: CGFloat = 0.22
    private var followTimer: Timer?

    private enum Layout {
        case scatter
        case stack
        case line
        case grid
        case circle
    }

    private var sessionManager: AgentSessionManager? {
        (NSApplication.shared.delegate as? AppDelegate)?.sessionManager
    }

    func makeMenu() -> NSMenu {
        let menu = NSMenu(title: "Arrange Agents")
        menu.delegate = self
        rebuild(menu)
        startFollowTimerIfNeeded()
        return menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        rebuild(menu)
    }

    private func rebuild(_ menu: NSMenu) {
        menu.removeAllItems()
        addItem("Move Current to Cursor", action: #selector(moveCurrentToCursor(_:)), to: menu)

        let followItem = menu.addItem(
            withTitle: "Follow Current to Cursor",
            action: #selector(toggleFollowCurrentToCursor(_:)),
            keyEquivalent: ""
        )
        followItem.target = self
        if let activeID = sessionManager?.activeSession?.id.uuidString {
            followItem.state = followedSessionIDs().contains(activeID) ? .on : .off
        } else {
            followItem.isEnabled = false
        }

        let stopFollowingItem = menu.addItem(
            withTitle: "Stop All Cursor Following",
            action: #selector(stopAllCursorFollowing(_:)),
            keyEquivalent: ""
        )
        stopFollowingItem.target = self
        stopFollowingItem.isEnabled = !followedSessionIDs().isEmpty

        let displayItem = NSMenuItem(title: "Move All to Display", action: nil, keyEquivalent: "")
        displayItem.submenu = makeDisplayMenu()
        menu.addItem(displayItem)
        menu.addItem(.separator())

        addItem("Scatter", action: #selector(scatter(_:)), to: menu)
        addItem("Stack", action: #selector(stack(_:)), to: menu)
        addItem("Horizontal Line", action: #selector(line(_:)), to: menu)
        addItem("Grid", action: #selector(grid(_:)), to: menu)
        addItem("Circle", action: #selector(circle(_:)), to: menu)
    }

    private func makeDisplayMenu() -> NSMenu {
        let menu = NSMenu(title: "Move All to Display")
        for (index, screen) in NSScreen.screens.enumerated() {
            let item = AgentScreenMenuItem(
                title: screen.localizedName,
                action: #selector(moveAllToDisplay(_:)),
                keyEquivalent: ""
            )
            item.screenIndex = index
            item.target = self
            menu.addItem(item)
        }
        if NSScreen.screens.isEmpty {
            let item = menu.addItem(withTitle: "No Displays", action: nil, keyEquivalent: "")
            item.isEnabled = false
        }
        return menu
    }

    private func addItem(_ title: String, action: Selector, to menu: NSMenu) {
        let item = menu.addItem(withTitle: title, action: action, keyEquivalent: "")
        item.target = self
    }

    @objc private func moveCurrentToCursor(_ sender: Any?) {
        guard let session = sessionManager?.activeSession,
              let screen = screenContainingCursor() else { return }
        let pointer = NSEvent.mouseLocation
        let origin = CGPoint(
            x: pointer.x - session.window.frame.width / 2,
            y: pointer.y - session.window.frame.height / 2
        )
        move(session, to: origin, on: screen)
    }

    @objc private func toggleFollowCurrentToCursor(_ sender: NSMenuItem) {
        guard let session = sessionManager?.activeSession else { return }
        var identifiers = followedSessionIDs()
        let identifier = session.id.uuidString

        if identifiers.remove(identifier) != nil {
            saveFollowedSessionIDs(identifiers)
            sessionManager?.updateWindowFrame(for: session.id, frame: session.window.frame)
        } else {
            identifiers.insert(identifier)
            saveFollowedSessionIDs(identifiers)
            NSApplication.shared.unhide(nil)
            if session.controller.isHidden {
                session.controller.show()
            }
            session.window.orderFront(nil)
        }

        sender.state = identifiers.contains(identifier) ? .on : .off
        startFollowTimerIfNeeded()
    }

    @objc private func stopAllCursorFollowing(_ sender: Any?) {
        guard let manager = sessionManager else { return }
        let followed = followedSessionIDs()
        for session in manager.sessions where followed.contains(session.id.uuidString) {
            manager.updateWindowFrame(for: session.id, frame: session.window.frame)
        }
        saveFollowedSessionIDs([])
        followTimer?.invalidate()
        followTimer = nil
    }

    @objc private func moveAllToDisplay(_ sender: AgentScreenMenuItem) {
        guard NSScreen.screens.indices.contains(sender.screenIndex) else { return }
        arrange(.grid, on: NSScreen.screens[sender.screenIndex])
    }

    @objc private func scatter(_ sender: Any?) {
        arrange(.scatter, on: preferredScreen())
    }

    @objc private func stack(_ sender: Any?) {
        arrange(.stack, on: preferredScreen())
    }

    @objc private func line(_ sender: Any?) {
        arrange(.line, on: preferredScreen())
    }

    @objc private func grid(_ sender: Any?) {
        arrange(.grid, on: preferredScreen())
    }

    @objc private func circle(_ sender: Any?) {
        arrange(.circle, on: preferredScreen())
    }

    private func preferredScreen() -> NSScreen? {
        screenContainingCursor()
            ?? sessionManager?.activeSession?.window.screen
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }

    private func screenContainingCursor() -> NSScreen? {
        let point = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { $0.frame.contains(point) })
    }

    private func startFollowTimerIfNeeded() {
        guard !followedSessionIDs().isEmpty else {
            followTimer?.invalidate()
            followTimer = nil
            return
        }
        guard followTimer == nil else { return }

        let timer = Timer(timeInterval: followInterval, repeats: true) { [weak self] _ in
            self?.updateCursorFollowers()
        }
        RunLoop.main.add(timer, forMode: .common)
        followTimer = timer
    }

    private func updateCursorFollowers() {
        guard let manager = sessionManager else { return }
        var identifiers = followedSessionIDs()
        var followedSessions = manager.sessions.filter { identifiers.contains($0.id.uuidString) }

        let liveIdentifiers = Set(followedSessions.map { $0.id.uuidString })
        if liveIdentifiers != identifiers {
            identifiers.formIntersection(liveIdentifiers)
            saveFollowedSessionIDs(identifiers)
        }

        guard !followedSessions.isEmpty else {
            followTimer?.invalidate()
            followTimer = nil
            return
        }

        let pointer = NSEvent.mouseLocation
        if NSEvent.pressedMouseButtons != 0 {
            let manuallyGrabbed = followedSessions.filter { $0.window.frame.contains(pointer) }
            if !manuallyGrabbed.isEmpty {
                for session in manuallyGrabbed {
                    identifiers.remove(session.id.uuidString)
                    manager.updateWindowFrame(for: session.id, frame: session.window.frame)
                }
                saveFollowedSessionIDs(identifiers)
                followedSessions.removeAll { session in
                    manuallyGrabbed.contains { $0.id == session.id }
                }
            }
        }

        guard let screen = screenContainingCursor() else { return }
        for (index, session) in followedSessions.enumerated() where session.window.isVisible {
            let diagonalOffset = CGFloat(index) * 22
            let proposed = CGPoint(
                x: pointer.x + 18 + diagonalOffset,
                y: pointer.y - session.window.frame.height - 18 - diagonalOffset
            )
            let target = clampedOrigin(proposed, for: session.window.frame.size, on: screen)
            let current = session.window.frame.origin
            let next = CGPoint(
                x: current.x + (target.x - current.x) * followSmoothing,
                y: current.y + (target.y - current.y) * followSmoothing
            )

            guard hypot(next.x - current.x, next.y - current.y) >= 0.25 else { continue }
            let delegate = session.window.delegate
            session.window.delegate = nil
            session.window.setFrameOrigin(next)
            session.window.delegate = delegate
        }

        if identifiers.isEmpty {
            followTimer?.invalidate()
            followTimer = nil
        }
    }

    private func followedSessionIDs() -> Set<String> {
        Set(UserDefaults.standard.stringArray(forKey: Self.followCursorDefaultsKey) ?? [])
    }

    private func saveFollowedSessionIDs(_ identifiers: Set<String>) {
        UserDefaults.standard.set(identifiers.sorted(), forKey: Self.followCursorDefaultsKey)
    }

    private func clampedOrigin(_ proposed: CGPoint, for size: CGSize, on screen: NSScreen) -> CGPoint {
        let visible = screen.visibleFrame
        let maxX = max(visible.minX, visible.maxX - size.width)
        let maxY = max(visible.minY, visible.maxY - size.height)
        return CGPoint(
            x: max(visible.minX, min(proposed.x, maxX)),
            y: max(visible.minY, min(proposed.y, maxY))
        )
    }

    private func arrange(_ layout: Layout, on screen: NSScreen?) {
        guard let screen,
              let sessions = sessionManager?.sessions,
              !sessions.isEmpty else { return }

        disableFollowing(for: sessions)
        NSApplication.shared.unhide(nil)
        let visible = screen.visibleFrame.insetBy(dx: 24, dy: 24)

        switch layout {
        case .scatter:
            for session in sessions {
                let maxX = max(visible.minX, visible.maxX - session.window.frame.width)
                let maxY = max(visible.minY, visible.maxY - session.window.frame.height)
                let x = CGFloat.random(in: visible.minX...maxX)
                let y = CGFloat.random(in: visible.minY...maxY)
                move(session, to: CGPoint(x: x, y: y), on: screen)
            }

        case .stack:
            let base = CGPoint(x: visible.midX, y: visible.midY)
            for (index, session) in sessions.enumerated() {
                let offset = CGFloat(index) * 24
                let origin = CGPoint(
                    x: base.x - session.window.frame.width / 2 + offset,
                    y: base.y - session.window.frame.height / 2 - offset
                )
                move(session, to: origin, on: screen)
            }

        case .line:
            let spacing = visible.width / CGFloat(max(sessions.count, 1))
            for (index, session) in sessions.enumerated() {
                let centerX = visible.minX + spacing * (CGFloat(index) + 0.5)
                let origin = CGPoint(
                    x: centerX - session.window.frame.width / 2,
                    y: visible.midY - session.window.frame.height / 2
                )
                move(session, to: origin, on: screen)
            }

        case .grid:
            let columns = max(1, Int(ceil(sqrt(Double(sessions.count)))))
            let rows = max(1, Int(ceil(Double(sessions.count) / Double(columns))))
            let cellWidth = visible.width / CGFloat(columns)
            let cellHeight = visible.height / CGFloat(rows)
            for (index, session) in sessions.enumerated() {
                let column = index % columns
                let row = index / columns
                let centerX = visible.minX + cellWidth * (CGFloat(column) + 0.5)
                let centerY = visible.maxY - cellHeight * (CGFloat(row) + 0.5)
                let origin = CGPoint(
                    x: centerX - session.window.frame.width / 2,
                    y: centerY - session.window.frame.height / 2
                )
                move(session, to: origin, on: screen)
            }

        case .circle:
            let radius = max(40, min(visible.width, visible.height) * 0.34)
            for (index, session) in sessions.enumerated() {
                let angle = (2 * CGFloat.pi * CGFloat(index) / CGFloat(sessions.count)) + (.pi / 2)
                let center = CGPoint(
                    x: visible.midX + cos(angle) * radius,
                    y: visible.midY + sin(angle) * radius
                )
                let origin = CGPoint(
                    x: center.x - session.window.frame.width / 2,
                    y: center.y - session.window.frame.height / 2
                )
                move(session, to: origin, on: screen)
            }
        }

        sessionManager?.persistSessions()
    }

    private func disableFollowing(for sessions: [AgentSession]) {
        var identifiers = followedSessionIDs()
        for session in sessions {
            identifiers.remove(session.id.uuidString)
        }
        saveFollowedSessionIDs(identifiers)
        startFollowTimerIfNeeded()
    }

    private func move(_ session: AgentSession, to proposedOrigin: CGPoint, on screen: NSScreen) {
        let visible = screen.visibleFrame
        var frame = session.window.frame
        frame.origin.x = max(visible.minX, min(proposedOrigin.x, visible.maxX - frame.width))
        frame.origin.y = max(visible.minY, min(proposedOrigin.y, visible.maxY - frame.height))

        if session.controller.isHidden {
            session.controller.show()
        }
        session.window.setFrame(frame, display: true, animate: true)
        sessionManager?.updateWindowFrame(for: session.id, frame: frame)
    }
}
