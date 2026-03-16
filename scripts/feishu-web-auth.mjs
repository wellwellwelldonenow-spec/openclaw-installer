#!/usr/bin/env node

import crypto from "node:crypto";
import fs from "node:fs/promises";
import http from "node:http";
import os from "node:os";
import path from "node:path";

const DEFAULT_SECRET = "megaaifeishu";
const DEFAULT_TIMEOUT_SEC = 900;
const DEFAULT_PORT = 38459;
const SESSION_COOKIE = "openclaw_feishu_web_auth";

function parseArgs(argv) {
  const options = {
    appId: "",
    appSecret: "",
    authSecret: DEFAULT_SECRET,
    bindHost: "0.0.0.0",
    port: DEFAULT_PORT,
    timeoutSec: DEFAULT_TIMEOUT_SEC,
    publicBaseUrl: "",
    brand: "feishu",
  };

  for (let index = 0; index < argv.length; index += 1) {
    const key = argv[index];
    const next = argv[index + 1];
    switch (key) {
      case "--app-id":
        options.appId = String(next || "").trim();
        index += 1;
        break;
      case "--app-secret":
        options.appSecret = String(next || "").trim();
        index += 1;
        break;
      case "--auth-secret":
        options.authSecret = String(next || "").trim() || DEFAULT_SECRET;
        index += 1;
        break;
      case "--bind-host":
        options.bindHost = String(next || "").trim() || "0.0.0.0";
        index += 1;
        break;
      case "--port":
        options.port = Number(next || DEFAULT_PORT) || DEFAULT_PORT;
        index += 1;
        break;
      case "--timeout-sec":
        options.timeoutSec = Number(next || DEFAULT_TIMEOUT_SEC) || DEFAULT_TIMEOUT_SEC;
        index += 1;
        break;
      case "--public-base-url":
        options.publicBaseUrl = String(next || "").trim();
        index += 1;
        break;
      case "--brand":
        options.brand = String(next || "").trim() || "feishu";
        index += 1;
        break;
      default:
        throw new Error(`Unknown argument: ${key}`);
    }
  }

  if (!options.appId) {
    throw new Error("Missing required argument --app-id");
  }
  if (!options.appSecret) {
    throw new Error("Missing required argument --app-secret");
  }
  if (!Number.isInteger(options.timeoutSec) || options.timeoutSec <= 0) {
    throw new Error(`Invalid --timeout-sec: ${options.timeoutSec}`);
  }
  if (!Number.isInteger(options.port) || options.port < 0 || options.port > 65535) {
    throw new Error(`Invalid --port: ${options.port}`);
  }

  return options;
}

const options = parseArgs(process.argv.slice(2));

const state = {
  unlockedSessions: new Set(),
  currentFlow: null,
  authState: {
    stage: "locked",
    message: "请输入访问密钥后继续。",
    detail: "",
    authUrl: "",
    expiresAt: 0,
    userOpenId: "",
  },
  stopTimer: null,
};

let shuttingDown = false;
let server;
let publicBaseUrl = "";
let listenPort = options.port;
const startedAt = Date.now();
const timeoutHandle = setTimeout(() => {
  failAndExit("等待飞书网页授权超时，请重新运行脚本。", 1);
}, options.timeoutSec * 1000);

function log(message) {
  process.stdout.write(`${message}\n`);
}

function normalizeBaseUrl(value) {
  return String(value || "").trim().replace(/\/+$/, "");
}

function randomId() {
  return crypto.randomBytes(18).toString("hex");
}

function jsonHeaders(extra = {}) {
  return {
    "Content-Type": "application/json; charset=utf-8",
    "Cache-Control": "no-store",
    ...extra,
  };
}

function htmlHeaders(extra = {}) {
  return {
    "Content-Type": "text/html; charset=utf-8",
    "Cache-Control": "no-store",
    ...extra,
  };
}

