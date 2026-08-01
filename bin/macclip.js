#!/usr/bin/env node

import { spawnSync } from "node:child_process";
import { copyFileSync, existsSync, mkdirSync, rmSync, writeFileSync } from "node:fs";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const projectRoot = path.resolve(__dirname, "..");

const APP_NAME = "MacClip";
const LABEL = "com.macclip.agent";

const UID = process.getuid?.();
const DOMAIN = UID != null ? `gui/${UID}` : null;

const HOME = os.homedir();
const installDir = path.join(HOME, "Library", "ApplicationSupport", APP_NAME);
const binPath = path.join(installDir, APP_NAME);
const sessionPlistPath = path.join(installDir, `${LABEL}.plist`);
const launchAgentPlistPath = path.join(HOME, "Library", "LaunchAgents", `${LABEL}.plist`);
const packagePath = path.join(projectRoot, "Package.swift");
const builtBinaryPath = path.join(projectRoot, ".build", "release", "macclip");

function fail(message) {
  console.error(`Error: ${message}`);
  process.exit(1);
}

function run(cmd, args, check = true) {
  const result = spawnSync(cmd, args, { encoding: "utf8" });
  if (result.error) {
    fail(result.error.message);
  }

  if (check && result.status !== 0) {
    const out = (result.stderr || result.stdout || "").trim();
    fail(`${cmd} ${args.join(" ")} failed${out ? `\n${out}` : ""}`);
  }
  return result;
}

function ensureMacOS() {
  if (process.platform !== "darwin") {
    fail("This package only works on macOS.");
  }
}

function ensureUID() {
  if (UID == null || DOMAIN == null) {
    fail("Unable to resolve current user UID.");
  }
}

function ensureSource() {
  if (!existsSync(packagePath)) {
    fail(`Cannot find Swift package manifest: ${packagePath}`);
  }
}

function serviceTarget(label) {
  ensureUID();
  return `${DOMAIN}/${label}`;
}

function launchAgentPlistForLabel(label) {
  return path.join(HOME, "Library", "LaunchAgents", `${label}.plist`);
}

function sessionPlistForLabel(label) {
  return path.join(installDir, `${label}.plist`);
}

function ensureDirectories() {
  mkdirSync(path.dirname(launchAgentPlistPath), { recursive: true });
  mkdirSync(installDir, { recursive: true });
}

function compileBinary() {
  ensureSource();
  ensureDirectories();

  run("swift", ["build", "-c", "release", "--package-path", projectRoot], true);
  copyFileSync(builtBinaryPath, binPath);
}

function plistXML() {
  return `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>${LABEL}</string>
  <key>ProgramArguments</key>
  <array>
    <string>${binPath}</string>
  </array>
  <key>RunAtLoad</key>
  <true/>
  <key>KeepAlive</key>
  <false/>
</dict>
</plist>
`;
}

function writePlist(filePath) {
  ensureDirectories();
  writeFileSync(filePath, plistXML(), "utf8");
}

function bootoutLabel(label) {
  run("launchctl", ["bootout", serviceTarget(label)], false);
  run("launchctl", ["bootout", DOMAIN, launchAgentPlistForLabel(label)], false);
  run("launchctl", ["bootout", DOMAIN, sessionPlistForLabel(label)], false);
}

function bootoutAllKnown() {
  bootoutLabel(LABEL);
}

function startAgent(plistPath) {
  bootoutAllKnown();
  run("launchctl", ["enable", serviceTarget(LABEL)], false);
  run("launchctl", ["bootstrap", DOMAIN, plistPath], true);
  run("launchctl", ["kickstart", "-k", serviceTarget(LABEL)], true);
}

function stopAgent() {
  bootoutAllKnown();
}

function install({ autostart }) {
  ensureMacOS();
  compileBinary();
  writePlist(sessionPlistPath);

  if (autostart) {
    writePlist(launchAgentPlistPath);
    startAgent(launchAgentPlistPath);
    console.log(`${APP_NAME} installed and running with autostart enabled.`);
  } else {
    rmSync(launchAgentPlistPath, { force: true });
    startAgent(sessionPlistPath);
    console.log(`${APP_NAME} installed and running (autostart disabled).`);
  }

  console.log("Option+V: clipboard history · Option+Shift+R: capture region");
}

function uninstall() {
  ensureMacOS();
  stopAgent();

  rmSync(launchAgentPlistPath, { force: true });
  rmSync(sessionPlistPath, { force: true });
  rmSync(binPath, { force: true });

  console.log(`${APP_NAME} stopped and removed.`);
}

function getRunningOutput() {
  const res = run("launchctl", ["print", serviceTarget(LABEL)], false);
  return res.status === 0 ? res.stdout : null;
}

function status() {
  ensureMacOS();
  ensureUID();

  const running = getRunningOutput();
  const autostartEnabled = existsSync(launchAgentPlistPath);

  if (!running) {
    console.log(`${APP_NAME} is not running. Autostart: ${autostartEnabled ? "enabled" : "disabled"}`);
    process.exit(0);
  }

  const lines = running
    .split("\n")
    .filter((line) => line.includes("state =") || line.includes("pid =") || line.includes("last exit code"));

  console.log(`${APP_NAME} status (autostart: ${autostartEnabled ? "enabled" : "disabled"}):`);
  for (const line of lines) {
    console.log(line.trim());
  }
}

function start() {
  ensureMacOS();

  const chosenPlist = existsSync(launchAgentPlistPath) ? launchAgentPlistPath : sessionPlistPath;
  if (!existsSync(chosenPlist)) {
    fail(`Missing plist: ${chosenPlist}\nRun: macclip install`);
  }

  startAgent(chosenPlist);
  console.log(`${APP_NAME} started.`);
}

function stop() {
  ensureMacOS();
  stopAgent();
  console.log(`${APP_NAME} stopped.`);
}

function setAutostart(enabled) {
  ensureMacOS();

  if (!existsSync(binPath)) {
    fail(`${APP_NAME} is not installed. Run: macclip install`);
  }

  writePlist(sessionPlistPath);

  if (enabled) {
    writePlist(launchAgentPlistPath);
    startAgent(launchAgentPlistPath);
    console.log("Autostart enabled.");
  } else {
    const wasRunning = getRunningOutput() != null;
    if (wasRunning) {
      stopAgent();
    }
    rmSync(launchAgentPlistPath, { force: true });
    if (wasRunning) {
      startAgent(sessionPlistPath);
    }
    console.log("Autostart disabled.");
  }
}

function help() {
  console.log(`macclip <command>

Commands:
  install [--autostart]   Build + install + start app
  start                   Start app
  stop                    Stop app
  status                  Show running status + autostart state
  autostart on|off        Toggle login autostart
  uninstall               Stop app and remove files
  help                    Show this help
`);
}

const cmd = (process.argv[2] || "help").toLowerCase();
const args = process.argv.slice(3);

switch (cmd) {
  case "install":
    install({ autostart: args.includes("--autostart") });
    break;
  case "start":
    start();
    break;
  case "stop":
    stop();
    break;
  case "status":
    status();
    break;
  case "autostart":
    if (args[0] === "on") {
      setAutostart(true);
      break;
    }
    if (args[0] === "off") {
      setAutostart(false);
      break;
    }
    fail("Usage: macclip autostart on|off");
    break;
  case "uninstall":
    uninstall();
    break;
  case "help":
    help();
    break;
  default:
    fail(`Unknown command: ${cmd}\nRun: macclip help`);
}
