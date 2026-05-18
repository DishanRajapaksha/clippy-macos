//
//  ACSAgentParser.swift
//  Clippy
//
//  Parses Microsoft Agent ACS files directly.
//

import CoreGraphics
import Foundation

enum ACSAgentParserError: LocalizedError {
    case invalidSignature
    case unexpectedEndOfFile
    case invalidOffset
    case invalidCompressedData
    case invalidImageData
    case imageCreationFailed

    var errorDescription: String? {
        switch self {
        case .invalidSignature:
            return "not a Microsoft Agent ACS file"
        case .unexpectedEndOfFile:
            return "the ACS file ended unexpectedly"
        case .invalidOffset:
            return "the ACS file contains an invalid data offset"
        case .invalidCompressedData:
            return "the ACS file contains invalid compressed data"
        case .invalidImageData:
            return "the ACS file contains invalid image data"
        case .imageCreationFailed:
            return "could not create images from the ACS file"
        }
    }
}

struct ParsedACSAgent {
    let character: AgentCharacter
    let balloon: AgentBalloon
    let animations: [AgentAnimation]
    let states: [AgentState]
    let spriteMap: CGImage
    let spriteImages: [CGImage]
    let soundsURL: URL
    let soundURLsByIndex: [Int: URL]
}

struct ACSAgentParser {
    private static let signature: UInt32 = 0xABCDABC3

    static func parse(url: URL, resourceName: String) throws -> ParsedACSAgent {
        let data = try Data(contentsOf: url)
        var reader = ACSBinaryReader(data: data)

        guard try reader.readUInt32() == signature else {
            throw ACSAgentParserError.invalidSignature
        }

        let characterLocator = try reader.readLocator()
        let animationLocator = try reader.readLocator()
        let imageLocator = try reader.readLocator()
        let audioLocator = try reader.readLocator()

        let characterInfo = try parseCharacterInfo(from: data, locator: characterLocator)
        let images = try parseImages(
            from: data,
            locator: imageLocator,
            palette: characterInfo.palette,
            transparentIndex: characterInfo.transparentIndex
        )
        let sourceAnimations = try parseAnimations(from: data, locator: animationLocator)
        let audioURLs = try writeAudioCache(from: data, locator: audioLocator, acsURL: url, resourceName: resourceName)

        let spriteFrames = try buildSpriteFrames(
            animations: sourceAnimations,
            sourceImages: images,
            characterWidth: characterInfo.character.width,
            characterHeight: characterInfo.character.height
        )

        let spriteMap: CGImage
        if let firstImage = spriteFrames.images.first {
            spriteMap = firstImage
        } else {
            spriteMap = try makeEmptyImage(
                width: characterInfo.character.width,
                height: characterInfo.character.height
            )
        }

        let animations = sourceAnimations.map { sourceAnimation in
            AgentAnimation(
                name: sourceAnimation.name,
                transitionType: sourceAnimation.transitionType,
                frames: sourceAnimation.frames.map { sourceFrame in
                    let spriteIndex = spriteFrames.indexesByFrameID[sourceFrame.id] ?? 0
                    let soundEffect = sourceFrame.audioIndex.map { "Audio\\\($0).wav" }
                    return AgentFrame(
                        duration: sourceFrame.duration,
                        soundEffect: soundEffect,
                        exitBranch: sourceFrame.exitBranch,
                        branchings: sourceFrame.branchings,
                        images: [AgentImage(fileName: "Images\\\(spriteIndex).bmp")]
                    )
                }
            )
        }

        return ParsedACSAgent(
            character: characterInfo.character,
            balloon: characterInfo.balloon,
            animations: animations,
            states: characterInfo.states,
            spriteMap: spriteMap,
            spriteImages: spriteFrames.images,
            soundsURL: audioURLs.directory,
            soundURLsByIndex: audioURLs.urlsByIndex
        )
    }
}

