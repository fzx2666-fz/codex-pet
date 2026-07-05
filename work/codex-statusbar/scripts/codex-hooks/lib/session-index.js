const fs = require("fs");
const os = require("os");
const path = require("path");

const DEFAULT_THREAD_NAME = "Unknown";
const SIDE_CHAT_THREAD_NAME = "Side Chat";

function sessionIndexPath(env = process.env) {
  return env.CODEX_SESSION_INDEX_PATH || path.join(os.homedir(), ".codex", "session_index.jsonl");
}

function globalStatePath(env = process.env) {
  return env.CODEX_GLOBAL_STATE_PATH || path.join(os.homedir(), ".codex", ".codex-global-state.json");
}

function latestSessionIndexThreadName(sessionId, env = process.env) {
  if (!sessionId) return DEFAULT_THREAD_NAME;

  let latest = "";
  try {
    const text = fs.readFileSync(sessionIndexPath(env), "utf8");
    for (const line of text.split(/\n+/)) {
      if (!line) continue;
      let row;
      try {
        row = JSON.parse(line);
      } catch {
        continue;
      }
      if (row.id === sessionId && typeof row.thread_name === "string" && row.thread_name.trim()) {
        latest = row.thread_name.trim();
      }
    }
  } catch {
    return DEFAULT_THREAD_NAME;
  }

  return latest || DEFAULT_THREAD_NAME;
}

function hasSideChatPromptHistory(sessionId, env = process.env) {
  if (!sessionId) return false;

  try {
    const globalState = JSON.parse(fs.readFileSync(globalStatePath(env), "utf8"));
    const persistedState = globalState["electron-persisted-atom-state"];
    const promptHistory = persistedState && persistedState["prompt-history"];
    const prompts = promptHistory && promptHistory[sessionId];
    return Array.isArray(prompts) && prompts.some((prompt) => typeof prompt === "string" && prompt.trim());
  } catch {
    return false;
  }
}

function latestThreadName(sessionId, env = process.env) {
  const indexName = latestSessionIndexThreadName(sessionId, env);
  if (indexName !== DEFAULT_THREAD_NAME) {
    return indexName;
  }
  if (hasSideChatPromptHistory(sessionId, env)) {
    return SIDE_CHAT_THREAD_NAME;
  }
  return DEFAULT_THREAD_NAME;
}

module.exports = {
  DEFAULT_THREAD_NAME,
  SIDE_CHAT_THREAD_NAME,
  globalStatePath,
  hasSideChatPromptHistory,
  latestThreadName,
  latestSessionIndexThreadName,
  sessionIndexPath,
};
