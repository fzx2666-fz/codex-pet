#!/usr/bin/env node
const fs = require("fs");
const os = require("os");
const path = require("path");
const { ensureStatusBarRunning, parseAppPathArg } = require("./lib/hook-manager");
const { latestThreadName } = require("./lib/session-index");
const { resolveSessionSurface } = require("./lib/session-surface");

const event = process.argv[2] || "unknown";
const appPath = parseAppPathArg();
const home = os.homedir();
const dir = process.env.CODEX_STATUSBAR_DIR || path.join(home, ".codex", "statusbar");
const stateDir = path.join(dir, "state.d");

let raw = "";
process.stdin.on("data", (chunk) => {
  raw += chunk;
});
process.stdin.on("end", run);
process.stdin.on("error", run);
setTimeout(run, 1000);

let done = false;

function safeId(value) {
  return String(value || "").replace(/[^A-Za-z0-9_.-]/g, "").slice(0, 80) || "unknown";
}

function basename(value) {
  if (!value || typeof value !== "string") return "";
  return path.basename(value);
}

function writeJsonAtomic(filePath, object) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  const tmp = `${filePath}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(object, null, 2));
  fs.renameSync(tmp, filePath);
}

function sessionIdFor(payload) {
  return safeId(payload.session_id || payload.sessionId);
}

function statePathFor(sessionId) {
  return path.join(stateDir, `${safeId(sessionId)}.json`);
}

function readPrevious(sessionId) {
  try {
    return JSON.parse(fs.readFileSync(statePathFor(sessionId), "utf8"));
  } catch {
    return {};
  }
}

function run() {
  if (done) return;
  done = true;

  let payload = {};
  try {
    payload = JSON.parse(raw || "{}");
  } catch {
    payload = {};
  }

  const sessionId = sessionIdFor(payload);
  const statePath = statePathFor(sessionId);

  if (event === "SessionStart") {
    const now = Date.now() / 1000;
    const pid = Number(process.ppid || 0);
    const surface = resolveSessionSurface(payload, {}, process.env, { pid, sessionId });
    writeJsonAtomic(statePath, {
      state: "idle",
      label: "",
      tool: "",
      threadName: latestThreadName(sessionId),
      project: basename(payload.cwd || payload.working_directory || payload.current_working_directory),
      sessionId,
      turnId: "",
      pid,
      entrypoint: surface.entrypoint,
      entrypointSource: surface.entrypointSource,
      termProgram: surface.termProgram,
      focusTarget: surface.focusTarget,
      started: false,
      startedAt: 0,
      ts: now,
    });
    ensureStatusBarRunning({ scriptDir: __dirname, appPath });
  } else if (event === "SessionEnd") {
    const prev = readPrevious(sessionId);
    if (prev.sessionId) {
      const now = Date.now() / 1000;
      const pid = Number(prev.pid || process.ppid || 0);
      const surface = resolveSessionSurface(payload, prev, process.env, { pid, sessionId });
      writeJsonAtomic(statePath, {
        ...prev,
        state: "done",
        label: "Done",
        tool: "",
        threadName: latestThreadName(sessionId),
        project: basename(payload.cwd || payload.working_directory || payload.current_working_directory) || prev.project || "",
        sessionId,
        turnId: "",
        pid,
        entrypoint: surface.entrypoint,
        entrypointSource: surface.entrypointSource,
        termProgram: surface.termProgram,
        focusTarget: surface.focusTarget,
        started: false,
        startedAt: 0,
        ts: now,
      });
    }
  }

  process.exit(0);
}