private extension ACSAgentParser {
    struct CharacterInfo {
        let character: AgentCharacter
        let balloon: AgentBalloon
        let states: [AgentState]
        let palette: [ACSPaletteColor]
        let transparentIndex: Int
    }

    struct SourceImage {
        let width: Int
        let height: Int
        let cgImage: CGImage
    }

    struct SourceFrameImage: Hashable {
        let imageIndex: Int
        let x: Int
        let y: Int
    }

    struct SourceFrame {
        let id: Int
        let duration: Int
        let audioIndex: Int?
        let exitBranch: Int?
        let branchings: [AgentBranching]
        let images: [SourceFrameImage]
    }

    struct SourceAnimation {
        let name: String
        let transitionType: Int
        let frames: [SourceFrame]
    }

    struct SpriteFrames {
        let images: [CGImage]
        let indexesByFrameID: [Int: Int]
    }

    struct AudioCache {
        let directory: URL
        let urlsByIndex: [Int: URL]
    }

    static func parseCharacterInfo(from data: Data, locator: ACSLocator) throws -> CharacterInfo {
        var reader = ACSBinaryReader(data: data)
        try reader.seek(to: locator.offset)

        _ = try reader.readUInt16() // minor version
        _ = try reader.readUInt16() // major version
        let localizedInfoLocator = try reader.readLocator()
        let guid = try reader.readGUIDString()
        let width = Int(try reader.readUInt16())
        let height = Int(try reader.readUInt16())
        let transparentIndex = Int(try reader.readUInt8())
        let flags = try reader.readUInt32()
        _ = try reader.readUInt16() // animation set major version
        _ = try reader.readUInt16() // animation set minor version

        if flags & 0x20 != 0 {
            try reader.skipVoiceInfo()
        }

        let balloon: AgentBalloon
        if flags & 0x200 != 0 {
            balloon = try reader.readBalloonInfo()
        } else {
            balloon = AgentBalloon(
                numberOfLines: 2,
                charactersPerLine: 32,
                fontName: "MS Sans Serif",
                fontHeight: 13,
                foregroundColor: "00000000",
                backgroundColor: "00ffffff",
                borderColor: "00000000"
            )
        }

        let paletteCount = Int(try reader.readUInt32())
        var palette: [ACSPaletteColor] = []
        palette.reserveCapacity(paletteCount)
        for _ in 0..<paletteCount {
            palette.append(try reader.readPaletteColor())
        }

        if try reader.readBool() {
            try reader.skipTrayIcon()
        }

        let states = try reader.readStates()
        let infos = try parseLocalizedInfo(from: data, locator: localizedInfoLocator)
        let style = styleString(from: flags)
        let colorTable = "ACS"
        let character = AgentCharacter(
            infos: infos,
            guid: guid,
            width: width,
            height: height,
            transparency: transparentIndex,
            defaultFrameDuration: 10,
            style: style,
            colorTable: colorTable
        )

        return CharacterInfo(
            character: character,
            balloon: balloon,
            states: states,
            palette: palette,
            transparentIndex: transparentIndex
        )
    }

    static func parseLocalizedInfo(from data: Data, locator: ACSLocator) throws -> [AgentInfo] {
        guard locator.offset > 0 || locator.size > 0 else { return [] }
        var reader = ACSBinaryReader(data: data)
        try reader.seek(to: locator.offset)

        let count = Int(try reader.readUInt16())
        var infos: [AgentInfo] = []
        infos.reserveCapacity(count)
        for _ in 0..<count {
            let language = String(format: "0x%04X", try reader.readUInt16())
            let name = try reader.readString()
            let description = try reader.readString()
            let extraData = try reader.readString()
            infos.append(AgentInfo(language: language, name: name, description: description, extraData: extraData))
        }
        return infos
    }

