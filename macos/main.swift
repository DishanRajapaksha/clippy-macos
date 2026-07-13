//
//  main.swift
//  Clippy macOS
//
//  Created by Devran on 08.09.19.
//  Copyright © 2019 Devran. All rights reserved.
//

import Cocoa
import Foundation
import UniformTypeIdentifiers
#if canImport(AppIntents)
import AppIntents
#endif

enum ClippyAutomationCommand: Equatable {
    case show
    case say(String)
    case animate(String?)
    case agent(String)
}

enum ClippyAutomationError: LocalizedError {
    case invalidURL
    case unsupportedAction(String)
    case missingValue(String)
    case valueTooLong(String, Int)
    case noAgentsAvailable
    case agentNotFound(String)
    case animationNotFound(String)
    case automationUnavailable

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "The Clippy automation URL is invalid."
        case .unsupportedAction(let action):
            return "The automation action \"\(action)\" is not supported."
        case .missingValue(let name):
            return "The automation action requires a non-empty \(name)."
        case .valueTooLong(let name, let limit):
            return "The \(name) is longer than the \(limit)-character limit."
        case .noAgentsAvailable:
            return "No Clippy agents are installed."
        case .agentNotFound(let name):
            return "The agent \"\(name)\" was not found."
        case .animationNotFound(let name):
            return "The animation \"\(name)\" was not found for the current agent."
        case .automationUnavailable:
            return "Clippy has not finished launching."
        }
    }
}

final class ClippyAutomation {
    static let shared = ClippyAutomation()

    private struct PendingCommand {
        let command: ClippyAutomationCommand
        let completion: ((Result<Void, Error>) -> Void)?
    }

    private weak var delegate: ClippyAppDelegate?
    private var pendingCommands: [PendingCommand] = []
    private var speechPopover: NSPopover?
    private var speechDismissWorkItem: DispatchWorkItem?

    private init() {}

    func attach(delegate: ClippyAppDelegate) {
        dispatchPrecondition(condition: .onQueue(.main))
        self.delegate = delegate

        let pending = pendingCommands
        pendingCommands.removeAll()
        for command in pending {
            perform(command)
        }
    }

    func handle(url: URL) {
        do {
            enqueue(try command(from: url)) { [weak self] result in
                if case .failure(let error) = result {
                    self?.report(error: error)
                }
            }
        } catch {
            report(error: error)
        }
    }

    func execute(_ command: ClippyAutomationCommand) async throws {
        try await withCheckedThrowingContinuation { continuation in
            enqueue(command) { result in
                continuation.resume(with: result)
            }
        }
    }

    private func enqueue(
        _ command: ClippyAutomationCommand,
        completion: ((Result<Void, Error>) -> Void)? = nil
    ) {
        DispatchQueue.main.async {
            let pending = PendingCommand(command: command, completion: completion)
            guard self.delegate != nil else {
                self.pendingCommands.append(pending)
                return
            }
            self.perform(pending)
        }
    }

    private func perform(_ pending: PendingCommand) {
        do {
            try perform(pending.command)
            pending.completion?(.success(()))
        } catch {
            pending.completion?(.failure(error))
        }
    }

    private func perform(_ command: ClippyAutomationCommand) throws {
        guard let delegate = delegate else {
            throw ClippyAutomationError.automationUnavailable
        }

        switch command {
        case .show:
            show(delegate: delegate)

        case .say(let text):
            show(delegate: delegate)
            try showSpeech(text: text)

        case .animate(let requestedName):
            let controller = try controllerWithLoadedAgent(delegate: delegate)
            show(delegate: delegate)
            if let requestedName = requestedName {
                guard let animation = controller.agent?.findAnimation(requestedName) else {
                    throw ClippyAutomationError.animationNotFound(requestedName)
                }
                controller.play(animation: animation)
            } else {
                controller.animate()
            }

        case .agent(let requestedName):
            let availableNames = Agent.agentNames()
            guard let name = availableNames.first(where: {
                $0.caseInsensitiveCompare(requestedName) == .orderedSame
            }) else {
                throw ClippyAutomationError.agentNotFound(requestedName)
            }

            guard let controller = AppDelegate.agentController else {
                throw ClippyAutomationError.automationUnavailable
            }
            try controller.load(name: name)
            show(delegate: delegate)
        }
    }

    private func show(delegate: ClippyAppDelegate) {
        if let controller = AppDelegate.agentController {
            if controller.agent == nil {
                _ = try? loadDefaultAgent(into: controller, delegate: delegate)
            }
            controller.show()
        } else {
            NSApp.unhide(delegate)
            NSApp.activate(ignoringOtherApps: true)
            delegate.window?.makeKeyAndOrderFront(delegate)
        }
    }

