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
import Darwin

enum AgentControllerError: LocalizedError {
    case agentCouldNotLoad(String)

    var errorDescription: String? {
        switch self {
        case .agentCouldNotLoad(let name):
            return "The agent \"\(name)\" could not be loaded."
        }
    }
}

struct AgentResourceSnapshot {
    let currentAnimationName: String?
    let renderedFrameCount: UInt64
    let framesPerSecond: Double
    let textureCacheBytes: UInt64
    let preparationWorkSeconds: TimeInterval
    let isAnimating: Bool
}

class AgentController {
    static let autoAnimateIntervalDefaultsKey = "AutoAnimateIntervalSeconds"
    static let defaultAutoAnimateInterval: TimeInterval = 12.0
    static let randomAutoAnimateInterval: TimeInterval = -1
    static let randomAutoAnimateRange: ClosedRange<TimeInterval> = 5...60
    static let muteDefaultsKey = "IsMuted"

    var isMuted = false
    var configuredAutoAnimateInterval = AgentController.defaultAutoAnimateInterval
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
    private let metricsLock = NSLock()
    private var currentAnimationName: String?
    private var renderedFrameCount: UInt64 = 0
    private var recentFrameTimestamps: [TimeInterval] = []
    private var textureCacheBytes: UInt64 = 0
    private var preparationWorkSeconds: TimeInterval = 0

    var delegate: AgentControllerDelegate?
    var isHidden = true

    init() {
        AgentResourceMonitorMenuInstaller.installWhenReady()
    }

    convenience init(agentView: AgentView) {
        self.init()
        self.agentView = agentView
    }

    func load(name: String) throws {
        guard let agent = Agent(resourceName: name) else {
            throw AgentControllerError.agentCouldNotLoad(name)
        }

        cancelPlayback()
        delegate?.willLoadAgent(agent: agent)
        textureCacheLock.lock()
        textureCache.removeAll(keepingCapacity: true)
        textureCacheLock.unlock()
        metricsLock.lock()
        textureCacheBytes = 0
        metricsLock.unlock()
        self.agent = agent
        showInitialFrame()
        restartAutoAnimateTimer()
        delegate?.didLoadAgent(agent: agent)
    }

    func cancelPlayback() {
        playbackID = UUID()
        isAnimating = false
        metricsLock.lock()
        currentAnimationName = nil
        metricsLock.unlock()
        agentView?.agentSprite.removeAllActions()
        player.pause()
        player.replaceCurrentItem(with: nil)
    }

    func audioActionForFrame(frame: AgentFrame) -> SKAction? {
        guard let agent = agent, let soundIndex = frame.soundIndex else { return nil }
        guard let soundURL = agent.soundURL(forIndex: soundIndex) else { return nil }
        let action = SKAction.run {
            let playerItem = AVPlayerItem(url: soundURL)
            self.player.replaceCurrentItem(with: playerItem)
            self.player.volume = self.isMuted ? 0 : 1.0
            self.player.play()
        }
        return action
    }

    func showInitialFrame() {
        guard let agent = agent, let texture = texture(at: 0, for: agent) else { return }
        self.agentView?.agentSprite.texture = texture
    }