    static func parseImages(
        from data: Data,
        locator: ACSLocator,
        palette: [ACSPaletteColor],
        transparentIndex: Int
    ) throws -> [SourceImage] {
        var reader = ACSBinaryReader(data: data)
        try reader.seek(to: locator.offset)

        let count = Int(try reader.readUInt32())
        var entries: [(locator: ACSLocator, checksum: UInt32)] = []
        entries.reserveCapacity(count)
        for _ in 0..<count {
            entries.append((try reader.readLocator(), try reader.readUInt32()))
        }

        return try entries.map { entry in
            var imageReader = ACSBinaryReader(data: data)
            try imageReader.seek(to: entry.locator.offset)

            _ = try imageReader.readUInt8()
            let width = Int(try imageReader.readUInt16())
            let height = Int(try imageReader.readUInt16())
            let isCompressed = try imageReader.readBool()
            let imageBlock = try imageReader.readDataBlock()
            try imageReader.skipCompressedBlock()

            let stride = (width + 3) & ~3
            let expectedSize = stride * height
            let image: CGImage
            do {
                let bitmapData = isCompressed
                    ? try ACSDecompressor.decompress(imageBlock, expectedSize: expectedSize)
                    : imageBlock

                guard bitmapData.count >= expectedSize else {
                    throw ACSAgentParserError.invalidImageData
                }

                image = try makeImage(
                    width: width,
                    height: height,
                    stride: stride,
                    indexedBitmap: bitmapData,
                    palette: palette,
                    transparentIndex: transparentIndex
                )
            } catch {
                // Some ACS files in the wild contain a few corrupt compressed bitmaps.
                // Keep the character loadable and leave only those source images transparent.
                image = try makeEmptyImage(width: width, height: height)
            }
            return SourceImage(width: width, height: height, cgImage: image)
        }
    }

    static func parseAnimations(from data: Data, locator: ACSLocator) throws -> [SourceAnimation] {
        var reader = ACSBinaryReader(data: data)
        try reader.seek(to: locator.offset)

        let count = Int(try reader.readUInt32())
        var entries: [(name: String, locator: ACSLocator)] = []
        entries.reserveCapacity(count)
        for _ in 0..<count {
            entries.append((try reader.readString(), try reader.readLocator()))
        }

        var nextFrameID = 0
        return try entries.map { entry in
            var animationReader = ACSBinaryReader(data: data)
            try animationReader.seek(to: entry.locator.offset)

            let parsedName = try animationReader.readString()
            let name = parsedName.isEmpty ? entry.name : parsedName
            let transitionType = Int(try animationReader.readUInt8())
            _ = try animationReader.readString() // return animation

            let frameCount = Int(try animationReader.readUInt16())
            var frames: [SourceFrame] = []
            frames.reserveCapacity(frameCount)
            for _ in 0..<frameCount {
                let frameImagesCount = Int(try animationReader.readUInt16())
                var frameImages: [SourceFrameImage] = []
                frameImages.reserveCapacity(frameImagesCount)
                for _ in 0..<frameImagesCount {
                    frameImages.append(SourceFrameImage(
                        imageIndex: Int(try animationReader.readUInt32()),
                        x: Int(try animationReader.readInt16()),
                        y: Int(try animationReader.readInt16())
                    ))
                }

                let audioIndexValue = Int(try animationReader.readUInt16())
                let duration = Int(try animationReader.readUInt16())
                let exitBranchValue = Int(try animationReader.readInt16())
                let branchings = try animationReader.readBranchings()
                try animationReader.skipOverlays()

                let frame = SourceFrame(
                    id: nextFrameID,
                    duration: duration,
                    audioIndex: audioIndexValue == Int(UInt16.max) ? nil : audioIndexValue,
                    exitBranch: exitBranchValue < 0 ? nil : exitBranchValue,
                    branchings: branchings,
                    images: frameImages
                )
                frames.append(frame)
                nextFrameID += 1
            }

            return SourceAnimation(name: name, transitionType: transitionType, frames: frames)
        }
    }

