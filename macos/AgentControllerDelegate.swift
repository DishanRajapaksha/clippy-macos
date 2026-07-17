//
//  AgentControllerDelegate.swift
//  Clippy macOS
//
//  Created by Devran on 08.09.19.
//  Copyright © 2019 Devran. All rights reserved.
//

import Cocoa

protocol AgentControllerDelegate {
    func willLoadAgent(agent: Agent)
    func didLoadAgent(agent: Agent)
    
    func handleHide()
    func handleShow()
}

protocol AgentWindowSessionDelegate: AnyObject {
    func agentWindowDidBecomeKey(_ window: AgentWindow)
    func agentWindowDidMove(_ window: AgentWindow)
}

private final class AgentWindowSessionEntry {
    weak var window: AgentWindow?
    weak var delegate: AgentWindowSessionDelegate?
    var sessionID: UUID?
    var observers: [NSObjectProtocol] = []

    init(window: AgentWindow) {
        self.window = window
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }
}

private final class AgentWindowSessionRegistry {
    static let shared = AgentWindowSessionRegistry()

    private var entries: [ObjectIdentifier: AgentWindowSessionEntry] = [:]

    func sessionID(for window: AgentWindow) -> UUID? {
        prune()
        return entries[ObjectIdentifier(window)]?.sessionID
    }

    func setSessionID(_ sessionID: UUID?, for window: AgentWindow) {
        entry(for: window).sessionID = sessionID
    }

    func delegate(for window: AgentWindow) -> AgentWindowSessionDelegate? {
        prune()
        return entries[ObjectIdentifier(window)]?.delegate
    }

    func setDelegate(_ delegate: AgentWindowSessionDelegate?, for window: AgentWindow) {
        let entry = entry(for: window)
        entry.delegate = delegate
        guard entry.observers.isEmpty else { return }

        let center = NotificationCenter.default
        entry.observers.append(center.addObserver(
            forName: NSWindow.didBecomeKeyNotification,
            object: window,
            queue: .main
        ) { [weak entry] _ in
            guard let entry, let window = entry.window else { return }
            entry.delegate?.agentWindowDidBecomeKey(window)
        })
        entry.observers.append(center.addObserver(
            forName: NSWindow.didMoveNotification,
            object: window,
            queue: .main
        ) { [weak entry] _ in
            guard let entry, let window = entry.window else { return }
            entry.delegate?.agentWindowDidMove(window)
        })
        AgentManagerMenuInstaller.installWhenReady()
    }

    private func entry(for window: AgentWindow) -> AgentWindowSessionEntry {
        prune()
        let key = ObjectIdentifier(window)
        if let entry = entries[key] {
            return entry
        }
        let entry = AgentWindowSessionEntry(window: window)
        entries[key] = entry
        return entry
    }

    private func prune() {
        entries = entries.filter { $0.value.window != nil }
    }
}

extension AgentWindow {
    var sessionID: UUID? {
        get { AgentWindowSessionRegistry.shared.sessionID(for: self) }
        set { AgentWindowSessionRegistry.shared.setSessionID(newValue, for: self) }
    }

    var sessionDelegate: AgentWindowSessionDelegate? {
        get { AgentWindowSessionRegistry.shared.delegate(for: self) }
        set { AgentWindowSessionRegistry.shared.setDelegate(newValue, for: self) }
    }
}

private enum AgentManagerMenuInstaller {
    private static let marker = "ClippyAgentManagerMenuItem"
    private static var installed = false

    static func installWhenReady() {
        DispatchQueue.main.async {
            installIfNeeded()
        }
    }

    private static func installIfNeeded() {
        guard !installed,
              let appDelegate = NSApplication.shared.delegate as? AppDelegate,
              let menu = appDelegate.statusItem?.menu else { return }

        if menu.items.contains(where: { $0.identifier?.rawValue == marker }) {
            installed = true
            return
        }

        let item = NSMenuItem(
            title: "Agent Manager…",
            action: #selector(AgentManagerWindowController.showManager(_:)),
            keyEquivalent: ""
        )
        item.identifier = NSUserInterfaceItemIdentifier(marker)
        item.target = AgentManagerWindowController.shared

        if let windowsIndex = menu.items.firstIndex(where: { $0.title == "Agent Windows" }) {
            menu.insertItem(item, at: windowsIndex + 1)
        } else {
            menu.insertItem(item, at: min(4, menu.numberOfItems))
        }
        installed = true
    }
}

private final class AgentSessionButton: NSButton {
    var sessionID: UUID?
}

private final class AgentSessionPopUpButton: NSPopUpButton {
    var sessionID: UUID?
}

