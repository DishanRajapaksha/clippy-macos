//
//  AgentView.swift
//  Clippy macOS
//
//  Created by Devran on 07.09.19.
//  Copyright © 2019 Devran. All rights reserved.
//

import Cocoa
import SpriteKit

class AgentView: NSView {
    lazy var skView: SKView = {
        let skView = GhostSKView()
        skView.wantsLayer = true
        skView.allowsTransparency = true
        skView.layer?.backgroundColor = .clear
        return skView
    }()
    
    lazy var scene: SKScene = {
        let scene = SKScene(size: frame.size)
        scene.scaleMode = .resizeFill
        scene.backgroundColor = .clear
        scene.addChild(agentSprite)
        return scene
    }()
    
    lazy var agentSprite: SKSpriteNode = {
        let sprite = SKSpriteNode()
        sprite.position = CGPoint.zero
        sprite.anchorPoint = CGPoint.zero
        return sprite
    }()
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layer?.backgroundColor = .clear
        
        addSubview(skView)
        
        setupConstraints()
        
        skView.presentScene(scene)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    override func layout() {
        super.layout()
        
        agentSprite.size = frame.size
    }
    
    func setupConstraints() {
        skView.translatesAutoresizingMaskIntoConstraints = false
        skView.topAnchor.constraint(equalTo: topAnchor).isActive = true
        skView.leftAnchor.constraint(equalTo: leftAnchor).isActive = true
        rightAnchor.constraint(equalTo: skView.rightAnchor).isActive = true
        bottomAnchor.constraint(equalTo: skView.bottomAnchor).isActive = true
    }

}

extension AppDelegate {
    // Compatibility for automation actions that still write the historical
    // defaults before applying behaviour to the active agent session.
    func applyWindowBehavior() {
        guard let session = sessionManager.activeSession else { return }
        let defaults = UserDefaults.standard
        sessionManager.updateSettings(for: session.id) {
            $0.alwaysOnTop = defaults.bool(forKey: Self.alwaysOnTopDefaultsKey)
            $0.joinAllSpaces = defaults.bool(forKey: Self.joinAllSpacesDefaultsKey)
        }
    }
}
