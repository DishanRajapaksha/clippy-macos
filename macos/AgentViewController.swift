//
//  AgentViewController.swift
//  Clippy
//
//  Created by Devran on 04.09.19.
//  Copyright © 2019 Devran. All rights reserved.
//

import AppKit

enum AgentReactionDirection {
    case left
    case right
}

class AgentViewController: NSViewController {
    let sessionID: UUID
    var agentController: AgentController
    var agentView: AgentView
    private var speechPopover: NSPopover?
    private var speechDismissWorkItem: DispatchWorkItem?
    private var lastDragScreenPoint: CGPoint?
    private var mouseDownScreenPoint: CGPoint?
    private var lastDragTimestamp: TimeInterval = 0
    private var dragVelocity: CGPoint = .zero
    private var hasDragged = false
    private var hasLoadedInitialAgent = false
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

    init(sessionID: UUID) {
        self.sessionID = sessionID
        agentView = AgentView()
        agentController = AgentController(agentView: agentView)
        super.init(nibName: nil, bundle: nil)
        agentController.delegate = self
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func loadView() {
        let size = CGSize(width: 100, height: 200)
        view = NSView(frame: CGRect(origin: .zero, size: size))
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
        guard !hasLoadedInitialAgent else { return }
        hasLoadedInitialAgent = true

        if let settings = currentSettings {
            agentController.isMuted = settings.isMuted
            agentController.configuredAutoAnimateInterval = settings.autoAnimateInterval
        }

        let name = currentSettings?.agentName ?? Agent.randomAgentName()
        if let name {
            do {
                try agentController.load(name: name)
                agentController.show()
            } catch {
                (NSApplication.shared.delegate as? AppDelegate)?.presentAlert(
                    title: "Agent Could Not Load",
                    message: error.localizedDescription
                )
            }
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

    var currentSettings: AgentSessionSettings? {
        (NSApplication.shared.delegate as? AppDelegate)?.sessionManager.settings(for: sessionID)
    }

    func reactToNearbyAgent(named otherName: String, direction: AgentReactionDirection, isReply: Bool) {
        guard currentSettings?.proximityReactionsEnabled ?? true else { return }
        let directionNames = direction == .right
            ? ["LookRight", "LookRightReturn", "Wave", "Greet"]
            : ["LookLeft", "LookLeftReturn", "Wave", "Greet"]
        if let animation = directionNames.compactMap({ agentController.agent?.findAnimation($0) }).first {
            agentController.play(animation: animation)
        } else {
            agentController.animate()
        }

        guard currentSettings?.speechBubblesEnabled ?? true else { return }
        let greetingPhrases = [
            "Hello, \(otherName)!",
            "Two assistants. This should be efficient.",
            "Well, fancy meeting you here."
        ]
        let replyPhrases = [
            "I was wondering when you'd show up.",
            "Need a hand, \(otherName)?",
            "Let's compare notes."
        ]
        if let phrase = (isReply ? replyPhrases : greetingPhrases).randomElement() {
            speak(text: phrase)
        }
    }
}

extension AgentViewController {
    override func mouseEntered(with event: NSEvent) {
        view.window?.alphaValue = 1.0
    }

    override func mouseExited(with event: NSEvent) {
        view.window?.alphaValue = 1.0
    }

    @objc func animateAction() {
        agentController.animate()
    }

    @objc func idleAnimationAction() {
        agentController.animateIdle()
    }

    @objc func chooseAssistantAction() {
        guard let name = Agent.randomAgentName(),
              let appDelegate = NSApplication.shared.delegate as? AppDelegate else { return }
        appDelegate.sessionManager.selectAgent(name, for: sessionID)
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
        case 49:
            agentController.animate()
        case 36:
            chooseAssistantAction()
        case 124:
            guard let animation = agent.findAnimation("LookLeft") else { break }
            agentController.play(animation: animation)
        case 123:
            guard let animation = agent.findAnimation("LookRight") else { break }
            agentController.play(animation: animation)
        case 126:
            guard let animation = agent.findAnimation("LookUp") else { break }
            agentController.play(animation: animation)
        case 125:
            guard let animation = agent.findAnimation("LookDown") else { break }
            agentController.play(animation: animation)
        default:
            super.keyDown(with: event)
        }
    }

    override func mouseDown(with event: NSEvent) {
        stopInertia()
        (NSApplication.shared.delegate as? AppDelegate)?.sessionManager.activate(
            sessionID: sessionID,
            bringForward: false
        )
        if event.clickCount == 2 {
            agentController.animate()
        }

        let location = NSEvent.mouseLocation
        mouseDownScreenPoint = location
        lastDragScreenPoint = location
        lastDragTimestamp = event.timestamp
        dragVelocity = .zero
        hasDragged = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window = view.window, let previous = lastDragScreenPoint else { return }
        let current = NSEvent.mouseLocation
        let dx = current.x - previous.x
        let dy = current.y - previous.y
        guard dx != 0 || dy != 0 else { return }

        if let mouseDownScreenPoint,
           hypot(current.x - mouseDownScreenPoint.x, current.y - mouseDownScreenPoint.y) >= 3 {
            hasDragged = true
        }

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
            mouseDownScreenPoint = nil
            lastDragTimestamp = 0
            hasDragged = false
        }

        if hasDragged {
            applyEdgeSnap()
            applyThrowInertiaIfNeeded()
            saveCurrentWindowFrame()
        } else if event.clickCount == 1,
                  currentSettings?.speechBubblesEnabled ?? true {
            speakRandomPhrase()
        }
    }

    override func rightMouseDown(with event: NSEvent) {
        guard let appDelegate = NSApplication.shared.delegate as? AppDelegate else { return }
        appDelegate.sessionManager.activate(sessionID: sessionID, bringForward: false)
        let menu = appDelegate.createMainMenu()
        NSMenu.popUpContextMenu(menu, with: event, for: agentView)
    }

    @objc func hideAction(sender: AnyObject) {
        agentController.hide()
    }

    @objc func optionsAction(sender: AnyObject) {
        let viewController = BalloonViewController(
            text: "Options are currently minimal.",
            balloon: agentController.agent?.balloon
        )
        let popOver = NSPopover()
        popOver.behavior = .semitransient
        popOver.contentSize = viewController.contentSize
        popOver.animates = true
        popOver.contentViewController = viewController
        popOver.show(relativeTo: view.frame, of: view, preferredEdge: .maxY)
    }

    @objc private func saySomethingAction() {
        speakRandomPhrase()
    }

    private func speakRandomPhrase() {
        guard let phrase = quickPhrases.randomElement() else { return }
        speak(text: phrase)
    }

    func speak(text: String) {
        speechDismissWorkItem?.cancel()
        speechPopover?.close()

        let bubbleVC = BalloonViewController(text: text, balloon: agentController.agent?.balloon)
        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.contentSize = bubbleVC.contentSize
        popover.animates = true
        popover.contentViewController = bubbleVC
        popover.show(
            relativeTo: agentView.bounds,
            of: agentView,
            preferredEdge: preferredSpeechEdge(for: bubbleVC.contentSize)
        )
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
        guard currentSettings?.throwInertiaEnabled ?? true else { return }
        guard let window = view.window else { return }
        let speed = hypot(dragVelocity.x, dragVelocity.y)
        guard speed > 250 else { return }

        stopInertia()
        inertiaTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60.0, repeats: true) { [weak self, weak window] timer in
            guard let self, let window else {
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
        guard currentSettings?.edgeSnapEnabled ?? true else { return }
        guard let window = view.window,
              let screen = relevantScreen(for: window.frame, window: window) else { return }
        let snapDistance: CGFloat = 18
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
        guard let screen = relevantScreen(for: frame, window: window) else { return frame }
        let visible = screen.visibleFrame
        var clamped = frame
        clamped.origin.x = max(visible.minX, min(clamped.origin.x, visible.maxX - clamped.width))
        clamped.origin.y = max(visible.minY, min(clamped.origin.y, visible.maxY - clamped.height))
        return clamped
    }

    private func relevantScreen(for frame: CGRect, window: NSWindow) -> NSScreen? {
        let screens = NSScreen.screens
        if hasDragged,
           let pointerScreen = screens.first(where: { $0.frame.contains(NSEvent.mouseLocation) }) {
            return pointerScreen
        }
        if let bestMatch = screens.max(by: {
            intersectionArea(of: $0.frame, with: frame) < intersectionArea(of: $1.frame, with: frame)
        }), intersectionArea(of: bestMatch.frame, with: frame) > 0 {
            return bestMatch
        }
        return window.screen ?? screens.first ?? NSScreen.main
    }

    private func intersectionArea(of lhs: CGRect, with rhs: CGRect) -> CGFloat {
        let intersection = lhs.intersection(rhs)
        guard !intersection.isNull else { return 0 }
        return intersection.width * intersection.height
    }

    private func saveCurrentWindowFrame() {
        guard let frame = view.window?.frame,
              let appDelegate = NSApplication.shared.delegate as? AppDelegate else { return }
        appDelegate.sessionManager.updateWindowFrame(for: sessionID, frame: frame)
    }
}