function sendJson(res, statusCode, payload, extraHeaders = {}) {
  res.writeHead(statusCode, jsonHeaders(extraHeaders));
  res.end(JSON.stringify(payload));
}

function sendHtml(res, statusCode, html, extraHeaders = {}) {
  res.writeHead(statusCode, htmlHeaders(extraHeaders));
  res.end(html);
}

function readCookies(req) {
  const raw = String(req.headers.cookie || "");
  const cookies = {};
  for (const segment of raw.split(/;\s*/u)) {
    if (!segment) {
      continue;
    }
    const separator = segment.indexOf("=");
    if (separator <= 0) {
      continue;
    }
    const key = segment.slice(0, separator).trim();
    const value = segment.slice(separator + 1).trim();
    cookies[key] = decodeURIComponent(value);
  }
  return cookies;
}

async function readBody(req) {
  const chunks = [];
  for await (const chunk of req) {
    chunks.push(Buffer.isBuffer(chunk) ? chunk : Buffer.from(chunk));
  }
  const raw = Buffer.concat(chunks).toString("utf8").trim();
  if (!raw) {
    return {};
  }
  return JSON.parse(raw);
}

function sessionAllowed(req) {
  const cookies = readCookies(req);
  const token = String(cookies[SESSION_COOKIE] || "");
  return Boolean(token) && state.unlockedSessions.has(token);
}

