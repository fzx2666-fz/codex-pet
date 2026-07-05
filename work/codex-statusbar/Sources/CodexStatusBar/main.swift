import AppKit
import Foundation

enum TaskState: String, Codable {
    case idle
    case running
    case done
    case error
}

struct CodexTaskStatus: Codable {
    var state: TaskState
    var task: String
    var detail: String
    var updatedAt: Date

    static let empty = CodexTaskStatus(
        state: .idle,
        task: "Codex idle",
        detail: "No recent Codex runtime activity.",
        updatedAt: Date(timeIntervalSince1970: 0)
    )
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var floatingWindow: NSWindow?
    private var floatingTitleLabel: NSTextField?
    private var timer: Timer?
    private var currentStatus = CodexTaskStatus.empty
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
        currentStatus = loadRuntimeStatus()
        render()
    }

    private func loadRuntimeStatus() -> CodexTaskStatus {
        let records = loadSessionRecords()
        guard let lead = records.max(by: { left, right in
            let leftPriority = priority(for: left.state)
            let rightPriority = priority(for: right.state)
            return leftPriority == rightPriority ? left.ts < right.ts : leftPriority < rightPriority
        }) else {
            return loadCoreLogStatus()
        }

        if isActiveState(lead.state) {
            return CodexTaskStatus(
                state: .running,
                task: "Codex running",
                detail: lead.label.isEmpty ? lead.state : lead.label,
                updatedAt: Date(timeIntervalSince1970: lead.ts)
            )
        }

        if lead.state == "done" {
            return CodexTaskStatus(
                state: .done,
                task: "Codex done",
                detail: lead.label,
                updatedAt: Date(timeIntervalSince1970: lead.ts)
            )
        }

        return CodexTaskStatus(
            state: .idle,
            task: "Codex idle",
            detail: lead.label,
            updatedAt: Date(timeIntervalSince1970: lead.ts)
        )
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

    private func priority(for state: String) -> Int {
        if state == "permission" {
            return 3
        }
        if isActiveState(state) {
            return 2
        }
        return 1
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
        let latest = max(latestRun, latestDone)
        let latestDate = latest > 0 ? Date(timeIntervalSince1970: TimeInterval(latest)) : Date()

        if latestRun > latestDone {
            return CodexTaskStatus(
                state: .running,
                task: "Codex running",
                detail: "Codex core is processing a turn.",
                updatedAt: latestDate
            )
        }

        if latestDone > 0 && Date().timeIntervalSince(latestDate) < 300 {
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

    private func queryCoreLogEventTimes() -> (latestRun: Int, latestDone: Int)? {
        guard FileManager.default.fileExists(atPath: logDBURL.path) else {
            return nil
        }

        let query = """
        select
          coalesce((select max(ts) from logs where target = 'codex_core::stream_events_utils' and feedback_log_body like '%model=gpt-%' and feedback_log_body not like '%codex-auto-review%'), 0),
          coalesce((select max(ts) from logs where target = 'log' and feedback_log_body like 'Received message {"type":"response.completed"%' and feedback_log_body not like '%You are judging one planned coding-agent action%'), 0);
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
        guard parts.count == 2, let latestRun = Int(parts[0]), let latestDone = Int(parts[1]) else {
            return nil
        }

        return (latestRun, latestDone)
    }

    private func render() {
        statusItem.button?.title = title(for: currentStatus)
        statusItem.button?.toolTip = tooltip(for: currentStatus)
        statusItem.menu = makeMenu(for: currentStatus)
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
        case .error:
            return "C!"
        }
    }

    private func tooltip(for status: CodexTaskStatus) -> String {
        return status.task
    }

    private func makeMenu(for status: CodexTaskStatus) -> NSMenu {
        let menu = NSMenu()

        let heading = NSMenuItem(title: status.task, action: nil, keyEquivalent: "")
        heading.isEnabled = false
        menu.addItem(heading)

        if !status.detail.isEmpty {
            let detail = NSMenuItem(title: status.detail, action: nil, keyEquivalent: "")
            detail.isEnabled = false
            menu.addItem(detail)
        }

        let updated = NSMenuItem(title: "Updated \(relativeTime(from: status.updatedAt))", action: nil, keyEquivalent: "")
        updated.isEnabled = false
        menu.addItem(updated)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Refresh", action: #selector(refreshNow), keyEquivalent: "r"))
        menu.addItem(NSMenuItem(title: "Open Codex Log DB", action: #selector(openLogDatabase), keyEquivalent: "o"))
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Codex Status", action: #selector(quit), keyEquivalent: "q"))

        for item in menu.items where item.action != nil {
            item.target = self
        }
        return menu
    }

    private func makeFloatingStatusWindow() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 180, height: 36),
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

        let container = NSView(frame: window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 180, height: 36))
        container.wantsLayer = true
        container.layer?.cornerRadius = 12
        container.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92).cgColor
        container.layer?.borderWidth = 1
        container.layer?.borderColor = NSColor.separatorColor.withAlphaComponent(0.5).cgColor

        let title = NSTextField(labelWithString: "Codex -")
        title.frame = NSRect(x: 12, y: 9, width: 156, height: 18)
        title.font = NSFont.monospacedSystemFont(ofSize: 14, weight: .bold)
        title.textColor = .labelColor

        container.addSubview(title)
        window.contentView = container

        floatingWindow = window
        floatingTitleLabel = title
        positionFloatingWindow()
        window.orderFrontRegardless()
    }

    private func renderFloatingWindow(for status: CodexTaskStatus) {
        floatingTitleLabel?.stringValue = floatingTitle(for: status)
        positionFloatingWindow()
        floatingWindow?.orderFrontRegardless()
    }

    private func floatingTitle(for status: CodexTaskStatus) -> String {
        switch status.state {
        case .idle:
            return "Codex idle"
        case .running:
            return "Codex running"
        case .done:
            return "Codex done"
        case .error:
            return "Codex done"
        }
    }

    private func positionFloatingWindow() {
        guard let screen = NSScreen.main, let window = floatingWindow else {
            return
        }
        let frame = screen.visibleFrame
        let size = window.frame.size
        let origin = NSPoint(x: frame.maxX - size.width - 12, y: frame.maxY - size.height - 8)
        window.setFrameOrigin(origin)
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

    @objc private func quit() {
        NSApplication.shared.terminate(nil)
    }

}

struct HookSessionRecord: Decodable {
    let state: String
    let label: String
    let ts: Double

    enum CodingKeys: String, CodingKey {
        case state
        case label
        case ts
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = try container.decodeIfPresent(String.self, forKey: .state) ?? "idle"
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        ts = try container.decodeIfPresent(Double.self, forKey: .ts) ?? 0
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