    static func writeAudioCache(
        from data: Data,
        locator: ACSLocator,
        acsURL: URL,
        resourceName: String
    ) throws -> AudioCache {
        guard locator.offset > 0 || locator.size > 0 else {
            return AudioCache(directory: acsURL.deletingLastPathComponent(), urlsByIndex: [:])
        }

        var reader = ACSBinaryReader(data: data)
        try reader.seek(to: locator.offset)

        let count = Int(try reader.readUInt32())
        var entries: [(locator: ACSLocator, checksum: UInt32)] = []
        entries.reserveCapacity(count)
        for _ in 0..<count {
            entries.append((try reader.readLocator(), try reader.readUInt32()))
        }

        let fileAttributes = (try? FileManager.default.attributesOfItem(atPath: acsURL.path)) ?? [:]
        let fileSize = (fileAttributes[.size] as? NSNumber)?.intValue ?? data.count
        let modifiedAt = ((fileAttributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0).rounded()
        let cacheID = "\(resourceName)-\(fileSize)-\(Int(modifiedAt))".sanitizedFileComponent()
        let directory = Agent.acsAudioCacheURL().appendingPathComponent(cacheID, isDirectory: true)

        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)

        var urlsByIndex: [Int: URL] = [:]
        for (index, entry) in entries.enumerated() where entry.locator.size > 0 {
            let url = directory.appendingPathComponent("\(resourceName)_\(index).wav")
            if !FileManager.default.fileExists(atPath: url.path) {
                let audioData = try data.subdata(locator: entry.locator)
                try audioData.write(to: url, options: .atomic)
            }
            urlsByIndex[index] = url
        }
        return AudioCache(directory: directory, urlsByIndex: urlsByIndex)
    }

    static func buildSpriteFrames(
        animations: [SourceAnimation],
        sourceImages: [SourceImage],
        characterWidth: Int,
        characterHeight: Int
    ) throws -> SpriteFrames {
        var images: [CGImage] = []
        var indexesByFrameID: [Int: Int] = [:]
        var indexesByImageStack: [[SourceFrameImage]: Int] = [:]

        for animation in animations {
            for frame in animation.frames {
                if let existingIndex = indexesByImageStack[frame.images] {
                    indexesByFrameID[frame.id] = existingIndex
                    continue
                }

                let spriteIndex = images.count
                let image = try composeFrame(
                    frame,
                    sourceImages: sourceImages,
                    characterWidth: characterWidth,
                    characterHeight: characterHeight
                )
                indexesByImageStack[frame.images] = spriteIndex
                indexesByFrameID[frame.id] = spriteIndex
                images.append(image)
            }
        }

        if images.isEmpty {
            images.append(try makeEmptyImage(width: characterWidth, height: characterHeight))
        }

        return SpriteFrames(images: images, indexesByFrameID: indexesByFrameID)
    }

    static func composeFrame(
        _ frame: SourceFrame,
        sourceImages: [SourceImage],
        characterWidth: Int,
        characterHeight: Int
    ) throws -> CGImage {
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: characterWidth,
            height: characterHeight,
            bitsPerComponent: 8,
            bytesPerRow: characterWidth * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else {
            throw ACSAgentParserError.imageCreationFailed
        }

        context.clear(CGRect(x: 0, y: 0, width: characterWidth, height: characterHeight))
        for frameImage in frame.images.reversed() {
            guard sourceImages.indices.contains(frameImage.imageIndex) else { continue }
            let sourceImage = sourceImages[frameImage.imageIndex]
            let drawRect = CGRect(
                x: frameImage.x,
                y: characterHeight - frameImage.y - sourceImage.height,
                width: sourceImage.width,
                height: sourceImage.height
            )
            context.draw(sourceImage.cgImage, in: drawRect)
        }

        guard let image = context.makeImage() else {
            throw ACSAgentParserError.imageCreationFailed
        }
        return image
    }

