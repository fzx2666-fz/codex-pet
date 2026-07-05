const cp = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

const MARKERS = [
  "codex-status-writer.js",
  "codex-lifecycle-writer.js",
  "codex-hook-logger.js",
];

const EVENT_SPECS = [
  { event: "SessionStart", matcher: "", writer: "lifecycle" },
  { event: "SessionEnd", matcher: "", writer: "lifecycle" },
  { event: "UserPromptSubmit", matcher: "", writer: "status" },
  { event: "PreToolUse", matcher: "*", writer: "status" },
  { event: "PreCompact", matcher: "", writer: "status" },
  { event: "PermissionRequest", matcher: "*", writer: "status" },
  { event: "PostToolUse", matcher: "*", writer: "status" },
  { event: "PostCompact", matcher: "", writer: "status" },
  { event: "Stop", matcher: "", writer: "status" },
  { event: "SubagentStart", matcher: "", writer: "status" },
  { event: "SubagentStop", matcher: "", writer: "status" },
];

function isOwnCommand(command) {
  return MARKERS.some((marker) => String(command || "").includes(marker));
}

function quote(value) {
  return `"${String(value).replace(/"/g, '\\"')}"`;
}

function executableExists(candidate, exists = fs.existsSync) {
  if (!candidate || !exists(candidate)) return false;
  try {
    fs.accessSync(candidate, fs.constants.X_OK);
    return true;
  } catch {
    return true;
  }
}

function nvmCandidates(home, exists = fs.existsSync) {
  const versionsDir = path.join(home, ".nvm", "versions", "node");
  if (!exists(versionsDir)) return [];
  try {
    return fs.readdirSync(versionsDir)
      .sort()
      .reverse()
      .map((version) => path.join(versionsDir, version, "bin", "node"));
  } catch {
    return [];
  }
}

function findNode(options = {}) {
  const home = options.home || os.homedir();
  const env = options.env || process.env;
  const exists = options.exists || fs.existsSync;
  const candidates = [
    options.currentExecPath || process.execPath,
    env.VOLTA_HOME ? path.join(env.VOLTA_HOME, "bin", "node") : "",
    path.join(home, ".volta", "bin", "node"),
    env.ASDF_DIR ? path.join(env.ASDF_DIR, "shims", "node") : "",
    path.join(home, ".asdf", "shims", "node"),
    ...nvmCandidates(home, exists),
    "/opt/homebrew/bin/node",
    "/usr/local/bin/node",
    "/usr/bin/node",
  ];

  for (const candidate of candidates) {
    if (executableExists(candidate, exists)) return candidate;
  }

  const pathDirs = String(env.PATH || "").split(path.delimiter).filter(Boolean);
  for (const dir of pathDirs) {
    const candidate = path.join(dir, "node");
    if (executableExists(candidate, exists)) return candidate;
  }
  return options.currentExecPath || process.execPath;
}

function parseAppPathArg(argv = process.argv) {
  const index = argv.indexOf("--app-path");
  if (index >= 0 && argv[index + 1]) return argv[index + 1];
  return "";
}

function resourcesPathForApp(appPath) {
  return path.join(appPath, "Contents", "Resources");
}

function firstExistingPath(paths) {
  return paths.find((candidate) => candidate && fs.existsSync(candidate)) || paths[paths.length - 1];
}

