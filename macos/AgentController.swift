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
    static let muteDefaultsKey = "IsMuted"

    var isMuted = false
    var autoAnimateTimer: Timer?
    private var isAnimating = false
    private var playbackID = UUID()
    var player: AVPlayer = {
        return AVPlayer()
    }()
    
    var agent: Agent?
    var agentView: AgentView?
    private var textureCache: [Int: SKTexture] = [:]
    private let textureCacheLock = NSLock()
    
    var delegate: AgentControllerDelegate?
    var isHidden = true
    
    init() {
    }
    
    convenience init(agentView: AgentView) {
        self.init()
        self.agentView = agentView
    }
    
    func load(name: String) throws {
        guard let agent = Agent(resourceName: name) else { return }
        delegate?.willLoadAgent(agent: agent)
        textureCacheLock.lock()
        textureCache.removeAll(keepingCapacity: true)
        textureCacheLock.unlock()
        self.agent = agent
        showInitialFrame()
        restartAutoAnimateTimer()
        delegate?.didLoadAgent(agent: agent)
    }
    
    func audioActionForFrame(frame: AgentFrame) -> SKAction? {
        guard let agent = agent, let soundIndex = frame.soundIndex else { return nil }
        guard let soundURL = agent.soundURL(forIndex: soundIndex) else { return nil }
        let action = SKAction.run {
            let playerItem = AVPlayerItem(url: soundURL)
            self.player.replaceCurrentItem(with: playerItem)
            self.player.play()
            self.player.volume = self.isMuted ? 0 : 1.0
        }
        return action
    }
    
    func showInitialFrame() {
        guard let agent = agent, let texture = texture(at: 0, for: agent) else { return }
        self.agentView?.agentSprite.texture = texture
    }
    
    func play(animation: AgentAnimation, withSoundEnabled soundEnabled: Bool = true, interruptCurrent: Bool = true, completion: (() -> Void)? = nil) {
        guard let agent = agent else { return }
        if isAnimating && !interruptCurrent {
            return
        }
        let currentPlaybackID = UUID()
        playbackID = currentPlaybackID
        isAnimating = true
        
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
                
                guard let texture = self.texture(for: frame, in: agent) else {
                    safetyCounter += 1
                    frameIndex = self.nextFrameIndex(after: frameIndex, in: animation)
                    continue
                }
                let action = SKAction.animate(with: [texture], timePerFrame: frame.durationInSeconds)
                actions.append(action)

                safetyCounter += 1
                frameIndex = self.nextFrameIndex(after: frameIndex, in: animation)
            }
            
            DispatchQueue.main.asyncAfter(deadline: .now(), execute: {
                guard self.playbackID == currentPlaybackID else { return }
                guard !actions.isEmpty else {
                    self.isAnimating = false
                    completion?()
                    return
                }
                self.agentView?.agentSprite.removeAllActions()
                self.agentView?.agentSprite.run(SKAction.sequence(actions), completion: {
                    guard self.playbackID == currentPlaybackID else { return }
                    self.isAnimating = false
                    completion?()
                })
            })
        }
    }

    private func nextFrameIndex(after currentIndex: Int, in animation: AgentAnimation) -> Int {
        let frame = animation.frames[currentIndex]

        if !frame.branchings.isEmpty {
            if let branch = selectBranch(from: frame.branchings),
               animation.frames.indices.contains(branch.branchTo) {
                return branch.branchTo
            }

            if let exitBranch = frame.exitBranch,
               animation.frames.indices.contains(exitBranch) {
                return exitBranch
            }
        }

        // Fallback: play linearly.
        let next = currentIndex + 1
        return next < animation.frames.count ? next : -1
    }

    private func texture(for frame: AgentFrame, in agent: Agent) -> SKTexture? {
        if frame.images.count == 1, let imageNumber = frame.images.first?.imageNumber {
            return texture(at: imageNumber, for: agent)
        }

        guard let image = agent.imageForFrame(frame) else { return texture(at: 0, for: agent) }
        let texture = SKTexture(cgImage: image)
        texture.filteringMode = .nearest
        return texture
    }

    private func texture(at index: Int, for agent: Agent) -> SKTexture? {
        textureCacheLock.lock()
        if let texture = textureCache[index] {
            textureCacheLock.unlock()
            return texture
        }
        textureCacheLock.unlock()

        guard let image = try? agent.textureAtIndex(index: index) else { return nil }
        let texture = SKTexture(cgImage: image)
        texture.filteringMode = .nearest
        textureCacheLock.lock()
        textureCache[index] = texture
        textureCacheLock.unlock()
        return texture
    }

    private func selectBranch(from branchings: [AgentBranching]) -> AgentBranching? {
        guard !branchings.isEmpty else { return nil }

        let total = branchings.reduce(0) { $0 + max(0, $1.probability) }
        guard total > 0 else { return nil }

        let rollLimit = max(total, 100)
        let roll = Int.random(in: 0..<rollLimit)
        var running = 0
        for branch in branchings {
            running += max(0, branch.probability)
            if roll < running {
                return branch
            }
        }
        return nil
    }
    
    func animate() {
        guard let agent = agent else { return }
        let animation = agent.animations.randomElement()!
        play(animation: animation)
    }

    func animateIdle() {
        guard !isHidden, let animation = idleAnimations().randomElement() else { return }
        play(animation: animation, interruptCurrent: false)
    }

    private func idleAnimations() -> [AgentAnimation] {
        guard let agent = agent else { return [] }
        let idleAnimationNames = Set(
            agent.states
                .filter { $0.name.range(of: "Idling", options: [.caseInsensitive, .anchored]) != nil }
                .flatMap { $0.animationNames }
                .map { $0.lowercased() }
        )
        let stateAnimations = agent.animations.filter { idleAnimationNames.contains($0.name.lowercased()) }
        if !stateAnimations.isEmpty {
            return stateAnimations
        }

        return agent.animations.filter { $0.name.localizedCaseInsensitiveContains("idle") }
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
        let configured = UserDefaults.standard.double(forKey: Self.autoAnimateIntervalDefaultsKey)
        guard configured > 0 else {
            autoAnimateTimer = nil
            return
        }
        autoAnimateTimer = Timer.scheduledTimer(withTimeInterval: nextAutoAnimateInterval(), repeats: false) { [weak self] _ in
            self?.animateIdle()
            self?.restartAutoAnimateTimer()
        }
    }

    private func nextAutoAnimateInterval() -> TimeInterval {
        let interval = autoAnimateInterval()
        let lowerBound = max(5, interval * 0.75)
        let upperBound = max(lowerBound, interval * 2)
        return TimeInterval.random(in: lowerBound...upperBound)
    }
}
