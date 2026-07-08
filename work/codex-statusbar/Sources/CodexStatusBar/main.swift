import AppKit
import Foundation
import QuartzCore

enum TaskState: String, Codable {
    case idle
    case running
    case done
    case closed
    case error
}

final class FocusTarget: Codable {
    var kind: String = ""
    var url: String = ""
    var bundleId: String = ""
    var appName: String = ""
    var fallback: FocusTarget?

    static let none = FocusTarget(kind: "none")

    enum CodingKeys: String, CodingKey {
        case kind
        case url
        case bundleId
        case appName
        case fallback
    }

    init(kind: String = "", url: String = "", bundleId: String = "", appName: String = "", fallback: FocusTarget? = nil) {
        self.kind = kind
        self.url = url
        self.bundleId = bundleId
        self.appName = appName
        self.fallback = fallback
    }

    required init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        kind = try container.decodeIfPresent(String.self, forKey: .kind) ?? "none"
        url = try container.decodeIfPresent(String.self, forKey: .url) ?? ""
        bundleId = try container.decodeIfPresent(String.self, forKey: .bundleId) ?? ""
        appName = try container.decodeIfPresent(String.self, forKey: .appName) ?? ""
        fallback = try container.decodeIfPresent(FocusTarget.self, forKey: .fallback)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(url, forKey: .url)
        try container.encode(bundleId, forKey: .bundleId)
        try container.encode(appName, forKey: .appName)
        try container.encodeIfPresent(fallback, forKey: .fallback)
    }
}

struct CodexTaskStatus: Codable {
    var state: TaskState
    var task: String
    var detail: String
    var updatedAt: Date
    var sessionId: String = ""
    var title: String = ""
    var project: String = ""
    var focusTarget: FocusTarget = .none

    func withSessionMetadata(from record: HookSessionRecord, title: String) -> CodexTaskStatus {
        var copy = self
        copy.sessionId = record.taskId.isEmpty ? record.sessionId : record.taskId
        copy.title = title
        copy.project = record.project
        copy.focusTarget = record.focusTarget
        return copy
    }

    static let empty = CodexTaskStatus(
        state: .idle,
        task: "Codex idle",
        detail: "No recent Codex runtime activity.",
        updatedAt: Date(timeIntervalSince1970: 0)
    )
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let floatingWindowOriginKey = "floatingWindowOrigin"
    private static let activeHookRecordTTL: TimeInterval = 90
    private static let doneRecordTTL: TimeInterval = 12
    private static let idleRecordTTL: TimeInterval = 86_400

    private var statusItem: NSStatusItem!
    private var floatingWindow: NSWindow?
    private var floatingTitleLabel: NSTextField?
    private var floatingStatusLabel: NSTextField?
    private var floatingTaskLabels: [NSTextField] = []
    private var floatingListToggleButton: NSButton?
    private var floatingCatView: CatStatusView?
    private var floatingHairlineView: GlassPanelView?
    private var floatingHighlightView: NSView?
    private var isFloatingHovered = false
    private var isFloatingTaskListExpanded = true
    private var isProgrammaticallyMovingFloatingWindow = false
    private let collapsedFloatingSize = NSSize(width: 72, height: 72)
    private var timer: Timer?
    private var currentStatus = CodexTaskStatus.empty
    private var currentTasks = [CodexTaskStatus.empty]
    private let stateDirURL = resolveStatusBarStateDirURL()
    private let logDBURL = resolveCodexLogDBURL()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        statusItem = NSStatusBar.system.statusItem(withLength: 28)
        statusItem.button?.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
        makeFloatingStatusWindow()

