#!/usr/bin/env node
const fs = require("fs");
const os = require("os");
const path = require("path");
const { readHooks, removeOwnHooks, writeHooks } = require("./lib/hook-manager");

const hooksPath = path.join(os.homedir(), ".codex", "hooks.json");

if (!fs.existsSync(hooksPath)) {
  console.log(`No hooks file at ${hooksPath}`);
  process.exit(0);
}

const settings = removeOwnHooks(readHooks(hooksPath));
writeHooks(hooksPath, settings);
console.log(`Removed Codex Status Bar hooks from ${hooksPath}`);
