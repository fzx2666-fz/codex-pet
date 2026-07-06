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
    private static let floatingWindowOriginKey = "floatingWindowOrigin"
    private static let activeHookRecordTTL: TimeInterval = 90
    private static let doneRecordTTL: TimeInterval = 12

    private var statusItem: NSStatusItem!
    private var floatingWindow: NSWindow?
    private var floatingTitleLabel: NSTextField?
    private var floatingStatusLabel: NSTextField?
    private var floatingCatView: CatStatusView?
    private var floatingHairlineView: NSView?
    private var floatingHighlightView: NSView?
    private var isFloatingHovered = false
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
        guard isCodexDesktopRunning() else {
            return CodexTaskStatus(
                state: .closed,
                task: "Codex closed",
                detail: "Codex Desktop is not running.",
                updatedAt: Date()
            )
        }

        let records = loadSessionRecords().filter(isUsableHookRecord)
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
            return true
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
        case .closed:
            return "Cx"
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
            contentRect: NSRect(x: 0, y: 0, width: 126, height: 62),
            styleMask: [.borderless],
            backing: .buffered,
            defer: false
        )
        window.isReleasedWhenClosed = false
        window.level = .floating
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        window.backgroundColor = .clear
        window.isOpaque = false
        window.hasShadow = false
        window.ignoresMouseEvents = false
        window.isMovableByWindowBackground = false
        window.delegate = self

        let bounds = window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 126, height: 62)
        let material = HoverStatusView(frame: bounds)
        material.onHoverChanged = { [weak self] isHovered in
            self?.setFloatingHover(isHovered)
        }
        material.onClick = { [weak self] in
            self?.activateCodexDesktop()
        }
        material.material = .hudWindow
        material.blendingMode = .behindWindow
        material.state = .active
        material.wantsLayer = true
        material.layer?.cornerRadius = 20
        material.layer?.masksToBounds = true

        let hairline = NSView(frame: bounds)
        hairline.wantsLayer = true
        hairline.layer?.cornerRadius = 20
        hairline.layer?.borderWidth = 1
        hairline.layer?.borderColor = floatingBorderColor(isHovered: false).cgColor
        hairline.layer?.backgroundColor = floatingBackgroundColor(isHovered: false).cgColor

        let highlight = NSView(frame: bounds.insetBy(dx: 1.5, dy: 1.5))
        highlight.wantsLayer = true
        highlight.layer?.cornerRadius = 18.5
        highlight.layer?.borderWidth = 1
        highlight.layer?.borderColor = floatingHighlightColor(isHovered: false).cgColor
        highlight.layer?.backgroundColor = NSColor.clear.cgColor

        let cat = CatStatusView(frame: NSRect(x: 8, y: 6, width: 58, height: 50))

        let title = NSTextField(labelWithString: "Codex")
        title.frame = NSRect(x: 70, y: 34, width: 45, height: 16)
        title.font = NSFont.systemFont(ofSize: 10, weight: .semibold)
        title.textColor = .labelColor
        title.isHidden = true

        let status = NSTextField(labelWithString: "idle")
        status.frame = NSRect(x: 67, y: 22, width: 50, height: 17)
        status.alignment = .center
        status.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .semibold)
        status.textColor = .secondaryLabelColor

        material.addSubview(hairline)
        material.addSubview(highlight)
        material.addSubview(cat)
        material.addSubview(title)
        material.addSubview(status)
        window.contentView = material

        floatingWindow = window
        floatingTitleLabel = title
        floatingStatusLabel = status
        floatingCatView = cat
        floatingHairlineView = hairline
        floatingHighlightView = highlight
        positionFloatingWindow()
        window.orderFrontRegardless()
    }

    private func renderFloatingWindow(for status: CodexTaskStatus) {
        floatingTitleLabel?.stringValue = "Codex"
        floatingStatusLabel?.stringValue = floatingStatusWord(for: status)
        floatingStatusLabel?.font = floatingStatusFont(for: status)
        floatingStatusLabel?.textColor = isFloatingHovered ? .labelColor : floatingStatusTextColor(for: status)
        floatingCatView?.setState(status.state)
        positionFloatingWindow()
        floatingWindow?.orderFrontRegardless()
    }

    private func setFloatingHover(_ isHovered: Bool) {
        guard isFloatingHovered != isHovered else {
            return
        }

        isFloatingHovered = isHovered
        floatingCatView?.setHovered(isHovered)
        floatingStatusLabel?.textColor = isHovered ? .labelColor : floatingStatusTextColor(for: currentStatus)

        CATransaction.begin()
        CATransaction.setAnimationDuration(0.16)
        floatingHairlineView?.layer?.borderColor = floatingBorderColor(isHovered: isHovered).cgColor
        floatingHairlineView?.layer?.backgroundColor = floatingBackgroundColor(isHovered: isHovered).cgColor
        floatingHighlightView?.layer?.borderColor = floatingHighlightColor(isHovered: isHovered).cgColor
        CATransaction.commit()
    }

    private func floatingBackgroundColor(isHovered: Bool) -> NSColor {
        if isHovered {
            return NSColor(calibratedRed: 1.00, green: 0.90, blue: 0.58, alpha: 0.98)
        }
        return NSColor(calibratedRed: 1.00, green: 0.94, blue: 0.70, alpha: 0.97)
    }

    private func floatingBorderColor(isHovered: Bool) -> NSColor {
        NSColor(calibratedRed: 0.74, green: 0.52, blue: 0.18, alpha: isHovered ? 0.50 : 0.34)
    }

    private func floatingHighlightColor(isHovered: Bool) -> NSColor {
        NSColor.white.withAlphaComponent(isHovered ? 0.58 : 0.44)
    }

    private func floatingStatusWord(for status: CodexTaskStatus) -> String {
        switch status.state {
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
        let size: CGFloat = status.state == .running || status.state == .closed ? 9 : 11
        return NSFont.monospacedSystemFont(ofSize: size, weight: .semibold)
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
        window.setFrameOrigin(origin)
    }

    private func clamp(_ origin: NSPoint, size: NSSize, in frame: NSRect) -> NSPoint {
        NSPoint(
            x: min(max(origin.x, frame.minX), frame.maxX - size.width),
            y: min(max(origin.y, frame.minY), frame.maxY - size.height)
        )
    }

    private func saveFloatingWindowOrigin() {
        guard let window = floatingWindow else {
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

    @objc private func activateCodexDesktop() {
        if let application = NSWorkspace.shared.runningApplications.first(where: { application in
            application.bundleIdentifier == "com.openai.codex"
        }) {
            application.activate(options: [.activateAllWindows, .activateIgnoringOtherApps])
            return
        }

        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.openai.codex") else {
            return
        }

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        NSWorkspace.shared.openApplication(at: url, configuration: configuration)
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

    enum CodingKeys: String, CodingKey {
        case state
        case label
        case ts
        case visibleUntilMs
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        state = try container.decodeIfPresent(String.self, forKey: .state) ?? "idle"
        label = try container.decodeIfPresent(String.self, forKey: .label) ?? ""
        ts = try container.decodeIfPresent(Double.self, forKey: .ts) ?? 0
        visibleUntilMs = try container.decodeIfPresent(Double.self, forKey: .visibleUntilMs)
    }
}

final class HoverStatusView: NSVisualEffectView {
    var onHoverChanged: ((Bool) -> Void)?
    var onClick: (() -> Void)?
    private var trackingAreaRef: NSTrackingArea?
    private var mouseDownScreenPoint: NSPoint?
    private var mouseDownWindowOrigin: NSPoint?
    private var didDrag = false

    override func hitTest(_ point: NSPoint) -> NSView? {
        super.hitTest(point) == nil ? nil : self
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
