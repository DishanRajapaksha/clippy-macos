//
//  AgentCharacterDescription.swift
//  Clippy
//
//  Created by Devran on 06.09.19.
//  Copyright © 2019 Devran. All rights reserved.
//

import Foundation
import SpriteKit

enum AgentError: Error {
    case frameOutOfBounds
    case invalidSpriteMap
}

struct Agent {
    var character: AgentCharacter
    var balloon: AgentBalloon
    var animations: [AgentAnimation]
    var states: [AgentState]
    
    var agentURL: URL
    var resourceName: String
    var resourceNameWithSuffix: String
    var spriteMap: CGImage
    var spriteImages: [CGImage] = []
    let soundsURL: URL
    var soundURLsByIndex: [Int: URL] = [:]
    
    init?(agentURL: URL) {
        self.agentURL = agentURL
        self.resourceNameWithSuffix = agentURL.lastPathComponent
        self.resourceName = agentURL.deletingPathExtension().lastPathComponent

        if agentURL.pathExtension.lowercased() == "acs" {
            guard let parsedAgent = try? ACSAgentParser.parse(url: agentURL, resourceName: resourceName) else {
                return nil
            }
            self.soundsURL = parsedAgent.soundsURL
            self.soundURLsByIndex = parsedAgent.soundURLsByIndex
            self.character = parsedAgent.character
            self.balloon = parsedAgent.balloon
            self.animations = parsedAgent.animations
            self.states = parsedAgent.states
            self.spriteMap = parsedAgent.spriteMap
            self.spriteImages = parsedAgent.spriteImages
            return
        }

        // Support both layouts:
        // 1) <name>.agent/<name>.acd
        // 2) <name>.agent/<name>.agent/<name>.acd (nested zip extraction)
        let nestedRoot = agentURL.appendingPathComponent(resourceNameWithSuffix, isDirectory: true)
        let baseURL: URL
        if FileManager.default.fileExists(atPath: nestedRoot.path) {
            baseURL = nestedRoot
        } else {
            baseURL = agentURL
        }

        self.soundsURL = baseURL.appendingPathComponent("sounds")
        let fileURL = baseURL.appendingPathComponent("\(resourceName).acd")
        let imageURL = baseURL.appendingPathComponent("\(resourceName)_sprite_map.png")

        guard let fileContent = try? String(contentsOf: fileURL, encoding: String.Encoding.utf8) else { return nil }
        
        // Character
        guard let characterText = fileContent.fetchInclusive("DefineCharacter", until: "EndCharacter").first else { return nil }
        let character = AgentCharacter.parse(content: characterText)
        
        // Balloon
        guard let balloonText = fileContent.fetchInclusive("DefineBalloon", until: "EndBalloon").first else { return nil }
        let balloon = AgentBalloon.parse(content: balloonText)
        
        // Animations
        let animationTexts = fileContent.fetchInclusive("DefineAnimation", until: "EndAnimation")
        let animations = animationTexts.compactMap { AgentAnimation.parse(content: $0) }
        
        // States
        let stateTexts = fileContent.fetchInclusive("DefineState", until: "EndState")
        let states = stateTexts.compactMap { AgentState.parse(content: $0) }
        
        // Sprite Map
        guard let image = NSImage(contentsOf: imageURL)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else { return nil }
        spriteMap = image
        
        if let character = character, let balloon = balloon {
            self.character = character
            self.balloon = balloon
            self.animations = animations
            self.states = states
        } else {
            return nil
        }
    }
    
    init?(resourceName: String) {
        guard let agentURL = Agent.agentURL(forResourceName: resourceName) else {
            return nil
        }
        self.init(agentURL: agentURL)
    }
    
    func soundURL(forIndex index: Int) -> URL? {
        if let soundURL = soundURLsByIndex[index] {
            return soundURL
        }

        let fileName = "\(resourceName)_\(index).mp3"
        let mp3URL = soundsURL.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: mp3URL.path) {
            return mp3URL
        }

        let wavURL = soundsURL.appendingPathComponent("\(resourceName)_\(index).wav")
        if FileManager.default.fileExists(atPath: wavURL.path) {
            return wavURL
        }

        return nil
    }
    
    func findAnimation(_ name: String) -> AgentAnimation? {
        return animations.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })
    }
}

extension Agent {
    var columns: Int {
        guard character.width > 0 else { return 0 }
        return Int(spriteMap.width) / character.width
    }
    var rows: Int {
        guard character.height > 0 else { return 0 }
        return Int(spriteMap.height) / character.height
    }
    
    func textureAtPosition(x: Int, y: Int) throws -> CGImage {
        guard x >= 0, y >= 0, x < columns, y < rows else { throw AgentError.frameOutOfBounds }
        let textureWidth = character.width
        let textureHeight = character.height
        let rect = CGRect(x: x * textureWidth, y: y * textureHeight, width: textureWidth, height: textureHeight)
        guard let image = spriteMap.cropping(to: rect) else { throw AgentError.invalidSpriteMap }
        return image
    }
    
