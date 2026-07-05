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
const debugLogPath = path.join(dir, "hooks-discovery.jsonl");
const minToolVisibleMs = Number(process.env.CODEX_STATUSBAR_MIN_TOOL_VISIBLE_MS || 900);
const maxToolVisibleMs = Number(process.env.CODEX_STATUSBAR_MAX_TOOL_VISIBLE_MS || 8000);
const minPermissionVisibleMs = Number(process.env.CODEX_STATUSBAR_MIN_PERMISSION_VISIBLE_MS || 12000);
const debugEnabled = process.env.CODEX_STATUSBAR_DEBUG === "1";

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

function typeOf(value) {
  if (Array.isArray(value)) return `array(${value.length})`;
  if (value === null) return "null";
  return typeof value;
}

function summarizePayload(payload) {
  const keys = Object.keys(payload).sort();
  const types = {};
  for (const key of keys) {
    types[key] = typeOf(payload[key]);
  }

  return {
    keys,
    types,
    safeValues: {
      cwdBasename: basename(payload.cwd || payload.working_directory || payload.current_working_directory),
      toolName: typeof payload.tool_name === "string" ? payload.tool_name : "",
      sessionId: sessionIdFor(payload),
      turnId: turnIdFor(payload),
      permissionMode: typeof payload.permission_mode === "string" ? payload.permission_mode : "",
      matcher: typeof payload.matcher === "string" ? payload.matcher : "",
    },
  };
}

function writeJsonAtomic(filePath, object) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  const tmp = `${filePath}.${process.pid}.tmp`;
  fs.writeFileSync(tmp, JSON.stringify(object, null, 2));
  fs.renameSync(tmp, filePath);
}

function appendJsonl(filePath, object) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.appendFileSync(filePath, `${JSON.stringify(object)}\n`);
}

function labelForTool(toolName) {
  const labels = {
    Bash: "Running command",
    Shell: "Running command",
    LocalShell: "Running command",
    exec_command: "Running command",
    apply_patch: "Editing",
    Read: "Reading",
    Grep: "Searching",
    Glob: "Searching",
    WebFetch: "Browsing web",
    WebSearch: "Searching web",
    TodoWrite: "Planning",
  };
  return labels[toolName];
}

function sessionIdFor(payload) {
  return safeId(payload.session_id || payload.sessionId);
}

function turnIdFor(payload) {
  return optionalSafeId(payload.turn_id || payload.turnId || "");
}