function buildPage() {
  const expiresAt = Number(state.authState.expiresAt || 0);
  const expiresIso = expiresAt > 0 ? new Date(expiresAt).toISOString() : "";
  const stage = JSON.stringify({
    stage: state.authState.stage,
    message: state.authState.message,
    detail: state.authState.detail,
    authUrl: state.authState.authUrl,
    expiresAt,
    expiresIso,
    userOpenId: state.authState.userOpenId,
    publicBaseUrl,
  });

  return `<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>OpenClaw Feishu Auth</title>
  <style>
    :root {
      --bg: #f5f3ee;
      --panel: #fffdf7;
      --ink: #1f2937;
      --muted: #6b7280;
      --line: rgba(31, 41, 55, 0.12);
      --accent: #0f766e;
      --accent-2: #f59e0b;
      --danger: #dc2626;
      --good: #15803d;
    }
    * { box-sizing: border-box; }
    body {
      margin: 0;
      min-height: 100vh;
      font-family: "SF Pro Display", "PingFang SC", "Microsoft YaHei", sans-serif;
      background:
        radial-gradient(circle at top left, rgba(15,118,110,0.16), transparent 28%),
        radial-gradient(circle at bottom right, rgba(245,158,11,0.14), transparent 26%),
        var(--bg);
      color: var(--ink);
      display: grid;
      place-items: center;
      padding: 24px;
    }
    .shell {
      width: min(720px, 100%);
      background: var(--panel);
      border: 1px solid var(--line);
      border-radius: 24px;
      box-shadow: 0 28px 70px rgba(31, 41, 55, 0.12);
      overflow: hidden;
    }
    .hero {
      padding: 28px 28px 18px;
      border-bottom: 1px solid var(--line);
      background: linear-gradient(135deg, rgba(15,118,110,0.09), rgba(245,158,11,0.09));
    }
    .badge {
      display: inline-flex;
      align-items: center;
      gap: 8px;
      padding: 6px 10px;
      border-radius: 999px;
      font-size: 12px;
      letter-spacing: 0.04em;
      text-transform: uppercase;
      background: rgba(255,255,255,0.8);
      border: 1px solid rgba(15,118,110,0.15);
      color: var(--accent);
    }
    h1 {
      margin: 14px 0 10px;
      font-size: clamp(28px, 4vw, 40px);
      line-height: 1.04;
    }
    p {
      margin: 0;
      color: var(--muted);
      line-height: 1.7;
    }
    .body {
      padding: 24px 28px 28px;
      display: grid;
      gap: 20px;
    }
    .panel {
      border: 1px solid var(--line);
      border-radius: 18px;
      padding: 18px;
      background: rgba(255,255,255,0.72);
    }
    label {
      display: block;
      margin-bottom: 10px;
      font-weight: 600;
    }
    input {
      width: 100%;
      border-radius: 14px;
      border: 1px solid rgba(31,41,55,0.18);
      padding: 14px 16px;
      font: inherit;
      background: #fff;
    }
    button, .button-link {
      appearance: none;
      border: 0;
      border-radius: 14px;
      padding: 14px 18px;
      font: inherit;
      font-weight: 700;
      cursor: pointer;
      transition: transform 160ms ease, opacity 160ms ease, box-shadow 160ms ease;
      text-decoration: none;
      display: inline-flex;
      align-items: center;
      justify-content: center;
      gap: 10px;
    }
    button:hover, .button-link:hover { transform: translateY(-1px); }
    button.primary, .button-link.primary {
      color: #fff;
      background: linear-gradient(135deg, var(--accent), #155e75);
      box-shadow: 0 18px 36px rgba(15,118,110,0.18);
    }
    button.secondary {
      color: var(--ink);
      background: rgba(31,41,55,0.06);
    }
    button.warn {
      color: #fff;
      background: linear-gradient(135deg, #d97706, var(--accent-2));
    }
    .hidden { display: none !important; }
    .actions {
      display: flex;
      flex-wrap: wrap;
      gap: 12px;
      margin-top: 16px;
    }
    .status {
      padding: 16px 18px;
      border-radius: 16px;
      background: rgba(15,118,110,0.08);
      border: 1px solid rgba(15,118,110,0.15);
    }
    .status.good {
      background: rgba(21,128,61,0.08);
      border-color: rgba(21,128,61,0.18);
    }
    .status.warn {
      background: rgba(245,158,11,0.12);
      border-color: rgba(245,158,11,0.18);
    }
    .status.bad {
      background: rgba(220,38,38,0.08);
      border-color: rgba(220,38,38,0.16);
    }
    .status strong {
      display: block;
      font-size: 18px;
      margin-bottom: 6px;
    }
    .mini {
      margin-top: 8px;
      font-size: 13px;
      color: var(--muted);
      word-break: break-all;
    }
    .tips {
      margin: 0;
      padding-left: 18px;
      color: var(--muted);
      line-height: 1.7;
    }
  </style>
</head>
<body>
  <div class="shell">
    <div class="hero">
      <span class="badge">OpenClaw Temporary Access</span>
      <h1>飞书临时授权页</h1>
      <p>输入访问密钥后生成一次性的飞书授权链接。授权完成后，Linux 安装脚本会自动继续，当前页面可以关闭。</p>
    </div>
    <div class="body">
      <section id="unlock-panel" class="panel">
        <label for="secret">访问密钥</label>
        <input id="secret" type="password" placeholder="请输入访问密钥">
        <div class="actions">
          <button id="unlock-button" class="primary" type="button">进入授权页</button>
        </div>
        <p id="unlock-error" class="mini"></p>
      </section>
      <section id="auth-panel" class="panel hidden">
        <div id="auth-status" class="status">
          <strong>等待开始</strong>
          <span>点击下方按钮生成飞书授权链接。</span>
          <div class="mini"></div>
        </div>
        <div class="actions">
          <button id="start-auth" class="primary" type="button">点击进行飞书授权</button>
          <a id="open-auth-link" class="button-link primary hidden" href="#" target="_blank" rel="noreferrer">打开授权页</a>
          <button id="refresh-auth" class="warn hidden" type="button">重新生成授权链接</button>
        </div>
        <ul class="tips">
          <li>如果浏览器未登录飞书，打开后会出现扫码登录页。</li>
          <li>底层授权码有效期很短，过期后直接点“重新生成授权链接”。</li>
          <li>授权成功后脚本会自动继续，无需手动回终端输入。</li>
        </ul>
      </section>
    </div>
  </div>
  <script>
    const initialState = ${stage};
    const unlockPanel = document.querySelector("#unlock-panel");
    const authPanel = document.querySelector("#auth-panel");
    const unlockButton = document.querySelector("#unlock-button");
    const unlockError = document.querySelector("#unlock-error");
    const secretInput = document.querySelector("#secret");
    const startAuthButton = document.querySelector("#start-auth");
    const openAuthLink = document.querySelector("#open-auth-link");
    const refreshAuthButton = document.querySelector("#refresh-auth");
    const authStatus = document.querySelector("#auth-status");
    let pollTimer = null;

    function renderStatus(payload) {
      const stage = payload.stage || "idle";
      let tone = "";
      if (stage === "success") tone = "good";
      if (stage === "expired" || stage === "denied") tone = "warn";
      if (stage === "failed") tone = "bad";
      authStatus.className = "status" + (tone ? " " + tone : "");
      authStatus.querySelector("strong").textContent = payload.message || "等待开始";
      authStatus.querySelector("span").textContent = payload.detail || "";
      const detail = [];
      if (payload.authUrl) detail.push(payload.authUrl);
      if (payload.expiresAt) detail.push("授权码截止: " + new Date(payload.expiresAt).toLocaleString());
      if (payload.userOpenId) detail.push("授权用户: " + payload.userOpenId);
      authStatus.querySelector(".mini").textContent = detail.join("  |  ");
      openAuthLink.classList.toggle("hidden", !payload.authUrl);
      openAuthLink.href = payload.authUrl || "#";
      refreshAuthButton.classList.toggle("hidden", !(stage === "expired" || stage === "failed" || stage === "denied"));
      startAuthButton.classList.toggle("hidden", stage === "pending" || stage === "success");
      if (stage === "success") {
        window.clearInterval(pollTimer);
        pollTimer = null;
        window.setTimeout(() => {
          try {
            window.close();
          } catch {}
        }, 1200);
      }
    }

    async function refreshStatus() {
      const response = await fetch("/api/status", { cache: "no-store" });
      const payload = await response.json();
      if (!response.ok) {
        throw new Error(payload.error || "读取状态失败");
      }
      renderStatus(payload);
      return payload;
    }

    function ensurePolling() {
      if (pollTimer) return;
      pollTimer = window.setInterval(() => {
        refreshStatus().catch((error) => {
          authStatus.className = "status bad";
          authStatus.querySelector("strong").textContent = "授权状态读取失败";
          authStatus.querySelector("span").textContent = error.message;
        });
      }, 1500);
    }

    async function unlock() {
      unlockError.textContent = "";
      const response = await fetch("/api/unlock", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ secret: secretInput.value }),
      });
      const payload = await response.json();
      if (!response.ok) {
        unlockError.textContent = payload.error || "访问密钥错误";
        return;
      }
      unlockPanel.classList.add("hidden");
      authPanel.classList.remove("hidden");
      renderStatus(payload);
      ensurePolling();
    }

    async function createFlow() {
      const response = await fetch("/api/device/start", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({}),
      });
      const payload = await response.json();
      if (!response.ok) {
        throw new Error(payload.error || "创建授权链接失败");
      }
      renderStatus(payload);
      ensurePolling();
      if (payload.authUrl) {
        window.open(payload.authUrl, "_blank", "noopener,noreferrer");
      }
    }

    unlockButton.addEventListener("click", () => unlock().catch((error) => {
      unlockError.textContent = error.message;
    }));
    secretInput.addEventListener("keydown", (event) => {
      if (event.key === "Enter") {
        event.preventDefault();
        unlockButton.click();
      }
    });
    startAuthButton.addEventListener("click", () => createFlow().catch((error) => {
      renderStatus({ stage: "failed", message: "创建授权链接失败", detail: error.message });
    }));
    refreshAuthButton.addEventListener("click", () => createFlow().catch((error) => {
      renderStatus({ stage: "failed", message: "重新生成授权链接失败", detail: error.message });
    }));

    if (document.cookie.includes("${SESSION_COOKIE}=")) {
      unlockPanel.classList.add("hidden");
      authPanel.classList.remove("hidden");
      renderStatus(initialState);
      ensurePolling();
    }
  </script>
</body>
</html>`;
}

