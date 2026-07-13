//
//  AgentWindow.swift
//  Clippy macOS
//
//  Created by Devran on 07.09.19.
//  Copyright © 2019 Devran. All rights reserved.
//

import Cocoa

func max<T: Comparable>(_ first: T, _ second: T, _ third: T) -> T {
    Swift.max(Swift.max(first, second), third)
}

protocol AgentWindowSessionDelegate: AnyObject {
    func agentWindowDidBecomeKey(_ window: AgentWindow)
    func agentWindowDidMove(_ window: AgentWindow)
}

class AgentWindow: NSWindow {
    weak var sessionDelegate: AgentWindowSessionDelegate?
    var sessionID: UUID?

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
        hasShadow = false
        isOpaque = false
        delegate = self
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
        sessionDelegate?.agentWindowDidBecomeKey(self)
    }

    func windowDidMove(_ notification: Notification) {
        sessionDelegate?.agentWindowDidMove(self)
    }
}

extension AppDelegate {
    // Compatibility for preview-management code that predates multi-session
    // windows. New code should route through sessionManager explicitly.
    static var agentController: AgentController? {
        (NSApplication.shared.delegate as? AppDelegate)?.agentController
    }
}