final class AgentManagerWindowController:
    NSWindowController,
    NSTableViewDataSource,
    NSTableViewDelegate,
    NSWindowDelegate
{
    static let shared = AgentManagerWindowController()

    private enum Column: String, CaseIterable {
        case active
        case character
        case visible
        case muted
        case autoAnimate
        case reactions
        case position
        case actions

        var title: String {
            switch self {
            case .active: return "Active"
            case .character: return "Character"
            case .visible: return "Visible"
            case .muted: return "Muted"
            case .autoAnimate: return "Auto Animate"
            case .reactions: return "Paired Reactions"
            case .position: return "Position"
            case .actions: return "Actions"
            }
        }

        var width: CGFloat {
            switch self {
            case .active: return 55
            case .character: return 150
            case .visible: return 70
            case .muted: return 65
            case .autoAnimate: return 120
            case .reactions: return 105
            case .position: return 150
            case .actions: return 150
            }
        }
    }

    private let tableView = NSTableView()
    private let countLabel = NSTextField(labelWithString: "")
    private var observers: [NSObjectProtocol] = []
    private var isRefreshing = false

    private var appDelegate: AppDelegate? {
        NSApplication.shared.delegate as? AppDelegate
    }

    private var sessionManager: AgentSessionManager? {
        appDelegate?.sessionManager
    }

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 900, height: 430),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Agent Manager"
        window.minSize = NSSize(width: 760, height: 300)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("ClippyAgentManagerWindow")

        super.init(window: window)
        window.delegate = self
        configureContent()
        observeSessionChanges()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        observers.forEach(NotificationCenter.default.removeObserver)
    }

    @objc func showManager(_ sender: Any?) {
        refresh()
        showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        sessionManager?.sessions.count ?? 0
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard let columnID = tableColumn?.identifier.rawValue,
              let column = Column(rawValue: columnID),
              let session = sessionManager?.sessions[safe: row] else { return nil }

        switch column {
        case .active:
            let button = sessionButton(
                type: .radio,
                sessionID: session.id,
                action: #selector(activateSession(_:))
            )
            button.state = sessionManager?.activeSession?.id == session.id ? .on : .off
            button.toolTip = "Make this the active agent"
            return centred(button)

        case .character:
            let popup = AgentSessionPopUpButton(frame: .zero, pullsDown: false)
            popup.sessionID = session.id
            popup.target = self
            popup.action = #selector(changeCharacter(_:))
            popup.controlSize = .small
            let names = Agent.agentNames()
            for name in names {
                let item = NSMenuItem(title: name.capitalized, action: nil, keyEquivalent: "")
                item.representedObject = name
                popup.menu?.addItem(item)
            }
            if let configuredName = session.settings.agentName,
               let index = names.firstIndex(where: {
                   $0.caseInsensitiveCompare(configuredName) == .orderedSame
               }) {
                popup.selectItem(at: index)
            }
            popup.toolTip = "Change this session's character"
            return padded(popup)

        case .visible:
            let button = sessionButton(
                type: .switch,
                sessionID: session.id,
                action: #selector(toggleVisibility(_:))
            )
            button.state = session.window.isVisible && !session.controller.isHidden ? .on : .off
            button.toolTip = button.state == .on ? "Hide this agent" : "Show this agent"
            return centred(button)

        case .muted:
            let button = sessionButton(
                type: .switch,
                sessionID: session.id,
                action: #selector(toggleMute(_:))
            )
            button.state = session.settings.isMuted ? .on : .off
            button.toolTip = "Mute this agent's sounds"
            return centred(button)

        case .autoAnimate:
            let popup = AgentSessionPopUpButton(frame: .zero, pullsDown: false)
            popup.sessionID = session.id
            popup.target = self
            popup.action = #selector(changeAutoAnimate(_:))
            popup.controlSize = .small
            addAutoAnimateItem("Off", value: 0, to: popup)
            addAutoAnimateItem("Every 5s", value: 5, to: popup)
            addAutoAnimateItem("Every 10s", value: 10, to: popup)
            addAutoAnimateItem("Every 15s", value: 15, to: popup)
            addAutoAnimateItem("Every 30s", value: 30, to: popup)
            addAutoAnimateItem("Every 60s", value: 60, to: popup)
            addAutoAnimateItem(
                "Random",
                value: AgentController.randomAutoAnimateInterval,
                to: popup
            )
            selectAutoAnimateValue(session.settings.autoAnimateInterval, in: popup)
            popup.toolTip = "Set this agent's idle animation interval"
            return padded(popup)

        case .reactions:
            let button = sessionButton(
                type: .switch,
                sessionID: session.id,
                action: #selector(toggleReactions(_:))
            )
            button.state = session.settings.proximityReactionsEnabled ? .on : .off
            button.toolTip = "Allow paired reactions with nearby agents"
            return centred(button)

        case .position:
            let frame = session.window.frame
            let screenName = session.window.screen?.localizedName ?? "No display"
            let label = NSTextField(
                labelWithString: "\(Int(frame.origin.x)), \(Int(frame.origin.y)) · \(screenName)"
            )
            label.lineBreakMode = .byTruncatingTail
            label.toolTip = "Window origin on \(screenName)"
            return padded(label)

        case .actions:
            let focusButton = AgentSessionButton(
                title: "Focus",
                target: self,
                action: #selector(focusSession(_:))
            )
            focusButton.sessionID = session.id
            focusButton.controlSize = .small

            let closeButton = AgentSessionButton(
                title: "Close",
                target: self,
                action: #selector(closeSession(_:))
            )
            closeButton.sessionID = session.id
            closeButton.controlSize = .small

            let stack = NSStackView(views: [focusButton, closeButton])
            stack.orientation = .horizontal
            stack.alignment = .centerY
            stack.distribution = .fillEqually
            stack.spacing = 6
            return padded(stack)
        }
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard !isRefreshing,
              tableView.selectedRow >= 0,
              let session = sessionManager?.sessions[safe: tableView.selectedRow] else { return }
        sessionManager?.activate(sessionID: session.id, bringForward: false)
        refresh()
    }

    private func configureContent() {
        guard let window else { return }
        let root = NSView()
        window.contentView = root

        countLabel.font = .systemFont(ofSize: 12, weight: .medium)
        countLabel.textColor = .secondaryLabelColor

        let newButton = NSButton(
            title: "New Random Agent",
            target: self,
            action: #selector(newRandomAgent(_:))
        )
        let showAllButton = NSButton(
            title: "Show All",
            target: self,
            action: #selector(showAll(_:))
        )
        let hideAllButton = NSButton(
            title: "Hide All",
            target: self,
            action: #selector(hideAll(_:))
        )
        let resourceButton = NSButton(
            title: "Resource Monitor",
            target: AgentResourceMonitorWindowController.shared,
            action: #selector(AgentResourceMonitorWindowController.showMonitor(_:))
        )

        let spacer = NSView()
        spacer.setContentHuggingPriority(.defaultLow, for: .horizontal)
        let toolbar = NSStackView(
            views: [countLabel, spacer, resourceButton, newButton, showAllButton, hideAllButton]
        )
        toolbar.translatesAutoresizingMaskIntoConstraints = false
        toolbar.orientation = .horizontal
        toolbar.alignment = .centerY
        toolbar.spacing = 8
        root.addSubview(toolbar)

        for column in Column.allCases {
            let tableColumn = NSTableColumn(
                identifier: NSUserInterfaceItemIdentifier(column.rawValue)
            )
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = max(45, column.width * 0.7)
            tableView.addTableColumn(tableColumn)
        }
        tableView.delegate = self
        tableView.dataSource = self
        tableView.rowHeight = 32
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false
        tableView.target = self
        tableView.doubleAction = #selector(focusSelectedRow(_:))

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = tableView
        root.addSubview(scrollView)

        let footer = NSTextField(
            labelWithString: "Each row controls one independent agent session. Double-click a row to focus it."
        )
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.textColor = .secondaryLabelColor
        footer.font = .systemFont(ofSize: 11)
        root.addSubview(footer)

        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            toolbar.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            toolbar.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scrollView.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),
            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10)
        ])
    }

    private func observeSessionChanges() {
        let center = NotificationCenter.default
        observers.append(center.addObserver(
            forName: UserDefaults.didChangeNotification,
            object: UserDefaults.standard,
            queue: .main
        ) { [weak self] _ in
            self?.refresh()
        })

        for name in [
            NSWindow.didMoveNotification,
            NSWindow.didBecomeKeyNotification,
            NSWindow.didChangeOcclusionStateNotification,
            NSWindow.didMiniaturizeNotification,
            NSWindow.didDeminiaturizeNotification
        ] {
            observers.append(center.addObserver(
                forName: name,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                guard notification.object is AgentWindow else { return }
                self?.refresh()
            })
        }
    }

    private func refresh() {
        guard isWindowLoaded, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let selectedID = tableView.selectedRow >= 0
            ? sessionManager?.sessions[safe: tableView.selectedRow]?.id
            : nil
        tableView.reloadData()

        let count = sessionManager?.sessions.count ?? 0
        countLabel.stringValue = count == 1 ? "1 agent session" : "\(count) agent sessions"

        let preferredID = selectedID ?? sessionManager?.activeSession?.id
        if let preferredID,
           let row = sessionManager?.sessions.firstIndex(where: { $0.id == preferredID }) {
            tableView.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false)
        } else {
            tableView.deselectAll(nil)
        }
    }

    private func sessionButton(
        type: NSButton.ButtonType,
        sessionID: UUID,
        action: Selector
    ) -> AgentSessionButton {
        let button = AgentSessionButton(frame: .zero)
        button.sessionID = sessionID
        button.target = self
        button.action = action
        button.setButtonType(type)
        button.title = ""
        button.imagePosition = .imageOnly
        button.controlSize = .small
        return button
    }

    private func centred(_ view: NSView) -> NSView {
        let container = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.centerXAnchor.constraint(equalTo: container.centerXAnchor),
            view.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        return container
    }

    private func padded(_ view: NSView) -> NSView {
        let container = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            view.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        return container
    }

    private func addAutoAnimateItem(
        _ title: String,
        value: TimeInterval,
        to popup: NSPopUpButton
    ) {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.representedObject = NSNumber(value: value)
        popup.menu?.addItem(item)
    }

    private func selectAutoAnimateValue(_ value: TimeInterval, in popup: NSPopUpButton) {
        for (index, item) in popup.itemArray.enumerated() {
            guard let number = item.representedObject as? NSNumber else { continue }
            if abs(number.doubleValue - value) < 0.001 {
                popup.selectItem(at: index)
                return
            }
        }
        popup.selectItem(at: 0)
    }

    @objc private func newRandomAgent(_ sender: Any?) {
        _ = sessionManager?.createSession(agentName: Agent.randomAgentName())
        refresh()
    }

    @objc private func showAll(_ sender: Any?) {
        sessionManager?.showAll()
        refresh()
    }

    @objc private func hideAll(_ sender: Any?) {
        sessionManager?.hideAll()
        refresh()
    }

    @objc private func activateSession(_ sender: AgentSessionButton) {
        guard let id = sender.sessionID else { return }
        sessionManager?.activate(sessionID: id, bringForward: false)
        refresh()
    }

    @objc private func focusSession(_ sender: AgentSessionButton) {
        guard let id = sender.sessionID else { return }
        sessionManager?.activate(sessionID: id)
        refresh()
    }

    @objc private func focusSelectedRow(_ sender: Any?) {
        guard tableView.clickedRow >= 0,
              let session = sessionManager?.sessions[safe: tableView.clickedRow] else { return }
        sessionManager?.activate(sessionID: session.id)
        refresh()
    }

    @objc private func closeSession(_ sender: AgentSessionButton) {
        guard let id = sender.sessionID else { return }
        sessionManager?.close(sessionID: id)
        refresh()
    }

    @objc private func toggleVisibility(_ sender: AgentSessionButton) {
        guard let id = sender.sessionID,
              let session = sessionManager?.session(for: id) else { return }
        if sender.state == .on {
            NSApplication.shared.unhide(nil)
            session.controller.show()
            session.window.orderFront(nil)
        } else {
            session.controller.hide()
        }
        refresh()
    }

    @objc private func toggleMute(_ sender: AgentSessionButton) {
        guard let id = sender.sessionID else { return }
        sessionManager?.updateSettings(for: id) {
            $0.isMuted = sender.state == .on
        }
        refresh()
    }

    @objc private func toggleReactions(_ sender: AgentSessionButton) {
        guard let id = sender.sessionID else { return }
        sessionManager?.updateSettings(for: id) {
            $0.proximityReactionsEnabled = sender.state == .on
        }
        refresh()
    }

    @objc private func changeCharacter(_ sender: AgentSessionPopUpButton) {
        guard let id = sender.sessionID,
              let name = sender.selectedItem?.representedObject as? String else { return }
        sessionManager?.selectAgent(name, for: id)
        appDelegate?.lastUsedAgent = name
        refresh()
    }

    @objc private func changeAutoAnimate(_ sender: AgentSessionPopUpButton) {
        guard let id = sender.sessionID,
              let number = sender.selectedItem?.representedObject as? NSNumber else { return }
        sessionManager?.updateSettings(for: id) {
            $0.autoAnimateInterval = number.doubleValue
        }
        refresh()
    }
}

extension AppDelegate {
    // Compatibility for preview-management and automation code that predates
    // multi-session windows. New code should route through sessionManager.
    static var agentController: AgentController? {
        (NSApplication.shared.delegate as? AppDelegate)?.agentController
    }
}
