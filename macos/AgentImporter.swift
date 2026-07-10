//
//  AgentImporter.swift
//  Clippy macOS
//
//  Handles importing user-provided agent files into Application Support.
//

import AppKit
import Foundation

struct AgentImportOutcome {
    var imported: [String] = []
    var failures: [String] = []
}

enum AgentImportConflictResolution {
    case replace
    case keepBoth
    case cancel
}

enum AgentImportError: LocalizedError {
    case unsupportedFileType
    case unsafeArchiveEntry(String)
    case archiveExtractionFailed(Int32)
    case archiveTooLarge(String)
    case archiveContainsTooManyEntries(Int)
    case noAgentInArchive
    case copiedAgentCouldNotLoad(String)
    case importCancelled

    var errorDescription: String? {
        switch self {
        case .unsupportedFileType:
            return "unsupported file type"
        case .unsafeArchiveEntry(let entry):
            return "archive contains an unsafe entry: \(entry)"
        case .archiveExtractionFailed(let status):
            return "archive extraction failed with status \(status)"
        case .archiveTooLarge(let detail):
            return "archive exceeds the import limit: \(detail)"
        case .archiveContainsTooManyEntries(let count):
            return "archive contains too many entries (\(count))"
        case .noAgentInArchive:
            return "archive did not contain a supported .agent folder or .acs file"
        case .copiedAgentCouldNotLoad(let reason):
            return "agent could not be loaded: \(reason)"
        case .importCancelled:
            return "import cancelled"
        }
    }
}

final class AgentImporter {
    private struct ArchiveEntry {
        let path: String
        let uncompressedSize: Int64
    }

    private enum Limits {
        static let maximumArchiveBytes: Int64 = 100 * 1024 * 1024
        static let maximumExpandedBytes: Int64 = 250 * 1024 * 1024
        static let maximumEntryBytes: Int64 = 64 * 1024 * 1024
        static let maximumEntryCount = 2_000
        static let maximumPathLength = 1_024
    }

    private let fileManager: FileManager

    init(fileManager: FileManager = .default) {
        self.fileManager = fileManager
    }

