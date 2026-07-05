#!/usr/bin/env node
const fs = require("fs");
const os = require("os");
const path = require("path");
const {
  findNode,
  parseAppPathArg,
  readHooks,
  repairHooks,
  resolveScriptPaths,
  writeHooks,
} = require("./lib/hook-manager");

const home = os.homedir();
const repoRoot = path.resolve(__dirname, "..");
const hooksPath = path.join(home, ".codex", "hooks.json");

function main() {
  const appPath = parseAppPathArg();
  const nodePath = findNode({ currentExecPath: process.execPath });
  const { writerPath, lifecyclePath } = resolveScriptPaths({ scriptDir: __dirname, repoRoot, appPath });

  if (!fs.existsSync(writerPath)) {
    throw new Error(`Writer not found: ${writerPath}`);
  }
  if (!fs.existsSync(lifecyclePath)) {
    throw new Error(`Lifecycle writer not found: ${lifecyclePath}`);
  }

  const settings = readHooks(hooksPath);

  fs.mkdirSync(path.dirname(hooksPath), { recursive: true });
  const backupPath = `${hooksPath}.bak-codex-status-bar`;
  if (fs.existsSync(hooksPath) && !fs.existsSync(backupPath)) {
    fs.copyFileSync(hooksPath, backupPath);
  }

  const repaired = repairHooks(settings, { nodePath, writerPath, lifecyclePath, appPath });
  writeHooks(hooksPath, repaired);
  console.log(`Installed Codex Status Bar hooks into ${hooksPath}`);
  console.log(`Node: ${nodePath}`);
  if (appPath) console.log(`App: ${appPath}`);
  console.log(`Backup: ${backupPath}`);
  console.log(`State directory: ${path.join(home, ".codex", "statusbar", "state.d")}`);
}

try {
  main();
} catch (error) {
  console.error(error && error.stack ? error.stack : error);
  process.exit(1);
}