    func play(animation: AgentAnimation, withSoundEnabled soundEnabled: Bool = true, interruptCurrent: Bool = true, completion: (() -> Void)? = nil) {
        guard let agent = agent else { return }
        if isAnimating {
            guard interruptCurrent else { return }
            cancelPlayback()
        }

        let currentPlaybackID = UUID()
        playbackID = currentPlaybackID
        isAnimating = true
        metricsLock.lock()
        currentAnimationName = animation.name
        metricsLock.unlock()

        DispatchQueue.global(qos: .background).async {
            let preparationStartedAt = ProcessInfo.processInfo.systemUptime
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
                actions.append(SKAction.run { [weak self] in
                    self?.recordRenderedFrame()
                })
                let action = SKAction.animate(with: [texture], timePerFrame: frame.durationInSeconds)
                actions.append(action)

                safetyCounter += 1
                frameIndex = self.nextFrameIndex(after: frameIndex, in: animation)
            }

            self.recordPreparationWork(
                ProcessInfo.processInfo.systemUptime - preparationStartedAt
            )

            DispatchQueue.main.async {
                guard self.playbackID == currentPlaybackID else { return }
                guard !actions.isEmpty else {
                    self.isAnimating = false
                    self.finishAnimationMetrics()
                    completion?()
                    return
                }
                self.agentView?.agentSprite.removeAllActions()
                self.agentView?.agentSprite.run(SKAction.sequence(actions), completion: {
                    guard self.playbackID == currentPlaybackID else { return }
                    self.isAnimating = false
                    self.finishAnimationMetrics()
                    completion?()
                })
            }
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
        metricsLock.lock()
        textureCacheBytes += UInt64(image.width * image.height * 4)
        metricsLock.unlock()
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
        guard let animation = agent.animations.randomElement() else { return }
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
        configuredAutoAnimateInterval > 0 ? configuredAutoAnimateInterval : Self.defaultAutoAnimateInterval
    }

    func isRandomAutoAnimateInterval() -> Bool {
        configuredAutoAnimateInterval == Self.randomAutoAnimateInterval
    }

    func restartAutoAnimateTimer() {
        autoAnimateTimer?.invalidate()
        let configured = configuredAutoAnimateInterval
        guard configured > 0 || configured == Self.randomAutoAnimateInterval else {
            autoAnimateTimer = nil
            return
        }
        autoAnimateTimer = Timer.scheduledTimer(withTimeInterval: nextAutoAnimateInterval(), repeats: false) { [weak self] _ in
            self?.animateIdle()
            self?.restartAutoAnimateTimer()
        }
    }

    func resourceSnapshot() -> AgentResourceSnapshot {
        let now = ProcessInfo.processInfo.systemUptime
        metricsLock.lock()
        recentFrameTimestamps.removeAll { now - $0 > 1.0 }
        let snapshot = AgentResourceSnapshot(
            currentAnimationName: currentAnimationName,
            renderedFrameCount: renderedFrameCount,
            framesPerSecond: Double(recentFrameTimestamps.count),
            textureCacheBytes: textureCacheBytes,
            preparationWorkSeconds: preparationWorkSeconds,
            isAnimating: isAnimating
        )
        metricsLock.unlock()
        return snapshot
    }

    private func recordRenderedFrame() {
        let now = ProcessInfo.processInfo.systemUptime
        metricsLock.lock()
        renderedFrameCount += 1
        recentFrameTimestamps.append(now)
        recentFrameTimestamps.removeAll { now - $0 > 1.0 }
        metricsLock.unlock()
    }

    private func recordPreparationWork(_ duration: TimeInterval) {
        metricsLock.lock()
        preparationWorkSeconds += max(0, duration)
        metricsLock.unlock()
    }

    private func finishAnimationMetrics() {
        metricsLock.lock()
        currentAnimationName = nil
        metricsLock.unlock()
    }

    private func nextAutoAnimateInterval() -> TimeInterval {
        if isRandomAutoAnimateInterval() {
            return TimeInterval.random(in: Self.randomAutoAnimateRange)
        }

        let interval = autoAnimateInterval()
        let lowerBound = max(5, interval * 0.75)
        let upperBound = max(lowerBound, interval * 2)
        return TimeInterval.random(in: lowerBound...upperBound)
    }
}

private enum AgentResourceMonitorMenuInstaller {
    private static let marker = "ClippyAgentResourceMonitorMenuItem"
    private static var installed = false

    static func installWhenReady() {
        DispatchQueue.main.async {
            installIfNeeded()
        }
    }

