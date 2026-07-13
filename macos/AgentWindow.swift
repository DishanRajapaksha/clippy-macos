//
//  AgentWindow.swift
//  Clippy macOS
//
//  Created by Devran on 07.09.19.
//  Copyright © 2019 Devran. All rights reserved.
//

import Cocoa

class AgentWindow: NSWindow {
    private var applicationVisibilityController: ApplicationVisibilityController?

    override var collectionBehavior: NSWindow.CollectionBehavior {
        get { super.collectionBehavior }
        set {
            // fullScreenAuxiliary opts Clippy into appearing over another app's
            // full-screen Space. Strip it regardless of which caller updates
            // the remaining Space behaviour.
            super.collectionBehavior = newValue.subtracting(.fullScreenAuxiliary)
        }
    }

    override init(contentRect: NSRect, styleMask style: NSWindow.StyleMask, backing backingStoreType: NSWindow.BackingStoreType, defer flag: Bool) {
        super.init(contentRect: contentRect, styleMask: style, backing: backingStoreType, defer: flag)
        level = NSWindow.Level.floating
        collectionBehavior = [.canJoinAllSpaces, .stationary]
        canHide = true
        backingType = .buffered
        isMovable = true
        isMovableByWindowBackground = true
        backgroundColor = .clear
        
        /// Fixes glitches
        hasShadow = false
        isOpaque = false
        delegate = self

        let visibilityController = ApplicationVisibilityController(window: self)
        applicationVisibilityController = visibilityController
        DispatchQueue.main.async {
            visibilityController.start()
        }
    }
    
    override var canBecomeKey: Bool {
        return true
    }
}

extension AgentWindow: NSWindowDelegate {
    func windowDidResignKey(_ notification: Notification) {
        alphaValue = 1.0
    }

    func windowDidBecomeKey(_ notification: Notification) {
        alphaValue = 1.0
    }
}

private final class ApplicationVisibilityController: NSObject, NSMenuDelegate {
    private static let defaultsKey = "HiddenApplicationRules"
    private static let menuMarker = "ClippyApplicationVisibilityMenu"

    private weak var window: NSWindow?
    private var workspaceObserver: NSObjectProtocol?
    private var appHiddenObserver: NSObjectProtocol?
    private var lastExternalApplication: NSRunningApplication?
    private var isHiddenByRule = false
    private var shouldRestoreAfterRule = false
    private var foregroundApplicationTimer: Timer?
    private let visibilityMenu = NSMenu(title: "App Visibility")

    init(window: NSWindow) {
        self.window = window
        super.init()
        visibilityMenu.delegate = self
    }