        refreshStatus()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
    }

    private func refreshStatus() {
        currentTasks = loadRuntimeStatuses()
        currentStatus = currentTasks.first ?? CodexTaskStatus.empty
        render()
    }

    private func loadRuntimeStatuses() -> [CodexTaskStatus] {
        guard isCodexDesktopRunning() else {
            return [CodexTaskStatus(
                state: .closed,
                task: "Codex closed",
                detail: "Codex Desktop is not running.",
                updatedAt: Date()
            )]
        }

        let records = loadSessionRecords()
        let statuses = records
            .filter(isUsableHookRecord)
            .map(status(for:))
            .sorted(by: isHigherPriority)

        if statuses.isEmpty {
            var fallback = loadCoreLogStatus()
            if let latestRecord = records.max(by: { $0.ts < $1.ts }) {
                fallback = fallback.withSessionMetadata(from: latestRecord, title: taskTitle(for: latestRecord))
            }
            return [fallback]
        }

        return statuses
    }

    private func status(for record: HookSessionRecord) -> CodexTaskStatus {
        let state: TaskState
        if isActiveState(record.state) {
            state = .running
        } else if record.state == "done" {
            state = .done
        } else {
            state = .idle
        }

        let title = taskTitle(for: record)
        let detail = [record.label, record.project]
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && $0 != title }
            .joined(separator: " / ")

        return CodexTaskStatus(
            state: state,
            task: floatingStatusWord(for: state),
            detail: detail,
            updatedAt: Date(timeIntervalSince1970: record.ts),
            sessionId: record.taskId.isEmpty ? record.sessionId : record.taskId,
            title: title,
            project: record.project,
            focusTarget: record.focusTarget
        )
    }

    private func taskTitle(for record: HookSessionRecord) -> String {
        let candidates = [record.taskTitle, record.threadName, record.project, record.sessionId]
        return candidates
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first { !$0.isEmpty && $0 != "Untitled" } ?? "Codex task"
    }

    private func isHigherPriority(_ left: CodexTaskStatus, than right: CodexTaskStatus) -> Bool {
        let leftPriority = priority(for: left.state)
        let rightPriority = priority(for: right.state)
        if leftPriority != rightPriority {
            return leftPriority > rightPriority
        }
        return left.updatedAt > right.updatedAt
    }

    private func isCodexDesktopRunning() -> Bool {
        NSWorkspace.shared.runningApplications.contains { application in
            application.bundleIdentifier == "com.openai.codex"
        }
    }

    private func loadSessionRecords() -> [HookSessionRecord] {
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: stateDirURL,
            includingPropertiesForKeys: nil
        ) else {
            return []
        }

        let decoder = JSONDecoder()
        return urls
            .filter { $0.pathExtension == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else {
                    return nil
                }
                return try? decoder.decode(HookSessionRecord.self, from: data)
            }
    }

    private func isUsableHookRecord(_ record: HookSessionRecord) -> Bool {
        let now = Date().timeIntervalSince1970

        if record.state == "done" {
            return now - record.ts <= Self.doneRecordTTL
        }

        guard isActiveState(record.state) else {
            return now - record.ts <= Self.idleRecordTTL
        }

        if let visibleUntilMs = record.visibleUntilMs, visibleUntilMs > 0 {
            return now * 1000 <= visibleUntilMs
        }

        return now - record.ts <= Self.activeHookRecordTTL
    }

    private func priority(for state: String) -> Int {
        if state == "permission" {
            return 3
        }
        if isActiveState(state) {
            return 2
        }
        return 1
    }

    private func priority(for state: TaskState) -> Int {
        switch state {
        case .running:
            return 2
        case .done:
            return 1
        case .idle:
            return 0
        case .closed:
            return -1
        case .error:
            return -2
        }
    }

    private func isActiveState(_ state: String) -> Bool {
        ["thinking", "tool", "compacting", "permission", "waiting"].contains(state)
    }

    private func loadCoreLogStatus() -> CodexTaskStatus {
        guard let eventTimes = queryCoreLogEventTimes() else {
            return CodexTaskStatus(
                state: .idle,
                task: "Codex idle",
                detail: "No Codex runtime signal is available.",
                updatedAt: Date()
            )
        }

        let latestRun = eventTimes.latestRun
        let latestDone = eventTimes.latestDone
        let latestNeedsFollowUp = eventTimes.latestNeedsFollowUp
        let latestInterrupt = eventTimes.latestInterrupt
        let latest = max(latestRun, latestDone, latestNeedsFollowUp, latestInterrupt)
        let latestDate = latest > 0 ? Date(timeIntervalSince1970: TimeInterval(latest)) : Date()

        if latestRun > max(latestDone, latestInterrupt) || latestNeedsFollowUp > max(latestDone, latestInterrupt) {
            return CodexTaskStatus(
                state: .running,
                task: "Codex running",
                detail: "Codex core is processing a turn.",
                updatedAt: latestDate
            )
        }

        if max(latestDone, latestInterrupt) > 0 && Date().timeIntervalSince(latestDate) < Self.doneRecordTTL {
            return CodexTaskStatus(
                state: .done,
                task: "Codex done",
                detail: "Codex core completed the latest turn.",
                updatedAt: latestDate
            )
        }

        return CodexTaskStatus(
            state: .idle,
            task: "Codex idle",
            detail: "No active Codex turn in recent logs.",
            updatedAt: latestDate
        )
    }

    private func queryCoreLogEventTimes() -> (latestRun: Int, latestDone: Int, latestNeedsFollowUp: Int, latestInterrupt: Int)? {
        guard FileManager.default.fileExists(atPath: logDBURL.path) else {
            return nil
        }

        let query = """
        select
          max(
            coalesce((select max(ts) from logs where target = 'codex_core::stream_events_utils' and feedback_log_body like '%model=gpt-%' and feedback_log_body not like '%codex-auto-review%'), 0),
            coalesce((select max(ts) from logs where target = 'codex_core::session::handlers' and feedback_log_body like '%op: UserInput%' and feedback_log_body not like '%The following is the Codex agent history%'), 0)
          ),
          coalesce((select max(ts) from logs where target = 'codex_core::session::turn' and feedback_log_body like '%model=gpt-%' and feedback_log_body not like '%codex-auto-review%' and feedback_log_body like '%post sampling token usage%' and feedback_log_body like '%needs_follow_up=false%'), 0),
          coalesce((select max(ts) from logs where target = 'codex_core::session::turn' and feedback_log_body like '%model=gpt-%' and feedback_log_body not like '%codex-auto-review%' and feedback_log_body like '%post sampling token usage%' and feedback_log_body like '%needs_follow_up=true%'), 0),
          coalesce((select max(ts) from logs where target = 'codex_core::session' and feedback_log_body like '%op.dispatch.interrupt%' and feedback_log_body like '%interrupt received%'), 0);
        """

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = ["-noheader", "-separator", "|", logDBURL.path, query]

        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()

        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }

        guard process.terminationStatus == 0 else {
            return nil
        }

        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        guard let output = String(data: data, encoding: .utf8) else {
            return nil
        }

        let parts = output.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: "|")
        guard
            parts.count == 4,
            let latestRun = Int(parts[0]),
            let latestDone = Int(parts[1]),
            let latestNeedsFollowUp = Int(parts[2]),
            let latestInterrupt = Int(parts[3])
        else {
            return nil
        }

        return (latestRun, latestDone, latestNeedsFollowUp, latestInterrupt)
    }

    private func render() {
        statusItem.button?.title = title(for: currentStatus)
        statusItem.button?.toolTip = tooltip(for: currentStatus)
        statusItem.menu = makeMenu()
        renderFloatingWindow(for: currentStatus)
    }

    private func title(for status: CodexTaskStatus) -> String {
        switch status.state {
        case .idle:
            return "C-"
        case .running:
            return "C*"
        case .done:
            return "C+"
        case .closed:
            return "Cx"
        case .error:
            return "C!"
        }
    }

    private func tooltip(for status: CodexTaskStatus) -> String {
        if currentTasks.count <= 1 {
            return status.title.isEmpty ? status.task : "\(status.task) - \(status.title)"
        }

        let lines = currentTasks.prefix(5).map { task in
            taskStatusLine(for: task)
        }
        return lines.joined(separator: "\n")
    }

    private func makeMenu() -> NSMenu {
        let menu = NSMenu()

        let headingTitle = currentTasks.count <= 1 ? currentStatus.task : "\(currentStatus.task) - \(currentTasks.count) tasks"
        let heading = NSMenuItem(title: headingTitle, action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)

        if currentTasks.count > 1 {
            menu.addItem(.separator())
            for task in currentTasks.prefix(12) {
                let item = NSMenuItem(
                    title: taskStatusLine(for: task),
                    action: #selector(activateSelectedCodexTask(_:)),
                    keyEquivalent: ""
                )
                item.representedObject = task.focusTarget
                item.isEnabled = task.focusTarget.kind != "none"
                menu.addItem(item)

                if !task.detail.isEmpty {
                    let detail = NSMenuItem(title: "  \(task.detail)", action: nil, keyEquivalent: "")
                    detail.isEnabled = false
                    menu.addItem(detail)
                }
            }
        } else if !currentStatus.detail.isEmpty {
            let detail = NSMenuItem(title: currentStatus.detail, action: nil, keyEquivalent: "")
            detail.isEnabled = false
            menu.addItem(detail)
        }

        let updated = NSMenuItem(title: "Updated \(relativeTime(from: currentStatus.updatedAt))", action: nil, keyEquivalent: "")
        updated.isEnabled = false
        menu.addItem(updated)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Refresh", action: #selector(refreshNow), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Open Codex Log DB", action: #selector(openLogDatabase), keyEquivalent: "o"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Codex Pet", action: #selector(quit), keyEquivalent: "q"))

        for item in menu.items where item.action != nil {
            item.target = self
        }
        return menu
    }

    private func displayTitle(for status: CodexTaskStatus) -> String {
        if !status.title.isEmpty {
            return status.title
        }
        if !status.sessionId.isEmpty {
            return status.sessionId
        }
        return "Codex task"
    }

    private func taskStatusLine(for status: CodexTaskStatus) -> String {
        "\(displayTitle(for: status)) \(shortStatusWord(for: status.state))"
    }

    private func makeFloatingStatusWindow() {
        let floatingSize = floatingWindowSize(forTaskCount: 0)
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: floatingSize),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = true
        window.ignoresMouseEvents = false
        window.isMovableByWindowBackground = false
        window.delegate = self

        let bounds = window.contentView?.bounds ?? NSRect(origin: .zero, size: floatingSize)
        let material = HoverStatusView(frame: bounds)
        material.onHoverChanged = { [weak self] isHovered in
            self?.setFloatingHover(isHovered)
        }
        material.onClick = { [weak self] in
            self?.activateCodexDesktop()
        }
        material.wantsLayer = true
        material.layer?.cornerRadius = 22
        material.layer?.masksToBounds = true
        material.layer?.backgroundColor = NSColor.clear.cgColor

        let hairline = GlassPanelView(frame: bounds)

        let highlight = NSView(frame: bounds.insetBy(dx: 1.5, dy: 1.5))
        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 20.5
        highlight.layer?.borderWidth = 1
        highlight.layer?.borderColor = floatingHighlightColor(isHovered: false).cgColor
        highlight.layer?.backgroundColor = NSColor.clear.cgColor

        let cat = CatStatusView(frame: NSRect(x: 18, y: 46, width: 54, height: 48))

        let title = NSTextField(labelWithString: "Codex")
        title.frame = NSRect(x: 70, y: 34, width: 45, height: 16)
        title.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        title.textColor = .labelColor
        title.isHidden = true

        let status = NSTextField(labelWithString: "Codex 0 jobs running")
        status.frame = NSRect(x: 86, y: 64, width: 174, height: 20)
        status.alignment = .left
        status.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
        status.textColor = .secondaryLabelColor

        let toggleButton = NSButton(frame: NSRect(x: 238, y: 56, width: 24, height: 24))
        toggleButton.isBordered = false
        toggleButton.image = floatingListToggleImage()
        toggleButton.imagePosition = .imageOnly
        toggleButton.contentTintColor = .secondaryLabelColor
        toggleButton.toolTip = "Toggle task list"
        toggleButton.target = self
        toggleButton.action = #selector(toggleFloatingTaskList)
        toggleButton.isHidden = true

        let taskLabels = (0..<5).map { index in
            let label = NSTextField(labelWithString: "")
            label.frame = NSRect(x: 22, y: 18, width: 234, height: 15)
            label.alignment = .left
            label.font = NSFont.systemFont(ofSize: 10.5, weight: .medium)
            label.lineBreakMode = .byTruncatingTail
            label.textColor = .secondaryLabelColor
            label.isHidden = true
            return label
        }

        material.addSubview(hairline)
        material.addSubview(highlight)
        material.addSubview(cat)
        material.addSubview(title)
        material.addSubview(status)
        material.addSubview(toggleButton)
        taskLabels.forEach { material.addSubview($0) }
        window.contentView = material

        floatingWindow = window
        floatingTitleLabel = title
        floatingStatusLabel = status
        floatingTaskLabels = taskLabels
        floatingListToggleButton = toggleButton
        floatingCatView = cat
        floatingHairlineView = hairline
        floatingHighlightView = highlight
        positionFloatingWindow()
        window.orderFrontRegardless()
    }

    private func renderFloatingWindow(for status: CodexTaskStatus) {
        floatingTitleLabel?.stringValue = "Codex"
        layoutFloatingWindow()
        floatingStatusLabel?.stringValue = floatingSummaryText()
        floatingStatusLabel?.font = floatingStatusFont(for: status)
        floatingStatusLabel?.textColor = isFloatingHovered ? .labelColor : floatingStatusTextColor(for: status)
        floatingCatView?.setState(status.state)
        renderFloatingTaskListToggle()
        renderFloatingTaskList()
        floatingWindow?.contentView?.toolTip = tooltip(for: status)
        floatingWindow?.orderFrontRegardless()
    }

    private func layoutFloatingWindow() {
        let rowCount = visibleFloatingTaskCount()
        let size = floatingWindowSize(forTaskCount: rowCount)
        let isExpanded = isFloatingHovered

        if let window = floatingWindow, window.frame.size != size {
            var frame = window.frame
            let centerX = frame.midX
            let maxY = frame.maxY
            frame.size = size
            frame.origin.x = centerX - (size.width / 2)
            frame.origin.y = maxY - size.height
            isProgrammaticallyMovingFloatingWindow = true
            window.setFrame(frame, display: true)
            isProgrammaticallyMovingFloatingWindow = false
        }

        let bounds = NSRect(origin: .zero, size: size)
        floatingWindow?.contentView?.frame = bounds
        floatingWindow?.contentView?.bounds = bounds
        let cornerRadius = isExpanded ? CGFloat(22) : min(size.width, size.height) / 2
        floatingWindow?.contentView?.layer?.cornerRadius = cornerRadius
        floatingHairlineView?.frame = bounds
        floatingHighlightView?.frame = bounds.insetBy(dx: 1.5, dy: 1.5)
        floatingHighlightView?.layer?.cornerRadius = max(0, cornerRadius - 1.5)

        let catSize = NSSize(width: 54, height: 48)
        let catX = isExpanded ? CGFloat(18) : (size.width - catSize.width) / 2
        let catY: CGFloat
        if !isExpanded {
            catY = (size.height - catSize.height) / 2 + 2
        } else if rowCount == 0 {
            catY = ((size.height - catSize.height) / 2) + 3
        } else {
            catY = size.height - 14 - catSize.height
        }
        floatingCatView?.frame = NSRect(x: catX, y: catY, width: catSize.width, height: catSize.height)
        let statusY = rowCount == 0 ? ((size.height - 20) / 2) + 2 : catY + 18
        let hasToggle = !runningFloatingTasks().isEmpty
        floatingStatusLabel?.frame = NSRect(x: 86, y: statusY, width: size.width - (hasToggle ? 132 : 108), height: 20)
        floatingStatusLabel?.isHidden = !isExpanded
        floatingListToggleButton?.frame = NSRect(x: size.width - 38, y: statusY - 2, width: 24, height: 24)
        floatingHighlightView?.isHidden = false

        let rowHeight: CGFloat = 16
        let bottomPadding: CGFloat = 18
        let firstRowY = bottomPadding + (CGFloat(rowCount - 1) * rowHeight)
        for (index, label) in floatingTaskLabels.enumerated() {
            label.frame = NSRect(x: 22, y: firstRowY - (CGFloat(index) * rowHeight), width: size.width - 44, height: 15)
        }
    }

    private func visibleFloatingTaskCount() -> Int {
        guard isFloatingHovered else {
            return 0
        }
        guard isFloatingTaskListExpanded else {
            return 0
        }
        return min(runningFloatingTasks().count, floatingTaskLabels.count)
    }

    private func floatingWindowSize(forTaskCount taskCount: Int) -> NSSize {
        guard isFloatingHovered else {
            return collapsedFloatingSize
        }
        let rowCount = max(0, min(taskCount, 5))
        if rowCount == 0 {
            return NSSize(width: 310, height: 72)
        }
        return NSSize(width: 310, height: 92 + CGFloat(rowCount * 16))
    }

    private func floatingSummaryText() -> String {
        let runningCount = runningFloatingTasks().count
        if runningCount == 0 {
            return "Codex idle"
        }
        return "Codex \(runningCount) \(runningCount == 1 ? "job" : "jobs") running"
    }

    private func renderFloatingTaskList() {
        guard isFloatingHovered else {
            for label in floatingTaskLabels {
                label.isHidden = true
                label.stringValue = ""
            }
            return
        }

        guard isFloatingTaskListExpanded else {
            for label in floatingTaskLabels {
                label.isHidden = true
                label.stringValue = ""
            }
            return
        }

        let tasks = Array(runningFloatingTasks().prefix(floatingTaskLabels.count))
        for (index, label) in floatingTaskLabels.enumerated() {
            guard index < tasks.count else {
                label.isHidden = true
                label.stringValue = ""
                continue
            }

            let task = tasks[index]
            label.isHidden = false
            label.stringValue = taskStatusLine(for: task)
            label.textColor = task.state == .running ? .labelColor : .secondaryLabelColor
        }
    }

    private func runningFloatingTasks() -> [CodexTaskStatus] {
        currentTasks.filter { $0.state == .running }
    }

    private func renderFloatingTaskListToggle() {
        let hasRunningTasks = !runningFloatingTasks().isEmpty
        floatingListToggleButton?.isHidden = !isFloatingHovered || !hasRunningTasks
        floatingListToggleButton?.image = floatingListToggleImage()
        floatingListToggleButton?.contentTintColor = isFloatingHovered ? .labelColor : .secondaryLabelColor
    }

    private func floatingListToggleImage() -> NSImage? {
        let symbolName = isFloatingTaskListExpanded ? "eye.slash" : "eye"
        return NSImage(systemSymbolName: symbolName, accessibilityDescription: "Toggle task list")
    }

    @objc private func toggleFloatingTaskList() {
        isFloatingTaskListExpanded.toggle()
        render()
    }

    private func setFloatingHover(_ isHovered: Bool) {
        guard isFloatingHovered != isHovered else {
            return
        }

        isFloatingHovered = isHovered
        floatingCatView?.setHovered(isHovered)
        layoutFloatingWindow()
        floatingStatusLabel?.textColor = isHovered ? .labelColor : floatingStatusTextColor(for: currentStatus)
        renderFloatingTaskListToggle()
        renderFloatingTaskList()

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.16)
        floatingHairlineView?.setHovered(isHovered)
        floatingHighlightView?.layer?.borderColor = floatingHighlightColor(isHovered: isHovered).cgColor
        CATransaction.commit()
    }

    private func floatingHighlightColor(isHovered: Bool) -> NSColor {
        NSColor.white.withAlphaComponent(isHovered ? 0.72 : 0.52)
    }

    private func floatingStatusWord(for status: CodexTaskStatus) -> String {
        floatingStatusWord(for: status.state)
    }

    private func floatingStatusWord(for state: TaskState) -> String {
        switch state {
        case .idle:
            return "Codex idle"
        case .running:
            return "Codex running"
        case .done:
            return "Codex done"
        case .closed:
            return "Codex closed"
        case .error:
            return "Codex error"
        }
    }

    private func shortStatusWord(for state: TaskState) -> String {
        switch state {
        case .idle:
            return "idle"
        case .running:
            return "running"
        case .done:
            return "done"
        case .closed:
            return "closed"
        case .error:
            return "error"
        }
    }

    private func floatingStatusFont(for status: CodexTaskStatus) -> NSFont {
        NSFont.monospacedSystemFont(ofSize: 13, weight: .semibold)
    }

    private func floatingStatusColor(for status: CodexTaskStatus) -> NSColor {
        switch status.state {
        case .idle:
            return NSColor.systemGray
        case .running:
            return NSColor.systemBlue
        case .done:
            return NSColor.systemGreen
        case .closed:
            return NSColor.systemRed
        case .error:
            return NSColor.systemOrange
        }
    }

    private func floatingStatusTextColor(for status: CodexTaskStatus) -> NSColor {
        switch status.state {
        case .idle:
            return .secondaryLabelColor
        case .running:
            return .labelColor
        case .done:
            return .secondaryLabelColor
        case .closed:
            return .labelColor
        case .error:
            return .labelColor
        }
    }

    private func positionFloatingWindow() {
        guard let screen = NSScreen.main, let window = floatingWindow else {
            return
        }
        let frame = screen.visibleFrame
        let size = window.frame.size
        let fallback = NSPoint(x: frame.maxX - size.width - 12, y: frame.maxY - size.height - 8)
        let saved = UserDefaults.standard.string(forKey: Self.floatingWindowOriginKey).flatMap(NSPointFromString)
        let origin = clamp(saved ?? fallback, size: size, in: frame)
        isProgrammaticallyMovingFloatingWindow = true
        window.setFrameOrigin(origin)
        isProgrammaticallyMovingFloatingWindow = false
    }

    private func clamp(_ origin: NSPoint, size: NSSize, in frame: NSRect) -> NSPoint {
        NSPoint(
            x: min(max(origin.x, frame.minX), frame.maxX - size.width),
            y: min(max(origin.y, frame.minY), frame.maxY - size.height)
        )
    }

    private func saveFloatingWindowOrigin() {
        guard !isProgrammaticallyMovingFloatingWindow, let window = floatingWindow else {
            return
        }
        UserDefaults.standard.set(NSStringFromPoint(window.frame.origin), forKey: Self.floatingWindowOriginKey)
    }

    private func relativeTime(from date: Date) -> String {
        if date.timeIntervalSince1970 == 0 {
            return "never"
        }

        let seconds = Int(Date().timeIntervalSince(date))
        if seconds < 5 {
            return "just now"
        }
        if seconds < 60 {
            return "\(seconds)s ago"
        }
        if seconds < 3600 {
            return "\(seconds / 60)m ago"
        }
        if seconds < 86_400 {
            return "\(seconds / 3600)h ago"
        }

        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    @objc private func refreshNow() {
        refreshStatus()
    }

    @objc private func openLogDatabase() {
        try? FileManager.default.createDirectory(at: stateDirURL, withIntermediateDirectories: true)
        NSWorkspace.shared.activateFileViewerSelecting([stateDirURL])
    }

    @objc private func activateSelectedCodexTask(_ sender: NSMenuItem) {
        if let target = sender.representedObject as? FocusTarget {
            activate(target: target)
        } else {
            activateCodexDesktop()
        }
    }

    private func activate(target: FocusTarget) {
        switch target.kind {
        case "url":
            if let url = URL(string: target.url), NSWorkspace.shared.open(url) {
                return
            }
            if let fallback = target.fallback {
                activate(target: fallback)
                return
            }
            activateCodexDesktop()
        case "bundle":
            activateApplication(bundleId: target.bundleId)
        case "app":
            activateApplication(named: target.appName)
        default:
            activateCodexDesktop()
        }
    }

    @objc private func activateCodexDesktop() {
        activateApplication(bundleId: "com.openai.codex")
    }

    private func activateApplication(bundleId: String) {
        if let application = NSWorkspace.shared.runningApplications.first(where: { application in
            application.bundleIdentifier == bundleId
        }) {
            application.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            return
        }

        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
    }

    private func activateApplication(named appName: String) {
        guard !appName.isEmpty else {
            return
        }

        if let application = NSWorkspace.shared.runningApplications.first(where: { application in
            application.localizedName == appName
        }) {
            application.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            return
        }

        NSWorkspace.shared.launchApplication(appName)
    }

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

}

