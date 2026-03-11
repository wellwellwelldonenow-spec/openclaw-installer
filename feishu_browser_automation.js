#!/usr/bin/env node

const { spawnSync } = require("child_process");
const fs = require("fs");
const os = require("os");
const path = require("path");

const OPENCLAW_COMMAND = process.platform === "win32" ? "openclaw.cmd" : "openclaw";
const LOG_PATH = path.join(os.tmpdir(), "feishu-browser-automation.log");

const TEXT = {
  eventPage: "\u4e8b\u4ef6\u4e0e\u56de\u8c03",
  eventConfig: "\u4e8b\u4ef6\u914d\u7f6e",
  subscriptionMethod: "\u8ba2\u9605\u65b9\u5f0f",
  useLongConnection: "\u4f7f\u7528 \u957f\u8fde\u63a5 \u63a5\u6536\u4e8b\u4ef6 \u63a8\u8350",
  longConnection: "\u957f\u8fde\u63a5",
  addEvent: "\u6dfb\u52a0\u4e8b\u4ef6",
  addEventDialog: "\u6dfb\u52a0\u4e8b\u4ef6",
  receiveMessage: "\u63a5\u6536\u6d88\u606f",
  receiveMessageEvent: "im.message.receive_v1",
  versionManagement: "\u7248\u672c\u7ba1\u7406\u4e0e\u53d1\u5e03",
  createVersion: "\u521b\u5efa\u7248\u672c",
  versionDetails: "\u7248\u672c\u8be6\u60c5",
  currentChangesPublished: "\u5f53\u524d\u4fee\u6539\u5747\u5df2\u53d1\u5e03",
  pendingPublish: "\u5f85\u7533\u8bf7",
  published: "\u5df2\u53d1\u5e03",
  confirmPublish: "\u786e\u8ba4\u53d1\u5e03",
  confirmPublishDialog: "\u786e\u8ba4\u63d0\u4ea4\u53d1\u5e03\u7533\u8bf7\uff1f",
  versionNumber: "\u5e94\u7528\u7248\u672c\u53f7",
  updateNotes: "\u66f4\u65b0\u8bf4\u660e",
  appCapability: "\u5e94\u7528\u80fd\u529b",
  createEnterpriseApp: "\u521b\u5efa\u4f01\u4e1a\u81ea\u5efa\u5e94\u7528",
  createApp: "\u521b\u5efa",
  appIcon: "\u5e94\u7528\u56fe\u6807",
  cancel: "\u53d6\u6d88",
  bot: "\u673a\u5668\u4eba",
  botConfig: "\u673a\u5668\u4eba\u914d\u7f6e",
  deleteCapability: "\u5220\u9664\u80fd\u529b",
  add: "\u6dfb\u52a0",
  webApp: "\u7f51\u9875\u5e94\u7528",
  appId: "App ID",
  appSecret: "App Secret",
  summaryInfo: "\u7efc\u5408\u4fe1\u606f",
  permissions: "\u5f00\u901a\u6743\u9650",
  permissionsDialog: "\u5f00\u901a\u6743\u9650",
  permissionsConfirm: "\u786e\u8ba4\u5f00\u901a\u6743\u9650",
  messageAndGroup: "\u6d88\u606f\u4e0e\u7fa4\u7ec4",
  permissionsHeader: "\u6743\u9650\u540d\u79f0 \u662f\u5426\u9700\u8981\u5ba1\u6838 \u5173\u8054 API/\u4e8b\u4ef6",
  iKnow: "\u6211\u77e5\u9053\u4e86",
};

function parseArgs(argv) {
  const options = {
    mode: "bootstrap",
    appId: "",
    appName: `OpenClaw ${timestamp()}`,
    appDescription: "OpenClaw Feishu channel integration",
    versionNumber: defaultVersionNumber(),
    versionNotes: "OpenClaw Feishu channel auto setup",
    verbose: false,
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];
    if (arg === "--mode") {
      options.mode = (argv[i + 1] || options.mode).toLowerCase();
      i += 1;
    } else if (arg === "--app-id") {
      options.appId = argv[i + 1] || options.appId;
      i += 1;
    } else if (arg === "--app-name") {
      options.appName = argv[i + 1] || options.appName;
      i += 1;
    } else if (arg === "--app-description") {
      options.appDescription = argv[i + 1] || options.appDescription;
      i += 1;
    } else if (arg === "--version-number") {
      options.versionNumber = argv[i + 1] || options.versionNumber;
      i += 1;
    } else if (arg === "--version-notes") {
      options.versionNotes = argv[i + 1] || options.versionNotes;
      i += 1;
    } else if (arg === "--verbose") {
      options.verbose = true;
    }
  }

  return options;
}

function timestamp() {
  const now = new Date();
  return [
    now.getFullYear().toString(),
    String(now.getMonth() + 1).padStart(2, "0"),
    String(now.getDate()).padStart(2, "0"),
    "-",
    String(now.getHours()).padStart(2, "0"),
    String(now.getMinutes()).padStart(2, "0"),
    String(now.getSeconds()).padStart(2, "0"),
  ].join("");
}

function defaultVersionNumber() {
  return `1.0.${Math.floor(Date.now() / 1000)}`;
}

