#!/usr/bin/env node

import crypto from "node:crypto";
import fs from "node:fs/promises";
import http from "node:http";
import os from "node:os";

const DEFAULT_SECRET = "megaaifeishu";
const DEFAULT_TIMEOUT_SEC = 900;
const DEFAULT_PORT = 38459;
const DEFAULT_ENV = "prod";
const SESSION_COOKIE = "openclaw_feishu_registration";

const DOMAIN_MAP = {
  feishu: {
    prod: "https://accounts.feishu.cn",
    boe: "https://accounts.feishu-boe.cn",
    pre: "https://accounts.feishu-pre.cn",
  },
  lark: {
    prod: "https://accounts.larksuite.com",
    boe: "https://accounts.larksuite-boe.com",
    pre: "https://accounts.larksuite-pre.com",
  },
};

function parseArgs(argv) {
  const options = {
    authSecret: DEFAULT_SECRET,
    bindHost: "0.0.0.0",
    port: DEFAULT_PORT,
    timeoutSec: DEFAULT_TIMEOUT_SEC,
    publicBaseUrl: "",
    brand: "feishu",
    env: DEFAULT_ENV,
    resultFile: "",
  };

  for (let index = 0; index < argv.length; index += 1) {
    const key = argv[index];
    const next = argv[index + 1];
    switch (key) {
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
        options.timeoutSec = next === undefined ? DEFAULT_TIMEOUT_SEC : Number(next);
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
      case "--env":
        options.env = String(next || "").trim() || DEFAULT_ENV;
        index += 1;
        break;
      case "--result-file":
        options.resultFile = String(next || "").trim();
        index += 1;
        break;
      default:
        throw new Error(`Unknown argument: ${key}`);
    }
  }

  if (!DOMAIN_MAP[options.brand]) {
    throw new Error(`Unsupported --brand: ${options.brand}`);
  }
  if (!DOMAIN_MAP[options.brand][options.env]) {
    throw new Error(`Unsupported --env: ${options.env}`);
  }
  if (!Number.isInteger(options.timeoutSec) || options.timeoutSec < 0) {
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
    appId: "",
  },
  stopTimer: null,
};

let shuttingDown = false;
let server;
let publicBaseUrl = "";
let listenPort = options.port;
const timeoutHandle = options.timeoutSec > 0
  ? setTimeout(() => {
      failAndExit("等待飞书新建机器人二维码超时，请重新运行脚本。", 1);
    }, options.timeoutSec * 1000)
  : null;

function log(message) {
  process.stdout.write(`${message}\n`);
}

function normalizeBaseUrl(value) {
  return String(value || "").trim().replace(/\/+$/, "");
}

function randomId() {
  return crypto.randomBytes(18).toString("hex");
}

