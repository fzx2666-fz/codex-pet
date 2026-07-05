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
    var progress: Int?
    var updatedAt: Date
}

func resolveStatusURL() -> URL {
    if let override = ProcessInfo.processInfo.environment["CODEX_STATUS_FILE"], !override.isEmpty {
        return URL(fileURLWithPath: (override as NSString).expandingTildeInPath)
    }
    return FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex-status/status.json")
}

let statusURL = resolveStatusURL()

let decoder: JSONDecoder = {
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return decoder
}()

let encoder: JSONEncoder = {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    return encoder
}()

func usage() -> Never {
    print("""
    Usage:
      codex-status running --task "Task name" [--detail "What is happening"]
      codex-status done --task "Task name" [--detail "Result"]
      codex-status idle
      codex-status show

    Status file:
      \(statusURL.path)
    """)
    exit(2)
}

func argumentValue(_ name: String, in args: [String]) -> String? {
    guard let index = args.firstIndex(of: name), args.indices.contains(index + 1) else {
        return nil
    }
    return args[index + 1]
}

func readStatus() -> CodexTaskStatus? {
    guard let data = try? Data(contentsOf: statusURL) else {
        return nil
    }
    return try? decoder.decode(CodexTaskStatus.self, from: data)
}

func writeStatus(_ status: CodexTaskStatus) throws {
    try FileManager.default.createDirectory(at: statusURL.deletingLastPathComponent(), withIntermediateDirectories: true)
    let data = try encoder.encode(status)
    try data.write(to: statusURL, options: .atomic)
}

let args = Array(CommandLine.arguments.dropFirst())
guard let command = args.first else {
    usage()
}

if command == "show" {
    if let status = readStatus(), let data = try? encoder.encode(status), let text = String(data: data, encoding: .utf8) {
        print(text)
        exit(0)
    }
    print("No status has been written yet.")
    exit(1)
}

guard let state = TaskState(rawValue: command) else {
    usage()
}

let task = argumentValue("--task", in: args) ?? {
    switch state {
    case .idle:
        return "Codex is idle"
    case .running:
        return "Codex is working"
    case .done:
        return "Codex task complete"
    case .error:
        return "Codex needs attention"
    }
}()

let detail = argumentValue("--detail", in: args) ?? ""
let status = CodexTaskStatus(
    state: state,
    task: task,
    detail: detail,
    progress: nil,
    updatedAt: Date()
)

do {
    try writeStatus(status)
    print("\(state.rawValue): \(task)")
} catch {
    fputs("codex-status: \(error.localizedDescription)\n", stderr)
    exit(1)
}