    func importAgents(from urls: [URL]) -> AgentImportOutcome {
        var outcome = AgentImportOutcome()
        for url in urls {
            do {
                let names = try importAgent(from: url)
                outcome.imported.append(contentsOf: names)
            } catch {
                outcome.failures.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        outcome.imported = Array(Set(outcome.imported)).sorted()
        return outcome
    }

    private func importAgent(from url: URL) throws -> [String] {
        let pathExtension = url.pathExtension.lowercased()
        if pathExtension == "zip" {
            return try importArchive(from: url)
        }
        if pathExtension == "acs" || pathExtension == "agent" || url.hasDirectoryPath {
            let stagingRoot = try makeTemporaryDirectory()
            defer { try? fileManager.removeItem(at: stagingRoot) }
            let stagedURL = stagingRoot.appendingPathComponent(url.lastPathComponent, isDirectory: url.hasDirectoryPath)
            try fileManager.copyItem(at: url, to: stagedURL)
            try validateExtractedTree(at: stagingRoot)
            return [try installCandidate(stagedURL)]
        }
        throw AgentImportError.unsupportedFileType
    }

    private func importArchive(from url: URL) throws -> [String] {
        let archiveSize = try fileSize(at: url)
        guard archiveSize <= Limits.maximumArchiveBytes else {
            throw AgentImportError.archiveTooLarge("compressed file is \(formattedBytes(archiveSize))")
        }

        let entries = try archiveEntries(in: url)
        guard entries.count <= Limits.maximumEntryCount else {
            throw AgentImportError.archiveContainsTooManyEntries(entries.count)
        }

        var expandedBytes: Int64 = 0
        for entry in entries {
            try validateArchivePath(entry.path)
            guard entry.uncompressedSize <= Limits.maximumEntryBytes else {
                throw AgentImportError.archiveTooLarge("\(entry.path) expands to \(formattedBytes(entry.uncompressedSize))")
            }
            let (sum, overflow) = expandedBytes.addingReportingOverflow(entry.uncompressedSize)
            guard !overflow, sum <= Limits.maximumExpandedBytes else {
                throw AgentImportError.archiveTooLarge("expanded contents exceed \(formattedBytes(Limits.maximumExpandedBytes))")
            }
            expandedBytes = sum
        }

        let tempRoot = try makeTemporaryDirectory()
        defer { try? fileManager.removeItem(at: tempRoot) }

        let status = try runProcess("/usr/bin/unzip", arguments: ["-q", url.path, "-d", tempRoot.path]).status
        guard status == 0 else {
            throw AgentImportError.archiveExtractionFailed(status)
        }

        try validateExtractedTree(at: tempRoot)
        let candidates = try archiveCandidates(in: tempRoot)
        guard !candidates.isEmpty else {
            throw AgentImportError.noAgentInArchive
        }
        return try candidates.map { try installCandidate($0) }
    }

    private func archiveEntries(in url: URL) throws -> [ArchiveEntry] {
        let result = try runProcess("/usr/bin/unzip", arguments: ["-l", url.path])
        guard result.status == 0 else {
            throw AgentImportError.archiveExtractionFailed(result.status)
        }

        let listing = String(data: result.output, encoding: .utf8) ?? ""
        var entries: [ArchiveEntry] = []
        for line in listing.split(separator: "\n", omittingEmptySubsequences: false) {
            let parts = line.split(maxSplits: 3, whereSeparator: { $0.isWhitespace })
            guard parts.count == 4, let size = Int64(parts[0]) else { continue }
            let path = String(parts[3])
            entries.append(ArchiveEntry(path: path, uncompressedSize: size))
        }
        return entries
    }

    private func validateArchivePath(_ entry: String) throws {
        guard !entry.isEmpty,
              entry.count <= Limits.maximumPathLength,
              !entry.hasPrefix("/"),
              !entry.hasPrefix("\\"),
              !entry.contains("\0") else {
            throw AgentImportError.unsafeArchiveEntry(entry)
        }

        let components = entry.replacingOccurrences(of: "\\", with: "/").split(separator: "/")
        guard !components.contains("..") else {
            throw AgentImportError.unsafeArchiveEntry(entry)
        }
        if let first = components.first, first.contains(":") {
            throw AgentImportError.unsafeArchiveEntry(entry)
        }
    }

    private func validateExtractedTree(at root: URL) throws {
        let rootPath = root.standardizedFileURL.path
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        var fileCount = 0
        var totalSize: Int64 = 0
        for case let item as URL in enumerator {
            let standardisedPath = item.standardizedFileURL.path
            guard standardisedPath == rootPath || standardisedPath.hasPrefix(rootPath + "/") else {
                throw AgentImportError.unsafeArchiveEntry(item.path)
            }

            let values = try item.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true else {
                throw AgentImportError.unsafeArchiveEntry(item.lastPathComponent)
            }
            guard values.isRegularFile == true else { continue }

            fileCount += 1
            guard fileCount <= Limits.maximumEntryCount else {
                throw AgentImportError.archiveContainsTooManyEntries(fileCount)
            }

            let size = Int64(values.fileSize ?? 0)
            guard size <= Limits.maximumEntryBytes else {
                throw AgentImportError.archiveTooLarge("\(item.lastPathComponent) is \(formattedBytes(size))")
            }
            let (sum, overflow) = totalSize.addingReportingOverflow(size)
            guard !overflow, sum <= Limits.maximumExpandedBytes else {
                throw AgentImportError.archiveTooLarge("expanded contents exceed \(formattedBytes(Limits.maximumExpandedBytes))")
            }
            totalSize = sum
        }
    }

    private func archiveCandidates(in root: URL) throws -> [URL] {
        guard let enumerator = fileManager.enumerator(
            at: root,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var candidates: [URL] = []
        for case let item as URL in enumerator {
            let values = try? item.resourceValues(forKeys: [.isDirectoryKey])
            let isDirectory = values?.isDirectory ?? item.hasDirectoryPath
            let ext = item.pathExtension.lowercased()
            if isDirectory && ext == "agent" {
                candidates.append(item)
                enumerator.skipDescendants()
            } else if !isDirectory && ext == "acs" {
                candidates.append(item)
            }
        }
        return candidates
    }

    private func installCandidate(_ stagedURL: URL) throws -> String {
        let stagedStatus = Agent.agentStatus(for: stagedURL)
        guard stagedStatus.isSupported else {
            throw AgentImportError.copiedAgentCouldNotLoad(stagedStatus.reason ?? "unknown load error")
        }

        let agentsRoot = Agent.agentsURL()
        var destination = agentsRoot.appendingPathComponent(stagedURL.lastPathComponent, isDirectory: stagedURL.hasDirectoryPath)
        let destinationExists = fileManager.fileExists(atPath: destination.path)
        var shouldReplace = false

        if destinationExists {
            switch resolveConflict(for: stagedURL.lastPathComponent) {
            case .replace:
                shouldReplace = true
            case .keepBoth:
                destination = uniqueDestination(for: destination)
            case .cancel:
                throw AgentImportError.importCancelled
            }
        }

        let incoming = agentsRoot.appendingPathComponent(".clippy-import-\(UUID().uuidString)-\(destination.lastPathComponent)")
        defer { try? fileManager.removeItem(at: incoming) }
        try fileManager.copyItem(at: stagedURL, to: incoming)
        if incoming.hasDirectoryPath {
            try validateExtractedTree(at: incoming)
        } else {
            let size = try fileSize(at: incoming)
            guard size <= Limits.maximumEntryBytes else {
                throw AgentImportError.archiveTooLarge("\(incoming.lastPathComponent) is \(formattedBytes(size))")
            }
        }

        let incomingStatus = Agent.agentStatus(for: incoming)
        guard incomingStatus.isSupported else {
            throw AgentImportError.copiedAgentCouldNotLoad(incomingStatus.reason ?? "unknown load error")
        }

        if shouldReplace {
            try replaceItem(at: destination, with: incoming)
        } else {
            try fileManager.moveItem(at: incoming, to: destination)
        }

        return normalizedAgentName(from: destination)
    }

    private func replaceItem(at destination: URL, with incoming: URL) throws {
        let backup = destination.deletingLastPathComponent()
            .appendingPathComponent(".clippy-backup-\(UUID().uuidString)-\(destination.lastPathComponent)")
        try fileManager.moveItem(at: destination, to: backup)
        do {
            try fileManager.moveItem(at: incoming, to: destination)
            try? fileManager.removeItem(at: backup)
        } catch {
            try? fileManager.removeItem(at: destination)
            try? fileManager.moveItem(at: backup, to: destination)
            throw error
        }
    }

    private func resolveConflict(for name: String) -> AgentImportConflictResolution {
        let prompt = {
            let alert = NSAlert()
            alert.messageText = "An agent named \"\(name)\" already exists."
            alert.informativeText = "Replace the existing agent, keep both copies, or cancel this import."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Replace")
            alert.addButton(withTitle: "Keep Both")
            alert.addButton(withTitle: "Cancel")
            switch alert.runModal() {
            case .alertFirstButtonReturn:
                return AgentImportConflictResolution.replace
            case .alertSecondButtonReturn:
                return AgentImportConflictResolution.keepBoth
            default:
                return AgentImportConflictResolution.cancel
            }
        }

        if Thread.isMainThread {
            return prompt()
        }
        return DispatchQueue.main.sync(execute: prompt)
    }

    private func uniqueDestination(for destination: URL) -> URL {
        let directory = destination.deletingLastPathComponent()
        let ext = destination.pathExtension
        let stem = destination.deletingPathExtension().lastPathComponent
        var suffix = 2
        var candidate = destination
        while fileManager.fileExists(atPath: candidate.path) {
            let name = ext.isEmpty ? "\(stem) \(suffix)" : "\(stem) \(suffix).\(ext)"
            candidate = directory.appendingPathComponent(name, isDirectory: destination.hasDirectoryPath)
            suffix += 1
        }
        return candidate
    }

    private func makeTemporaryDirectory() throws -> URL {
        let directory = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    private func fileSize(at url: URL) throws -> Int64 {
        let values = try url.resourceValues(forKeys: [.fileSizeKey])
        return Int64(values.fileSize ?? 0)
    }

    private func runProcess(_ executable: String, arguments: [String]) throws -> (status: Int32, output: Data) {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, output)
    }

    private func formattedBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func normalizedAgentName(from url: URL) -> String {
        var name = url.deletingPathExtension().lastPathComponent
        if name.hasSuffix(".agent") {
            name = String(name.dropLast(".agent".count))
        }
        return name
    }
}