function brandDomains(brand) {
  if (brand === "lark") {
    return {
      accounts: "https://accounts.larksuite.com",
      open: "https://open.larksuite.com",
    };
  }
  return {
    accounts: "https://accounts.feishu.cn",
    open: "https://open.feishu.cn",
  };
}

async function requestJson(url, init = {}) {
  const response = await fetch(url, init);
  const text = await response.text();
  let payload = {};
  try {
    payload = text ? JSON.parse(text) : {};
  } catch {
    throw new Error(`Unexpected response from ${url}: ${text.slice(0, 200)}`);
  }
  if (!response.ok) {
    const message = payload.error_description || payload.msg || payload.error || `HTTP ${response.status}`;
    throw new Error(message);
  }
  return payload;
}

async function requestTenantAccessToken() {
  const { open } = brandDomains(options.brand);
  const payload = await requestJson(`${open}/open-apis/auth/v3/tenant_access_token/internal`, {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({
      app_id: options.appId,
      app_secret: options.appSecret,
    }),
  });
  if (payload.code !== 0 || !payload.tenant_access_token) {
    throw new Error(payload.msg || "Failed to get tenant access token");
  }
  return payload.tenant_access_token;
}

async function fetchGrantedUserScopes() {
  const { open } = brandDomains(options.brand);
  const tenantAccessToken = await requestTenantAccessToken();
  const payload = await requestJson(`${open}/open-apis/application/v6/applications/${encodeURIComponent(options.appId)}?lang=zh_cn`, {
    headers: {
      Authorization: `Bearer ${tenantAccessToken}`,
    },
  });
  if (payload.code !== 0) {
    throw new Error(payload.msg || "Failed to query application scopes");
  }
  const app = payload.data?.app || {};
  const scopes = Array.isArray(app.scopes) ? app.scopes : [];
  const userScopes = scopes
    .filter((entry) => typeof entry?.scope === "string" && entry.scope)
    .filter((entry) => !Array.isArray(entry.token_types) || entry.token_types.includes("user"))
    .map((entry) => entry.scope);
  if (!userScopes.includes("offline_access")) {
    userScopes.push("offline_access");
  }
  return Array.from(new Set(userScopes)).sort();
}