    static func makeImage(
        width: Int,
        height: Int,
        stride: Int,
        indexedBitmap: Data,
        palette: [ACSPaletteColor],
        transparentIndex: Int
    ) throws -> CGImage {
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let bytes = [UInt8](indexedBitmap)

        for y in 0..<height {
            let sourceY = height - 1 - y
            for x in 0..<width {
                let paletteIndex = Int(bytes[(sourceY * stride) + x])
                let destination = ((y * width) + x) * 4
                if paletteIndex == transparentIndex || !palette.indices.contains(paletteIndex) {
                    rgba[destination] = 0
                    rgba[destination + 1] = 0
                    rgba[destination + 2] = 0
                    rgba[destination + 3] = 0
                } else {
                    let color = palette[paletteIndex]
                    rgba[destination] = color.red
                    rgba[destination + 1] = color.green
                    rgba[destination + 2] = color.blue
                    rgba[destination + 3] = 255
                }
            }
        }

        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(
                width: width,
                height: height,
                bitsPerComponent: 8,
                bitsPerPixel: 32,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
                provider: provider,
                decode: nil,
                shouldInterpolate: false,
                intent: .defaultIntent
              ) else {
            throw ACSAgentParserError.imageCreationFailed
        }
        return image
    }

    static func makeEmptyImage(width: Int, height: Int) throws -> CGImage {
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ), let image = context.makeImage() else {
            throw ACSAgentParserError.imageCreationFailed
        }
        return image
    }

    static func styleString(from flags: UInt32) -> String {
        var styles: [String] = []
        styles.append(flags & 0x20 != 0 ? "AXS_VOICE" : "AXS_VOICE_NONE")
        if flags & 0x200 != 0 {
            styles.append("AXS_BALLOON_ROUNDRECT")
        }
        return styles.joined(separator: " | ")
    }
}

private struct ACSLocator {
    let offset: Int
    let size: Int
}

private struct ACSPaletteColor {
    let red: UInt8
    let green: UInt8
    let blue: UInt8

    var colorRefString: String {
        String(format: "00%02x%02x%02x", blue, green, red)
    }
}

private struct ACSBinaryReader {
    let data: Data
    var offset: Int = 0

    mutating func seek(to newOffset: Int) throws {
        guard newOffset >= 0, newOffset <= data.count else {
            throw ACSAgentParserError.invalidOffset
        }
        offset = newOffset
    }

    mutating func readUInt8() throws -> UInt8 {
        guard offset + 1 <= data.count else {
            throw ACSAgentParserError.unexpectedEndOfFile
        }
        defer { offset += 1 }
        return data[offset]
    }

    mutating func readBool() throws -> Bool {
        try readUInt8() != 0
    }

    mutating func readUInt16() throws -> UInt16 {
        let b0 = UInt16(try readUInt8())
        let b1 = UInt16(try readUInt8()) << 8
        return b0 | b1
    }

    mutating func readInt16() throws -> Int16 {
        Int16(bitPattern: try readUInt16())
    }

    mutating func readUInt32() throws -> UInt32 {
        let b0 = UInt32(try readUInt8())
        let b1 = UInt32(try readUInt8()) << 8
        let b2 = UInt32(try readUInt8()) << 16
        let b3 = UInt32(try readUInt8()) << 24
        return b0 | b1 | b2 | b3
    }

    mutating func readInt32() throws -> Int32 {
        Int32(bitPattern: try readUInt32())
    }

    mutating func readData(count: Int) throws -> Data {
        guard count >= 0, offset + count <= data.count else {
            throw ACSAgentParserError.unexpectedEndOfFile
        }
        let range = offset..<(offset + count)
        offset += count
        return data.subdata(in: range)
    }

    mutating func readDataBlock() throws -> Data {
        let size = Int(try readUInt32())
        return try readData(count: size)
    }

    mutating func readCompressedBlock() throws -> Data {
        let compressedSize = Int(try readUInt32())
        let uncompressedSize = Int(try readUInt32())
        if compressedSize == 0 {
            return try readData(count: uncompressedSize)
        }
        let compressed = try readData(count: compressedSize)
        return try ACSDecompressor.decompress(compressed, expectedSize: uncompressedSize)
    }

