//
//  AgentWindow.swift
//  Clippy macOS
//
//  Created by Devran on 07.09.19.
//  Copyright © 2019 Devran. All rights reserved.
//

import Cocoa

class AgentWindow: NSWindow {
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
