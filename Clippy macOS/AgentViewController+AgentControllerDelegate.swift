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
        
        view.superview?.window?.title = agentName
        // Use native asset size (1:1) so rendered character matches source files.
        let newSize = CGSize(width: agent.character.width, height: agent.character.height)
        var rect = CGRect(origin: oldRect.origin, size: newSize)

        // Keep the character reliably visible on-screen.
        if let screen = NSScreen.main ?? window.screen {
            let visible = screen.visibleFrame
            let x = visible.maxX - newSize.width - 24
            let y = visible.minY + 24
            rect.origin = CGPoint(x: max(visible.minX, x), y: max(visible.minY, y))
        }
        
        /// Disable animation, when the window was not moved before.
        /// This happens, when the window was initially created.
        let animated = oldRect.origin.x > 0 && oldRect.origin.y > 0
        window.setFrame(rect, display: true, animate: animated)
    }
    
    func didLoadAgent(agent: Agent) {
        (NSApplication.shared.delegate as? AppDelegate)?.lastUsedAgent = agent.resourceName
    }
    
    func handleHide() {
        if let animation = agentController.agent?.findAnimation("Hide") {
            agentController.play(animation: animation) {
                self.agentController.isHidden = true
                NSApp.hide(self)
            }
        }
    }
    
    func handleShow() {
        NSApp.unhide(self)
        NSApp.activate(ignoringOtherApps: true)
        view.superview?.window?.makeKeyAndOrderFront(self)
        agentController.isHidden = false
        if let animation = agentController.agent?.findAnimation("Show") {
            agentController.play(animation: animation)
        }
    }
}