extension AppDelegate: NSWindowDelegate {
    func windowDidMove(_ notification: Notification) {
        saveFloatingWindowOrigin()
    }
}

struct HookSessionRecord: Decodable {
    let state: String
    let label: String
    let ts: Double
    let visibleUntilMs: Double?
    let sessionId: String
    let taskId: String
    let taskTitle: String
    let threadName: String
    let project: String
    let focusTarget: FocusTarget

    enum CodingKeys: String, CodingKey {
        case state
        case label
        case ts
        case visibleUntilMs
        case sessionId
        case taskId
        case taskTitle
        case threadName
        case project
        case focusTarget
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = try container.decodeIfPresent(String.self, forKey: .state) ?? "idle"
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        ts = try container.decodeIfPresent(Double.self, forKey: .ts) ?? 0
        visibleUntilMs = try container.decodeIfPresent(Double.self, forKey: .visibleUntilMs)
        sessionId = try container.decodeIfPresent(String.self, forKey: .sessionId) ?? ""
        taskId = try container.decodeIfPresent(String.self, forKey: .taskId) ?? ""
        taskTitle = try container.decodeIfPresent(String.self, forKey: .taskTitle) ?? ""
        threadName = try container.decodeIfPresent(String.self, forKey: .threadName) ?? ""
        project = try container.decodeIfPresent(String.self, forKey: .project) ?? ""
        focusTarget = try container.decodeIfPresent(FocusTarget.self, forKey: .focusTarget) ?? .none
    }
}