async function requestDeviceAuthorization(scope) {
  const { accounts } = brandDomains(options.brand);
  const basic = Buffer.from(`${options.appId}:${options.appSecret}`).toString("base64");
  const body = new URLSearchParams();
  body.set("client_id", options.appId);
  body.set("scope", scope);
  const payload = await requestJson(`${accounts}/oauth/v1/device_authorization`, {
    method: "POST",
    headers: {
      "Content-Type": "application/x-www-form-urlencoded",
      Authorization: `Basic ${basic}`,
    },
    body: body.toString(),
  });
  return {
    deviceCode: payload.device_code,
    userCode: payload.user_code,
    verificationUriComplete: payload.verification_uri_complete || payload.verification_uri,
    expiresIn: Number(payload.expires_in || 180),
    interval: Number(payload.interval || 5),
  };
}

async function pollDeviceToken(flow) {
  const { open } = brandDomains(options.brand);
  let intervalSec = flow.interval;

  while (Date.now() < flow.expiresAt) {
    await new Promise((resolve) => setTimeout(resolve, intervalSec * 1000));
    if (state.currentFlow !== flow || shuttingDown) {
      return;
    }

    const response = await fetch(`${open}/open-apis/authen/v2/oauth/token`, {
      method: "POST",
      headers: {
        "Content-Type": "application/x-www-form-urlencoded",
      },
      body: new URLSearchParams({
        grant_type: "urn:ietf:params:oauth:grant-type:device_code",
        device_code: flow.deviceCode,
        client_id: options.appId,
        client_secret: options.appSecret,
      }).toString(),
    });

    const payload = await response.json().catch(() => ({}));
    const error = String(payload.error || "");
    if (payload.access_token) {
      const userOpenId = await fetchAuthorizedOpenId(payload.access_token);
      await storeToken({
        userOpenId,
        appId: options.appId,
        accessToken: payload.access_token,
        refreshToken: payload.refresh_token || "",
        expiresAt: Date.now() + Number(payload.expires_in || 7200) * 1000,
        refreshExpiresAt: Date.now() + Number(payload.refresh_token_expires_in || payload.expires_in || 7200) * 1000,
        scope: String(payload.scope || flow.scope || ""),
        grantedAt: Date.now(),
      });
      state.authState = {
        stage: "success",
        message: "飞书授权成功，脚本继续中",
        detail: "授权结果已写入 OpenClaw 官方插件的 Linux token store。",
        authUrl: flow.verificationUriComplete,
        expiresAt: flow.expiresAt,
        userOpenId,
      };
      scheduleStop(1500, 0);
      return;
    }
    if (error === "authorization_pending") {
      continue;
    }
    if (error === "slow_down") {
      intervalSec = Math.min(intervalSec + 5, 60);
      continue;
    }
    if (error === "access_denied") {
      state.authState = {
        stage: "denied",
        message: "用户拒绝了飞书授权",
        detail: "点击“重新生成授权链接”可再次发起。",
        authUrl: flow.verificationUriComplete,
        expiresAt: flow.expiresAt,
        userOpenId: "",
      };
      return;
    }
    if (error === "expired_token" || error === "invalid_grant") {
      state.authState = {
        stage: "expired",
        message: "授权链接已失效",
        detail: "飞书底层 device_code 已过期，请重新生成授权链接。",
        authUrl: flow.verificationUriComplete,
        expiresAt: flow.expiresAt,
        userOpenId: "",
      };
      return;
    }

    state.authState = {
      stage: "failed",
      message: "授权流程失败",
      detail: payload.error_description || payload.msg || error || "未知错误",
      authUrl: flow.verificationUriComplete,
      expiresAt: flow.expiresAt,
      userOpenId: "",
    };
    return;
  }

  state.authState = {
    stage: "expired",
    message: "授权链接已失效",
    detail: "超过有效时间，请重新生成授权链接。",
    authUrl: flow.verificationUriComplete,
    expiresAt: flow.expiresAt,
    userOpenId: "",
  };
}

