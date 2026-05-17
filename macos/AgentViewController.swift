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
    private var lastDragScreenPoint: CGPoint?
    private var lastDragTimestamp: TimeInterval = 0
    private var dragVelocity: CGPoint = .zero
    private var inertiaTimer: Timer?
    private let quickPhrases = [
        "Need a hand?",
        "I found a few things you might like.",
        "That looks important.",
        "I can play an animation for this.",
        "Right-click me for more options.",
        "Need a quick break?",
        "You're doing great.",
        "Want to animate me?",
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

    @objc func idleAnimationAction() {
        agentController.animateIdle()
    }
    
    @objc func chooseAssistantAction() {
        guard let name = Agent.randomAgentName() else { return }
        try? agentController.load(name: name)
        agentController.show()
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
        stopInertia()
        if event.clickCount == 2 {
            agentController.animate()
        } else if event.clickCount == 1 {
            if (NSApplication.shared.delegate as? AppDelegate)?.isSpeechBubblesEnabled() ?? true {
                speakRandomPhrase()
            }
        }
        lastDragScreenPoint = NSEvent.mouseLocation
        lastDragTimestamp = event.timestamp
        dragVelocity = .zero
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window = view.window, let previous = lastDragScreenPoint else { return }
        let current = NSEvent.mouseLocation
        let dx = current.x - previous.x
        let dy = current.y - previous.y
        guard dx != 0 || dy != 0 else { return }

        var frame = window.frame
        frame.origin.x += dx
        frame.origin.y += dy
        frame = clampedFrame(frame, in: window)
        window.setFrame(frame, display: true)

        let dt = max(event.timestamp - lastDragTimestamp, 0.0001)
        dragVelocity = CGPoint(x: dx / dt, y: dy / dt)
        lastDragScreenPoint = current
        lastDragTimestamp = event.timestamp
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            lastDragScreenPoint = nil
            lastDragTimestamp = 0
        }
        applyEdgeSnap()
        applyThrowInertiaIfNeeded()
        saveCurrentWindowFrame()
    }
    
    override func rightMouseDown(with event: NSEvent) {
        guard let agent = agentController.agent else { return }
        
        let menu = NSMenu(title: "Agent")
        menu.addItem(withTitle: "Animate!", action: #selector(animateAction), keyEquivalent: "")
        menu.addItem(withTitle: "Idle Animation", action: #selector(idleAnimationAction), keyEquivalent: "")
        menu.addItem(withTitle: "Say Something", action: #selector(saySomethingAction), keyEquivalent: "")
        menu.addItem(NSMenuItem.separator())

        let animationMenu = NSMenu(title: "Animations")
        for animation in commonAnimations(from: agent) {
            let item = NSMenuItem(title: animation.name, action: #selector(playAnimationMenuAction(sender:)), keyEquivalent: "")
            item.representedObject = animation.name
            animationMenu.addItem(item)
        }
        let animationsItem = NSMenuItem(title: "Animations", action: nil, keyEquivalent: "")
        animationsItem.submenu = animationMenu
        animationsItem.isEnabled = !animationMenu.items.isEmpty
        menu.addItem(animationsItem)

        menu.addItem(withTitle: "Change Agent", action: #selector(chooseAssistantAction), keyEquivalent: "")
        menu.addItem(withTitle: "Hide", action: #selector(hideAction(sender:)), keyEquivalent: "")
        NSMenu.popUpContextMenu(menu, with: event, for: agentView)
    }
    
    @objc func hideAction(sender: AnyObject) {
        agentController.hide()
    }
    
    @objc func optionsAction(sender: AnyObject) {
        let viewController = BalloonViewController(text: "Options are currently minimal.", balloon: agentController.agent?.balloon)
        let popOver = NSPopover()
        popOver.behavior = .semitransient
        popOver.contentSize = viewController.contentSize
        popOver.animates = true
        popOver.contentViewController = viewController
        let rect = self.view.frame
        popOver.show(relativeTo: rect, of: view, preferredEdge: NSRectEdge.maxY)
    }

    @objc private func saySomethingAction() {
        speakRandomPhrase()
    }

    @objc private func playAnimationMenuAction(sender: NSMenuItem) {
        guard let name = sender.representedObject as? String,
              let animation = agentController.agent?.findAnimation(name) else { return }
        agentController.play(animation: animation)
    }

    private func commonAnimations(from agent: Agent) -> [AgentAnimation] {
        let preferredNames = [
            "Greeting", "Wave", "GetAttention", "Alert", "Thinking", "Processing",
            "Explain", "GestureLeft", "GestureRight", "GestureUp", "GestureDown"
        ]
        var animations = preferredNames.compactMap { agent.findAnimation($0) }
        let existingNames = Set(animations.map { $0.name })
        animations.append(contentsOf: agent.animations
            .filter { !existingNames.contains($0.name) && !$0.name.localizedCaseInsensitiveContains("idle") }
            .prefix(max(0, 12 - animations.count)))
        return animations
    }

    private func speakRandomPhrase() {
        guard let phrase = quickPhrases.randomElement() else { return }
        speak(text: phrase)
    }

    private func speak(text: String) {
        speechDismissWorkItem?.cancel()
        speechPopover?.close()

        let bubbleVC = BalloonViewController(text: text, balloon: agentController.agent?.balloon)
        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.contentSize = bubbleVC.contentSize
        popover.animates = true
        popover.contentViewController = bubbleVC
        popover.show(relativeTo: agentView.bounds, of: agentView, preferredEdge: preferredSpeechEdge(for: bubbleVC.contentSize))
        speechPopover = popover

        let work = DispatchWorkItem { [weak self] in
            self?.speechPopover?.close()
        }
        speechDismissWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.2, execute: work)
    }

    private func preferredSpeechEdge(for size: CGSize) -> NSRectEdge {
        guard let window = view.window, let screen = window.screen ?? NSScreen.main else { return .maxY }
        let visible = screen.visibleFrame
        let frame = window.frame
        if visible.maxY - frame.maxY >= size.height + 8 {
            return .maxY
        }
        if frame.minY - visible.minY >= size.height + 8 {
            return .minY
        }
        if frame.minX - visible.minX >= size.width + 8 {
            return .minX
        }
        return .maxX
    }

    private func applyThrowInertiaIfNeeded() {
        guard (NSApplication.shared.delegate as? AppDelegate)?.isThrowInertiaEnabled() ?? true else { return }
        guard let window = view.window else { return }
        let speed = hypot(dragVelocity.x, dragVelocity.y)
        guard speed > 250 else { return }

        stopInertia()
        inertiaTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self, weak window] timer in
            guard let self = self, let window = window else {
                timer.invalidate()
                return
            }

            self.dragVelocity.x *= 0.90
            self.dragVelocity.y *= 0.90

            if hypot(self.dragVelocity.x, self.dragVelocity.y) < 20 {
                timer.invalidate()
                return
            }

            var frame = window.frame
            frame.origin.x += self.dragVelocity.x / 60.0
            frame.origin.y += self.dragVelocity.y / 60.0
            frame = self.clampedFrame(frame, in: window)
            window.setFrame(frame, display: true)
            self.saveCurrentWindowFrame()
        }
    }

    private func stopInertia() {
        inertiaTimer?.invalidate()
        inertiaTimer = nil
    }

    private func applyEdgeSnap() {
        guard (NSApplication.shared.delegate as? AppDelegate)?.isEdgeSnapEnabled() ?? true else { return }
        guard let window = view.window else { return }
        let snapDistance: CGFloat = 18
        guard let screen = NSScreen.main ?? window.screen else { return }
        let visible = screen.visibleFrame

        var frame = clampedFrame(window.frame, in: window)

        let leftDistance = abs(frame.minX - visible.minX)
        let rightDistance = abs(visible.maxX - frame.maxX)
        let bottomDistance = abs(frame.minY - visible.minY)
        let topDistance = abs(visible.maxY - frame.maxY)

        if leftDistance <= snapDistance {
            frame.origin.x = visible.minX
        } else if rightDistance <= snapDistance {
            frame.origin.x = visible.maxX - frame.width
        }

        if bottomDistance <= snapDistance {
            frame.origin.y = visible.minY
        } else if topDistance <= snapDistance {
            frame.origin.y = visible.maxY - frame.height
        }

        window.setFrame(frame, display: true, animate: true)
        saveCurrentWindowFrame()
    }

    private func clampedFrame(_ frame: CGRect, in window: NSWindow) -> CGRect {
        guard let screen = NSScreen.main ?? window.screen else { return frame }
        let visible = screen.visibleFrame

        var clamped = frame
        clamped.origin.x = max(visible.minX, min(clamped.origin.x, visible.maxX - clamped.width))
        clamped.origin.y = max(visible.minY, min(clamped.origin.y, visible.maxY - clamped.height))
        return clamped
    }

    private func saveCurrentWindowFrame() {
        guard let frame = view.window?.frame else { return }
        (NSApplication.shared.delegate as? AppDelegate)?.saveWindowFrame(frame)
    }
}
