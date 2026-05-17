//
//  AgentViewController.swift
//  Clippy
//
//  Created by Devran on 04.09.19.
//  Copyright © 2019 Devran. All rights reserved.
//

import AppKit

class AgentViewController: NSViewController {
    var agentController: AgentController
    var agentView: AgentView
    private var speechPopover: NSPopover?
    private var speechDismissWorkItem: DispatchWorkItem?
    private let quickPhrases = [
        "Need a hand?",
        "You're doing great.",
        "Want to animate me?",
        "Tip: right-click for Animate!",
        "Let's get this done."
    ]
    
    init() {
        agentView = AgentView()
        agentController = AgentController(agentView: agentView)
        AppDelegate.agentController = agentController
        super.init(nibName: nil, bundle: nil)
        agentController.delegate = self
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func loadView() {
        let size = CGSize(width: 100, height: 200)
        view = NSView(frame: CGRect(origin: CGPoint.zero, size: size))
        view.wantsLayer = true
        view.layer?.backgroundColor = .clear
    }
    
    override func viewDidLoad() {
        super.viewDidLoad()
        view.addSubview(agentView)
        setupConstraints()
        setupTrackingArea()
    }
    
    
    override func viewDidAppear() {
        super.viewDidAppear()
        view.window?.makeFirstResponder(self)
        if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
            agentController.isMuted = appDelegate.isMuted()
        }
        
        let lastUsedName = (NSApplication.shared.delegate as? AppDelegate)?.lastUsedAgent
        let name = lastUsedName ?? Agent.randomAgentName()
        if let name = name {
            try? agentController.load(name: name)
            agentController.show()
        }
    }
    
    func setupConstraints() {
        agentView.translatesAutoresizingMaskIntoConstraints = false
        agentView.topAnchor.constraint(equalTo: view.topAnchor).isActive = true
        agentView.leftAnchor.constraint(equalTo: view.leftAnchor).isActive = true
        view.rightAnchor.constraint(equalTo: agentView.rightAnchor).isActive = true
        view.bottomAnchor.constraint(equalTo: agentView.bottomAnchor).isActive = true
    }
    
    func setupTrackingArea() {
        let options: NSTrackingArea.Options = [.mouseEnteredAndExited, .inVisibleRect, .activeAlways]
        let trackingArea = NSTrackingArea(rect: view.frame, options: options, owner: self, userInfo: nil)
        view.addTrackingArea(trackingArea)
    }
}

extension AgentViewController {
    override func mouseEntered(with event: NSEvent) {
        self.view.superview?.window?.alphaValue = 1.0
    }
    
    override func mouseExited(with event: NSEvent) {
        self.view.superview?.window?.alphaValue = 1.0
    }
    
    @objc func animateAction() {
        agentController.animate()
    }
    
    @objc func chooseAssistantAction() {
        guard let name = Agent.randomAgentName() else { return }
        try? agentController.load(name: name)
    }
    
    override var acceptsFirstResponder: Bool {
        return true
    }
    
    override func becomeFirstResponder() -> Bool {
        return true
    }
    
    override func keyDown(with event: NSEvent) {
        guard let agent = agentController.agent else {
            super.keyDown(with: event)
            return
        }
        switch Int(event.keyCode) {
        case 49: // Spacebar
            agentController.animate()
        case 36: // Return
            guard let name = Agent.randomAgentName() else { return }
            try? agentController.load(name: name)
            agentController.show()
        case 124: // Arrow Right Key
            guard let animation = agent.findAnimation("LookLeft") else { break }
            agentController.play(animation: animation)
        case 123: // Arrow Left Key
            guard let animation = agent.findAnimation("LookRight") else { break }
            agentController.play(animation: animation)
        case 126: // Arrow Up Key
            guard let animation = agent.findAnimation("LookUp") else { break }
            agentController.play(animation: animation)
        case 125: // Arrow Down Key
            guard let animation = agent.findAnimation("LookDown") else { break }
            agentController.play(animation: animation)
        default:
            super.keyDown(with: event)
        }
    }
    
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 {
            agentController.animate()
        } else if event.clickCount == 1 {
            speakRandomPhrase()
        }
    }
    
    override func rightMouseDown(with event: NSEvent) {
        guard let _ = agentController.agent else { return }
        
        let menu = NSMenu(title: "Agent")
        let menuItems = [NSMenuItem(title: "Animate!",
                                    action: #selector(animateAction),
                                    keyEquivalent: "")]
        
        for (index, menuItem) in menuItems.enumerated() {
            menu.insertItem(menuItem, at: index)
        }
        NSMenu.popUpContextMenu(menu, with: event, for: agentView)
    }
    
    @objc func hideAction(sender: AnyObject) {
        agentController.hide()
    }
    
    @objc func optionsAction(sender: AnyObject) {
        let viewController = BalloonViewController(text: "Options are currently minimal.")
        print(viewController)
        let popOver = NSPopover()
        popOver.behavior = .semitransient
        popOver.contentSize = CGSize(width: 200, height: 300)
        popOver.animates = true
        popOver.contentViewController = viewController
        let rect = self.view.frame
        popOver.show(relativeTo: rect, of: view, preferredEdge: NSRectEdge.maxY)
    }

    private func speakRandomPhrase() {
        guard let phrase = quickPhrases.randomElement() else { return }
        speak(text: phrase)
    }

    private func speak(text: String) {
        speechDismissWorkItem?.cancel()
        speechPopover?.close()

        let bubbleVC = BalloonViewController(text: text)
        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.contentSize = CGSize(width: 260, height: 80)
        popover.animates = true
        popover.contentViewController = bubbleVC
        popover.show(relativeTo: agentView.bounds, of: agentView, preferredEdge: .maxY)
        speechPopover = popover

        let work = DispatchWorkItem { [weak self] in
            self?.speechPopover?.close()
        }
        speechDismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
    }
}