final class GlassPanelView: NSView {
    private var isHovered = false

    override var isOpaque: Bool {
        false
    }

    func setHovered(_ isHovered: Bool) {
        guard self.isHovered != isHovered else {
            return
        }
        self.isHovered = isHovered
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)

        let rect = bounds.insetBy(dx: 2, dy: 2)
        let radius = min(rect.height / 2, bounds.width <= 80 ? rect.width / 2 : 23)
        let path = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)

        NSGraphicsContext.saveGraphicsState()

        let baseGradient = NSGradient(colors: glassBaseColors(isHovered: isHovered))!
        path.addClip()
        baseGradient.draw(in: rect, angle: -28)

        let upperGlowRect = rect.insetBy(dx: 5, dy: 4)
        let upperGlow = NSBezierPath(roundedRect: upperGlowRect, xRadius: radius - 5, yRadius: radius - 5)
        let glowGradient = NSGradient(colors: [
            NSColor.white.withAlphaComponent(isHovered ? 0.62 : 0.46),
            NSColor.white.withAlphaComponent(0.06),
            NSColor.clear
        ])!
        upperGlow.addClip()
        glowGradient.draw(in: upperGlowRect, angle: 92)

        NSGraphicsContext.restoreGraphicsState()

        NSColor(calibratedWhite: 1.0, alpha: isHovered ? 0.82 : 0.68).setStroke()
        path.lineWidth = 1.4
        path.stroke()

        let innerRect = rect.insetBy(dx: 2, dy: 2)
        let innerPath = NSBezierPath(roundedRect: innerRect, xRadius: radius - 2, yRadius: radius - 2)
        NSColor(calibratedRed: 0.70, green: 0.64, blue: 0.82, alpha: isHovered ? 0.36 : 0.24).setStroke()
        innerPath.lineWidth = 1
        innerPath.stroke()

    }

    private func glassBaseColors(isHovered: Bool) -> [NSColor] {
        if isHovered {
            return [
                NSColor(calibratedRed: 1.00, green: 0.99, blue: 0.94, alpha: 0.96),
                NSColor(calibratedRed: 0.86, green: 0.96, blue: 0.91, alpha: 0.94),
                NSColor(calibratedRed: 0.95, green: 0.89, blue: 1.00, alpha: 0.94),
                NSColor(calibratedRed: 0.82, green: 0.93, blue: 0.94, alpha: 0.95)
            ]
        }

        return [
            NSColor(calibratedRed: 1.00, green: 0.99, blue: 0.95, alpha: 0.92),
            NSColor(calibratedRed: 0.90, green: 0.97, blue: 0.92, alpha: 0.90),
            NSColor(calibratedRed: 0.96, green: 0.91, blue: 1.00, alpha: 0.90),
            NSColor(calibratedRed: 0.86, green: 0.94, blue: 0.94, alpha: 0.92)
        ]
    }
}