    private static func installIfNeeded() {
        guard !installed,
              let appDelegate = NSApplication.shared.delegate as? AppDelegate,
              let menu = appDelegate.statusItem?.menu else { return }

        if menu.items.contains(where: { $0.identifier?.rawValue == marker }) {
            installed = true
            return
        }

        let item = NSMenuItem(
            title: "Resource Monitor…",
            action: #selector(AgentResourceMonitorWindowController.showMonitor(_:)),
            keyEquivalent: ""
        )
        item.identifier = NSUserInterfaceItemIdentifier(marker)
        item.target = AgentResourceMonitorWindowController.shared

        if let managerIndex = menu.items.firstIndex(where: { $0.title == "Agent Manager…" }) {
            menu.insertItem(item, at: managerIndex + 1)
        } else if let windowsIndex = menu.items.firstIndex(where: { $0.title == "Agent Windows" }) {
            menu.insertItem(item, at: windowsIndex + 1)
        } else {
            menu.insertItem(item, at: min(5, menu.numberOfItems))
        }
        installed = true
    }
}

private struct ProcessResourceSnapshot {
    let cpuPercent: Double
    let residentMemoryBytes: UInt64
}

private final class ProcessResourceSampler {
    private var previousWallTime: TimeInterval?
    private var previousCPUTime: TimeInterval?

    func reset() {
        previousWallTime = nil
        previousCPUTime = nil
    }

    func sample() -> ProcessResourceSnapshot {
        let wallTime = ProcessInfo.processInfo.systemUptime
        let cpuTime = Self.totalCPUTime()
        let cpuPercent: Double

        if let previousWallTime,
           let previousCPUTime {
            let wallDelta = max(0.001, wallTime - previousWallTime)
            let cpuDelta = max(0, cpuTime - previousCPUTime)
            cpuPercent = cpuDelta / wallDelta * 100
        } else {
            cpuPercent = 0
        }

        self.previousWallTime = wallTime
        self.previousCPUTime = cpuTime
        return ProcessResourceSnapshot(
            cpuPercent: cpuPercent,
            residentMemoryBytes: Self.residentMemoryBytes()
        )
    }

    private static func totalCPUTime() -> TimeInterval {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        let user = TimeInterval(usage.ru_utime.tv_sec)
            + TimeInterval(usage.ru_utime.tv_usec) / 1_000_000
        let system = TimeInterval(usage.ru_stime.tv_sec)
            + TimeInterval(usage.ru_stime.tv_usec) / 1_000_000
        return user + system
    }

    private static func residentMemoryBytes() -> UInt64 {
        var info = mach_task_basic_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<mach_task_basic_info_data_t>.size
                / MemoryLayout<natural_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(
                to: integer_t.self,
                capacity: Int(count)
            ) { rebound in
                task_info(
                    mach_task_self_,
                    task_flavor_t(MACH_TASK_BASIC_INFO),
                    rebound,
                    &count
                )
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        return UInt64(info.resident_size)
    }
}

private struct AgentResourceMonitorRow {
    let sessionID: UUID
    let agentName: String
    let status: String
    let workPercent: Double
    let textureCacheBytes: UInt64
    let renderedFrameCount: UInt64
    let framesPerSecond: Double
    let speechQueueDepth: Int
}

final class AgentResourceMonitorWindowController:
    NSWindowController,
    NSTableViewDataSource,
    NSTableViewDelegate,
    NSWindowDelegate
{
    static let shared = AgentResourceMonitorWindowController()

    private enum Column: String, CaseIterable {
        case agent
        case status
        case work
        case cache
        case frames
        case fps
        case speech

        var title: String {
            switch self {
            case .agent: return "Agent"
            case .status: return "Status"
            case .work: return "Work %"
            case .cache: return "Texture Cache"
            case .frames: return "Frames"
            case .fps: return "FPS"
            case .speech: return "Speech"
            }
        }

        var width: CGFloat {
            switch self {
            case .agent: return 130
            case .status: return 190
            case .work: return 75
            case .cache: return 105
            case .frames: return 90
            case .fps: return 65
            case .speech: return 70
            }
        }
    }

    private let tableView = NSTableView()
    private let processLabel = NSTextField(labelWithString: "Collecting resource usage…")
    private let processSampler = ProcessResourceSampler()
    private var rows: [AgentResourceMonitorRow] = []
    private var previousPreparationWork: [UUID: TimeInterval] = [:]
    private var previousAgentSampleTime: TimeInterval?
    private var timer: Timer?

    private var sessionManager: AgentSessionManager? {
        (NSApplication.shared.delegate as? AppDelegate)?.sessionManager
    }

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 790, height: 380),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Agent Resource Monitor"
        window.minSize = NSSize(width: 650, height: 260)
        window.isReleasedWhenClosed = false
        window.setFrameAutosaveName("ClippyAgentResourceMonitorWindow")

