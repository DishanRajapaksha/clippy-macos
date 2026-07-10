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

struct AgentListing {
    let name: String
    let url: URL
    let isSupported: Bool
    let reason: String?
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
            guard let parsedAgent = try? SafeACSAgentParser.parse(url: agentURL, resourceName: resourceName) else {
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
        let names = agentListings()
            .filter(\.isSupported)
            .map(\.name)
        return Array(Set(names)).sorted()
    }

    static func randomAgentName() -> String? {
        agentNames().randomElement()
    }

    static func agentListings() -> [AgentListing] {
        let fileManager = FileManager.default
        guard let items = try? fileManager.contentsOfDirectory(at: agentsURL(),
                                                               includingPropertiesForKeys: [.isDirectoryKey],
                                                               options: []) else {
            return []
        }

        return items.compactMap { item -> AgentListing? in
            let isDirectory = (try? item.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? item.hasDirectoryPath
            let ext = item.pathExtension.lowercased()
            let name = item.deletingPathExtension().lastPathComponent

            if isDirectory && ext == "agent" {
                return AgentListing(name: name, url: item, isSupported: true, reason: nil)
            }

            if !isDirectory && ext == "acs" {
                let reason = acsUnsupportedReason(item)
                return AgentListing(name: name, url: item, isSupported: reason == nil, reason: reason)
            }

            return nil
        }
        .sorted {
            $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    static func agentStatus(for url: URL) -> (isSupported: Bool, reason: String?) {
        let ext = url.pathExtension.lowercased()
        if ext == "acs" {
            let reason = acsUnsupportedReason(url)
            guard reason == nil else { return (false, reason) }
            do {
                try SafeACSAgentParser.preflight(url: url)
                return (true, nil)
            } catch {
                return (false, error.localizedDescription)
            }
        }
        if ext == "agent" || url.hasDirectoryPath {
            let reason = Agent(agentURL: url) == nil ? "could not read .agent resources" : nil
            return (reason == nil, reason)
        }
        return (false, "unsupported file type")
    }

    private static func isSupportedACSFile(_ url: URL) -> Bool {
        guard acsUnsupportedReason(url) == nil else { return false }
        return (try? SafeACSAgentParser.preflight(url: url)) != nil
    }

    private static func acsUnsupportedReason(_ url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return "could not read ACS file" }
        defer {
            try? handle.close()
        }
        let signature = handle.readData(ofLength: 4)
        guard signature.count == 4 else { return "file is too small to be an ACS agent" }
        if signature[0] == 0xC3 &&
            signature[1] == 0xAB &&
            signature[2] == 0xCD &&
            signature[3] == 0xAB {
            return nil
        }
        if signature[0] == 0xD0 &&
            signature[1] == 0xCF &&
            signature[2] == 0x11 &&
            signature[3] == 0xE0 {
            return "OLE-container ACS files are not supported yet"
        }
        return "unsupported ACS signature"
    }
}

private enum ACSPreflightError: LocalizedError {
    case fileTooLarge(Int64)
    case invalidHeader
    case invalidOffset
    case limitExceeded(String)
    case unexpectedEndOfFile

    var errorDescription: String? {
        switch self {
        case .fileTooLarge(let size):
            return "ACS file is too large (\(ByteCountFormatter.string(fromByteCount: size, countStyle: .file)))"
        case .invalidHeader:
            return "invalid ACS header"
        case .invalidOffset:
            return "ACS file contains an invalid data offset"
        case .limitExceeded(let detail):
            return "ACS resource limit exceeded: \(detail)"
        case .unexpectedEndOfFile:
            return "ACS file ended unexpectedly during validation"
        }
    }
}

private struct SafeACSAgentParser {
    private struct Locator {
        let offset: Int
        let size: Int
    }

    private enum Limits {
        static let fileBytes: Int64 = 128 * 1024 * 1024
        static let blockBytes = 64 * 1024 * 1024
        static let totalAudioBytes = 128 * 1024 * 1024
        static let characterDimension = 2_048
        static let sourceImageDimension = 4_096
        static let sourceImagePixels = 16_777_216
        static let images = 4_096
        static let animations = 2_048
        static let framesPerAnimation = 10_000
        static let totalFrames = 50_000
        static let frameImages = 256
        static let audioEntries = 4_096
        static let stringCharacters = 65_536
        static let branches = 64
        static let overlays = 64
    }

    static func parse(url: URL, resourceName: String) throws -> ParsedACSAgent {
        try preflight(url: url)
        return try ACSAgentParser.parse(url: url, resourceName: resourceName)
    }

    static func preflight(url: URL) throws {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        let size = Int64(values.fileSize ?? 0)
        guard size <= Limits.fileBytes else {
            throw ACSPreflightError.fileTooLarge(size)
        }

        let data = try Data(contentsOf: url, options: [.mappedIfSafe])
        var reader = Reader(data: data)
        guard try reader.readUInt32() == 0xABCDABC3 else {
            throw ACSPreflightError.invalidHeader
        }

        let character = try reader.readLocator()
        let animations = try reader.readLocator()
        let images = try reader.readLocator()
        let audio = try reader.readLocator()
        try [character, animations, images, audio].forEach { try validate($0, in: data) }

        try validateCharacter(at: character, in: data)
        try validateImages(at: images, in: data)
        try validateAnimations(at: animations, in: data)
        try validateAudio(at: audio, in: data)
    }

    private static func validateCharacter(at locator: Locator, in data: Data) throws {
        guard locator.offset > 0 || locator.size > 0 else { return }
        var reader = Reader(data: data, offset: locator.offset)
        try reader.skip(4)
        let localisedInfo = try reader.readLocator()
        try validate(localisedInfo, in: data)
        try reader.skip(16)
        let width = Int(try reader.readUInt16())
        let height = Int(try reader.readUInt16())
        guard width > 0, height > 0,
              width <= Limits.characterDimension,
              height <= Limits.characterDimension else {
            throw ACSPreflightError.limitExceeded("character dimensions \(width)×\(height)")
        }
    }

    private static func validateImages(at locator: Locator, in data: Data) throws {
        guard locator.offset > 0 || locator.size > 0 else { return }
        var reader = Reader(data: data, offset: locator.offset)
        let count = Int(try reader.readUInt32())
        guard count <= Limits.images else {
            throw ACSPreflightError.limitExceeded("\(count) images")
        }

        var entries: [Locator] = []
        entries.reserveCapacity(count)
        for _ in 0..<count {
            let entry = try reader.readLocator()
            try validate(entry, in: data)
            entries.append(entry)
            _ = try reader.readUInt32()
        }

        for entry in entries where entry.size > 0 {
            var imageReader = Reader(data: data, offset: entry.offset)
            _ = try imageReader.readUInt8()
            let width = Int(try imageReader.readUInt16())
            let height = Int(try imageReader.readUInt16())
            _ = try imageReader.readUInt8()
            guard width > 0, height > 0,
                  width <= Limits.sourceImageDimension,
                  height <= Limits.sourceImageDimension else {
                throw ACSPreflightError.limitExceeded("source image dimensions \(width)×\(height)")
            }
            let (pixels, overflow) = width.multipliedReportingOverflow(by: height)
            guard !overflow, pixels <= Limits.sourceImagePixels else {
                throw ACSPreflightError.limitExceeded("source image pixel count")
            }
            try imageReader.skipDataBlock(maximum: Limits.blockBytes)
            try imageReader.skipCompressedBlock(maximum: Limits.blockBytes)
        }
    }

    private static func validateAnimations(at locator: Locator, in data: Data) throws {
        guard locator.offset > 0 || locator.size > 0 else { return }
        var reader = Reader(data: data, offset: locator.offset)
        let count = Int(try reader.readUInt32())
        guard count <= Limits.animations else {
            throw ACSPreflightError.limitExceeded("\(count) animations")
        }

        var entries: [Locator] = []
        entries.reserveCapacity(count)
        for _ in 0..<count {
            try reader.skipString(maximumCharacters: Limits.stringCharacters)
            let entry = try reader.readLocator()
            try validate(entry, in: data)
            entries.append(entry)
        }

        var totalFrames = 0
        for entry in entries where entry.size > 0 {
            var animationReader = Reader(data: data, offset: entry.offset)
            try animationReader.skipString(maximumCharacters: Limits.stringCharacters)
            _ = try animationReader.readUInt8()
            try animationReader.skipString(maximumCharacters: Limits.stringCharacters)
            let frameCount = Int(try animationReader.readUInt16())
            guard frameCount <= Limits.framesPerAnimation else {
                throw ACSPreflightError.limitExceeded("\(frameCount) frames in one animation")
            }
            totalFrames += frameCount
            guard totalFrames <= Limits.totalFrames else {
                throw ACSPreflightError.limitExceeded("more than \(Limits.totalFrames) total frames")
            }

            for _ in 0..<frameCount {
                let frameImageCount = Int(try animationReader.readUInt16())
                guard frameImageCount <= Limits.frameImages else {
                    throw ACSPreflightError.limitExceeded("\(frameImageCount) images in one frame")
                }
                try animationReader.skip(frameImageCount * 8)
                try animationReader.skip(6)

                let branchCount = Int(try animationReader.readUInt8())
                guard branchCount <= Limits.branches else {
                    throw ACSPreflightError.limitExceeded("\(branchCount) frame branches")
                }
                try animationReader.skip(branchCount * 4)

                let overlayCount = Int(try animationReader.readUInt8())
                guard overlayCount <= Limits.overlays else {
                    throw ACSPreflightError.limitExceeded("\(overlayCount) frame overlays")
                }
                for _ in 0..<overlayCount {
                    _ = try animationReader.readUInt8()
                    _ = try animationReader.readUInt8()
                    try animationReader.skip(3)
                    let hasRegionData = try animationReader.readUInt8() != 0
                    try animationReader.skip(8)
                    if hasRegionData {
                        try animationReader.skipDataBlock(maximum: Limits.blockBytes)
                    }
                }
            }
        }
    }

    private static func validateAudio(at locator: Locator, in data: Data) throws {
        guard locator.offset > 0 || locator.size > 0 else { return }
        var reader = Reader(data: data, offset: locator.offset)
        let count = Int(try reader.readUInt32())
        guard count <= Limits.audioEntries else {
            throw ACSPreflightError.limitExceeded("\(count) audio entries")
        }

        var total = 0
        for _ in 0..<count {
            let entry = try reader.readLocator()
            try validate(entry, in: data)
            guard entry.size <= Limits.blockBytes else {
                throw ACSPreflightError.limitExceeded("audio block larger than \(Limits.blockBytes) bytes")
            }
            let (sum, overflow) = total.addingReportingOverflow(entry.size)
            guard !overflow, sum <= Limits.totalAudioBytes else {
                throw ACSPreflightError.limitExceeded("audio data exceeds \(Limits.totalAudioBytes) bytes")
            }
            total = sum
            _ = try reader.readUInt32()
        }
    }

    private static func validate(_ locator: Locator, in data: Data) throws {
        guard locator.offset >= 0, locator.size >= 0 else {
            throw ACSPreflightError.invalidOffset
        }
        let (end, overflow) = locator.offset.addingReportingOverflow(locator.size)
        guard !overflow, end <= data.count else {
            throw ACSPreflightError.invalidOffset
        }
    }

    private struct Reader {
        let data: Data
        var offset: Int

        init(data: Data, offset: Int = 0) {
            self.data = data
            self.offset = offset
        }

        mutating func readUInt8() throws -> UInt8 {
            guard offset < data.count else { throw ACSPreflightError.unexpectedEndOfFile }
            defer { offset += 1 }
            return data[offset]
        }

        mutating func readUInt16() throws -> UInt16 {
            let b0 = UInt16(try readUInt8())
            let b1 = UInt16(try readUInt8()) << 8
            return b0 | b1
        }

        mutating func readUInt32() throws -> UInt32 {
            let b0 = UInt32(try readUInt8())
            let b1 = UInt32(try readUInt8()) << 8
            let b2 = UInt32(try readUInt8()) << 16
            let b3 = UInt32(try readUInt8()) << 24
            return b0 | b1 | b2 | b3
        }

        mutating func readLocator() throws -> Locator {
            Locator(offset: Int(try readUInt32()), size: Int(try readUInt32()))
        }

        mutating func skip(_ count: Int) throws {
            guard count >= 0 else { throw ACSPreflightError.limitExceeded("negative block length") }
            let (newOffset, overflow) = offset.addingReportingOverflow(count)
            guard !overflow, newOffset <= data.count else {
                throw ACSPreflightError.unexpectedEndOfFile
            }
            offset = newOffset
        }

        mutating func skipString(maximumCharacters: Int) throws {
            let characterCount = Int(try readUInt32())
            guard characterCount <= maximumCharacters else {
                throw ACSPreflightError.limitExceeded("string with \(characterCount) characters")
            }
            let (byteCount, overflow) = characterCount.multipliedReportingOverflow(by: 2)
            guard !overflow else {
                throw ACSPreflightError.limitExceeded("string length overflow")
            }
            try skip(byteCount)
            if offset + 2 <= data.count,
               data[offset] == 0,
               data[offset + 1] == 0 {
                offset += 2
            }
        }

        mutating func skipDataBlock(maximum: Int) throws {
            let size = Int(try readUInt32())
            guard size <= maximum else {
                throw ACSPreflightError.limitExceeded("data block with \(size) bytes")
            }
            try skip(size)
        }

        mutating func skipCompressedBlock(maximum: Int) throws {
            let compressedSize = Int(try readUInt32())
            let uncompressedSize = Int(try readUInt32())
            guard compressedSize <= maximum, uncompressedSize <= maximum else {
                throw ACSPreflightError.limitExceeded("compressed block exceeds \(maximum) bytes")
            }
            try skip(compressedSize == 0 ? uncompressedSize : compressedSize)
        }
    }
}