final class HoverStatusView: NSView {
    var onHoverChanged: ((Bool) -> Void)?
    var onClick: (() -> Void)?
    private var trackingAreaRef: NSTrackingArea?
    private var mouseDownScreenPoint: NSPoint?
    private var mouseDownWindowOrigin: NSPoint?
    private var didDrag = false

    override var isOpaque: Bool {
        false
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let hitView = super.hitTest(point) else {
            return nil
        }
        return hitView is NSButton ? hitView : self
    }

    override func updateTrackingAreas() {
        if let trackingAreaRef {
            removeTrackingArea(trackingAreaRef)
        }

        let area = NSTrackingArea(
            rect: bounds,
            options: [.activeAlways, .mouseEnteredAndExited, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        trackingAreaRef = area
        super.updateTrackingAreas()
    }

    override func mouseEntered(with event: NSEvent) {
        onHoverChanged?(true)
    }

    override func mouseExited(with event: NSEvent) {
        onHoverChanged?(false)
    }

    override func mouseDown(with event: NSEvent) {
        mouseDownScreenPoint = NSEvent.mouseLocation
        mouseDownWindowOrigin = window?.frame.origin
        didDrag = false
    }

    override func mouseDragged(with event: NSEvent) {
        guard let window, let mouseDownScreenPoint, let mouseDownWindowOrigin else {
            return
        }

        let current = NSEvent.mouseLocation
        let dx = current.x - mouseDownScreenPoint.x
        let dy = current.y - mouseDownScreenPoint.y
        didDrag = didDrag || hypot(dx, dy) > 3
        window.setFrameOrigin(NSPoint(x: mouseDownWindowOrigin.x + dx, y: mouseDownWindowOrigin.y + dy))
    }

    override func mouseUp(with event: NSEvent) {
        defer {
            mouseDownScreenPoint = nil
            mouseDownWindowOrigin = nil
            didDrag = false
        }

        guard let start = mouseDownScreenPoint else {
            return
        }

        let current = NSEvent.mouseLocation
        if !didDrag && hypot(current.x - start.x, current.y - start.y) <= 3 {
            onClick?()
        }
    }
}

final class CatStatusView: NSView {
    private struct SpriteFrame {
        let column: Int
        let row: Int
    }

    private var state: TaskState = .idle
    private var isHovered = false
    private var phase: CGFloat = 0
    private var animationTimer: Timer?
    private let spriteImage = NSImage(named: "oneko") ?? NSImage(contentsOf: Bundle.module.url(forResource: "oneko", withExtension: "gif") ?? URL(fileURLWithPath: ""))

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        startAnimation()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        startAnimation()
    }

    deinit {
        animationTimer?.invalidate()
    }

    func setState(_ state: TaskState) {
        guard self.state != state else {
            return
        }
        self.state = state
        needsDisplay = true
    }

    func setHovered(_ isHovered: Bool) {
        guard self.isHovered != isHovered else {
            return
        }
        self.isHovered = isHovered
        needsDisplay = true
    }

    private func startAnimation() {
        wantsLayer = true
        layer?.masksToBounds = false
        animationTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 24.0, repeats: true) { [weak self] _ in
            guard let self else {
                return
            }
            self.phase += self.state == .running ? 0.34 : 0.16
            self.needsDisplay = true
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        NSColor.clear.setFill()
        bounds.fill(using: .copy)

        guard let image = spriteImage else {
            return
        }

        NSGraphicsContext.current?.imageInterpolation = .none
        let frame = currentFrame()
        let source = NSRect(x: frame.column * 32, y: Int(image.size.height) - ((frame.row + 1) * 32), width: 32, height: 32)
        let size: CGFloat = isHovered ? 53 : 50
        let dest = NSRect(
            x: (bounds.width - size) / 2 + sway,
            y: (bounds.height - size) / 2 + bounce,
            width: size,
            height: size
        )
        image.draw(in: dest, from: source, operation: .sourceOver, fraction: opacity)
    }

    private func currentFrame() -> SpriteFrame {
        let frames = frames(for: state)
        let index = Int(phase) % frames.count
        return frames[index]
    }

    private func frames(for state: TaskState) -> [SpriteFrame] {
        switch state {
        case .idle:
            return [
                SpriteFrame(column: 2, row: 0),
                SpriteFrame(column: 2, row: 0),
                SpriteFrame(column: 2, row: 1),
                SpriteFrame(column: 2, row: 1)
            ]
        case .running:
            return [
                SpriteFrame(column: 3, row: 0),
                SpriteFrame(column: 3, row: 1)
            ]
        case .done:
            return [
                SpriteFrame(column: 5, row: 0),
                SpriteFrame(column: 6, row: 0),
                SpriteFrame(column: 7, row: 0),
                SpriteFrame(column: 6, row: 0)
            ]
        case .closed:
            return [
                SpriteFrame(column: 2, row: 0),
                SpriteFrame(column: 2, row: 0),
                SpriteFrame(column: 2, row: 1),
                SpriteFrame(column: 2, row: 1)
            ]
        case .error:
            return [
                SpriteFrame(column: 7, row: 3),
                SpriteFrame(column: 7, row: 3),
                SpriteFrame(column: 7, row: 0)
            ]
        }
    }

    private var bounce: CGFloat {
        switch state {
        case .running:
            return sin(phase * 2) * 2
        case .done:
            return abs(sin(phase * 1.6)) * 2
        default:
            return 0
        }
    }

    private var sway: CGFloat {
        state == .running ? sin(phase * 1.4) * 2 : 0
    }

    private var opacity: CGFloat {
        if state == .closed {
            return isHovered ? 0.9 : 0.82
        }
        return 1
    }

}

private func resolveStatusBarStateDirURL() -> URL {
    if let override = ProcessInfo.processInfo.environment["CODEX_STATUSBAR_STATE_DIR"], !override.isEmpty {
        return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
    }
    return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/statusbar/state.d")
}

private func resolveCodexLogDBURL() -> URL {
    if let override = ProcessInfo.processInfo.environment["CODEX_LOG_DB"], !override.isEmpty {
        return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
    }
    return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/logs_2.sqlite")
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.run()