function registrationBaseUrl(brand = options.brand) {
  return DOMAIN_MAP[brand][options.env];
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
  const stage = JSON.stringify({
    stage: state.authState.stage,
    message: state.authState.message,
    detail: state.authState.detail,
    authUrl: state.authState.authUrl,
    expiresAt: Number(state.authState.expiresAt || 0),
    userOpenId: state.authState.userOpenId,
    appId: state.authState.appId,
    publicBaseUrl,
  });

  return `<!doctype html>
<html lang="zh-CN">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <title>OpenClaw Feishu Bot Registration</title>
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
      width: min(760px, 100%);
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
    .grid {
      display: grid;
      gap: 20px;
      grid-template-columns: minmax(240px, 280px) 1fr;
      align-items: start;
    }
    .qr-wrap {
      display: grid;
      place-items: center;
      gap: 12px;
      padding: 18px;
      border-radius: 18px;
      background: rgba(15,118,110,0.05);
      border: 1px dashed rgba(15,118,110,0.24);
      min-height: 280px;
    }
    #qr-canvas {
      display: none;
      background: #fff;
      border-radius: 12px;
      padding: 10px;
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
    @media (max-width: 760px) {
      .grid { grid-template-columns: 1fr; }
    }
  </style>
  <script src="https://cdn.jsdelivr.net/npm/qrcode@1.5.4/build/qrcode.min.js"></script>
</head>
<body>
  <div class="shell">
    <div class="hero">
      <span class="badge">OpenClaw Temporary Access</span>
      <h1>飞书临时创建机器人页</h1>
      <p>输入访问密钥后生成飞书官方“一键创建机器人”二维码。扫码成功后，脚本会自动继续并写入新机器人的 App ID / App Secret。</p>
    </div>
    <div class="body">
      <section id="unlock-panel" class="panel">
        <label for="secret">访问密钥</label>
        <input id="secret" type="password" placeholder="请输入访问密钥">
        <div class="actions">
          <button id="unlock-button" class="primary" type="button">进入创建页</button>
        </div>
        <p id="unlock-error" class="mini"></p>
      </section>
      <section id="auth-panel" class="panel hidden">
        <div class="grid">
          <div class="qr-wrap">
            <canvas id="qr-canvas" width="240" height="240"></canvas>
            <div id="qr-hint" class="mini">点击下方按钮后，这里会显示官方创建机器人二维码。</div>
          </div>
          <div>
            <div id="auth-status" class="status">
              <strong>等待开始</strong>
              <span>点击下方按钮生成官方二维码。</span>
              <div class="mini"></div>
            </div>
            <div class="actions">
              <button id="start-auth" class="primary" type="button">生成官方二维码</button>
              <a id="open-auth-link" class="button-link primary hidden" href="#" target="_blank" rel="noreferrer">打开授权页</a>
              <button id="refresh-auth" class="warn hidden" type="button">重新生成二维码</button>
            </div>
            <ul class="tips">
              <li>这不是开发者后台登录二维码，而是官方新建机器人二维码。</li>
              <li>二维码过期后，直接点“重新生成二维码”。</li>
              <li>扫码成功后，脚本会自动继续，当前网页可以关闭。</li>
            </ul>
          </div>
        </div>
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
    const qrCanvas = document.querySelector("#qr-canvas");
    const qrHint = document.querySelector("#qr-hint");
    let pollTimer = null;

    async function renderQr(url) {
      if (!url) {
        qrCanvas.style.display = "none";
        qrHint.textContent = "点击下方按钮后，这里会显示官方创建机器人二维码。";
        return;
      }
      if (!window.QRCode || !window.QRCode.toCanvas) {
        qrCanvas.style.display = "none";
        qrHint.textContent = "二维码脚本加载失败，请直接点击“打开授权页”。";
        return;
      }
      try {
        await window.QRCode.toCanvas(qrCanvas, url, { width: 240, margin: 1 });
        qrCanvas.style.display = "block";
        qrHint.textContent = "请使用飞书扫码，确认一键创建机器人。";
      } catch (error) {
        qrCanvas.style.display = "none";
        qrHint.textContent = error && error.message ? error.message : "二维码生成失败，请直接点击“打开授权页”。";
      }
    }

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
      if (payload.expiresAt) detail.push("二维码截止: " + new Date(payload.expiresAt).toLocaleString());
      if (payload.userOpenId) detail.push("授权用户: " + payload.userOpenId);
      if (payload.appId) detail.push("机器人 App ID: " + payload.appId);
      authStatus.querySelector(".mini").textContent = detail.join("  |  ");
      openAuthLink.classList.toggle("hidden", !payload.authUrl);
      openAuthLink.href = payload.authUrl || "#";
      refreshAuthButton.classList.toggle("hidden", !(stage === "expired" || stage === "failed" || stage === "denied"));
      startAuthButton.classList.toggle("hidden", stage === "pending" || stage === "success");
      renderQr(payload.authUrl || "");
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
          authStatus.querySelector("strong").textContent = "创建状态读取失败";
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
      const response = await fetch("/api/registration/start", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({}),
      });
      const payload = await response.json();
      if (!response.ok) {
        throw new Error(payload.error || "创建二维码失败");
      }
      renderStatus(payload);
      ensurePolling();
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
      renderStatus({ stage: "failed", message: "创建二维码失败", detail: error.message });
    }));
    refreshAuthButton.addEventListener("click", () => createFlow().catch((error) => {
      renderStatus({ stage: "failed", message: "重新生成二维码失败", detail: error.message });
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

async function registrationInit(baseUrl) {
  return requestJson(`${baseUrl}/oauth/v1/app/registration`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({ action: "init" }).toString(),
  });
}

async function registrationBegin(baseUrl) {
  return requestJson(`${baseUrl}/oauth/v1/app/registration`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      action: "begin",
      archetype: "PersonalAgent",
      auth_method: "client_secret",
      request_user_info: "open_id",
    }).toString(),
  });
}

async function registrationPoll(baseUrl, deviceCode) {
  const response = await fetch(`${baseUrl}/oauth/v1/app/registration`, {
    method: "POST",
    headers: { "Content-Type": "application/x-www-form-urlencoded" },
    body: new URLSearchParams({
      action: "poll",
      device_code: deviceCode,
    }).toString(),
  });
  const text = await response.text();
  if (!text) {
    return {};
  }
  try {
    return JSON.parse(text);
  } catch {
    throw new Error(`Unexpected response from ${baseUrl}/oauth/v1/app/registration: ${text.slice(0, 200)}`);
  }
}

async function writeResultFile(result) {
  if (!options.resultFile) {
    return;
  }
  await fs.writeFile(options.resultFile, `${JSON.stringify(result)}\n`, "utf8");
}

async function pollRegistrationFlow(flow) {
  let intervalSec = flow.interval;

  while (Date.now() < flow.expiresAt) {
    await new Promise((resolve) => setTimeout(resolve, intervalSec * 1000));
    if (state.currentFlow !== flow || shuttingDown) {
      return;
    }

    let payload;
    try {
      payload = await registrationPoll(flow.baseUrl, flow.deviceCode);
    } catch (error) {
      state.authState = {
        stage: "failed",
        message: "官方创建机器人轮询失败",
        detail: error.message,
        authUrl: flow.authUrl,
        expiresAt: flow.expiresAt,
        userOpenId: "",
        appId: "",
      };
      return;
    }

    if (payload.user_info?.tenant_brand && payload.user_info.tenant_brand === "lark" && !flow.domainSwitched) {
      flow.domainSwitched = true;
      flow.baseUrl = registrationBaseUrl("lark");
      continue;
    }

    if (payload.client_id && payload.client_secret) {
      const result = {
        appId: String(payload.client_id || ""),
        appSecret: String(payload.client_secret || ""),
        brand: payload.user_info?.tenant_brand === "lark" ? "lark" : options.brand,
        userOpenId: String(payload.user_info?.open_id || ""),
      };
      await writeResultFile(result);
      state.authState = {
        stage: "success",
        message: "机器人已创建，脚本继续中",
        detail: "已拿到 App ID / App Secret，当前网页可以关闭。",
        authUrl: flow.authUrl,
        expiresAt: flow.expiresAt,
        userOpenId: result.userOpenId,
        appId: result.appId,
      };
      scheduleStop(1500, 0);
      return;
    }

    const errorCode = String(payload.error || "");
    if (errorCode === "authorization_pending") {
      continue;
    }
    if (errorCode === "slow_down") {
      intervalSec = Math.min(intervalSec + 5, 60);
      continue;
    }
    if (errorCode === "access_denied") {
      state.authState = {
        stage: "denied",
        message: "用户取消了创建机器人授权",
        detail: "点击“重新生成二维码”可再次发起。",
        authUrl: flow.authUrl,
        expiresAt: flow.expiresAt,
        userOpenId: "",
        appId: "",
      };
      return;
    }
    if (errorCode === "expired_token") {
      state.authState = {
        stage: "expired",
        message: "官方二维码已失效",
        detail: "请重新生成二维码。",
        authUrl: flow.authUrl,
        expiresAt: flow.expiresAt,
        userOpenId: "",
        appId: "",
      };
      return;
    }

    state.authState = {
      stage: "failed",
      message: "创建机器人失败",
      detail: payload.error_description || payload.msg || errorCode || "未知错误",
      authUrl: flow.authUrl,
      expiresAt: flow.expiresAt,
      userOpenId: "",
      appId: "",
    };
    return;
  }

  state.authState = {
    stage: "expired",
    message: "官方二维码已失效",
    detail: "超过有效时间，请重新生成二维码。",
    authUrl: flow.authUrl,
    expiresAt: flow.expiresAt,
    userOpenId: "",
    appId: "",
  };
}

async function startRegistrationFlow() {
  const baseUrl = registrationBaseUrl();
  const initRes = await registrationInit(baseUrl);
  if (!Array.isArray(initRes.supported_auth_methods) || !initRes.supported_auth_methods.includes("client_secret")) {
    throw new Error("当前环境不支持 client_secret 创建机器人");
  }

  const beginRes = await registrationBegin(baseUrl);
  state.currentFlow = {
    baseUrl,
    domainSwitched: false,
    deviceCode: String(beginRes.device_code || ""),
    authUrl: String(beginRes.verification_uri_complete || beginRes.verification_uri || ""),
    interval: Number(beginRes.interval || 5),
    expiresAt: Date.now() + Number(beginRes.expire_in || 600) * 1000,
  };

  state.authState = {
    stage: "pending",
    message: "官方二维码已生成",
    detail: "请使用飞书扫码，确认一键创建机器人。",
    authUrl: state.currentFlow.authUrl,
    expiresAt: state.currentFlow.expiresAt,
    userOpenId: "",
    appId: "",
  };

  void pollRegistrationFlow(state.currentFlow).catch((error) => {
    state.authState = {
      stage: "failed",
      message: "创建机器人轮询失败",
      detail: error.message,
      authUrl: state.currentFlow?.authUrl || "",
      expiresAt: state.currentFlow?.expiresAt || 0,
      userOpenId: "",
      appId: "",
    };
  });

  return state.authState;
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
    message: "临时创建机器人页失败",
    detail: message,
    authUrl: "",
    expiresAt: 0,
    userOpenId: "",
    appId: "",
  };
  process.stderr.write(`${message}\n`);
  scheduleStop(10, exitCode);
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
        sendJson(res, 401, { error: "未解锁临时创建页" });
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
        detail: state.currentFlow ? state.authState.detail : "现在可以生成官方二维码。",
      };
      sendJson(res, 200, state.authState, {
        "Set-Cookie": `${SESSION_COOKIE}=${encodeURIComponent(sessionId)}; HttpOnly; SameSite=Lax; Path=/`,
      });
      return;
    }

    if (url.pathname === "/api/registration/start") {
      if (!sessionAllowed(req)) {
        sendJson(res, 401, { error: "未解锁临时创建页" });
        return;
      }
      const payload = await startRegistrationFlow();
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
  log("========== Feishu Temporary Registration ==========");
  log(`临时网页创建地址（公网）: ${publicBaseUrl}`);
  log(`临时网页创建地址（本地）: ${localBaseUrl}`);
  log(`访问密钥: ${options.authSecret}`);
  log("操作说明: 打开上面的网页地址，输入访问密钥，点击“生成官方二维码”。");
  log("扫码创建成功后脚本会自动继续，网页可以直接关闭。");
  log("==================================================");
  log("");
}

process.on("SIGINT", () => {
  failAndExit("用户取消了临时创建机器人页。", 130);
});

process.on("SIGTERM", () => {
  failAndExit("临时创建机器人页已终止。", 143);
});

main().catch((error) => {
  process.stderr.write(`${error.message}\n`);
  process.exit(1);
});
