//
//  main.swift
//  Clippy macOS
//
//  Created by Devran on 08.09.19.
//  Copyright © 2019 Devran. All rights reserved.
//

import Cocoa
import Foundation

final class ClippyAppDelegate: AppDelegate {
    private let backgroundAgentImporter = AgentImporter()
    private var isImportingAgents = false

    @objc override func importAgentAction(sender: AnyObject) {
        guard !isImportingAgents else {
            presentAlert(title: "Import in Progress", message: "Clippy is already importing an agent.")
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.zip, UTType(filenameExtension: "agent"), UTType(filenameExtension: "acs")].compactMap { $0 }
        panel.prompt = "Import"

        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        isImportingAgents = true
        statusItem?.button?.title = "⏳"

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let outcome = autoreleasepool {
                self.backgroundAgentImporter.importAgents(from: urls)
            }

            DispatchQueue.main.async {
                self.isImportingAgents = false
                self.statusItem?.button?.title = "📎"
                self.reloadAction(sender: self)
                self.presentImportOutcome(outcome)
            }
        }
    }

    private func presentImportOutcome(_ outcome: AgentImportOutcome) {
        guard !outcome.imported.isEmpty || !outcome.failures.isEmpty else { return }
        let title = outcome.failures.isEmpty ? "Import Complete" : "Import Finished With Issues"
        var lines: [String] = []
        if !outcome.imported.isEmpty {
            lines.append("Imported: \(outcome.imported.sorted().joined(separator: ", "))")
        }
        if !outcome.failures.isEmpty {
            lines.append("Failed:\n\(outcome.failures.joined(separator: "\n"))")
        }
        presentAlert(title: title, message: lines.joined(separator: "\n\n"))
    }
}

private enum SafetySelfTest {
    static func run() -> Int32 {
        let fileManager = FileManager.default
        let root = fileManager.temporaryDirectory.appendingPathComponent("clippy-safety-tests-\(UUID().uuidString)", isDirectory: true)

        do {
            try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? fileManager.removeItem(at: root) }

            try expectRejected(Data([0x00, 0x00, 0x00, 0x00]), named: "invalid-signature.acs", in: root)
            try expectRejected(signatureData(), named: "truncated-header.acs", in: root)
            try expectRejected(invalidLocatorData(), named: "invalid-locator.acs", in: root)
            try expectRejected(oversizedCharacterData(), named: "oversized-character.acs", in: root)
            try verifyUnsupportedImport(in: root)
            try fuzzMalformedACSFiles(in: root, iterations: 256)

            print("Clippy parser safety tests passed")
            return 0
        } catch {
            fputs("Clippy parser safety tests failed: \(error)\n", stderr)
            return 1
        }
    }

    private static func expectRejected(_ data: Data, named name: String, in root: URL) throws {
        let url = root.appendingPathComponent(name)
        try data.write(to: url, options: .atomic)
        let status = Agent.agentStatus(for: url)
        guard !status.isSupported else {
            throw SelfTestError.expectedRejection(name)
        }
    }

    private static func verifyUnsupportedImport(in root: URL) throws {
        let url = root.appendingPathComponent("unsupported-import.acs")
        try signatureData().write(to: url, options: .atomic)
        let outcome = AgentImporter().importAgents(from: [url])
        guard outcome.imported.isEmpty, outcome.failures.count == 1 else {
            throw SelfTestError.unsupportedImportReportedAsSuccess
        }
    }

    private static func fuzzMalformedACSFiles(in root: URL, iterations: Int) throws {
        var generator = DeterministicGenerator(state: 0xC11F_F00D_5AFE_BAAD)
        for index in 0..<iterations {
            let length = max(4, Int(generator.next() % 4096))
            var bytes = [UInt8](repeating: 0, count: length)
            for byteIndex in bytes.indices {
                bytes[byteIndex] = UInt8(truncatingIfNeeded: generator.next())
            }
            bytes[0] = 0xC3
            bytes[1] = 0xAB
            bytes[2] = 0xCD
            bytes[3] = 0xAB

            let url = root.appendingPathComponent("fuzz-\(index).acs")
            try Data(bytes).write(to: url, options: .atomic)
            _ = Agent.agentStatus(for: url)
            try fileManager.removeItem(at: url)
        }
    }

    private static var fileManager: FileManager {
        FileManager.default
    }

    private static func signatureData() -> Data {
        var data = Data()
        append(UInt32(0xABCDABC3), to: &data)
        return data
    }

    private static func invalidLocatorData() -> Data {
        var data = Data()
        append(UInt32(0xABCDABC3), to: &data)
        append(UInt32.max, to: &data)
        append(UInt32(1), to: &data)
        for _ in 0..<3 {
            append(UInt32(0), to: &data)
            append(UInt32(0), to: &data)
        }
        return data
    }

    private static func oversizedCharacterData() -> Data {
        var data = Data()
        append(UInt32(0xABCDABC3), to: &data)
        append(UInt32(36), to: &data)
        append(UInt32(32), to: &data)
        for _ in 0..<3 {
            append(UInt32(0), to: &data)
            append(UInt32(0), to: &data)
        }

        append(UInt16(0), to: &data)
        append(UInt16(0), to: &data)
        append(UInt32(0), to: &data)
        append(UInt32(0), to: &data)
        data.append(Data(repeating: 0, count: 16))
        append(UInt16(4096), to: &data)
        append(UInt16(32), to: &data)
        return data
    }

    private static func append<T: FixedWidthInteger>(_ value: T, to data: inout Data) {
        var littleEndian = value.littleEndian
        withUnsafeBytes(of: &littleEndian) { bytes in
            data.append(contentsOf: bytes)
        }
    }

    private struct DeterministicGenerator {
        var state: UInt64

        mutating func next() -> UInt64 {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            return state
        }
    }

    private enum SelfTestError: LocalizedError {
        case expectedRejection(String)
        case unsupportedImportReportedAsSuccess

        var errorDescription: String? {
            switch self {
            case .expectedRejection(let name):
                return "\(name) was unexpectedly accepted"
            case .unsupportedImportReportedAsSuccess:
                return "an unsupported ACS import was reported as successful"
            }
        }
    }
}

if CommandLine.arguments.contains("--self-test-parser") {
    exit(SafetySelfTest.run())
}

autoreleasepool {
    let application = NSApplication.shared
    let delegate = ClippyAppDelegate()
    application.delegate = delegate
    application.setActivationPolicy(.accessory)
    application.run()
}