async function fetchAuthorizedOpenId(accessToken) {
  const { open } = brandDomains(options.brand);
  const payload = await requestJson(`${open}/open-apis/authen/v1/user_info`, {
    headers: {
      Authorization: `Bearer ${accessToken}`,
    },
  });
  if (payload.code !== 0 || !payload.data?.open_id) {
    throw new Error(payload.msg || "Failed to resolve authorized user open_id");
  }
  return payload.data.open_id;
}

const linuxUatDir = path.join(process.env.XDG_DATA_HOME || path.join(os.homedir(), ".local", "share"), "openclaw-feishu-uat");
const masterKeyPath = path.join(linuxUatDir, "master.key");

function linuxSafeFileName(account) {
  return `${account.replace(/[^a-zA-Z0-9._-]/g, "_")}.enc`;
}

async function ensureLinuxCredDir() {
  await fs.mkdir(linuxUatDir, { recursive: true, mode: 0o700 });
}

async function getMasterKey() {
  try {
    const existing = await fs.readFile(masterKeyPath);
    if (existing.length === 32) {
      return existing;
    }
  } catch {}
  await ensureLinuxCredDir();
  const key = crypto.randomBytes(32);
  await fs.writeFile(masterKeyPath, key, { mode: 0o600 });
  await fs.chmod(masterKeyPath, 0o600);
  return key;
}