function resolveScriptPaths(options = {}) {
  const scriptDir = options.scriptDir || __dirname;
  const repoRoot = options.repoRoot || path.resolve(scriptDir, "..");
  const appResourcesDir = options.appPath ? resourcesPathForApp(options.appPath) : "";
  const appWriterPath = appResourcesDir ? path.join(appResourcesDir, "codex-status-writer.js") : "";
  const appLifecyclePath = appResourcesDir ? path.join(appResourcesDir, "codex-lifecycle-writer.js") : "";
  const appInstallPath = appResourcesDir ? path.join(appResourcesDir, "install-codex-statusbar.js") : "";
  const bundledWriterPath = path.join(scriptDir, "codex-status-writer.js");
  const bundledLifecyclePath = path.join(scriptDir, "codex-lifecycle-writer.js");
  const bundledInstallPath = path.join(scriptDir, "install-codex-statusbar.js");
  const repoWriterPath = path.join(repoRoot, "scripts", "codex-status-writer.js");
  const repoLifecyclePath = path.join(repoRoot, "scripts", "codex-lifecycle-writer.js");
  const repoInstallPath = path.join(repoRoot, "scripts", "install-codex-statusbar.js");

  return {
    writerPath: firstExistingPath([appWriterPath, bundledWriterPath, repoWriterPath]),
    lifecyclePath: firstExistingPath([appLifecyclePath, bundledLifecyclePath, repoLifecyclePath]),
    installPath: firstExistingPath([appInstallPath, bundledInstallPath, repoInstallPath]),
  };
}

function stripOwnHooksFromEntries(entries) {
  return (entries || [])
    .map((entry) => ({
      ...entry,
      hooks: (entry.hooks || []).filter((hook) => !isOwnCommand(hook.command)),
    }))
    .filter((entry) => (entry.hooks || []).length > 0);
}

function removeOwnHooks(settings) {
  const cleaned = { ...settings, hooks: { ...(settings.hooks || {}) } };
  for (const event of Object.keys(cleaned.hooks)) {
    cleaned.hooks[event] = stripOwnHooksFromEntries(cleaned.hooks[event]);
    if (cleaned.hooks[event].length === 0) delete cleaned.hooks[event];
  }
  return cleaned;
}

function hookCommand(nodePath, commandPath, event, appPath = "") {
  const appPathArgs = appPath ? ` --app-path ${quote(appPath)}` : "";
  return `${quote(nodePath)} ${quote(commandPath)} ${event}${appPathArgs}`;
}

function desiredHookSettings({ existing, nodePath, writerPath, lifecyclePath, appPath }) {
  const settings = removeOwnHooks(existing || { hooks: {} });
  settings.hooks = settings.hooks || {};

  for (const spec of EVENT_SPECS) {
    const commandPath = spec.writer === "lifecycle" ? lifecyclePath : writerPath;
    const hook = {
      type: "command",
      command: hookCommand(nodePath, commandPath, spec.event, appPath),
      timeout: 5,
      statusMessage: `Codex Status Bar: ${spec.event}`,
    };
    const group = spec.matcher ? { matcher: spec.matcher, hooks: [hook] } : { hooks: [hook] };
    settings.hooks[spec.event] = stripOwnHooksFromEntries(settings.hooks[spec.event]);
    settings.hooks[spec.event].push(group);
  }

  return settings;
}

function ownCommandsByEvent(settings) {
  const result = {};
  for (const [event, groups] of Object.entries(settings.hooks || {})) {
    for (const group of groups || []) {
      for (const hook of group.hooks || []) {
        if (!isOwnCommand(hook.command)) continue;
        result[event] = result[event] || [];
        result[event].push(hook.command);
      }
    }
  }
  return result;
}

function needsRepair(existing, desired) {
  const current = ownCommandsByEvent(existing || { hooks: {} });
  const target = ownCommandsByEvent(desired || { hooks: {} });
  for (const spec of EVENT_SPECS) {
    const event = spec.event;
    const currentCommands = current[event] || [];
    const targetCommands = target[event] || [];
    if (currentCommands.length !== targetCommands.length) return true;
    for (const command of targetCommands) {
      if (!currentCommands.includes(command)) return true;
    }
  }
  return false;
}

function repairHooks(existing, options) {
  return desiredHookSettings({ existing, ...options });
}

function readHooks(hooksPath) {
  if (!fs.existsSync(hooksPath)) return { hooks: {} };
  return JSON.parse(fs.readFileSync(hooksPath, "utf8"));
}

