const cp = require("child_process");

const CODEX_BUNDLE_ID = "com.openai.codex";

function nonEmptyString(value) {
  return typeof value === "string" && value.trim() ? value.trim() : "";
}

function isDesktopEntrypoint(entrypoint) {
  return entrypoint === "codex-desktop" || entrypoint === "desktop" || entrypoint === "app";
}

function codexThreadUrl(sessionId) {
  const id = nonEmptyString(sessionId);
  return id ? `codex://threads/${encodeURIComponent(id)}` : "";
}

function codexBundleTarget() {
  return { kind: "bundle", bundleId: CODEX_BUNDLE_ID };
}

function codexThreadTarget(sessionId) {
  const url = codexThreadUrl(sessionId);
  if (!url) return codexBundleTarget();
  return {
    kind: "url",
    url,
    fallback: codexBundleTarget(),
  };
}

function terminalAppName(termProgram) {
  switch (termProgram) {
    case "Apple_Terminal":
      return "Terminal";
    case "iTerm.app":
      return "iTerm";
    case "WarpTerminal":
      return "Warp";
    case "vscode":
      return "Visual Studio Code";
    default:
      return termProgram;
  }
}

function isCodexDesktopCommand(command) {
  return /Codex\.app\/Contents\/Resources\/codex app-server/.test(command)
    || /\/Applications\/Codex\.app\//.test(command);
}

function processCommandForPid(pid) {
  const numericPid = Number(pid || 0);
  if (!numericPid) return "";
  try {
    return cp.execFileSync("/bin/ps", ["-p", String(numericPid), "-o", "command="], {
      encoding: "utf8",
      stdio: ["ignore", "pipe", "ignore"],
      timeout: 400,
    }).trim();
  } catch {
    return "";
  }
}

function focusTargetForState(state) {
  const existing = state && state.focusTarget;
  if (existing && typeof existing === "object" && nonEmptyString(existing.kind)) {
    return existing;
  }

  const entrypoint = nonEmptyString(state && state.entrypoint).toLowerCase();
  const termProgram = nonEmptyString(state && (state.termProgram || state.term_program));
  if (isDesktopEntrypoint(entrypoint)) {
    return codexThreadTarget(state && state.sessionId);
  }
  if (entrypoint === "cli" && termProgram) {
    return { kind: "app", appName: terminalAppName(termProgram) };
  }
  return { kind: "none" };
}

function resolved(entrypoint, entrypointSource, termProgram, focusTarget) {
  const cleanEntrypoint = nonEmptyString(entrypoint) || "unknown";
  const state = {
    entrypoint: cleanEntrypoint,
    termProgram: nonEmptyString(termProgram),
    focusTarget,
  };
  return {
    entrypoint: cleanEntrypoint,
    entrypointSource,
    termProgram: state.termProgram,
    focusTarget: focusTargetForState(state),
  };
}

function resolveSessionSurface(payload = {}, prev = {}, env = process.env, options = {}) {
  const sessionId = nonEmptyString(options.sessionId) || nonEmptyString(payload.session_id) || nonEmptyString(payload.sessionId) || nonEmptyString(prev.sessionId);
  const payloadEntrypoint = nonEmptyString(payload.entrypoint) || nonEmptyString(payload.entry_point);
  const payloadTermProgram = nonEmptyString(payload.term_program) || nonEmptyString(payload.termProgram);
  const envEntrypoint = nonEmptyString(env.CODEX_STATUSBAR_ENTRYPOINT) || nonEmptyString(env.CODEX_ENTRYPOINT);
  const envTermProgram = nonEmptyString(env.TERM_PROGRAM);
  const previousTermProgram = nonEmptyString(prev.termProgram) || nonEmptyString(prev.term_program);
  const termProgram = payloadTermProgram || envTermProgram || previousTermProgram;

  if (payloadEntrypoint) {
    return resolved(payloadEntrypoint, "payload", termProgram, focusTargetForState({ entrypoint: payloadEntrypoint, termProgram, sessionId }));
  }
  if (envEntrypoint) {
    return resolved(envEntrypoint, "env", termProgram, focusTargetForState({ entrypoint: envEntrypoint, termProgram, sessionId }));
  }
  if (envTermProgram) {
    return resolved("cli", "termProgram", envTermProgram, focusTargetForState({ entrypoint: "cli", termProgram: envTermProgram, sessionId }));
  }

  const pid = Number(options.pid || prev.pid || process.ppid || 0);
  const processCommand = typeof options.processCommand === "string"
    ? options.processCommand
    : processCommandForPid(pid);
  if (isCodexDesktopCommand(processCommand)) {
    return resolved("codex-desktop", "process", termProgram, focusTargetForState({ entrypoint: "codex-desktop", termProgram, sessionId }));
  }

  const previousEntrypoint = nonEmptyString(prev.entrypoint);
  if (previousEntrypoint && previousEntrypoint !== "unknown") {
    return resolved(previousEntrypoint, "previous", termProgram, prev.focusTarget);
  }

  return resolved("unknown", "unknown", termProgram);
}

module.exports = {
  CODEX_BUNDLE_ID,
  focusTargetForState,
  resolveSessionSurface,
  terminalAppName,
};