function encryptData(plaintext, key) {
  const iv = crypto.randomBytes(12);
  const cipher = crypto.createCipheriv("aes-256-gcm", key, iv);
  const enc = Buffer.concat([cipher.update(plaintext, "utf8"), cipher.final()]);
  return Buffer.concat([iv, cipher.getAuthTag(), enc]);
}

async function storeToken(token) {
  const key = await getMasterKey();
  await ensureLinuxCredDir();
  const account = `${token.appId}:${token.userOpenId}`;
  const filePath = path.join(linuxUatDir, linuxSafeFileName(account));
  const payload = JSON.stringify(token);
  const encrypted = encryptData(payload, key);
  await fs.writeFile(filePath, encrypted, { mode: 0o600 });
  await fs.chmod(filePath, 0o600);
}

async function detectPublicBaseUrl(port) {
  if (normalizeBaseUrl(options.publicBaseUrl)) {
    return normalizeBaseUrl(options.publicBaseUrl);
  }

  const candidates = [
    "https://api.ipify.org?format=json",
    "https://ifconfig.me/all.json",
  ];

  for (const candidate of candidates) {
    try {
      const response = await fetch(candidate, { headers: { Accept: "application/json" } });
      if (!response.ok) {
        continue;
      }
      const payload = await response.json();
      const ip = String(payload.ip || payload.ip_addr || "").trim();
      if (ip) {
        return `http://${ip}:${port}`;
      }
    } catch {}
  }

  const interfaces = os.networkInterfaces();
  for (const addresses of Object.values(interfaces)) {
    for (const entry of addresses || []) {
      if (!entry || entry.internal || entry.family !== "IPv4") {
        continue;
      }
      return `http://${entry.address}:${port}`;
    }
  }

  return `http://127.0.0.1:${port}`;
}

function scheduleStop(delayMs, exitCode) {
  if (state.stopTimer) {
    clearTimeout(state.stopTimer);
  }
  state.stopTimer = setTimeout(() => {
    stopAndExit(exitCode).catch((error) => {
      process.stderr.write(`${error.message}\n`);
      process.exit(exitCode || 1);
    });
  }, delayMs);
}

async function stopAndExit(exitCode) {
  if (shuttingDown) {
    return;
  }
  shuttingDown = true;
  clearTimeout(timeoutHandle);
  await new Promise((resolve) => server.close(() => resolve()));
  process.exit(exitCode);
}

function failAndExit(message, exitCode) {
  state.authState = {
    stage: "failed",
    message: "临时飞书授权页失败",
    detail: message,
    authUrl: "",
    expiresAt: 0,
    userOpenId: "",
  };
  process.stderr.write(`${message}\n`);
  scheduleStop(10, exitCode);
}

async function startFlow() {
  const scopes = await fetchGrantedUserScopes();
  const flow = await requestDeviceAuthorization(scopes.join(" "));
  state.currentFlow = {
    ...flow,
    scope: scopes.join(" "),
    expiresAt: Date.now() + flow.expiresIn * 1000,
  };
  state.authState = {
    stage: "pending",
    message: "授权链接已创建",
    detail: "点击“打开授权页”，若飞书未登录会先出现扫码登录。",
    authUrl: flow.verificationUriComplete,
    expiresAt: state.currentFlow.expiresAt,
    userOpenId: "",
  };
  void pollDeviceToken(state.currentFlow).catch((error) => {
    state.authState = {
      stage: "failed",
      message: "飞书授权轮询失败",
      detail: error.message,
      authUrl: flow.verificationUriComplete,
      expiresAt: state.currentFlow?.expiresAt || 0,
      userOpenId: "",
    };
  });
  return state.authState;
}

