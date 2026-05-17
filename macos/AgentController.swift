//
//  AgentController.swift
//  Clippy macOS
//
//  Created by Devran on 07.09.19.
//  Copyright © 2019 Devran. All rights reserved.
//

import Cocoa
import AVKit
import SpriteKit

class AgentController {
    static let autoAnimateIntervalDefaultsKey = "AutoAnimateIntervalSeconds"
    static let defaultAutoAnimateInterval: TimeInterval = 12.0
    static let idleCursorProximityDefaultsKey = "IdleCursorProximityPoints"
    static let defaultIdleCursorProximity: CGFloat = 180.0
    static let muteDefaultsKey = "IsMuted"

    var isMuted = false
    var autoAnimateTimer: Timer?
    var player: AVPlayer = {
        return AVPlayer()
    }()
    
    var agent: Agent?
    var agentView: AgentView?
    
    var delegate: AgentControllerDelegate?
    var isHidden = true
    
    init() {
    }
    
    convenience init(agentView: AgentView) {
        self.init()
        self.agentView = agentView
    }
    
    func load(name: String) throws {
        print(name)
        guard let agent = Agent(resourceName: name) else { return }
        delegate?.willLoadAgent(agent: agent)
        self.agent = agent
        showInitialFrame()
        restartAutoAnimateTimer()
        delegate?.didLoadAgent(agent: agent)
    }
    
    func audioActionForFrame(frame: AgentFrame) -> SKAction? {
        guard let agent = agent, let soundIndex = frame.soundIndex else { return nil }
        let soundURL = agent.soundURL(forIndex: soundIndex)
        let action = SKAction.run {
            let playerItem = AVPlayerItem(url: soundURL)
            self.player.replaceCurrentItem(with: playerItem)
            self.player.play()
            self.player.volume = self.isMuted ? 0 : 1.0
        }
        return action
    }
    
    func showInitialFrame() {
        guard let agent = agent else { return }
        self.agentView?.agentSprite.texture = SKTexture(cgImage: try! agent.textureAtIndex(index: 0))
    }
    
    func play(animation: AgentAnimation, withSoundEnabled soundEnabled: Bool = true, completion: (() -> Void)? = nil) {
        guard let agent = agent else { return }
        print(animation.name)
        
        DispatchQueue.global(qos: .background).async {
            var actions: [SKAction] = []

            // Microsoft Agent frames can branch via ExitBranch + DefineBranching.
            // Build action sequence by following probabilistic branches at runtime.
            var frameIndex = 0
            var safetyCounter = 0
            let maxFrames = max(animation.frames.count * 8, 64)

            while frameIndex >= 0 && frameIndex < animation.frames.count && safetyCounter < maxFrames {
                let frame = animation.frames[frameIndex]

                if soundEnabled, let audioAction = self.audioActionForFrame(frame: frame) {
                    actions.append(audioAction)
                }
                
                let texture = SKTexture(cgImage: agent.imageForFrame(frame))
                texture.filteringMode = .nearest
                let action = SKAction.animate(with: [texture], timePerFrame: frame.durationInSeconds)
                actions.append(action)

                safetyCounter += 1
                frameIndex = self.nextFrameIndex(after: frameIndex, in: animation)
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now(), execute: {
                self.agentView?.agentSprite.removeAllActions()
                self.agentView?.agentSprite.run(SKAction.sequence(actions), completion: {
                    completion?()
                })
            })
        }
    }

    private func nextFrameIndex(after currentIndex: Int, in animation: AgentAnimation) -> Int {
        let frame = animation.frames[currentIndex]

        // Use branching table when the frame explicitly exits via a branch.
        if let exitBranch = frame.exitBranch, !frame.branchings.isEmpty {
            if let branch = selectBranch(from: frame.branchings, matching: exitBranch) {
                return branch.branchTo
            }
        }

        // Fallback: play linearly.
        let next = currentIndex + 1
        return next < animation.frames.count ? next : -1
    }

    private func selectBranch(from branchings: [AgentBranching], matching exitBranch: Int) -> AgentBranching? {
        // Branch ids in files are often 1-based; support both 0-based and 1-based.
        let filtered = branchings.filter { $0.branchTo == exitBranch || $0.branchTo == (exitBranch - 1) }
        let candidates = filtered.isEmpty ? branchings : filtered
        guard !candidates.isEmpty else { return nil }

        let total = max(candidates.reduce(0) { $0 + max(0, $1.probability) }, 0)
        guard total > 0 else { return candidates.randomElement() }

        let roll = Int.random(in: 0..<total)
        var running = 0
        for branch in candidates {
            running += max(0, branch.probability)
            if roll < running {
                return branch
            }
        }
        return candidates.last
    }
    
    func animate() {
        guard let agent = agent else { return }
        let animation = agent.animations.randomElement()!
        play(animation: animation)
    }
    
    func hide() {
        delegate?.handleHide()
    }
    
    func show() {
        delegate?.handleShow()
    }

    func autoAnimateInterval() -> TimeInterval {
        let configured = UserDefaults.standard.double(forKey: Self.autoAnimateIntervalDefaultsKey)
        return configured > 0 ? configured : Self.defaultAutoAnimateInterval
    }

    func restartAutoAnimateTimer() {
        autoAnimateTimer?.invalidate()
        let interval = autoAnimateInterval()
        autoAnimateTimer = Timer.scheduledTimer(withTimeInterval: interval, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            guard self.shouldRunIdleAnimation() else { return }
            self.animate()
        }
    }

    private func shouldRunIdleAnimation() -> Bool {
        guard !isHidden else { return false } // hidden agent should not animate
        guard agent != nil else { return false } // no loaded agent
        let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        let currentPID = ProcessInfo.processInfo.processIdentifier
        guard frontmostPID == currentPID else { return false } // app-focus rule
        guard let window = agentView?.window else { return false }
        let cursor = NSEvent.mouseLocation
        if window.frame.contains(cursor) { return false } // don't idle while hovering Clippy
        let windowCenter = CGPoint(x: window.frame.midX, y: window.frame.midY)
        let dx = cursor.x - windowCenter.x
        let dy = cursor.y - windowCenter.y
        let distance = hypot(dx, dy)
        return distance <= idleCursorProximity() // cursor-proximity rule
    }

    private func idleCursorProximity() -> CGFloat {
        let configured = UserDefaults.standard.double(forKey: Self.idleCursorProximityDefaultsKey)
        if configured > 0 {
            return CGFloat(configured)
        }
        return Self.defaultIdleCursorProximity
    }
}