function sleep(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

function log(options, message) {
  if (!options.verbose) {
    return;
  }

  fs.appendFileSync(LOG_PATH, `[INFO] ${message}\n`);
  process.stderr.write(`[INFO] ${message}\n`);
}

function run(command, args, options = {}) {
  if (process.platform === "win32" && command === OPENCLAW_COMMAND) {
    const escapedArgs = args
      .map((arg) => `'${String(arg).replace(/'/g, "''")}'`)
      .join(", ");
    const psCommand = [
      "[Console]::InputEncoding = [System.Text.Encoding]::UTF8",
      "[Console]::OutputEncoding = [System.Text.Encoding]::UTF8",
      `$OutputEncoding = [Console]::OutputEncoding`,
      `$openclawArgs = @(${escapedArgs})`,
      "openclaw @openclawArgs",
    ].join("; ");

    return run("powershell.exe", ["-NoProfile", "-Command", psCommand], options);
  }

  const result = spawnSync(command, args, {
    encoding: "utf8",
    shell: false,
    windowsHide: true,
  });

  if (result.error) {
    throw result.error;
  }

  const stdout = result.stdout || "";
  const stderr = result.stderr || "";
  const output = `${stdout}${stderr}`.trim();

  if (result.status !== 0 && !options.allowFailure) {
    throw new Error(output || `${command} exited with code ${result.status}`);
  }

  return {
    stdout,
    stderr,
    output,
    status: result.status || 0,
  };
}

function runOpenClaw(args, options = {}) {
  let attempt = 0;
  while (attempt < 4) {
    try {
      return run(OPENCLAW_COMMAND, ["browser", ...args], options);
    } catch (error) {
      attempt += 1;
      const message = error && error.message ? error.message : String(error);
      const isTransient =
        message.includes("gateway closed") ||
        message.includes("gateway connect failed") ||
        message.includes("ECONNRESET");

      if (!isTransient || attempt >= 4 || options.allowFailure) {
        throw error;
      }

      sleep(1500);
    }
  }

  throw new Error("openclaw browser command failed after retries");
}

function parseTargetId(output) {
  const match = output.match(/^id:\s*(\S+)/m);
  return match ? match[1] : "";
}

function parseTabs(output) {
  const entries = [];
  const lines = output.split(/\r?\n/);

  for (let i = 0; i < lines.length; i += 1) {
    const titleLine = (lines[i] || "").trim();
    const titleMatch = titleLine.match(/^\d+\.\s*(.*)$/);
    if (!titleMatch) {
      continue;
    }

    const title = titleMatch[1].trim();
    const url = (lines[i + 1] || "").trim();
    const idLine = (lines[i + 2] || "").trim();
    const idMatch = idLine.match(/^id:\s*(\S+)/);
    if (!idMatch) {
      continue;
    }

    entries.push({
      title,
      url,
      id: idMatch[1],
    });
  }

  return entries;
}

function getTabById(targetId) {
  return parseTabs(runOpenClaw(["tabs"]).output).find((entry) => entry.id === targetId) || null;
}

function findTab(pattern) {
  return parseTabs(runOpenClaw(["tabs"]).output).find((entry) => pattern.test(entry.url)) || null;
}

function findBestFeishuHomeTab() {
  const tabs = parseTabs(runOpenClaw(["tabs"]).output).filter((entry) =>
    /^https:\/\/open\.feishu\.cn\/app(?:\?[^#]*)?$/.test(entry.url),
  );

  let fallback = null;
  for (const tab of tabs) {
    fallback = fallback || tab;

    try {
      const currentSnapshot = snapshot(tab.id, 260);
      if (
        isCreateAppDialog(currentSnapshot) ||
        findCreateAppButtonRef(currentSnapshot) ||
        currentSnapshot.includes("\u641c\u7d22\u5e94\u7528\u540d\u79f0\u6216 App ID")
      ) {
        return tab;
      }
    } catch (_error) {
      // Ignore transient tab snapshot failures and keep scanning.
    }
  }

  return fallback;
}

function waitFor(condition, timeoutMs, errorMessage, intervalMs = 2000) {
  const deadline = Date.now() + timeoutMs;
  while (Date.now() < deadline) {
    const value = condition();
    if (value) {
      return value;
    }

    sleep(intervalMs);
  }

  throw new Error(errorMessage);
}

function waitForTabUrl(targetId, pattern, timeoutMs) {
  return waitFor(() => {
    const tab = getTabById(targetId);
    if (tab && pattern.test(tab.url)) {
      return tab.url;
    }
    return "";
  }, timeoutMs, `Timed out waiting for URL ${pattern}`);
}

function snapshot(targetId, limit = 500) {
  return runOpenClaw(["snapshot", "--target-id", targetId, "--limit", String(limit)]).output;
}

function clickRef(targetId, ref) {
  runOpenClaw(["click", ref, "--target-id", targetId]);
}

function typeRef(targetId, ref, value) {
  runOpenClaw(["type", ref, value, "--target-id", targetId]);
}

function openUrl(url) {
  const output = runOpenClaw(["open", url]).output;
  const targetId = parseTargetId(output);
  if (!targetId) {
    throw new Error(`Unable to determine browser target id for ${url}`);
  }

  return targetId;
}

function extractRef(line) {
  const match = line.match(/\[ref=([^\]]+)\]/);
  return match ? match[1] : "";
}

function lineForRef(snapshotText, ref) {
  return snapshotText
    .split(/\r?\n/)
    .find((line) => extractRef(line) === ref) || "";
}

function matchesType(line, typeNames) {
  if (!typeNames || typeNames.length === 0) {
    return true;
  }

  return typeNames.some((typeName) => new RegExp(`^\\s*-\\s*${typeName}\\b`).test(line));
}

function matchesText(line, text) {
  return line.includes(`"${text}"`) || line.includes(`: ${text}`) || line.includes(text);
}

function findRef(snapshotText, predicate, index = 1) {
  let found = 0;

  for (const line of snapshotText.split(/\r?\n/)) {
    if (!predicate(line)) {
      continue;
    }

    const ref = extractRef(line);
    if (!ref) {
      continue;
    }

    found += 1;
    if (found === index) {
      return ref;
    }
  }

  return "";
}

function findRefByText(snapshotText, text, typeNames = [], index = 1, requireCursor = false) {
  return findRef(snapshotText, (line) => {
    if (!matchesType(line, typeNames)) {
      return false;
    }
    if (requireCursor && !line.includes("[cursor=pointer]")) {
      return false;
    }
    return matchesText(line, text);
  }, index);
}

function findRefInSection(snapshotText, options) {
  const {
    anchor,
    stop = "",
    typeNames = [],
    text = "",
    index = 1,
    requireCursor = false,
  } = options;

  let inSection = false;
  let found = 0;

  for (const line of snapshotText.split(/\r?\n/)) {
    if (!inSection) {
      if (line.includes(anchor)) {
        inSection = true;
      }
      continue;
    }

    if (stop && line.includes(stop)) {
      break;
    }
    if (!matchesType(line, typeNames)) {
      continue;
    }
    if (requireCursor && !line.includes("[cursor=pointer]")) {
      continue;
    }
    if (text && !matchesText(line, text)) {
      continue;
    }

    const ref = extractRef(line);
    if (!ref) {
      continue;
    }

    found += 1;
    if (found === index) {
      return ref;
    }
  }

  return "";
}

function getDialogSnapshot(snapshotText, dialogText = "") {
  const lines = snapshotText.split(/\r?\n/);
  let dialogStart = -1;

  for (let i = lines.length - 1; i >= 0; i -= 1) {
    if (/^\s*-\s*dialog\b/.test(lines[i])) {
      dialogStart = i;
      break;
    }
  }

  if (dialogStart === -1) {
    return "";
  }

  const dialogSnapshot = lines.slice(dialogStart).join("\n");
  if (dialogText && !dialogSnapshot.includes(dialogText)) {
    return "";
  }

  return dialogSnapshot;
}

function extractTextValueInSection(snapshotText, options) {
  const { anchor, stop = "" } = options;
  let inSection = false;

  for (const line of snapshotText.split(/\r?\n/)) {
    if (!inSection) {
      if (line.includes(anchor)) {
        inSection = true;
      }
      continue;
    }

    if (stop && line.includes(stop)) {
      break;
    }

    const match = line.match(/^\s*-\s*generic(?:\s+\[ref=[^\]]+\])?:\s*(.+)$/);
    if (!match) {
      continue;
    }

    const value = match[1].trim();
    if (!value || value === anchor) {
      continue;
    }

    return value;
  }

  return "";
}

function extractRefsInSection(snapshotText, options) {
  const {
    anchor,
    stop = "",
    typeNames = [],
    requireCursor = false,
  } = options;

  const refs = [];
  let inSection = false;

  for (const line of snapshotText.split(/\r?\n/)) {
    if (!inSection) {
      if (line.includes(anchor)) {
        inSection = true;
      }
      continue;
    }

    if (stop && line.includes(stop)) {
      break;
    }
    if (!matchesType(line, typeNames)) {
      continue;
    }
    if (requireCursor && !line.includes("[cursor=pointer]")) {
      continue;
    }

    const ref = extractRef(line);
    if (ref) {
      refs.push(ref);
    }
  }

  return refs;
}

function isMaskedValue(value) {
  return /^[*∗•\s]+$/.test((value || "").trim());
}

function isMaskedValue(value) {
  return /^[*\u2217\u2022\s]+$/.test((value || "").trim());
}

function isRefDisabled(snapshotText, ref) {
  const line = lineForRef(snapshotText, ref);
  return !!line && line.includes("[disabled]");
}

function findCheckboxBeforeText(snapshotText, text, lookBehind = 8) {
  const lines = snapshotText.split(/\r?\n/);
  for (let i = 0; i < lines.length; i += 1) {
    if (!matchesText(lines[i], text)) {
      continue;
    }

    for (let j = i - 1; j >= Math.max(0, i - lookBehind); j -= 1) {
      if (!matchesType(lines[j], ["checkbox"])) {
        continue;
      }

      const ref = extractRef(lines[j]);
      if (ref) {
        return ref;
      }
    }
  }

  return "";
}

function isCheckboxCheckedBeforeText(snapshotText, text, lookBehind = 8) {
  const lines = snapshotText.split(/\r?\n/);
  for (let i = 0; i < lines.length; i += 1) {
    if (!matchesText(lines[i], text)) {
      continue;
    }

    for (let j = i - 1; j >= Math.max(0, i - lookBehind); j -= 1) {
      if (!matchesType(lines[j], ["checkbox"])) {
        continue;
      }
      return lines[j].includes("[checked]");
    }
  }

  return false;
}

function clickOptionalByText(targetId, text, typeNames = ["button"]) {
  const currentSnapshot = snapshot(targetId, 260);
  const ref = findRefByText(currentSnapshot, text, typeNames, 1, false);
  if (!ref) {
    return false;
  }

  clickRef(targetId, ref);
  sleep(1200);
  return true;
}

function readClipboard() {
  const commands = process.platform === "win32"
    ? [["powershell.exe", ["-NoProfile", "-Command", "Get-Clipboard"]]]
    : [
        ["pbpaste", []],
        ["wl-paste", ["-n"]],
        ["xclip", ["-o", "-selection", "clipboard"]],
        ["xsel", ["--clipboard", "--output"]],
      ];

  for (const [command, args] of commands) {
    const result = run(command, args, { allowFailure: true });
    const value = result.stdout.trim();
    if (result.status === 0 && value) {
      return value;
    }
  }

  return "";
}

function readClipboardWithRetry(timeoutMs = 6000) {
  return waitFor(() => {
    const value = readClipboard();
    return value || "";
  }, timeoutMs, "Unable to read the clipboard");
}

function getAppIdFromUrl(url) {
  const match = url.match(/\/app\/(cli_[^/]+)/);
  return match ? match[1] : "";
}

function waitForFeishuLogin(targetId, options) {
  return waitFor(() => {
    const tab = getTabById(targetId);
    if (!tab || !/^https:\/\/open\.feishu\.cn\/app(?:[/?]|$)/.test(tab.url)) {
      return "";
    }

    const currentAppId = getAppIdFromUrl(tab.url);
    if (currentAppId) {
      return tab.url;
    }

    const currentSnapshot = snapshot(targetId, 260);
    if (
      currentSnapshot.includes(TEXT.createEnterpriseApp) ||
      currentSnapshot.includes("\u641c\u7d22\u5e94\u7528\u540d\u79f0\u6216 App ID") ||
      currentSnapshot.includes("\u521b\u5efa\u4f60\u7684\u7b2c\u4e00\u4e2a\u6d4b\u8bd5\u5e94\u7528")
    ) {
      return tab.url;
    }

    log(options, `Waiting for Feishu app list to finish loading: ${tab.url}`);
    return "";
  }, 10 * 60 * 1000, "Timed out waiting for Feishu login", 3000);
}

function findCreateAppButtonRef(snapshotText) {
  return findRefByText(snapshotText, TEXT.createEnterpriseApp, ["button"], 1, true);
}

function isCreateAppDialog(snapshotText) {
  return snapshotText.includes(TEXT.appIcon) && snapshotText.includes(TEXT.createEnterpriseApp);
}

function waitForDialog(targetId, dialogText, timeoutMs) {
  return waitFor(() => {
    const currentSnapshot = snapshot(targetId, 360);
    const dialogSnapshot = getDialogSnapshot(currentSnapshot, dialogText);
    return dialogSnapshot || "";
  }, timeoutMs, `Timed out waiting for dialog ${dialogText}`);
}

function createFeishuApp(targetId, appName, appDescription, options) {
  const currentUrl = waitForFeishuLogin(targetId, options);
  const existingAppId = getAppIdFromUrl(currentUrl);
  if (existingAppId) {
    log(options, `Already inside existing app: ${existingAppId}`);
    return existingAppId;
  }

  let currentSnapshot = waitFor(() => {
    const pageSnapshot = snapshot(targetId, 360);
    if (isCreateAppDialog(pageSnapshot) || findCreateAppButtonRef(pageSnapshot)) {
      return pageSnapshot;
    }
    return "";
  }, 30000, "Unable to find the create app entry");

  log(options, "Detected Feishu app home page");

  if (!isCreateAppDialog(currentSnapshot)) {
    const createButtonRef = findCreateAppButtonRef(currentSnapshot);
    if (!createButtonRef) {
      throw new Error("Unable to find the create app button on an existing-account page");
    }

    log(options, `Open create app dialog: ${createButtonRef}`);
    clickRef(targetId, createButtonRef);
    sleep(1500);
    currentSnapshot = waitForDialog(targetId, TEXT.appIcon, 20000);
  }

  let dialogSnapshot = getDialogSnapshot(currentSnapshot, TEXT.createEnterpriseApp) || currentSnapshot;
  let appNameRef = findRef(dialogSnapshot, (line) => matchesType(line, ["textbox"]), 1);
  if (!appNameRef) {
    throw new Error("Unable to locate the Feishu app creation form");
  }

  log(options, `Fill app name: ${appNameRef}`);
  typeRef(targetId, appNameRef, appName);
  sleep(1000);

  currentSnapshot = snapshot(targetId, 360);
  dialogSnapshot = getDialogSnapshot(currentSnapshot, TEXT.createEnterpriseApp) || currentSnapshot;
  const appDescriptionRef = findRef(dialogSnapshot, (line) => matchesType(line, ["textbox"]), 2);
  const createRef = findRefByText(dialogSnapshot, TEXT.createApp, ["button"], 1, true);
  if (!appDescriptionRef || !createRef) {
    throw new Error("Unable to locate the Feishu app description / create button");
  }

  log(options, `Fill app description: ${appDescriptionRef}`);
  typeRef(targetId, appDescriptionRef, appDescription);
  sleep(800);

  currentSnapshot = snapshot(targetId, 360);
  dialogSnapshot = getDialogSnapshot(currentSnapshot, TEXT.createEnterpriseApp) || currentSnapshot;
  const refreshedCreateRef =
    findRefByText(dialogSnapshot, TEXT.createApp, ["button"], 1, true) || createRef;

  log(options, `Submit create app dialog: ${refreshedCreateRef}`);
  clickRef(targetId, refreshedCreateRef);

  const capabilityUrl = waitForTabUrl(targetId, /\/app\/(cli_[^/]+)\/(capability|bot)(?:\/)?$/, 30000);
  const appId = getAppIdFromUrl(capabilityUrl);
  if (!appId) {
    throw new Error("Unable to determine the newly created Feishu app id");
  }

  return appId;
}

function enableBotCapability(targetId, appId, options) {
  let botTargetId = targetId;
  const currentTab = getTabById(targetId);
  if (!currentTab || !/\/(capability|bot)(?:\/)?$/.test(currentTab.url)) {
    botTargetId = openUrl(`https://open.feishu.cn/app/${appId}/capability`);
    waitForTabUrl(botTargetId, /\/capability(?:\/)?$/, 20000);
  }

  let currentSnapshot = snapshot(botTargetId, 360);
  if (currentSnapshot.includes(TEXT.botConfig) || currentSnapshot.includes(TEXT.deleteCapability)) {
    log(options, "Bot capability already enabled");
    return;
  }

  const addBotRef = findRefInSection(currentSnapshot, {
    anchor: TEXT.bot,
    stop: TEXT.webApp,
    typeNames: ["button"],
    text: TEXT.add,
    index: 1,
  });
  if (!addBotRef) {
    throw new Error("Unable to locate the bot add button");
  }

  log(options, `Enable bot capability: ${addBotRef}`);
  clickRef(botTargetId, addBotRef);

  waitFor(() => {
    const tab = getTabById(botTargetId);
    if (tab && /\/bot(?:\/)?$/.test(tab.url)) {
      return tab.url;
    }

    const botSnapshot = snapshot(botTargetId, 280);
    if (botSnapshot.includes(TEXT.botConfig) || botSnapshot.includes(TEXT.deleteCapability)) {
      return "enabled";
    }

    return "";
  }, 20000, "Timed out waiting for the bot page");
}

function readCredentials(appId, options) {
  const targetId = openUrl(`https://open.feishu.cn/app/${appId}/baseinfo`);
  waitForTabUrl(targetId, /\/baseinfo(?:\/)?$/, 15000);

  const currentSnapshot = waitFor(() => {
    const baseInfoSnapshot = snapshot(targetId, 320);
    if (baseInfoSnapshot.includes(TEXT.appSecret)) {
      return baseInfoSnapshot;
    }
    return "";
  }, 20000, "Timed out waiting for the base info page");

  const appIdCopyRef = findRefInSection(currentSnapshot, {
    anchor: TEXT.appId,
    stop: TEXT.appSecret,
    requireCursor: true,
    index: 1,
  });
  const appIdText = extractTextValueInSection(currentSnapshot, {
    anchor: TEXT.appId,
    stop: TEXT.appSecret,
  });
  const appSecretText = extractTextValueInSection(currentSnapshot, {
    anchor: TEXT.appSecret,
    stop: TEXT.summaryInfo,
  });

  let copiedAppId = appIdText || appId;
  if (!appIdText && appIdCopyRef) {
    log(options, `Copy App ID from ${appIdCopyRef}`);
    clickRef(targetId, appIdCopyRef);
    sleep(500);
    copiedAppId = readClipboardWithRetry() || appId;
  }

  let appSecret = !isMaskedValue(appSecretText) ? appSecretText : "";
  if (!appSecret) {
    const secretActionRefs = extractRefsInSection(currentSnapshot, {
      anchor: TEXT.appSecret,
      stop: TEXT.summaryInfo,
      typeNames: ["img", "button"],
      requireCursor: true,
    });
    if (!secretActionRefs.length) {
      throw new Error("Unable to locate the App Secret value");
    }

    for (const ref of secretActionRefs) {
      log(options, `Try App Secret action: ${ref}`);
      clickRef(targetId, ref);
      sleep(700);
      const copiedValue = readClipboard();
      if (
        copiedValue &&
        !isMaskedValue(copiedValue) &&
        copiedValue !== copiedAppId &&
        !/^cli_/i.test(copiedValue)
      ) {
        appSecret = copiedValue;
        break;
      }
    }
  }

  if (!appSecret) {
    throw new Error("Unable to determine the App Secret");
  }

  return {
    appId: copiedAppId,
    appSecret,
  };
}

function ensurePermissionsDialog(targetId, options) {
  let currentSnapshot = snapshot(targetId, 420);
  if (currentSnapshot.includes(TEXT.permissionsDialog) && currentSnapshot.includes(TEXT.messageAndGroup)) {
    return currentSnapshot;
  }

  const openPermissionsRef =
    findRefByText(currentSnapshot, TEXT.permissions, ["button"], 1, true) ||
    findRefByText(currentSnapshot, "\u53bb\u5f00\u901a\u6743\u9650", ["button"], 1, true);
  if (!openPermissionsRef) {
    throw new Error("Unable to find the open permissions button");
  }

  log(options, `Open permissions dialog: ${openPermissionsRef}`);
  clickRef(targetId, openPermissionsRef);
  sleep(1500);
  clickOptionalByText(targetId, TEXT.iKnow);

  return waitForDialog(targetId, TEXT.permissionsDialog, 20000);
}

function enableMessageAndGroupPermissions(appId, options) {
  const targetId = openUrl(`https://open.feishu.cn/app/${appId}/auth`);
  waitForTabUrl(targetId, /\/auth(?:\/)?$/, 15000);

  clickOptionalByText(targetId, TEXT.iKnow);
  let currentSnapshot = ensurePermissionsDialog(targetId, options);

  const messageGroupRef = findRefByText(currentSnapshot, TEXT.messageAndGroup, ["menuitem"], 1, true);
  if (!messageGroupRef) {
    throw new Error("Unable to find the message and group category");
  }

  log(options, `Switch permission category: ${messageGroupRef}`);
  clickRef(targetId, messageGroupRef);
  sleep(1500);

  currentSnapshot = waitFor(() => {
    const authSnapshot = snapshot(targetId, 520);
    if (authSnapshot.includes("[active]") && authSnapshot.includes(TEXT.messageAndGroup)) {
      return authSnapshot;
    }
    return authSnapshot.includes(TEXT.permissionsHeader) ? authSnapshot : "";
  }, 20000, "Timed out waiting for the message and group permission list");

  const selectAllRef = findRefInSection(currentSnapshot, {
    anchor: TEXT.permissionsHeader,
    typeNames: ["checkbox"],
    index: 1,
  });
  if (!selectAllRef) {
    throw new Error("Unable to locate the message and group select-all checkbox");
  }

  log(options, `Select all message/group permissions: ${selectAllRef}`);
  clickRef(targetId, selectAllRef);
  sleep(1200);

  currentSnapshot = waitFor(() => {
    const authSnapshot = snapshot(targetId, 520);
    const confirmRef = findRefByText(authSnapshot, TEXT.permissionsConfirm, ["button"], 1, true);
    if (!confirmRef) {
      return "";
    }

    const confirmLine = authSnapshot
      .split(/\r?\n/)
      .find((line) => extractRef(line) === confirmRef);
    if (confirmLine && !confirmLine.includes("[disabled]")) {
      return { authSnapshot, confirmRef };
    }

    return "";
  }, 20000, "Timed out waiting for the confirm permissions button");

  log(options, `Confirm permissions: ${currentSnapshot.confirmRef}`);
  clickRef(targetId, currentSnapshot.confirmRef);

  waitFor(() => {
    const authSnapshot = snapshot(targetId, 260);
    return getDialogSnapshot(authSnapshot, TEXT.permissionsDialog) ? "" : "closed";
  }, 20000, "Timed out waiting for the permissions dialog to close");
}

function openFeishuPage(appId, pageName, pagePattern, readyText, options, snapshotLimit = 420) {
  const targetId = openUrl(`https://open.feishu.cn/app/${appId}/${pageName}`);
  waitForTabUrl(targetId, pagePattern, 20000);
  const currentSnapshot = waitFor(() => {
    const pageSnapshot = snapshot(targetId, snapshotLimit);
    return pageSnapshot.includes(readyText) ? pageSnapshot : "";
  }, 30000, `Timed out waiting for the ${pageName} page`);
  log(options, `Opened Feishu ${pageName} page`);
  return { targetId, currentSnapshot };
}

function ensureLongConnectionMode(appId, options) {
  const page = openFeishuPage(
    appId,
    "event",
    /\/event(?:\/)?$/,
    TEXT.eventPage,
    options,
    520,
  );
  const targetId = page.targetId;

  let currentSnapshot = waitFor(() => {
    const pageSnapshot = snapshot(targetId, 520);
    if (pageSnapshot.includes(TEXT.eventConfig) && pageSnapshot.includes(TEXT.subscriptionMethod)) {
      return pageSnapshot;
    }
    return "";
  }, 30000, "Timed out waiting for the Feishu event page");

  const addEventRef = findRefByText(currentSnapshot, TEXT.addEvent, ["button"], 1, true);
  const addEventEnabled = !!addEventRef && !isRefDisabled(currentSnapshot, addEventRef);
  if (
    currentSnapshot.includes(TEXT.longConnection) &&
    (addEventEnabled || currentSnapshot.includes(TEXT.receiveMessageEvent))
  ) {
    return { targetId, currentSnapshot };
  }

  const subscriptionRef = findRefByText(currentSnapshot, TEXT.subscriptionMethod, ["button"], 1, true);
  if (!subscriptionRef) {
    throw new Error("Unable to find the subscription method button");
  }

  log(options, `Open subscription method panel: ${subscriptionRef}`);
  clickRef(targetId, subscriptionRef);
  sleep(1200);

  currentSnapshot = waitFor(() => {
    const pageSnapshot = snapshot(targetId, 620);
    return pageSnapshot.includes(TEXT.useLongConnection) ? pageSnapshot : "";
  }, 20000, "Timed out waiting for the long connection settings");

  const longConnectionRadio =
    findRefByText(currentSnapshot, TEXT.useLongConnection, ["radio"], 1, false) ||
    findRefByText(currentSnapshot, TEXT.useLongConnection, ["generic"], 1, true);
  if (!longConnectionRadio) {
    throw new Error("Unable to find the long connection option");
  }

  if (!lineForRef(currentSnapshot, longConnectionRadio).includes("[checked]")) {
    log(options, `Choose long connection: ${longConnectionRadio}`);
    clickRef(targetId, longConnectionRadio);
    sleep(800);
    currentSnapshot = snapshot(targetId, 620);
  }

  const saveRef = findRefByText(currentSnapshot, "\u4fdd\u5b58", ["button"], 1, true);
  if (!saveRef) {
    throw new Error("Unable to find the long connection save button");
  }

  log(options, `Save long connection mode: ${saveRef}`);
  clickRef(targetId, saveRef);

  currentSnapshot = waitFor(() => {
    const pageSnapshot = snapshot(targetId, 620);
    const pageAddEventRef = findRefByText(pageSnapshot, TEXT.addEvent, ["button"], 1, true);
    const pageAddEventEnabled = !!pageAddEventRef && !isRefDisabled(pageSnapshot, pageAddEventRef);
    if (pageSnapshot.includes(TEXT.longConnection) && (pageAddEventEnabled || pageSnapshot.includes(TEXT.receiveMessageEvent))) {
      return pageSnapshot;
    }
    return "";
  }, 90000, "Timed out waiting for Feishu long connection to become available", 4000);

  return { targetId, currentSnapshot };
}

function ensureReceiveMessageEvent(appId, options) {
  let { targetId, currentSnapshot } = ensureLongConnectionMode(appId, options);
  if (currentSnapshot.includes(TEXT.receiveMessageEvent)) {
    log(options, "Receive message event already configured");
    return { targetId, currentSnapshot };
  }

  const addEventRef = waitFor(() => {
    const pageSnapshot = snapshot(targetId, 620);
    const ref = findRefByText(pageSnapshot, TEXT.addEvent, ["button"], 1, true);
    if (ref && !isRefDisabled(pageSnapshot, ref)) {
      currentSnapshot = pageSnapshot;
      return ref;
    }
    return "";
  }, 60000, "Timed out waiting for the add event button", 4000);

  log(options, `Open add event dialog: ${addEventRef}`);
  clickRef(targetId, addEventRef);
  sleep(1200);

  let dialogSnapshot = waitForDialog(targetId, TEXT.addEventDialog, 20000);
  const messageGroupRef = findRefByText(dialogSnapshot, TEXT.messageAndGroup, ["menuitem"], 1, true);
  if (!messageGroupRef) {
    throw new Error("Unable to find the message and group event category");
  }

  log(options, `Switch event category: ${messageGroupRef}`);
  clickRef(targetId, messageGroupRef);
  sleep(1200);

  dialogSnapshot = waitFor(() => {
    const pageSnapshot = snapshot(targetId, 850);
    const modalSnapshot = getDialogSnapshot(pageSnapshot, TEXT.addEventDialog);
    if (modalSnapshot && modalSnapshot.includes(TEXT.receiveMessage)) {
      return modalSnapshot;
    }
    return "";
  }, 20000, "Timed out waiting for the receive message event");

  const receiveMessageCheckbox = findCheckboxBeforeText(dialogSnapshot, TEXT.receiveMessage);
  if (!receiveMessageCheckbox) {
    throw new Error("Unable to find the receive message checkbox");
  }

  if (!isCheckboxCheckedBeforeText(dialogSnapshot, TEXT.receiveMessage)) {
    log(options, `Select receive message event: ${receiveMessageCheckbox}`);
    clickRef(targetId, receiveMessageCheckbox);
    sleep(800);
    dialogSnapshot = getDialogSnapshot(snapshot(targetId, 850), TEXT.addEventDialog) || dialogSnapshot;
  }

  const addRef = findRefByText(dialogSnapshot, TEXT.add, ["button"], 1, true);
  if (!addRef || isRefDisabled(dialogSnapshot, addRef)) {
    throw new Error("Unable to enable the add event button");
  }

  log(options, `Confirm add event: ${addRef}`);
  clickRef(targetId, addRef);

  currentSnapshot = waitFor(() => {
    const pageSnapshot = snapshot(targetId, 700);
    const modalSnapshot = getDialogSnapshot(pageSnapshot, TEXT.addEventDialog);
    if (!modalSnapshot && pageSnapshot.includes(TEXT.receiveMessageEvent)) {
      return pageSnapshot;
    }
    return "";
  }, 30000, "Timed out waiting for the receive message event to appear");

  return { targetId, currentSnapshot };
}

function publishCurrentFeishuVersion(appId, options) {
  const page = openFeishuPage(
    appId,
    "version",
    /\/version(?:\/create|\/\d+)?(?:\/)?$/,
    TEXT.versionManagement,
    options,
    720,
  );
  const targetId = page.targetId;

  let currentSnapshot = waitFor(() => {
    const pageSnapshot = snapshot(targetId, 850);
    if (pageSnapshot.includes(TEXT.versionManagement) || pageSnapshot.includes(TEXT.versionDetails)) {
      return pageSnapshot;
    }
    return "";
  }, 30000, "Timed out waiting for the version management page");

  if (currentSnapshot.includes(TEXT.currentChangesPublished)) {
    log(options, "All Feishu changes are already published");
    return { targetId, currentSnapshot, published: true, versionNumber: "", skipped: true };
  }

  if (!currentSnapshot.includes(TEXT.versionDetails)) {
    const createVersionRef = findRefByText(currentSnapshot, TEXT.createVersion, ["button"], 1, true);
    if (!createVersionRef) {
      throw new Error("Unable to find the create version button");
    }

    log(options, `Open create version page: ${createVersionRef}`);
    clickRef(targetId, createVersionRef);

    currentSnapshot = waitFor(() => {
      const tab = getTabById(targetId);
      if (tab && /\/version\/create(?:\/)?$/.test(tab.url)) {
        const pageSnapshot = snapshot(targetId, 850);
        if (pageSnapshot.includes(TEXT.versionNumber) && pageSnapshot.includes(TEXT.updateNotes)) {
          return pageSnapshot;
        }
      }
      return "";
    }, 30000, "Timed out waiting for the version creation page");

    const versionNumberRef = findRefInSection(currentSnapshot, {
      anchor: TEXT.versionNumber,
      stop: "\u79fb\u52a8\u7aef\u7684\u9ed8\u8ba4\u80fd\u529b",
      typeNames: ["textbox"],
      index: 1,
    });
    const updateNotesRef = findRefInSection(currentSnapshot, {
      anchor: TEXT.updateNotes,
      stop: TEXT.appCapability,
      typeNames: ["textbox"],
      index: 1,
    });
    const saveVersionRef = findRefByText(currentSnapshot, "\u4fdd\u5b58", ["button"], 1, true);

    if (!versionNumberRef || !updateNotesRef || !saveVersionRef) {
      throw new Error("Unable to locate the Feishu version creation form");
    }

    log(options, `Fill version number: ${versionNumberRef}`);
    typeRef(targetId, versionNumberRef, options.versionNumber);
    sleep(700);

    log(options, `Fill version notes: ${updateNotesRef}`);
    typeRef(targetId, updateNotesRef, options.versionNotes);
    sleep(700);

    log(options, `Save version draft: ${saveVersionRef}`);
    clickRef(targetId, saveVersionRef);

    currentSnapshot = waitFor(() => {
      const pageSnapshot = snapshot(targetId, 850);
      if (pageSnapshot.includes(TEXT.versionDetails) && pageSnapshot.includes(TEXT.confirmPublish)) {
        return pageSnapshot;
      }
      return "";
    }, 30000, "Timed out waiting for the saved version details");
  }

  const confirmPublishRef = findRefByText(currentSnapshot, TEXT.confirmPublish, ["button"], 1, true);
  if (!confirmPublishRef) {
    if (currentSnapshot.includes(TEXT.currentChangesPublished)) {
      return { targetId, currentSnapshot, published: true, versionNumber: options.versionNumber, skipped: true };
    }
    throw new Error("Unable to find the confirm publish button");
  }

  log(options, `Open publish confirmation: ${confirmPublishRef}`);
  clickRef(targetId, confirmPublishRef);

  const publishState = waitFor(() => {
    const pageSnapshot = snapshot(targetId, 850);
    const modalSnapshot = getDialogSnapshot(pageSnapshot, TEXT.confirmPublishDialog);
    if (!modalSnapshot && pageSnapshot.includes(TEXT.currentChangesPublished) && pageSnapshot.includes(TEXT.published)) {
      return { state: "published", snapshot: pageSnapshot };
    }
    if (modalSnapshot) {
      return { state: "confirm-dialog", snapshot: modalSnapshot };
    }
    return "";
  }, 20000, "Timed out waiting for Feishu publish confirmation", 2000);

  if (publishState.state === "confirm-dialog") {
    const confirmSubmitRef = findRefByText(publishState.snapshot, TEXT.confirmPublish, ["button"], 1, true);
    if (!confirmSubmitRef) {
      throw new Error("Unable to find the final publish confirmation button");
    }

    log(options, `Confirm publish: ${confirmSubmitRef}`);
    clickRef(targetId, confirmSubmitRef);

    currentSnapshot = waitFor(() => {
      const pageSnapshot = snapshot(targetId, 850);
      const modalSnapshot = getDialogSnapshot(pageSnapshot, TEXT.confirmPublishDialog);
      if (!modalSnapshot && pageSnapshot.includes(TEXT.currentChangesPublished) && pageSnapshot.includes(TEXT.published)) {
        return pageSnapshot;
      }
      return "";
    }, 60000, "Timed out waiting for Feishu version publish to finish", 3000);
  } else {
    currentSnapshot = publishState.snapshot;
  }

  return {
    targetId,
    currentSnapshot,
    published: true,
    versionNumber: options.versionNumber,
    skipped: false,
  };
}

function finalizeFeishuSetup(appId, options) {
  if (!appId) {
    throw new Error("Feishu finalize mode requires --app-id");
  }

  const eventState = ensureReceiveMessageEvent(appId, options);
  log(options, "Feishu long connection and receive message event configured");

  const publishState = publishCurrentFeishuVersion(appId, options);
  log(options, publishState.skipped ? "Feishu version already published" : "Feishu version published");

  return {
    appId,
    event: TEXT.receiveMessageEvent,
    connectionMode: "long-connection",
    versionNumber: publishState.versionNumber,
    published: true,
    eventConfigured: eventState.currentSnapshot.includes(TEXT.receiveMessageEvent),
  };
}

function bootstrapFeishuSetup(options) {
  const existingHomeTab = findBestFeishuHomeTab();
  const rootTargetId = existingHomeTab
    ? existingHomeTab.id
    : openUrl("https://open.feishu.cn/app?lang=zh-CN");
  log(
    options,
    existingHomeTab
      ? `Reusing Feishu developer portal tab: ${rootTargetId}`
      : `Opened Feishu developer portal tab: ${rootTargetId}`,
  );

  const appId = createFeishuApp(rootTargetId, options.appName, options.appDescription, options);
  log(options, `Using Feishu app id: ${appId}`);

  enableBotCapability(rootTargetId, appId, options);
  log(options, "Bot capability enabled");

  const credentials = readCredentials(appId, options);
  log(options, "Credentials copied");

  enableMessageAndGroupPermissions(appId, options);
  log(options, "Message and group permissions enabled");

  return {
    appId: credentials.appId,
    appSecret: credentials.appSecret,
    appName: options.appName,
    appDescription: options.appDescription,
  };
}

function main() {
  const options = parseArgs(process.argv.slice(2));

  log(options, "Starting OpenClaw browser");
  runOpenClaw(["start"]);

  const result = options.mode === "finalize"
    ? finalizeFeishuSetup(options.appId, options)
    : bootstrapFeishuSetup(options);

  process.stdout.write(`${JSON.stringify(result)}\n`);
}

try {
  main();
} catch (error) {
  process.stderr.write(`${error.message || String(error)}\n`);
  process.exit(1);
}