        super.init(window: window)
        window.delegate = self
        configureContent()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        timer?.invalidate()
    }

    @objc func showMonitor(_ sender: Any?) {
        resetSamplingBaseline()
        sample()
        showWindow(sender)
        window?.makeKeyAndOrderFront(sender)
        NSApplication.shared.activate(ignoringOtherApps: true)
        startSampling()
    }

    func windowWillClose(_ notification: Notification) {
        timer?.invalidate()
        timer = nil
    }

    func numberOfRows(in tableView: NSTableView) -> Int {
        rows.count
    }

    func tableView(
        _ tableView: NSTableView,
        viewFor tableColumn: NSTableColumn?,
        row: Int
    ) -> NSView? {
        guard rows.indices.contains(row),
              let identifier = tableColumn?.identifier.rawValue,
              let column = Column(rawValue: identifier) else { return nil }
        let item = rows[row]
        let text: String
        let tooltip: String?

        switch column {
        case .agent:
            text = item.agentName
            tooltip = item.sessionID.uuidString
        case .status:
            text = item.status
            tooltip = "Current animation and visibility state"
        case .work:
            text = String(format: "%.1f%%", item.workPercent)
            tooltip = "Estimated wall-time share spent preparing this agent's animation frames. Per-agent kernel CPU is not separable inside one process."
        case .cache:
            text = Self.formatBytes(item.textureCacheBytes)
            tooltip = "Estimated bytes retained by this agent's decoded texture cache"
        case .frames:
            text = NumberFormatter.localizedString(
                from: NSNumber(value: item.renderedFrameCount),
                number: .decimal
            )
            tooltip = "Frames presented since this agent session started"
        case .fps:
            text = String(format: "%.0f", item.framesPerSecond)
            tooltip = "Frames presented during the previous one-second window"
        case .speech:
            text = "\(item.speechQueueDepth)"
            tooltip = "Active or queued speech bubbles. Current speech replaces an older bubble, so the depth is normally 0 or 1."
        }

        let label = NSTextField(labelWithString: text)
        label.lineBreakMode = .byTruncatingTail
        label.toolTip = tooltip
        return padded(label)
    }

    private func configureContent() {
        guard let window else { return }
        let root = NSView()
        window.contentView = root

        processLabel.translatesAutoresizingMaskIntoConstraints = false
        processLabel.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)
        processLabel.textColor = .secondaryLabelColor
        processLabel.toolTip = "Process CPU is sampled from getrusage. Memory is the process resident set."
        root.addSubview(processLabel)

        for column in Column.allCases {
            let tableColumn = NSTableColumn(
                identifier: NSUserInterfaceItemIdentifier(column.rawValue)
            )
            tableColumn.title = column.title
            tableColumn.width = column.width
            tableColumn.minWidth = max(55, column.width * 0.7)
            tableView.addTableColumn(tableColumn)
        }
        tableView.delegate = self
        tableView.dataSource = self
        tableView.rowHeight = 30
        tableView.usesAlternatingRowBackgroundColors = true
        tableView.allowsMultipleSelection = false

        let scrollView = NSScrollView()
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.documentView = tableView
        root.addSubview(scrollView)

        let footer = NSTextField(
            labelWithString: "Process CPU and resident memory are actual app-wide measurements. Work % and texture cache are per-agent estimates."
        )
        footer.translatesAutoresizingMaskIntoConstraints = false
        footer.font = .systemFont(ofSize: 11)
        footer.textColor = .secondaryLabelColor
        footer.lineBreakMode = .byTruncatingTail
        footer.toolTip = footer.stringValue
        root.addSubview(footer)

        NSLayoutConstraint.activate([
            processLabel.topAnchor.constraint(equalTo: root.topAnchor, constant: 12),
            processLabel.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            processLabel.trailingAnchor.constraint(lessThanOrEqualTo: root.trailingAnchor, constant: -12),

            scrollView.topAnchor.constraint(equalTo: processLabel.bottomAnchor, constant: 10),
            scrollView.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            scrollView.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            scrollView.bottomAnchor.constraint(equalTo: footer.topAnchor, constant: -8),

            footer.leadingAnchor.constraint(equalTo: root.leadingAnchor, constant: 12),
            footer.trailingAnchor.constraint(equalTo: root.trailingAnchor, constant: -12),
            footer.bottomAnchor.constraint(equalTo: root.bottomAnchor, constant: -10)
        ])
    }

    private func startSampling() {
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            self?.sample()
        }
        if let timer {
            RunLoop.main.add(timer, forMode: .common)
        }
    }

    private func resetSamplingBaseline() {
        processSampler.reset()
        previousPreparationWork.removeAll()
        previousAgentSampleTime = nil
    }

    private func sample() {
        let now = ProcessInfo.processInfo.systemUptime
        let elapsed = previousAgentSampleTime.map { max(0.001, now - $0) } ?? 1
        previousAgentSampleTime = now

        var currentRows: [AgentResourceMonitorRow] = []
        var activeIDs: Set<UUID> = []
        var totalCacheBytes: UInt64 = 0
        var totalFPS: Double = 0

        for session in sessionManager?.sessions ?? [] {
            let snapshot = session.controller.resourceSnapshot()
            let previousWork = previousPreparationWork[session.id]
                ?? snapshot.preparationWorkSeconds
            let workDelta = max(0, snapshot.preparationWorkSeconds - previousWork)
            previousPreparationWork[session.id] = snapshot.preparationWorkSeconds
            activeIDs.insert(session.id)

            let status: String
            if !session.window.isVisible || session.controller.isHidden {
                status = "Hidden"
            } else if snapshot.isAnimating, let name = snapshot.currentAnimationName {
                status = session.viewController.speechQueueDepth > 0
                    ? "Animating \(name) + speech"
                    : "Animating \(name)"
            } else if session.viewController.speechQueueDepth > 0 {
                status = "Speaking"
            } else {
                status = "Idle"
            }

            totalCacheBytes += snapshot.textureCacheBytes
            totalFPS += snapshot.framesPerSecond
            currentRows.append(
                AgentResourceMonitorRow(
                    sessionID: session.id,
                    agentName: session.displayName,
                    status: status,
                    workPercent: workDelta / elapsed * 100,
                    textureCacheBytes: snapshot.textureCacheBytes,
                    renderedFrameCount: snapshot.renderedFrameCount,
                    framesPerSecond: snapshot.framesPerSecond,
                    speechQueueDepth: session.viewController.speechQueueDepth
                )
            )
        }

        previousPreparationWork = previousPreparationWork.filter {
            activeIDs.contains($0.key)
        }
        rows = currentRows
        tableView.reloadData()

        let process = processSampler.sample()
        processLabel.stringValue = [
            "Process CPU \(String(format: "%.1f%%", process.cpuPercent))",
            "Resident \(Self.formatBytes(process.residentMemoryBytes))",
            "Texture cache \(Self.formatBytes(totalCacheBytes))",
            "Agent FPS \(String(format: "%.0f", totalFPS))",
            "\(rows.count) agent\(rows.count == 1 ? "" : "s")"
        ].joined(separator: "  ·  ")
    }

    private func padded(_ view: NSView) -> NSView {
        let container = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(view)
        NSLayoutConstraint.activate([
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor, constant: 4),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor, constant: -4),
            view.centerYAnchor.constraint(equalTo: container.centerYAnchor)
        ])
        return container
    }

    private static func formatBytes(_ bytes: UInt64) -> String {
        ByteCountFormatter.string(
            fromByteCount: Int64(clamping: bytes),
            countStyle: .memory
        )
    }
}