    func textureAtIndex(index: Int) throws -> CGImage {
        if spriteImages.indices.contains(index) {
            return spriteImages[index]
        }

        guard columns > 0 else { throw AgentError.invalidSpriteMap }
        let x = index % columns
        let y = index / columns
        return try textureAtPosition(x: x, y: y)
    }
    
    func imageForFrame(_ frame: AgentFrame) -> CGImage? {
        if frame.images.count == 1, let imageNumber = frame.images.first?.imageNumber {
            return try? textureAtIndex(index: imageNumber)
        }

        let cgImages = frame.images.reversed().compactMap { try? textureAtIndex(index: $0.imageNumber) }
        guard !cgImages.isEmpty else { return try? textureAtIndex(index: 0) }
        if let mergedImage = CGImage.mergeImages(cgImages) {
            return mergedImage
        } else {
            return try? textureAtIndex(index: 0)
        }
    }
}

extension Agent {
    static func agentsURL() -> URL {
        let fileManager = FileManager.default
        
        guard let applicationSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            fatalError("Cant create Agents directory")
        }
        
        let agentsURL = applicationSupportURL.appendingPathComponent("Clippy/Agents", isDirectory: true)
        createAgentsDirectoriesIfNeeded(url: agentsURL)
        
        return agentsURL
    }

    static func acsAudioCacheURL() -> URL {
        let fileManager = FileManager.default

        guard let applicationSupportURL = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else {
            fatalError("Cant create ACS audio cache directory")
        }

        let cacheURL = applicationSupportURL.appendingPathComponent("Clippy/ACSAudioCache", isDirectory: true)
        if !fileManager.fileExists(atPath: cacheURL.path) {
            try? fileManager.createDirectory(at: cacheURL,
                                             withIntermediateDirectories: true,
                                             attributes: nil)
        }
        return cacheURL
    }
    
    static func createAgentsDirectoriesIfNeeded(url: URL) {
        let fileManager = FileManager.default
        if !fileManager.fileExists(atPath: url.path) {
            try? fileManager.createDirectory(at: url,
                                             withIntermediateDirectories: true,
                                             attributes: nil)
            ["clippit", "links", "merlin"].forEach {
                guard let agentsArchiveURL = Bundle.main.url(forResource: "\($0).agent", withExtension: "zip") else {
                    return
                }
                try? fileManager.copyItem(at: agentsArchiveURL, to: url.appendingPathComponent("\($0).agent.zip"))
            }
        }
    }
    
    static func agentURL(forResourceName resourceName: String) -> URL? {
        let fileManager = FileManager.default
        let strippedName = resourceName
            .replacingOccurrences(of: ".agent", with: "")
            .replacingOccurrences(of: ".acs", with: "")
        let agentsURL = Agent.agentsURL()
        let exactAgentURL = agentsURL.appendingPathComponent("\(strippedName).agent", isDirectory: true)
        if fileManager.fileExists(atPath: exactAgentURL.path) {
            return exactAgentURL
        }

        let exactACSURL = agentsURL.appendingPathComponent("\(strippedName).acs")
        if fileManager.fileExists(atPath: exactACSURL.path), isSupportedACSFile(exactACSURL) {
            return exactACSURL
        }

        guard let items = try? fileManager.contentsOfDirectory(at: agentsURL,
                                                               includingPropertiesForKeys: [.isDirectoryKey],
                                                               options: []) else {
            return nil
        }

        let lowercasedName = strippedName.lowercased()
        return items.first { item in
            let itemName = item.deletingPathExtension().lastPathComponent.lowercased()
            if item.hasDirectoryPath {
                return item.pathExtension.lowercased() == "agent" && itemName == lowercasedName
            }
            return item.pathExtension.lowercased() == "acs" && itemName == lowercasedName && isSupportedACSFile(item)
        }
    }

    static func agentNames() -> [String] {
        var agentNames = Set<String>()
        let fileManager = FileManager.default
        guard let items = try? fileManager.contentsOfDirectory(at: agentsURL(),
                                                               includingPropertiesForKeys: [.isDirectoryKey],
                                                               options: []) else {
            return []
        }

        for item in items {
            if item.hasDirectoryPath && item.lastPathComponent.hasSuffix(".agent") {
                agentNames.insert(item.deletingPathExtension().lastPathComponent)
            } else if !item.hasDirectoryPath && item.pathExtension.lowercased() == "acs" && isSupportedACSFile(item) {
                agentNames.insert(item.deletingPathExtension().lastPathComponent)
            }
        }
        return agentNames.sorted()
    }
    
    static func randomAgentName() -> String? {
        agentNames().randomElement()
    }

    private static func isSupportedACSFile(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer {
            try? handle.close()
        }
        let signature = handle.readData(ofLength: 4)
        guard signature.count == 4 else { return false }
        return signature[0] == 0xC3 &&
            signature[1] == 0xAB &&
            signature[2] == 0xCD &&
            signature[3] == 0xAB
    }
}