server = http.createServer(async (req, res) => {
  try {
    const url = new URL(req.url || "/", "http://127.0.0.1");

    if (req.method === "GET" && url.pathname === "/") {
      sendHtml(res, 200, buildPage());
      return;
    }

    if (req.method === "GET" && url.pathname === "/api/status") {
      if (!sessionAllowed(req)) {
        sendJson(res, 401, { error: "未解锁临时授权页" });
        return;
      }
      sendJson(res, 200, state.authState);
      return;
    }

    if (req.method !== "POST") {
      sendJson(res, 405, { error: "Method not allowed" });
      return;
    }

    if (url.pathname === "/api/unlock") {
      const body = await readBody(req);
      if (String(body.secret || "") !== options.authSecret) {
        sendJson(res, 403, { error: "访问密钥错误" });
        return;
      }
      const sessionId = randomId();
      state.unlockedSessions.add(sessionId);
      state.authState = {
        ...state.authState,
        stage: state.currentFlow ? state.authState.stage : "idle",
        message: state.currentFlow ? state.authState.message : "已通过密钥校验",
        detail: state.currentFlow ? state.authState.detail : "现在可以创建飞书授权链接。",
      };
      sendJson(res, 200, state.authState, {
        "Set-Cookie": `${SESSION_COOKIE}=${encodeURIComponent(sessionId)}; HttpOnly; SameSite=Lax; Path=/`,
      });
      return;
    }

    if (url.pathname === "/api/device/start") {
      if (!sessionAllowed(req)) {
        sendJson(res, 401, { error: "未解锁临时授权页" });
        return;
      }
      const payload = await startFlow();
      sendJson(res, 200, payload);
      return;
    }

    sendJson(res, 404, { error: "Not found" });
  } catch (error) {
    sendJson(res, 500, { error: error.message || "Internal server error" });
  }
});

async function listen(preferredPort) {
  try {
    await new Promise((resolve, reject) => {
      const onError = (error) => {
        server.off("listening", onListening);
        reject(error);
      };
      const onListening = () => {
        server.off("error", onError);
        resolve();
      };
      server.once("error", onError);
      server.once("listening", onListening);
      server.listen(preferredPort, options.bindHost);
    });
  } catch (error) {
    if ((error?.code === "EADDRINUSE" || error?.code === "EACCES") && preferredPort !== 0) {
      await listen(0);
      return;
    }
    throw error;
  }
}

async function main() {
  await listen(options.port);
  const address = server.address();
  listenPort = typeof address === "object" && address ? address.port : options.port;
  publicBaseUrl = await detectPublicBaseUrl(listenPort);
  const localBaseUrl = `http://127.0.0.1:${listenPort}`;

  log("");
  log("========== Feishu Temporary Web Auth ==========");
  log(`临时网页授权地址（公网）: ${publicBaseUrl}`);
  log(`临时网页授权地址（本地）: ${localBaseUrl}`);
  log(`访问密钥: ${options.authSecret}`);
  log("操作说明: 打开上面的网页地址，输入访问密钥，点击“进行飞书授权”。");
  log("授权完成后脚本会自动继续，网页可以直接关闭。");
  log("==============================================");
  log("");
  log(`[feishu-web-auth] local_url=${localBaseUrl}`);
  log(`[feishu-web-auth] public_url=${publicBaseUrl}`);
  log(`[feishu-web-auth] access_key=${options.authSecret}`);
  log(`[feishu-web-auth] hint=Open the public URL, enter the access key, click the Feishu auth button, and this script will continue automatically after success.`);
}

process.on("SIGINT", () => {
  failAndExit("用户取消了临时飞书授权页。", 130);
});
process.on("SIGTERM", () => {
  failAndExit("临时飞书授权页已终止。", 143);
});

main().catch((error) => {
  process.stderr.write(`${error.message}\n`);
  process.exit(1);
});