    private func controllerWithLoadedAgent(delegate: ClippyAppDelegate) throws -> AgentController {
        guard let controller = AppDelegate.agentController else {
            throw ClippyAutomationError.automationUnavailable
        }
        if controller.agent == nil {
            try loadDefaultAgent(into: controller, delegate: delegate)
        }
        return controller
    }

    private func loadDefaultAgent(into controller: AgentController, delegate: ClippyAppDelegate) throws {
        let names = Agent.agentNames()
        guard !names.isEmpty else {
            throw ClippyAutomationError.noAgentsAvailable
        }

        if let lastUsed = delegate.lastUsedAgent,
           let matchingName = names.first(where: {
               $0.caseInsensitiveCompare(lastUsed) == .orderedSame
           }) {
            try controller.load(name: matchingName)
            return
        }

        if let randomName = Agent.randomAgentName() {
            try controller.load(name: randomName)
            return
        }

        throw ClippyAutomationError.noAgentsAvailable
    }

    private func showSpeech(text: String) throws {
        guard let controller = AppDelegate.agentController,
              let agentView = controller.agentView else {
            throw ClippyAutomationError.automationUnavailable
        }

        speechDismissWorkItem?.cancel()
        speechPopover?.close()

        let bubbleController = BalloonViewController(text: text, balloon: controller.agent?.balloon)
        let popover = NSPopover()
        popover.behavior = .semitransient
        popover.contentSize = bubbleController.contentSize
        popover.animates = true
        popover.contentViewController = bubbleController
        popover.show(
            relativeTo: agentView.bounds,
            of: agentView,
            preferredEdge: preferredSpeechEdge(for: bubbleController.contentSize, agentView: agentView)
        )
        speechPopover = popover

        let readingTime = min(10.0, max(2.2, Double(text.count) / 18.0))
        let workItem = DispatchWorkItem { [weak self] in
            self?.speechPopover?.close()
            self?.speechPopover = nil
        }
        speechDismissWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + readingTime, execute: workItem)
    }

    private func preferredSpeechEdge(for size: CGSize, agentView: NSView) -> NSRectEdge {
        guard let window = agentView.window,
              let screen = window.screen ?? NSScreen.main else {
            return .maxY
        }

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

    func command(from url: URL) throws -> ClippyAutomationCommand {
        guard url.scheme?.caseInsensitiveCompare("clippy") == .orderedSame,
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else {
            throw ClippyAutomationError.invalidURL
        }

        let pathParts = url.path
            .split(separator: "/")
            .map(String.init)
        let host = url.host?.trimmingCharacters(in: .whitespacesAndNewlines)
        let action: String
        let pathValue: String?

        if let host = host, !host.isEmpty {
            action = host.lowercased()
            pathValue = pathParts.isEmpty ? nil : pathParts.joined(separator: "/")
        } else if let first = pathParts.first {
            action = first.lowercased()
            pathValue = pathParts.count > 1
                ? pathParts.dropFirst().joined(separator: "/")
                : nil
        } else {
            throw ClippyAutomationError.invalidURL
        }

        func queryValue(_ name: String) -> String? {
            components.queryItems?
                .first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame })?
                .value
        }

        switch action {
        case "show":
            return .show
        case "say":
            return .say(try validatedValue(queryValue("text") ?? pathValue, name: "text", limit: 1_000))
        case "animate":
            let requestedName = try optionalValidatedValue(
                queryValue("name") ?? queryValue("animation") ?? pathValue,
                name: "animation name",
                limit: 128
            )
            return .animate(requestedName)
        case "agent":
            return .agent(try validatedValue(queryValue("name") ?? pathValue, name: "agent name", limit: 128))
        default:
            throw ClippyAutomationError.unsupportedAction(action)
        }
    }

    private func validatedValue(_ value: String?, name: String, limit: Int) throws -> String {
        guard let value = try optionalValidatedValue(value, name: name, limit: limit) else {
            throw ClippyAutomationError.missingValue(name)
        }
        return value
    }

    private func optionalValidatedValue(_ value: String?, name: String, limit: Int) throws -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        guard value.count <= limit else {
            throw ClippyAutomationError.valueTooLong(name, limit)
        }
        return value
    }

    private func report(error: Error) {
        DispatchQueue.main.async {
            let message = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
            if let delegate = self.delegate {
                delegate.presentAlert(title: "Clippy Automation", message: message)
            } else {
                NSLog("Clippy Automation: %@", message)
            }
        }
    }
}

#if canImport(AppIntents)
@available(macOS 13.0, *)
struct ShowClippyIntent: AppIntent {
    static var title: LocalizedStringResource = "Show Clippy"
    static var description = IntentDescription("Shows the current Clippy agent.")
    static var openAppWhenRun: Bool { true }

