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