function optionalSafeId(value) {
  return value ? safeId(value) : "";
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

function isSubagentPayload(payload) {
  return Boolean(payload.agent_id || payload.agent_type);
}

function agentKeyFor(payload) {
  return safeId(payload.agent_id || payload.turn_id || payload.turnId || payload.agent_type || "subagent");
}

function normalizeMainFact(main) {
  if (!main || typeof main !== "object") {
    return { state: "idle", label: "", tool: "", turnId: "", startedAt: 0 };
  }
  return {
    state: typeof main.state === "string" ? main.state : "idle",
    label: typeof main.label === "string" ? main.label : "",
    tool: typeof main.tool === "string" ? main.tool : "",
    turnId: typeof main.turnId === "string" ? optionalSafeId(main.turnId) : "",
    startedAt: Number(main.startedAt || 0),
  };
}

function normalizeSubagents(subagents) {
  if (!subagents || typeof subagents !== "object" || Array.isArray(subagents)) return {};
  const normalized = {};
  for (const [key, value] of Object.entries(subagents)) {
    if (!value || typeof value !== "object") continue;
    normalized[safeId(key)] = {
      state: typeof value.state === "string" ? value.state : "running",
      label: typeof value.label === "string" ? value.label : "Subagent running",
      tool: typeof value.tool === "string" ? value.tool : "",
      turnId: typeof value.turnId === "string" ? optionalSafeId(value.turnId) : "",
      startedAt: Number(value.startedAt || 0),
    };
  }
  return normalized;
}

function factsFromPrevious(prev) {
  if (prev.statusFacts && typeof prev.statusFacts === "object") {
    return {
      main: normalizeMainFact(prev.statusFacts.main),
      subagents: normalizeSubagents(prev.statusFacts.subagents),
    };
  }

  const state = typeof prev.state === "string" ? prev.state : "idle";
  const isSubagentOnly = prev.activity === "subagent";
  return {
    main: normalizeMainFact({
      state: isSubagentOnly ? "idle" : state,
      label: isSubagentOnly ? "" : prev.label || "",
      tool: isSubagentOnly ? "" : prev.tool || "",
      turnId: isSubagentOnly ? "" : prev.turnId || "",
      startedAt: isSubagentOnly ? 0 : Number(prev.startedAt || 0),
    }),
    subagents: {},
  };
}

function deriveVisibleState(facts) {
  const subagents = Object.values(facts.subagents || {})
    .filter((subagent) => subagent.state !== "done")
    .sort((left, right) => Number(right.startedAt || 0) - Number(left.startedAt || 0));
  const subagentPermission = subagents.find((subagent) => subagent.state === "permission");
  const runningSubagent = subagents.find((subagent) => subagent.state === "running");
  const main = facts.main || {};

  if (main.state === "permission") {
    return { state: "permission", label: main.label || "Awaiting permission", tool: main.tool || "", activity: "", startedAt: 0, turnId: main.turnId || "" };
  }
  if (subagentPermission) {
    return { state: "permission", label: "Subagent awaiting permission", tool: subagentPermission.tool || "", activity: "subagent", startedAt: 0, turnId: main.turnId || subagentPermission.turnId || "" };
  }
  if (main.state === "tool") {
    return { state: "tool", label: main.label || "Using tool", tool: main.tool || "", activity: "", startedAt: Number(main.startedAt || 0), turnId: main.turnId || "" };
  }
  if (main.state === "compacting") {
    return { state: "compacting", label: main.label || "Compacting", tool: main.tool || "", activity: "", startedAt: Number(main.startedAt || 0), turnId: main.turnId || "" };
  }
  if (runningSubagent) {
    return { state: "thinking", label: "Subagent running", tool: runningSubagent.tool || "", activity: "subagent", startedAt: Number(runningSubagent.startedAt || 0), turnId: main.turnId || runningSubagent.turnId || "" };
  }
  if (main.state === "thinking") {
    return { state: "thinking", label: main.label || "Thinking", tool: main.tool || "", activity: "", startedAt: Number(main.startedAt || 0), turnId: main.turnId || "" };
  }
  if (main.state === "waiting") {
    return { state: "waiting", label: main.label || "Waiting", tool: main.tool || "", activity: "", startedAt: 0, turnId: main.turnId || "" };
  }
  if (main.state === "done") {
    return { state: "done", label: "", tool: "", activity: "", startedAt: 0, turnId: main.turnId || "" };
  }
  return { state: "idle", label: "", tool: "", activity: "", startedAt: 0, turnId: main.turnId || "" };
}

function isActiveMainTurn(payload, facts, prev) {
  const turnId = turnIdFor(payload);
  const mainTurnId = facts.main.turnId || (prev.activity === "subagent" ? "" : prev.turnId || "");
  if (!turnId || !mainTurnId) return Boolean(prev.sessionId);
  return turnId === mainTurnId;
}

function updateMain(facts, patch) {
  return {
    ...facts,
    main: {
      ...facts.main,
      ...patch,
    },
  };
}

function updateSubagent(facts, payload, patch) {
  const key = agentKeyFor(payload);
  return {
    ...facts,
    subagents: {
      ...facts.subagents,
      [key]: {
        state: "running",
        label: "Subagent running",
        tool: "",
        turnId: turnIdFor(payload),
        startedAt: Number(patch.startedAt || 0),
        ...facts.subagents[key],
        ...patch,
      },
    },
  };
}

function stopSubagent(facts, payload) {
  const key = agentKeyFor(payload);
  const subagents = { ...facts.subagents };
  if (subagents[key]) {
    delete subagents[key];
  }
  return { ...facts, subagents };
}

function stateFor(payload, prev, facts, now) {
  const sessionId = sessionIdFor(payload);
  const pid = Number(prev.pid || process.ppid || 0);
  const surface = resolveSessionSurface(payload, prev, process.env, { pid, sessionId });
  const visible = deriveVisibleState(facts);
  return {
    state: visible.state,
    label: visible.label,
    tool: visible.tool,
    activity: visible.activity,
    threadName: latestThreadName(sessionId),
    project: basename(payload.cwd || payload.working_directory || payload.current_working_directory) || prev.project || "",
    sessionId,
    turnId: visible.turnId || facts.main.turnId || (prev.statusFacts ? "" : prev.turnId || ""),
    pid,
    entrypoint: surface.entrypoint,
    entrypointSource: surface.entrypointSource,
    termProgram: surface.termProgram,
    focusTarget: surface.focusTarget,
    transcript: typeof payload.transcript_path === "string" ? payload.transcript_path : prev.transcript || "",
    started: true,
    startedAt: visible.startedAt,
    ts: now,
    statusFacts: facts,
  };
}

function wait(ms) {
  if (ms > 0) {
    Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
  }
}

function writeStateForEvent(payload) {
  const sessionId = sessionIdFor(payload);
  const nowMs = Date.now();
  const now = nowMs / 1000;
  const prev = readPrevious(sessionId);
  let facts = factsFromPrevious(prev);
  let startedAt = Number(facts.main.startedAt || 0);
  const toolName = typeof payload.tool_name === "string" ? payload.tool_name : "";
  const inSubagent = isSubagentPayload(payload);

  switch (event) {
    case "UserPromptSubmit": {
      startedAt = now;
      facts = inSubagent
        ? updateSubagent(facts, payload, { state: "running", label: "Subagent running", tool: toolName, startedAt, turnId: turnIdFor(payload) })
        : updateMain(facts, { state: "thinking", label: "Thinking", tool: toolName, turnId: turnIdFor(payload), startedAt });
      writeJsonAtomic(statePathFor(sessionId), stateFor(payload, prev, facts, now));
      return true;
    }
    case "SubagentStart": {
      startedAt = now;
      facts = updateSubagent(facts, payload, { state: "running", label: "Subagent running", tool: toolName, turnId: turnIdFor(payload), startedAt });
      writeJsonAtomic(statePathFor(sessionId), stateFor(payload, prev, facts, now));
      return true;
    }
    case "PreToolUse": {
      if (inSubagent) {
        const subagentStartedAt = Number(facts.subagents[agentKeyFor(payload)]?.startedAt || now);
        facts = updateSubagent(facts, payload, { state: "running", label: "Subagent running", tool: toolName, turnId: turnIdFor(payload), startedAt: subagentStartedAt });
        writeJsonAtomic(statePathFor(sessionId), stateFor(payload, prev, facts, now));
        return true;
      }
      if (!isActiveMainTurn(payload, facts, prev)) return false;
      if (!startedAt) startedAt = now;
      facts = updateMain(facts, { state: "tool", label: labelForTool(toolName) || "Using tool", tool: toolName, turnId: turnIdFor(payload) || facts.main.turnId, startedAt });
      writeJsonAtomic(statePathFor(sessionId), {
        ...stateFor(payload, prev, facts, now),
        visibleUntilMs: nowMs + maxToolVisibleMs,
        minVisibleUntilMs: nowMs + minToolVisibleMs,
      });
      return true;
    }
    case "PreCompact": {
      if (inSubagent) {
        const subagentStartedAt = Number(facts.subagents[agentKeyFor(payload)]?.startedAt || now);
        facts = updateSubagent(facts, payload, { state: "running", label: "Subagent running", tool: toolName, turnId: turnIdFor(payload), startedAt: subagentStartedAt });
        writeJsonAtomic(statePathFor(sessionId), stateFor(payload, prev, facts, now));
        return true;
      }
      if (!isActiveMainTurn(payload, facts, prev)) return false;
      if (!startedAt) startedAt = now;
      facts = updateMain(facts, { state: "compacting", label: "Compacting", tool: toolName, turnId: turnIdFor(payload) || facts.main.turnId, startedAt });
      writeJsonAtomic(statePathFor(sessionId), stateFor(payload, prev, facts, now));
      return true;
    }
    case "PostToolUse": {
      if (inSubagent) {
        const subagentStartedAt = Number(facts.subagents[agentKeyFor(payload)]?.startedAt || now);
        facts = updateSubagent(facts, payload, { state: "running", label: "Subagent running", tool: toolName, turnId: turnIdFor(payload), startedAt: subagentStartedAt });
        writeJsonAtomic(statePathFor(sessionId), stateFor(payload, prev, facts, now));
        return true;
      }
      if (!isActiveMainTurn(payload, facts, prev)) return false;
      if (prev.state !== "permission") {
        const waitMs = Math.max(0, Number(prev.minVisibleUntilMs || prev.visibleUntilMs || 0) - nowMs);
        if (prev.state === "tool" && waitMs > 0) {
          wait(waitMs);
        }
      }
      const afterWaitNow = Date.now() / 1000;
      if (!startedAt) startedAt = afterWaitNow;
      facts = updateMain(facts, { state: "thinking", label: "Thinking", tool: toolName, turnId: turnIdFor(payload) || facts.main.turnId, startedAt });
      writeJsonAtomic(statePathFor(sessionId), stateFor(payload, prev, facts, afterWaitNow));
      return true;
    }
    case "PostCompact": {
      if (inSubagent) {
        const subagentStartedAt = Number(facts.subagents[agentKeyFor(payload)]?.startedAt || now);
        facts = updateSubagent(facts, payload, { state: "running", label: "Subagent running", tool: toolName, turnId: turnIdFor(payload), startedAt: subagentStartedAt });
        writeJsonAtomic(statePathFor(sessionId), stateFor(payload, prev, facts, now));
        return true;
      }
      if (!isActiveMainTurn(payload, facts, prev)) return false;
      const afterCompactNow = Date.now() / 1000;
      if (!startedAt) startedAt = afterCompactNow;
      facts = updateMain(facts, { state: "thinking", label: "Thinking", tool: toolName, turnId: turnIdFor(payload) || facts.main.turnId, startedAt });
      writeJsonAtomic(statePathFor(sessionId), stateFor(payload, prev, facts, afterCompactNow));
      return true;
    }
    case "PermissionRequest":
      facts = inSubagent
        ? updateSubagent(facts, payload, { state: "permission", label: "Subagent awaiting permission", tool: toolName, turnId: turnIdFor(payload), startedAt: Number(facts.subagents[agentKeyFor(payload)]?.startedAt || now) })
        : updateMain(facts, { state: "permission", label: "Awaiting permission", tool: toolName, turnId: turnIdFor(payload) || facts.main.turnId, startedAt: 0 });
      writeJsonAtomic(statePathFor(sessionId), {
        ...stateFor(payload, prev, facts, now),
        minVisibleUntilMs: nowMs + minPermissionVisibleMs,
      });
      return true;
    case "Stop":
      if (!isActiveMainTurn(payload, facts, prev)) return false;
      facts = {
        ...updateMain(facts, { state: "done", label: "", tool: "", turnId: turnIdFor(payload) || facts.main.turnId, startedAt: 0 }),
        subagents: {},
      };
      writeJsonAtomic(statePathFor(sessionId), stateFor(payload, prev, facts, now));
      return true;
    case "SubagentStop":
      facts = stopSubagent(facts, payload);
      writeJsonAtomic(statePathFor(sessionId), stateFor(payload, prev, facts, now));
      return true;
    case "SessionStart":
    case "SessionEnd":
    default:
      return false;
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

  try {
    if (debugEnabled) {
      appendJsonl(debugLogPath, {
        ts: new Date().toISOString(),
        event,
        rawBytes: Buffer.byteLength(raw || "", "utf8"),
        ...summarizePayload(payload),
      });
    }
    if (writeStateForEvent(payload)) {
      ensureStatusBarRunning({ scriptDir: __dirname, appPath });
    }
  } catch (error) {
    if (debugEnabled) {
      try {
        appendJsonl(debugLogPath, {
          ts: new Date().toISOString(),
          event,
          error: String(error && error.message ? error.message : error),
        });
      } catch {}
    }
  }

  process.exit(0);
}