    func perform() async throws -> some IntentResult {
        try await ClippyAutomation.shared.execute(.show)
        return .result()
    }
}

@available(macOS 13.0, *)
struct SayWithClippyIntent: AppIntent {
    static var title: LocalizedStringResource = "Make Clippy Say"
    static var description = IntentDescription("Shows a speech bubble containing the supplied text.")
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Text")
    var text: String

    func perform() async throws -> some IntentResult {
        try await ClippyAutomation.shared.execute(.say(text))
        return .result()
    }
}

@available(macOS 13.0, *)
struct AnimateClippyIntent: AppIntent {
    static var title: LocalizedStringResource = "Animate Clippy"
    static var description = IntentDescription("Plays a named animation, or a random one when no name is supplied.")
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Animation", description: "Leave empty to play a random animation.")
    var animation: String?

    func perform() async throws -> some IntentResult {
        try await ClippyAutomation.shared.execute(.animate(animation))
        return .result()
    }
}

@available(macOS 13.0, *)
struct SelectClippyAgentIntent: AppIntent {
    static var title: LocalizedStringResource = "Select Clippy Agent"
    static var description = IntentDescription("Switches Clippy to an installed Microsoft Agent character.")
    static var openAppWhenRun: Bool { true }

    @Parameter(title: "Agent")
    var agent: String

    func perform() async throws -> some IntentResult {
        try await ClippyAutomation.shared.execute(.agent(agent))
        return .result()
    }
}

@available(macOS 13.0, *)
struct ClippyAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ShowClippyIntent(),
            phrases: ["Show \(.applicationName)", "Bring back \(.applicationName)"],
            shortTitle: "Show Clippy",
            systemImageName: "paperclip"
        )
        AppShortcut(
            intent: SayWithClippyIntent(),
            phrases: ["Make \(.applicationName) say \(\.$text)"],
            shortTitle: "Clippy Says",
            systemImageName: "text.bubble"
        )
        AppShortcut(
            intent: AnimateClippyIntent(),
            phrases: ["Animate \(.applicationName)"],
            shortTitle: "Animate Clippy",
            systemImageName: "sparkles"
        )
        AppShortcut(
            intent: SelectClippyAgentIntent(),
            phrases: ["Use \(\.$agent) in \(.applicationName)"],
            shortTitle: "Select Agent",
            systemImageName: "person.crop.circle"
        )
    }
}
#endif

final class ClippyAppDelegate: AppDelegate {
    private let backgroundAgentImporter = AgentImporter()
    private var isImportingAgents = false

    override func applicationDidFinishLaunching(_ aNotification: Notification) {
        super.applicationDidFinishLaunching(aNotification)
        ClippyAutomation.shared.attach(delegate: self)
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            ClippyAutomation.shared.handle(url: url)
        }
    }

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

private enum AutomationSelfTest {
    static func run() -> Int32 {
        let cases: [(String, ClippyAutomationCommand)] = [
            ("clippy://show", .show),
            ("clippy://say?text=Build%20finished", .say("Build finished")),
            ("clippy://say/Hello%20there", .say("Hello there")),
            ("clippy://animate", .animate(nil)),
            ("clippy://animate/Congratulate", .animate("Congratulate")),
            ("clippy://agent?name=merlin", .agent("merlin"))
        ]

        do {
            for (rawURL, expected) in cases {
                guard let url = URL(string: rawURL) else {
                    throw SelfTestError.invalidFixture(rawURL)
                }
                let actual = try ClippyAutomation.shared.command(from: url)
                guard actual == expected else {
                    throw SelfTestError.unexpectedCommand(rawURL)
                }
            }

            let rejectedURLs = [
                "https://example.com/show",
                "clippy://say",
                "clippy://agent",
                "clippy://unknown"
            ]
            for rawURL in rejectedURLs {
                guard let url = URL(string: rawURL) else {
                    throw SelfTestError.invalidFixture(rawURL)
                }
                guard (try? ClippyAutomation.shared.command(from: url)) == nil else {
                    throw SelfTestError.expectedRejection(rawURL)
                }
            }

            print("Clippy automation URL tests passed")
            return 0
        } catch {
            fputs("Clippy automation URL tests failed: \(error)\n", stderr)
            return 1
        }
    }

    private enum SelfTestError: LocalizedError {
        case invalidFixture(String)
        case unexpectedCommand(String)
        case expectedRejection(String)

        var errorDescription: String? {
            switch self {
            case .invalidFixture(let value):
                return "invalid test URL: \(value)"
            case .unexpectedCommand(let value):
                return "unexpected command parsed from \(value)"
            case .expectedRejection(let value):
                return "URL was unexpectedly accepted: \(value)"
            }
        }
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

if CommandLine.arguments.contains("--self-test-automation") {
    exit(AutomationSelfTest.run())
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