    mutating func skipCompressedBlock() throws {
        let compressedSize = Int(try readUInt32())
        let uncompressedSize = Int(try readUInt32())
        try skip(count: compressedSize == 0 ? uncompressedSize : compressedSize)
    }

    mutating func readLocator() throws -> ACSLocator {
        let offset = Int(try readUInt32())
        let size = Int(try readUInt32())
        return ACSLocator(offset: offset, size: size)
    }

    mutating func skip(count: Int) throws {
        guard count >= 0, offset + count <= data.count else {
            throw ACSAgentParserError.unexpectedEndOfFile
        }
        offset += count
    }

    mutating func readGUIDString() throws -> String {
        let data1 = try readUInt32()
        let data2 = try readUInt16()
        let data3 = try readUInt16()
        var bytes: [UInt8] = []
        bytes.reserveCapacity(8)
        for _ in 0..<8 {
            bytes.append(try readUInt8())
        }
        return String(
            format: "%08X-%04X-%04X-%02X%02X-%02X%02X%02X%02X%02X%02X",
            data1,
            data2,
            data3,
            bytes[0],
            bytes[1],
            bytes[2],
            bytes[3],
            bytes[4],
            bytes[5],
            bytes[6],
            bytes[7]
        )
    }

    mutating func readString() throws -> String {
        let characterCount = Int(try readUInt32())
        guard characterCount > 0 else { return "" }
        let stringData = try readData(count: characterCount * 2)
        if offset + 2 <= data.count {
            let terminatorOffset = offset
            let terminator = try readUInt16()
            if terminator != 0 {
                offset = terminatorOffset
            }
        }
        return String(data: stringData, encoding: .utf16LittleEndian) ?? ""
    }

    mutating func readPaletteColor() throws -> ACSPaletteColor {
        let red = try readUInt8()
        let green = try readUInt8()
        let blue = try readUInt8()
        _ = try readUInt8()
        return ACSPaletteColor(red: red, green: green, blue: blue)
    }

    mutating func readBalloonInfo() throws -> AgentBalloon {
        let lines = Int(try readUInt8())
        let charactersPerLine = Int(try readUInt8())
        let foreground = try readPaletteColor()
        let background = try readPaletteColor()
        let border = try readPaletteColor()
        let fontName = try readString()
        let fontHeight = Int(abs(try readInt32()))
        _ = try readInt32() // font weight
        _ = try readBool() // italic
        _ = try readUInt8()
        return AgentBalloon(
            numberOfLines: lines,
            charactersPerLine: charactersPerLine,
            fontName: fontName,
            fontHeight: fontHeight,
            foregroundColor: foreground.colorRefString,
            backgroundColor: background.colorRefString,
            borderColor: border.colorRefString
        )
    }

    mutating func skipVoiceInfo() throws {
        _ = try readGUIDString()
        _ = try readGUIDString()
        _ = try readUInt32()
        _ = try readUInt16()
        if try readBool() {
            _ = try readUInt16()
            _ = try readString()
            _ = try readUInt16()
            _ = try readUInt16()
            _ = try readString()
        }
    }

    mutating func skipTrayIcon() throws {
        _ = try readDataBlock()
        _ = try readDataBlock()
    }

    mutating func readStates() throws -> [AgentState] {
        let count = Int(try readUInt16())
        var states: [AgentState] = []
        states.reserveCapacity(count)
        for _ in 0..<count {
            let name = try readString()
            let animationCount = Int(try readUInt16())
            var animationNames: [String] = []
            animationNames.reserveCapacity(animationCount)
            for _ in 0..<animationCount {
                animationNames.append(try readString())
            }
            states.append(AgentState(name: name, animationNames: animationNames))
        }
        return states
    }

    mutating func readBranchings() throws -> [AgentBranching] {
        let count = Int(try readUInt8())
        var branchings: [AgentBranching] = []
        branchings.reserveCapacity(count)
        for _ in 0..<count {
            branchings.append(AgentBranching(
                branchTo: Int(try readUInt16()),
                probability: Int(try readUInt16())
            ))
        }
        return branchings
    }