    deinit {
        foregroundApplicationTimer?.invalidate()
        if let workspaceObserver {
            NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver)
        }
        if let appHiddenObserver {
            NotificationCenter.default.removeObserver(appHiddenObserver)
        }
    }

    func start() {
        installMenuIfNeeded()

        let workspaceCenter = NSWorkspace.shared.notificationCenter
        workspaceObserver = workspaceCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let application = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
                return
            }
            self?.applicationDidActivate(application)
        }

        let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
            self?.applyRuleForFrontmostApplication()
        }
        RunLoop.main.add(timer, forMode: .common)
        foregroundApplicationTimer = timer

        appHiddenObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didHideNotification,
            object: NSApp,
            queue: .main
        ) { [weak self] _ in
            guard let self, self.isHiddenByRule else { return }
            self.shouldRestoreAfterRule = false
        }

        if let application = NSWorkspace.shared.frontmostApplication {
            applicationDidActivate(application)
        }
    }

    func menuWillOpen(_ menu: NSMenu) {
        if menu === visibilityMenu {
            rebuildVisibilityMenu()
        } else {
            installMenuIfNeeded()
        }
    }

    private func installMenuIfNeeded() {
        guard let appDelegate = NSApplication.shared.delegate as? AppDelegate,
              let rootMenu = appDelegate.statusItem?.menu else {
            return
        }

        rootMenu.delegate = self

        guard let behaviorMenu = rootMenu.items
            .first(where: { $0.title == "Behavior" })?
            .submenu else {
            return
        }

        if behaviorMenu.items.contains(where: {
            ($0.representedObject as? String) == Self.menuMarker
        }) {
            return
        }

        behaviorMenu.addItem(NSMenuItem.separator())
        let item = NSMenuItem(title: "App Visibility", action: nil, keyEquivalent: "")
        item.representedObject = Self.menuMarker
        item.submenu = visibilityMenu
        behaviorMenu.addItem(item)
    }

    private func rebuildVisibilityMenu() {
        visibilityMenu.removeAllItems()

        if let application = foregroundExternalApplication(),
           let bundleIdentifier = application.bundleIdentifier {
            let name = application.localizedName ?? bundleIdentifier
            let item = NSMenuItem(
                title: "Hide in \(name)",
                action: #selector(toggleForegroundApplicationRule(_:)),
                keyEquivalent: ""
            )
            item.target = self
            item.representedObject = bundleIdentifier
            item.state = hiddenApplicationRules()[bundleIdentifier] == nil ? .off : .on
            visibilityMenu.addItem(item)
        } else {
            let unavailableItem = NSMenuItem(
                title: "No foreground application detected",
                action: nil,
                keyEquivalent: ""
            )
            unavailableItem.isEnabled = false
            visibilityMenu.addItem(unavailableItem)
        }

        visibilityMenu.addItem(NSMenuItem.separator())

        let rules = hiddenApplicationRules()
        if rules.isEmpty {
            let emptyItem = NSMenuItem(
                title: "No hidden applications",
                action: nil,
                keyEquivalent: ""
            )
            emptyItem.isEnabled = false
            visibilityMenu.addItem(emptyItem)
        } else {
            for (bundleIdentifier, name) in rules.sorted(by: {
                $0.value.localizedCaseInsensitiveCompare($1.value) == .orderedAscending
            }) {
                let item = NSMenuItem(
                    title: name,
                    action: #selector(removeApplicationRule(_:)),
                    keyEquivalent: ""
                )
                item.target = self
                item.representedObject = bundleIdentifier
                item.state = .on
                item.toolTip = bundleIdentifier
                visibilityMenu.addItem(item)
            }

            visibilityMenu.addItem(NSMenuItem.separator())
            let clearItem = NSMenuItem(
                title: "Clear All",
                action: #selector(clearApplicationRules(_:)),
                keyEquivalent: ""
            )
            clearItem.target = self
            visibilityMenu.addItem(clearItem)
        }
    }

    @objc private func toggleForegroundApplicationRule(_ sender: NSMenuItem) {
        guard let bundleIdentifier = sender.representedObject as? String,
              let application = foregroundExternalApplication() else {
            return
        }

        var rules = hiddenApplicationRules()
        if rules.removeValue(forKey: bundleIdentifier) == nil {
            rules[bundleIdentifier] = application.localizedName ?? bundleIdentifier
        }
        saveHiddenApplicationRules(rules)
        applyRule(for: application)
        rebuildVisibilityMenu()
    }

    @objc private func removeApplicationRule(_ sender: NSMenuItem) {
        guard let bundleIdentifier = sender.representedObject as? String else { return }
        var rules = hiddenApplicationRules()
        rules.removeValue(forKey: bundleIdentifier)
        saveHiddenApplicationRules(rules)
        applyRuleForFrontmostApplication()
        rebuildVisibilityMenu()
    }

    @objc private func clearApplicationRules(_ sender: NSMenuItem) {
        saveHiddenApplicationRules([:])
        applyRuleForFrontmostApplication()
        rebuildVisibilityMenu()
    }

    private func applicationDidActivate(_ application: NSRunningApplication) {
        guard application.processIdentifier != ProcessInfo.processInfo.processIdentifier else {
            return
        }

        lastExternalApplication = application
        applyRule(for: application)
    }

    private func applyRuleForFrontmostApplication() {
        if let application = foregroundExternalApplication() {
            applyRule(for: application)
        } else {
            restoreAfterRuleIfNeeded()
        }
    }

    private func applyRule(for application: NSRunningApplication) {
        guard let bundleIdentifier = application.bundleIdentifier else {
            restoreAfterRuleIfNeeded()
            return
        }

        if hiddenApplicationRules()[bundleIdentifier] != nil {
            hideForRule()
        } else {
            restoreAfterRuleIfNeeded()
        }
    }

    private func hideForRule() {
        guard let window else { return }

        if !isHiddenByRule {
            shouldRestoreAfterRule = window.alphaValue > 0
        }

        window.alphaValue = 0
        window.ignoresMouseEvents = true
        isHiddenByRule = true
    }

    private func restoreAfterRuleIfNeeded() {
        guard isHiddenByRule else { return }
        defer {
            isHiddenByRule = false
            shouldRestoreAfterRule = false
        }

        guard shouldRestoreAfterRule else { return }
        window?.ignoresMouseEvents = false
        window?.alphaValue = 1
    }

    private func foregroundExternalApplication() -> NSRunningApplication? {
        if let application = NSWorkspace.shared.frontmostApplication,
           application.processIdentifier != ProcessInfo.processInfo.processIdentifier {
            lastExternalApplication = application
            return application
        }
        return lastExternalApplication
    }

    private func hiddenApplicationRules() -> [String: String] {
        UserDefaults.standard.dictionary(forKey: Self.defaultsKey) as? [String: String] ?? [:]
    }

    private func saveHiddenApplicationRules(_ rules: [String: String]) {
        UserDefaults.standard.set(rules, forKey: Self.defaultsKey)
    }
}