function writeHooks(hooksPath, settings) {
  fs.mkdirSync(path.dirname(hooksPath), { recursive: true });
  fs.writeFileSync(hooksPath, `${JSON.stringify(settings, null, 2)}\n`);
}

function inferAppPath(options = {}) {
  if (options.appPath) return options.appPath;
  if (process.env.CODEX_STATUSBAR_APP_PATH) return process.env.CODEX_STATUSBAR_APP_PATH;
  const resourceDir = options.scriptDir || path.resolve(__dirname, "..");
  const contentsDir = path.dirname(resourceDir);
  if (path.basename(resourceDir) === "Resources" && path.basename(contentsDir) === "Contents") {
    return path.dirname(contentsDir);
  }
  return path.resolve(resourceDir, "..", "build", "CodexStatusBar.app");
}

function traceLaunch(event) {
  const tracePath = process.env.CODEX_STATUSBAR_LAUNCH_TRACE;
  if (!tracePath) return;
  try {
    fs.mkdirSync(path.dirname(tracePath), { recursive: true });
    fs.appendFileSync(tracePath, `${JSON.stringify({ ts: new Date().toISOString(), ...event })}\n`);
  } catch {}
}

function runningProcessCommands(processName, timeoutMs) {
  try {
    const output = cp.execFileSync("/usr/bin/pgrep", ["-x", processName], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
      timeout: timeoutMs,
    });
    return output
      .split(/\s+/)
      .filter(Boolean)
      .map((pid) => {
        try {
          return cp.execFileSync("/bin/ps", ["-p", pid, "-o", "command="], {
            encoding: "utf8",
            stdio: ["ignore", "pipe", "ignore"],
            timeout: timeoutMs,
          }).trim();
        } catch {
          return "";
        }
      })
      .filter(Boolean);
  } catch {
    return [];
  }
}

function statusBarProcessRunning(options = {}) {
  const processName = options.processName || process.env.CODEX_STATUSBAR_PROCESS_NAME || "CodexStatusBar";
  const timeoutMs = Number(options.timeoutMs || 1000);

  if (typeof options.runningProcessCommands === "function") {
    return options.runningProcessCommands().length > 0;
  }
  if (typeof options.processRunning === "function") {
    return Boolean(options.processRunning());
  }
  return runningProcessCommands(processName, timeoutMs).length > 0;
}

function ensureStatusBarRunning(options = {}) {
  if (process.env.CODEX_STATUSBAR_DISABLE_AUTO_LAUNCH === "1") {
    traceLaunch({ ok: false, reason: "disabled" });
    return false;
  }
  if (statusBarProcessRunning(options)) {
    traceLaunch({ ok: false, reason: "already_running" });
    return false;
  }
  const appPath = inferAppPath(options);
  if (!appPath || !fs.existsSync(appPath)) {
    traceLaunch({ ok: false, reason: "missing_app", appPath });
    return false;
  }
  const openBin = options.openBin || process.env.CODEX_STATUSBAR_OPEN_BIN || "/usr/bin/open";
  try {
    cp.execFileSync(openBin, ["-g", appPath], {
      stdio: "ignore",
      timeout: Number(options.timeoutMs || 1000),
    });
    traceLaunch({ ok: true, openBin, appPath });
    return true;
  } catch (error) {
    traceLaunch({ ok: false, reason: "open_failed", openBin, appPath, error: String(error && error.message ? error.message : error) });
    return false;
  }
}

module.exports = {
  EVENT_SPECS,
  MARKERS,
  desiredHookSettings,
  ensureStatusBarRunning,
  findNode,
  hookCommand,
  inferAppPath,
  needsRepair,
  parseAppPathArg,
  readHooks,
  removeOwnHooks,
  repairHooks,
  resolveScriptPaths,
  statusBarProcessRunning,
  writeHooks,
};