    mutating func skipOverlays() throws {
        let count = Int(try readUInt8())
        for _ in 0..<count {
            _ = try readUInt8()
            _ = try readBool()
            _ = try readUInt16()
            _ = try readUInt8()
            let hasRegionData = try readBool()
            _ = try readInt16()
            _ = try readInt16()
            _ = try readUInt16()
            _ = try readUInt16()
            if hasRegionData {
                _ = try readDataBlock()
            }
        }
    }
}

private struct ACSDecompressor {
    static func decompress(_ data: Data, expectedSize: Int) throws -> Data {
        guard expectedSize >= 0 else {
            throw ACSAgentParserError.invalidCompressedData
        }
        let bytes = [UInt8](data)
        guard !bytes.isEmpty else {
            return Data()
        }

        var bitReader = ACSBitReader(bytes: bytes, bitOffset: bytes.first == 0 ? 8 : 0)
        var output: [UInt8] = []
        output.reserveCapacity(expectedSize)

        while output.count < expectedSize {
            let isRange = try bitReader.readBit() == 1
            if !isRange {
                output.append(UInt8(try bitReader.readBits(8)))
                continue
            }

            var count = 2
            var prefixOnes = 0
            while prefixOnes < 3 {
                if try bitReader.readBit() == 1 {
                    prefixOnes += 1
                } else {
                    break
                }
            }

            let offsetBitCounts = [6, 9, 12, 20]
            let offsetAdditions = [1, 65, 577, 4673]
            let offsetBitCount = offsetBitCounts[prefixOnes]
            let rawOffset = try bitReader.readBits(offsetBitCount)
            if offsetBitCount == 20 && rawOffset == 0x000F_FFFF {
                break
            }

            let copyOffset = rawOffset + offsetAdditions[prefixOnes]
            if offsetBitCount == 20 {
                count += 1
            }

            var countBitCount = 0
            while countBitCount < 11 {
                if try bitReader.readBit() == 1 {
                    countBitCount += 1
                } else {
                    break
                }
            }

            if countBitCount == 11 {
                guard try bitReader.readBit() == 0 else {
                    throw ACSAgentParserError.invalidCompressedData
                }
            }

            count += (1 << countBitCount) - 1
            count += try bitReader.readBits(countBitCount)

            guard copyOffset > 0, copyOffset <= output.count else {
                throw ACSAgentParserError.invalidCompressedData
            }

            for _ in 0..<count {
                output.append(output[output.count - copyOffset])
                if output.count == expectedSize {
                    break
                }
            }
        }

        guard output.count >= expectedSize else {
            throw ACSAgentParserError.invalidCompressedData
        }

        return Data(output.prefix(expectedSize))
    }
}

private struct ACSBitReader {
    let bytes: [UInt8]
    var bitOffset: Int

    mutating func readBit() throws -> Int {
        guard bitOffset < bytes.count * 8 else {
            throw ACSAgentParserError.invalidCompressedData
        }
        let byte = bytes[bitOffset / 8]
        let bit = Int((byte >> UInt8(bitOffset % 8)) & 1)
        bitOffset += 1
        return bit
    }

    mutating func readBits(_ count: Int) throws -> Int {
        guard count >= 0 else {
            throw ACSAgentParserError.invalidCompressedData
        }
        var value = 0
        for index in 0..<count {
            if try readBit() == 1 {
                value |= 1 << index
            }
        }
        return value
    }
}

private extension Data {
    func subdata(locator: ACSLocator) throws -> Data {
        guard locator.offset >= 0,
              locator.size >= 0,
              locator.offset + locator.size <= count else {
            throw ACSAgentParserError.invalidOffset
        }
        return subdata(in: locator.offset..<(locator.offset + locator.size))
    }
}

private extension String {
    func sanitizedFileComponent() -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let scalars = unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" }
        let value = String(scalars)
        return value.isEmpty ? "agent" : value
    }
}
