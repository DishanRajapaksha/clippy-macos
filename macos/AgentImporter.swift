//
//  AgentImporter.swift
//  Clippy macOS
//
//  Handles importing user-provided agent files into Application Support.
//

import Foundation

struct AgentImportOutcome {
    var imported: [String] = []
    var failures: [String] = []
}

enum AgentImportError: LocalizedError {
    case unsupportedFileType
    case unsafeArchiveEntry(String)
    case archiveExtractionFailed(Int32)
    case noAgentInArchive
    case copiedAgentCouldNotLoad(String)

    var errorDescription: String? {
        switch self {
        case .unsupportedFileType:
            return "unsupported file type"
        case .unsafeArchiveEntry(let entry):
            return "archive contains an unsafe path: \(entry)"
        case .archiveExtractionFailed(let status):
            return "archive extraction failed with status \(status)"
        case .noAgentInArchive:
            return "archive did not contain a supported .agent folder or .acs file"
        case .copiedAgentCouldNotLoad(let reason):
            return "agent files were copied but could not be loaded: \(reason)"
        }
    }
}

final class AgentImporter {
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
            return [try copyCandidate(url)]
        }
        throw AgentImportError.unsupportedFileType
    }

    private func importArchive(from url: URL) throws -> [String] {
        try validateArchiveEntries(url)

        let tempRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try fileManager.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer {
            try? fileManager.removeItem(at: tempRoot)
        }

        let process = try Process.run(URL(fileURLWithPath: "/usr/bin/unzip"),
                                      arguments: ["-q", url.path, "-d", tempRoot.path])
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw AgentImportError.archiveExtractionFailed(process.terminationStatus)
        }

        let candidates = try archiveCandidates(in: tempRoot)
        guard !candidates.isEmpty else {
            throw AgentImportError.noAgentInArchive
        }
        return try candidates.map { try copyCandidate($0) }
    }

    private func validateArchiveEntries(_ url: URL) throws {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/unzip")
        process.arguments = ["-Z1", url.path]
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw AgentImportError.archiveExtractionFailed(process.terminationStatus)
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let listing = String(data: data, encoding: .utf8) ?? ""
        for entry in listing.split(separator: "\n").map(String.init) {
            if entry.hasPrefix("/") || entry.contains("../") || entry == ".." || entry.hasPrefix("..") {
                throw AgentImportError.unsafeArchiveEntry(entry)
            }
        }
    }

    private func archiveCandidates(in root: URL) throws -> [URL] {
        guard let enumerator = fileManager.enumerator(at: root,
                                                      includingPropertiesForKeys: [.isDirectoryKey],
                                                      options: [.skipsHiddenFiles]) else {
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

    private func copyCandidate(_ url: URL) throws -> String {
        let destination = Agent.agentsURL().appendingPathComponent(url.lastPathComponent)
        if fileManager.fileExists(atPath: destination.path) {
            try fileManager.removeItem(at: destination)
        }
        try fileManager.copyItem(at: url, to: destination)

        let name = normalizedAgentName(from: destination)
        let status = Agent.agentStatus(for: destination)
        if !status.isSupported {
            if destination.pathExtension.lowercased() == "acs" {
                return name
            }
            let reason = status.reason ?? "unknown load error"
            try? fileManager.removeItem(at: destination)
            throw AgentImportError.copiedAgentCouldNotLoad(reason)
        }
        return name
    }

    private func normalizedAgentName(from url: URL) -> String {
        var name = url.deletingPathExtension().lastPathComponent
        if name.hasSuffix(".agent") {
            name = String(name.dropLast(".agent".count))
        }
        return name
    }
}
