import fs from "node:fs";
import fsp from "node:fs/promises";
import http from "node:http";
import net from "node:net";
import os from "node:os";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { randomUUID } from "node:crypto";
import { spawn } from "node:child_process";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const ROOT_DIR = path.resolve(__dirname, "..");
const UI_DIR = path.join(__dirname, "ui");
const APP_BIN_DIR = path.join(__dirname, "bin");
const DEFAULT_BASE_URL = "https://newapi.megabyai.cc/v1";
const DEFAULT_MODEL_ID = "gpt-5.3-codex";
const UI_SUPPORTED = process.platform === "darwin" || process.platform === "win32";
const JOB_RETENTION_LIMIT = 40;
const DEFAULT_PROXY_ALLOWLIST = [
  "github.com",
  "githubusercontent.com",
  "githubassets.com",
  "raw.githubusercontent.com",
  "api.github.com",
  "codeload.github.com",
  "objects.githubusercontent.com",
  "release-assets.githubusercontent.com",
  "github-releases.githubusercontent.com",
  "openclaw.ai",
  "registry.npmjs.org",
  "npmjs.org",
  "nodesource.com",
  "deb.nodesource.com",
  "rpm.nodesource.com",
  "dl.google.com",
  "ghcr.io",
  "pkg-containers.githubusercontent.com",
  "formulae.brew.sh",
  "homebrew.github.io",
  "newapi.megabyai.cc",
];

const jobs = new Map();
const jobOrder = [];

function nowIso() {
  return new Date().toISOString();
}

function createJob(label, kind) {
  const job = {
    id: randomUUID(),
    label,
    kind,
    status: "running",
    startedAt: nowIso(),
    finishedAt: null,
    logs: "",
    meta: {},
  };
  jobs.set(job.id, job);
  jobOrder.unshift(job.id);
  while (jobOrder.length > JOB_RETENTION_LIMIT) {
    const removed = jobOrder.pop();
    if (removed) {
      jobs.delete(removed);
    }
  }
  return job;
}

function appendJobLog(job, chunk) {
  if (!chunk) {
    return;
  }
  const text = chunk.toString().replace(/\r\n/g, "\n");
  job.logs += text;
}

function finalizeJob(job, status) {
  job.status = status;
  job.finishedAt = nowIso();
}

function getJob(jobId) {
  return jobs.get(jobId) ?? null;
}

function sendJson(res, statusCode, payload) {
  const body = JSON.stringify(payload);
  res.writeHead(statusCode, {
    "Content-Type": "application/json; charset=utf-8",
    "Cache-Control": "no-store",
    "Content-Length": Buffer.byteLength(body),
  });
  res.end(body);
}

function sendText(res, statusCode, body, contentType = "text/plain; charset=utf-8") {
  res.writeHead(statusCode, {
    "Content-Type": contentType,
    "Cache-Control": "no-store",
    "Content-Length": Buffer.byteLength(body),
  });
  res.end(body);
}

async function readRequestBody(req) {
  const chunks = [];
  for await (const chunk of req) {
    chunks.push(chunk);
  }
  const raw = Buffer.concat(chunks).toString("utf8");
  if (!raw) {
    return {};
  }
  return JSON.parse(raw);
}

function resolveExecutable(name) {
  const pathEntries = (process.env.PATH || "").split(path.delimiter).filter(Boolean);
  const candidates = [];
  const isWin = process.platform === "win32";
  const extensions = isWin
    ? (process.env.PATHEXT || ".EXE;.CMD;.BAT;.COM")
        .split(";")
        .filter(Boolean)
        .map((item) => item.toLowerCase())
    : [""];

  const hasExtension = isWin && /\.[a-z0-9]+$/i.test(name);
  for (const entry of pathEntries) {
    if (hasExtension) {
      candidates.push(path.join(entry, name));
      continue;
    }
    for (const ext of extensions) {
      candidates.push(path.join(entry, `${name}${ext}`));
    }
  }

  for (const candidate of candidates) {
    try {
      fs.accessSync(candidate, fs.constants.X_OK);
      return candidate;
    } catch {}
  }

  return null;
}

function quoteWindowsArg(value) {
  if (value === "") {
    return '""';
  }
  if (!/[\s"]/u.test(value)) {
    return value;
  }
  return `"${value.replace(/(\\*)"/g, '$1$1\\"').replace(/(\\+)$/g, "$1$1")}"`;
}

function spawnResolved(command, args, options = {}) {
  const resolved = path.isAbsolute(command) ? command : resolveExecutable(command) || command;
  const env = options.env || process.env;
  const cwd = options.cwd || ROOT_DIR;
  const stdio = options.stdio || ["ignore", "pipe", "pipe"];
  const windowsHide = options.windowsHide !== false;

  if (process.platform === "win32" && /\.(cmd|bat)$/i.test(resolved)) {
    const comspec = process.env.ComSpec || "cmd.exe";
    const commandLine = [quoteWindowsArg(resolved), ...args.map(quoteWindowsArg)].join(" ");
    return spawn(comspec, ["/d", "/s", "/c", commandLine], {
      cwd,
      env,
      stdio,
      windowsHide,
    });
  }

  return spawn(resolved, args, {
    cwd,
    env,
    stdio,
    windowsHide,
  });
}

function collectProcessOutput(child, onChunk) {
  child.stdout?.on("data", (chunk) => onChunk(chunk));
  child.stderr?.on("data", (chunk) => onChunk(chunk));
}

function runCommandCapture(command, args, options = {}) {
  return new Promise((resolve, reject) => {
    const child = spawnResolved(command, args, options);
    let output = "";
    collectProcessOutput(child, (chunk) => {
      output += chunk.toString();
    });
    child.on("error", reject);
    child.on("close", (code) => {
      resolve({
        code: code ?? 0,
        output,
      });
    });
  });
}

function waitForPort(port, host = "127.0.0.1", timeoutMs = 12000) {
  const started = Date.now();
  return new Promise((resolve, reject) => {
    const attempt = () => {
      const socket = net.createConnection({ host, port });
      const clean = () => socket.destroy();
      socket.once("connect", () => {
        clean();
        resolve();
      });
      socket.once("error", () => {
        clean();
        if (Date.now() - started >= timeoutMs) {
          reject(new Error(`Timed out waiting for ${host}:${port}`));
        } else {
          setTimeout(attempt, 250);
        }
      });
    };
    attempt();
  });
}

async function findFreePort(preferredStart) {
  let port = preferredStart;
  for (let attempt = 0; attempt < 20; attempt += 1) {
    try {
      await new Promise((resolve, reject) => {
        const server = net.createServer();
        server.unref();
        server.once("error", reject);
        server.listen(port, "127.0.0.1", () => {
          server.close((closeError) => (closeError ? reject(closeError) : resolve()));
        });
      });
      return port;
    } catch {
      port += 1;
    }
  }
  throw new Error(`No free local port found near ${preferredStart}`);
}

function sanitizeBaseUrl(baseUrl) {
  const value = String(baseUrl || DEFAULT_BASE_URL).trim();
  return value.replace(/\/+$/, "");
}

function domainFromUrl(input) {
  try {
    return new URL(input).hostname.toLowerCase();
  } catch {
    return "";
  }
}

function buildManagedProxyAllowlist(baseUrl) {
  const domains = new Set(DEFAULT_PROXY_ALLOWLIST);
  const baseHost = domainFromUrl(sanitizeBaseUrl(baseUrl));
  if (baseHost) {
    domains.add(baseHost);
  }
  return Array.from(domains).sort();
}

function parseVlessUrl(rawUrl) {
  const value = String(rawUrl || "").trim();
  if (!value) {
    throw new Error("VLESS URL is required");
  }
  let parsed;
  try {
    parsed = new URL(value);
  } catch {
    throw new Error("Invalid VLESS URL");
  }
  if (parsed.protocol !== "vless:") {
    throw new Error("Only vless:// URLs are supported");
  }

  const params = parsed.searchParams;
  const profile = {
    server: parsed.hostname,
    port: Number(parsed.port || 443),
    uuid: decodeURIComponent(parsed.username),
    encryption: params.get("encryption") || "none",
    flow: params.get("flow") || "",
    security: params.get("security") || "none",
    sni: params.get("sni") || params.get("peer") || "",
    fingerprint: params.get("fp") || "chrome",
    publicKey: params.get("pbk") || "",
    shortId: params.get("sid") || params.get("shortId") || "",
    network: params.get("type") || "tcp",
    headerType: params.get("headerType") || "none",
    host: params.get("host") || "",
    path: params.get("path") || "",
    name: decodeURIComponent(parsed.hash.replace(/^#/, "")),
  };

  if (!profile.server || !profile.uuid || Number.isNaN(profile.port)) {
    throw new Error("VLESS URL is missing server, port, or UUID");
  }
  if (profile.security === "reality" && !profile.publicKey) {
    throw new Error("REALITY nodes require pbk/public key");
  }

  return profile;
}

function runtimeBinaryCandidates() {
  const exe = process.platform === "win32" ? ".exe" : "";
  const platformArch = `${process.platform}-${process.arch}`;
  return [
    path.join(APP_BIN_DIR, `sing-box${exe}`),
    path.join(APP_BIN_DIR, `xray${exe}`),
    path.join(APP_BIN_DIR, platformArch, `sing-box${exe}`),
    path.join(APP_BIN_DIR, platformArch, `xray${exe}`),
  ];
}

function resolveManagedProxyRuntime() {
  for (const candidate of runtimeBinaryCandidates()) {
    if (fs.existsSync(candidate)) {
      return {
        type: candidate.toLowerCase().includes("sing-box") ? "sing-box" : "xray",
        path: candidate,
      };
    }
  }

  const singBoxPath = resolveExecutable("sing-box");
  if (singBoxPath) {
    return { type: "sing-box", path: singBoxPath };
  }
  const xrayPath = resolveExecutable("xray");
  if (xrayPath) {
    return { type: "xray", path: xrayPath };
  }
  return null;
}

function buildSingBoxConfig(profile, httpPort, socksPort, allowedDomains) {
  const outbound = {
    type: "vless",
    tag: "proxy",
    server: profile.server,
    server_port: profile.port,
    uuid: profile.uuid,
  };

  if (profile.flow) {
    outbound.flow = profile.flow;
  }
  if (profile.network === "ws") {
    outbound.transport = {
      type: "ws",
      path: profile.path || "/",
      headers: profile.host ? { Host: profile.host } : undefined,
    };
  }
  if (profile.security !== "none") {
    outbound.tls = {
      enabled: true,
      server_name: profile.sni || undefined,
      utls: {
        enabled: Boolean(profile.fingerprint),
        fingerprint: profile.fingerprint || "chrome",
      },
    };
    if (profile.security === "reality") {
      outbound.tls.reality = {
        enabled: true,
        public_key: profile.publicKey,
        short_id: profile.shortId || "",
      };
    }
  }

  return {
    log: {
      level: "info",
      timestamp: true,
    },
    inbounds: [
      {
        type: "http",
        tag: "http-in",
        listen: "127.0.0.1",
        listen_port: httpPort,
      },
      {
        type: "socks",
        tag: "socks-in",
        listen: "127.0.0.1",
        listen_port: socksPort,
      },
    ],
    outbounds: [
      outbound,
      { type: "direct", tag: "direct" },
      { type: "block", tag: "block" },
    ],
    route: {
      auto_detect_interface: true,
      rules: [
        {
          domain_suffix: allowedDomains,
          outbound: "proxy",
        },
      ],
      final: "block",
    },
  };
}

function buildXrayConfig(profile, httpPort, socksPort, allowedDomains) {
  const outbound = {
    tag: "proxy",
    protocol: "vless",
    settings: {
      vnext: [
        {
          address: profile.server,
          port: profile.port,
          users: [
            {
              id: profile.uuid,
              encryption: profile.encryption,
            },
          ],
        },
      ],
    },
    streamSettings: {
      network: profile.network || "tcp",
      security: profile.security || "none",
    },
  };

  if (profile.flow) {
    outbound.settings.vnext[0].users[0].flow = profile.flow;
  }
  if (profile.security === "reality") {
    outbound.streamSettings.realitySettings = {
      show: false,
      serverName: profile.sni,
      fingerprint: profile.fingerprint || "chrome",
      publicKey: profile.publicKey,
      shortId: profile.shortId || "",
      spiderX: "/",
    };
  }
  if (profile.network === "ws") {
    outbound.streamSettings.wsSettings = {
      path: profile.path || "/",
      headers: profile.host ? { Host: profile.host } : {},
    };
  }
  if (profile.network === "tcp" && profile.headerType !== "none") {
    outbound.streamSettings.tcpSettings = {
      header: {
        type: profile.headerType,
      },
    };
  }

  return {
    log: {
      loglevel: "info",
    },
    inbounds: [
      {
        tag: "http-in",
        listen: "127.0.0.1",
        port: httpPort,
        protocol: "http",
      },
      {
        tag: "socks-in",
        listen: "127.0.0.1",
        port: socksPort,
        protocol: "socks",
        settings: {
          auth: "noauth",
          udp: false,
        },
      },
    ],
    outbounds: [
      outbound,
      { tag: "direct", protocol: "freedom" },
      { tag: "block", protocol: "blackhole" },
    ],
    routing: {
      domainStrategy: "AsIs",
      rules: [
        {
          type: "field",
          inboundTag: ["http-in", "socks-in"],
          domain: allowedDomains.map((domain) => `domain:${domain}`),
          outboundTag: "proxy",
        },
        {
          type: "field",
          inboundTag: ["http-in", "socks-in"],
          outboundTag: "block",
        },
      ],
    },
  };
}

async function startManagedProxy(vlessUrl, baseUrl, onLog) {
  const runtime = resolveManagedProxyRuntime();
  if (!runtime) {
    throw new Error("Managed proxy runtime not found. Put sing-box or xray in app/bin, or install it in PATH.");
  }

  const profile = parseVlessUrl(vlessUrl);
  const allowedDomains = buildManagedProxyAllowlist(baseUrl);
  const httpPort = await findFreePort(7890);
  const socksPort = await findFreePort(httpPort === 7890 ? 7891 : httpPort + 1);
  const tempDir = await fsp.mkdtemp(path.join(os.tmpdir(), "openclaw-proxy-"));
  const configPath = path.join(tempDir, runtime.type === "sing-box" ? "sing-box.json" : "xray.json");
  const config =
    runtime.type === "sing-box"
      ? buildSingBoxConfig(profile, httpPort, socksPort, allowedDomains)
      : buildXrayConfig(profile, httpPort, socksPort, allowedDomains);

  await fsp.writeFile(configPath, `${JSON.stringify(config, null, 2)}\n`, "utf8");

  const args =
    runtime.type === "sing-box"
      ? ["run", "-c", configPath]
      : ["run", "-c", configPath];

  onLog?.(`[proxy] starting ${runtime.type} with ${profile.server}:${profile.port}\n`);
  const child = spawnResolved(runtime.path, args, {
    cwd: tempDir,
    env: process.env,
  });
  collectProcessOutput(child, (chunk) => onLog?.(`[proxy] ${chunk.toString()}`));

  let exitedEarly = false;
  child.once("close", () => {
    exitedEarly = true;
  });

  try {
    await waitForPort(httpPort, "127.0.0.1", 15000);
  } catch (error) {
    if (exitedEarly) {
      throw new Error(`${runtime.type} exited before local proxy became ready`);
    }
    throw error;
  }

  return {
    type: "managed",
    runtime,
    proxyUrl: `http://127.0.0.1:${httpPort}`,
    socksUrl: `socks5h://127.0.0.1:${socksPort}`,
    allowedDomains,
    async stop() {
      if (!child.killed) {
        child.kill("SIGTERM");
        await new Promise((resolve) => {
          const timer = setTimeout(() => {
            child.kill("SIGKILL");
          }, 2500);
          child.once("close", () => {
            clearTimeout(timer);
            resolve();
          });
        });
      }
      await fsp.rm(tempDir, { recursive: true, force: true });
      onLog?.("[proxy] stopped\n");
    },
  };
}

async function prepareProxyContext(payload, onLog) {
  const proxyMode = payload.proxyMode || "none";
  if (proxyMode === "managed") {
    const proxy = await startManagedProxy(payload.vlessUrl, payload.baseUrl, onLog);
    return proxy;
  }
  if (proxyMode === "local" && payload.localProxyUrl) {
    const proxyUrl = String(payload.localProxyUrl).trim();
    return {
      type: "local",
      proxyUrl,
      socksUrl: proxyUrl,
      async stop() {},
    };
  }
  return {
    type: "none",
    proxyUrl: "",
    socksUrl: "",
    async stop() {},
  };
}

function buildProxyEnv(proxyUrl) {
  if (!proxyUrl) {
    return {};
  }
  return {
    HTTP_PROXY: proxyUrl,
    HTTPS_PROXY: proxyUrl,
    ALL_PROXY: proxyUrl,
    http_proxy: proxyUrl,
    https_proxy: proxyUrl,
    all_proxy: proxyUrl,
    OPENCLAW_PROXY_URL: proxyUrl,
  };
}

async function runCurlCheck({ url, method = "GET", apiKey, body, proxyUrl }) {
  const tmpDir = await fsp.mkdtemp(path.join(os.tmpdir(), "openclaw-curl-"));
  const bodyPath = path.join(tmpDir, "body.txt");
  const args = ["-sS", "-o", bodyPath, "-w", "%{http_code}", "-H", `Authorization: Bearer ${apiKey}`];
  if (proxyUrl) {
    args.push("--proxy", proxyUrl);
  }
  if (method === "POST") {
    args.push("-X", "POST", "-H", "Content-Type: application/json", "-d", JSON.stringify(body || {}));
  }
  args.push(url);

  const env = {
    ...process.env,
    ...buildProxyEnv(proxyUrl),
  };

  const result = await runCommandCapture("curl", args, { env, cwd: tmpDir });
  const responseBody = fs.existsSync(bodyPath) ? await fsp.readFile(bodyPath, "utf8") : "";
  await fsp.rm(tmpDir, { recursive: true, force: true });
  return {
    statusCode: Number(result.output.trim() || "0"),
    output: responseBody,
    curlOutput: result.output,
    exitCode: result.code,
  };
}

function responsesStatusSupported(statusCode) {
  return new Set([200, 201, 202, 400, 401, 403, 409, 422, 429, 500]).has(statusCode);
}

async function checkUpstreamReachability(payload, onLog) {
  const apiKey = String(payload.apiKey || "").trim();
  const modelId = String(payload.modelId || DEFAULT_MODEL_ID).trim();
  const baseUrl = sanitizeBaseUrl(payload.baseUrl);
  if (!apiKey) {
    throw new Error("API key is required");
  }

  const proxy = await prepareProxyContext(payload, onLog);
  try {
    const proxyText = proxy.proxyUrl ? ` via ${proxy.proxyUrl}` : "";
    onLog?.(`Checking ${baseUrl}/models${proxyText}\n`);
    const models = await runCurlCheck({
      url: `${baseUrl}/models`,
      apiKey,
      proxyUrl: proxy.proxyUrl,
    });
    if (models.statusCode !== 200) {
      throw new Error(`/models returned HTTP ${models.statusCode}`);
    }

    onLog?.(`Checking ${baseUrl}/responses with model ${modelId}\n`);
    const responses = await runCurlCheck({
      url: `${baseUrl}/responses`,
      method: "POST",
      apiKey,
      proxyUrl: proxy.proxyUrl,
      body: {
        model: modelId,
        input: "ping",
        max_output_tokens: 1,
      },
    });
    if (!responsesStatusSupported(responses.statusCode)) {
      throw new Error(`/responses returned HTTP ${responses.statusCode}`);
    }

    return {
      ok: true,
      proxyMode: proxy.type,
      proxyUrl: proxy.proxyUrl,
      modelsStatus: models.statusCode,
      responsesStatus: responses.statusCode,
    };
  } finally {
    await proxy.stop();
  }
}

function scriptPaths() {
  return {
    installUnix: path.join(ROOT_DIR, "install_openclaw.sh"),
    installWindows: path.join(ROOT_DIR, "install_openclaw.ps1"),
    channelUnix: path.join(ROOT_DIR, "channel_setup.sh"),
    channelWindows: path.join(ROOT_DIR, "channel_setup.ps1"),
  };
}

function openClawExecutable() {
  return resolveExecutable("openclaw");
}

function powershellExecutable() {
  return resolveExecutable("pwsh") || resolveExecutable("powershell");
}

function buildInstallerInvocation(payload, proxyUrl) {
  const scripts = scriptPaths();
  const uninstall = payload.uninstall === true;
  if (process.platform === "win32") {
    const shell = powershellExecutable();
    if (!shell) {
      throw new Error("PowerShell was not found");
    }
    const args = [
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      scripts.installWindows,
    ];
    if (uninstall) {
      args.push("-Uninstall");
    } else {
      args.push(
        "-ApiKey",
        String(payload.apiKey || "").trim(),
        "-ModelId",
        String(payload.modelId || DEFAULT_MODEL_ID).trim(),
      );
    }
    if (proxyUrl) {
      args.push("-ProxyUrl", proxyUrl);
    }
    return {
      command: shell,
      args,
      env: {
        ...process.env,
        ...buildProxyEnv(proxyUrl),
        OPENCLAW_MODEL_ID: String(payload.modelId || DEFAULT_MODEL_ID).trim(),
      },
    };
  }

  const args = [scripts.installUnix];
  if (uninstall) {
    args.push("--uninstall");
  }
  if (proxyUrl) {
    args.push("--proxy", proxyUrl);
  }
  return {
    command: "bash",
    args,
    env: {
      ...process.env,
      ...buildProxyEnv(proxyUrl),
      NEWAPI_API_KEY: String(payload.apiKey || "").trim(),
      OPENCLAW_MODEL_ID: String(payload.modelId || DEFAULT_MODEL_ID).trim(),
    },
  };
}

function buildChannelInvocation(channel, payload) {
  const scripts = scriptPaths();
  const restart = payload.restart !== false;
  const test = payload.test === true;

  if (process.platform === "win32") {
    const shell = powershellExecutable();
    if (!shell) {
      throw new Error("PowerShell was not found");
    }
    const args = [
      "-NoProfile",
      "-ExecutionPolicy",
      "Bypass",
      "-File",
      scripts.channelWindows,
      "-Channel",
      channel,
    ];
    if (!restart) {
      args.push("-NoRestart");
    }
    if (test) {
      args.push("-Test");
    }
    if (payload.guideMode) {
      args.push("-GuideMode", payload.guideMode);
    }
    if (payload.token) {
      args.push("-Token", payload.token);
    }
    if (payload.botToken) {
      args.push("-BotToken", payload.botToken);
    }
    if (payload.appToken) {
      args.push("-AppToken", payload.appToken);
    }
    if (payload.userId) {
      args.push("-UserId", payload.userId);
    }
    if (payload.channelId) {
      args.push("-ChannelId", payload.channelId);
    }
    if (payload.appId) {
      args.push("-AppId", payload.appId);
    }
    if (payload.appSecret) {
      args.push("-AppSecret", payload.appSecret);
    }
    if (payload.pluginId) {
      args.push("-PluginId", payload.pluginId);
    }
    return { command: shell, args, env: process.env };
  }

  const args = [scripts.channelUnix, channel];
  if (!restart) {
    args.push("--no-restart");
  }
  if (test) {
    args.push("--test");
  }
  if (payload.guideMode) {
    args.push("--guide-mode", payload.guideMode);
  }
  if (payload.token) {
    args.push("--token", payload.token);
  }
  if (payload.botToken) {
    args.push("--bot-token", payload.botToken);
  }
  if (payload.appToken) {
    args.push("--app-token", payload.appToken);
  }
  if (payload.userId) {
    args.push("--user-id", payload.userId);
  }
  if (payload.channelId) {
    args.push("--channel-id", payload.channelId);
  }
  if (payload.appId) {
    args.push("--app-id", payload.appId);
  }
  if (payload.appSecret) {
    args.push("--app-secret", payload.appSecret);
  }
  if (payload.pluginId) {
    args.push("--plugin-id", payload.pluginId);
  }
  return { command: "bash", args, env: process.env };
}

function runProcessJob({ label, kind, command, args, env, onStart, onComplete }) {
  const job = createJob(label, kind);

  Promise.resolve()
    .then(async () => {
      if (onStart) {
        await onStart(job);
      }
      appendJobLog(job, `[job] ${label}\n`);
      const resolvedCommand = typeof command === "function" ? await command(job) : command;
      const resolvedArgs = typeof args === "function" ? await args(job) : args;
      const resolvedEnv = typeof env === "function" ? await env(job) : env;
      const child = spawnResolved(resolvedCommand, resolvedArgs, { env: resolvedEnv, cwd: ROOT_DIR });
      collectProcessOutput(child, (chunk) => appendJobLog(job, chunk));
      return new Promise((resolve, reject) => {
        child.on("error", reject);
        child.on("close", (code) => {
          job.meta.exitCode = code ?? 0;
          resolve(code ?? 0);
        });
      });
    })
    .then(async (code) => {
      if (onComplete) {
        await onComplete(job, code);
      }
      finalizeJob(job, code === 0 ? "success" : "failed");
    })
    .catch((error) => {
      Promise.resolve(onComplete ? onComplete(job, null) : null)
        .catch(() => {})
        .finally(() => {
          appendJobLog(job, `[error] ${error.message}\n`);
          finalizeJob(job, "failed");
        });
    });

  return job;
}

function runInstallJob(payload) {
  let proxyContext = null;
  let invocation = null;

  return runProcessJob({
    label: "Install OpenClaw",
    kind: "install",
    async onStart(job) {
      appendJobLog(job, "Preparing proxy context\n");
      proxyContext = await prepareProxyContext(payload, (chunk) => appendJobLog(job, chunk));
      if (proxyContext.proxyUrl) {
        appendJobLog(job, `Proxy ready: ${proxyContext.proxyUrl}\n`);
        if (Array.isArray(proxyContext.allowedDomains)) {
          appendJobLog(job, `Proxy allowlist: ${proxyContext.allowedDomains.join(", ")}\n`);
        }
      } else {
        appendJobLog(job, "Proxy disabled for this run\n");
      }

      appendJobLog(job, "Preflight upstream check\n");
      const result = await checkUpstreamReachability(
        {
          ...payload,
          proxyMode: proxyContext.type === "local" ? "local" : proxyContext.type === "managed" ? "local" : "none",
          localProxyUrl: proxyContext.proxyUrl,
        },
        (chunk) => appendJobLog(job, `[check] ${chunk}`),
      );
      appendJobLog(job, `[check] models=${result.modelsStatus}, responses=${result.responsesStatus}\n`);

      invocation = buildInstallerInvocation(payload, proxyContext.proxyUrl);
      job.meta.command = invocation.command;
      job.meta.args = invocation.args;
      job.meta.proxyUrl = proxyContext.proxyUrl;
    },
    async onComplete(job) {
      if (proxyContext) {
        await proxyContext.stop();
      }
      job.meta.proxyUrl = proxyContext?.proxyUrl || "";
    },
    command: () => invocation?.command,
    args: () => invocation?.args,
    env: () => invocation?.env,
  });
}

function runUninstallJob(payload = {}) {
  let invocation = null;

  return runProcessJob({
    label: "Uninstall OpenClaw",
    kind: "uninstall",
    async onStart(job) {
      invocation = buildInstallerInvocation({ ...payload, uninstall: true }, "");
      job.meta.command = invocation.command;
      job.meta.args = invocation.args;
      appendJobLog(job, "Starting uninstall workflow\n");
    },
    command: () => invocation?.command,
    args: () => invocation?.args,
    env: () => invocation?.env,
  });
}

function runCommandJob(label, args) {
  const openclaw = openClawExecutable();
  if (!openclaw) {
    throw new Error("openclaw CLI not found in PATH");
  }
  return runProcessJob({
    label,
    kind: "command",
    command: openclaw,
    args,
    env: process.env,
  });
}

async function resolveDashboardUrl() {
  const openclaw = openClawExecutable();
  if (!openclaw) {
    throw new Error("openclaw CLI not found in PATH");
  }
  const result = await runCommandCapture(openclaw, ["dashboard"], { env: process.env });
  const match = result.output.match(/https?:\/\/\S+/u);
  return {
    url: match ? match[0].trim() : "http://127.0.0.1:18789/",
    output: result.output,
    exitCode: result.code,
  };
}

async function statusPayload() {
  const scripts = scriptPaths();
  const proxyRuntime = resolveManagedProxyRuntime();
  const nodePath = process.execPath;
  const openclaw = openClawExecutable();
  const curlPath = resolveExecutable("curl");
  return {
    platform: process.platform,
    arch: process.arch,
    hostname: os.hostname(),
    uiSupported: UI_SUPPORTED,
    nodePath,
    nodeVersion: process.version,
    openclawPath: openclaw,
    curlPath,
    proxyRuntime,
    scripts: {
      installUnix: fs.existsSync(scripts.installUnix),
      installWindows: fs.existsSync(scripts.installWindows),
      channelUnix: fs.existsSync(scripts.channelUnix),
      channelWindows: fs.existsSync(scripts.channelWindows),
    },
    jobs: jobOrder.map((jobId) => {
      const job = jobs.get(jobId);
      return job
        ? {
            id: job.id,
            label: job.label,
            kind: job.kind,
            status: job.status,
            startedAt: job.startedAt,
            finishedAt: job.finishedAt,
          }
        : null;
    }).filter(Boolean),
  };
}

function routeStatic(req, res) {
  const requestPath = new URL(req.url, "http://127.0.0.1").pathname;
  const relative = requestPath === "/" ? "index.html" : requestPath.replace(/^\/+/, "");
  const safePath = path.normalize(relative).replace(/^(\.\.[/\\])+/, "");
  const filePath = path.join(UI_DIR, safePath);
  if (!filePath.startsWith(UI_DIR)) {
    sendText(res, 403, "Forbidden");
    return;
  }
  if (!fs.existsSync(filePath) || fs.statSync(filePath).isDirectory()) {
    sendText(res, 404, "Not found");
    return;
  }
  const ext = path.extname(filePath);
  const contentType =
    ext === ".html"
      ? "text/html; charset=utf-8"
      : ext === ".js"
        ? "application/javascript; charset=utf-8"
        : ext === ".css"
          ? "text/css; charset=utf-8"
          : "application/octet-stream";
  sendText(res, 200, fs.readFileSync(filePath, "utf8"), contentType);
}

async function handleApi(req, res) {
  const url = new URL(req.url, "http://127.0.0.1");
  if (req.method === "GET" && url.pathname === "/api/status") {
    sendJson(res, 200, await statusPayload());
    return;
  }

  if (req.method === "GET" && url.pathname.startsWith("/api/jobs/")) {
    const jobId = url.pathname.split("/").pop();
    const job = getJob(jobId);
    if (!job) {
      sendJson(res, 404, { error: "Job not found" });
      return;
    }
    sendJson(res, 200, { job });
    return;
  }

  if (req.method !== "POST") {
    sendJson(res, 405, { error: "Method not allowed" });
    return;
  }

  let payload = {};
  try {
    payload = await readRequestBody(req);
  } catch {
    sendJson(res, 400, { error: "Invalid JSON payload" });
    return;
  }

  try {
    if (url.pathname === "/api/check-upstream") {
      const logs = [];
      const result = await checkUpstreamReachability(payload, (chunk) => logs.push(chunk));
      sendJson(res, 200, { ...result, logs: logs.join("") });
      return;
    }

    if (url.pathname === "/api/install") {
      if (!String(payload.apiKey || "").trim()) {
        sendJson(res, 400, { error: "API key is required" });
        return;
      }
      const job = runInstallJob(payload);
      sendJson(res, 202, { jobId: job.id });
      return;
    }

    if (url.pathname === "/api/uninstall") {
      const job = runUninstallJob(payload);
      sendJson(res, 202, { jobId: job.id });
      return;
    }

    if (url.pathname === "/api/dashboard") {
      const result = await resolveDashboardUrl();
      sendJson(res, 200, result);
      return;
    }

    if (url.pathname === "/api/command") {
      const commands = {
        gatewayStatus: { label: "Gateway Status", args: ["gateway", "status", "--deep"] },
        systemStatus: { label: "OpenClaw Status", args: ["status", "--all"] },
        gatewayRestart: { label: "Gateway Restart", args: ["gateway", "restart"] },
        channelsList: { label: "Channels List", args: ["channels", "list"] },
        doctorFix: { label: "Doctor Fix", args: ["doctor", "--fix"] },
      };
      const selected = commands[payload.command];
      if (!selected) {
        sendJson(res, 400, { error: "Unknown command" });
        return;
      }
      const job = runCommandJob(selected.label, selected.args);
      sendJson(res, 202, { jobId: job.id });
      return;
    }

    if (url.pathname === "/api/channel") {
      if (!payload.channel) {
        sendJson(res, 400, { error: "Channel is required" });
        return;
      }
      const invocation = buildChannelInvocation(payload.channel, payload);
      const label = payload.channel === "feishu" ? "Feishu Channel Setup" : `Channel Setup: ${payload.channel}`;
      const job = runProcessJob({
        label,
        kind: "channel",
        command: invocation.command,
        args: invocation.args,
        env: invocation.env,
      });
      sendJson(res, 202, { jobId: job.id });
      return;
    }
  } catch (error) {
    sendJson(res, 500, { error: error.message });
    return;
  }

  sendJson(res, 404, { error: "API route not found" });
}

const server = http.createServer(async (req, res) => {
  try {
    if ((req.url || "").startsWith("/api/")) {
      await handleApi(req, res);
      return;
    }
    routeStatic(req, res);
  } catch (error) {
    sendJson(res, 500, { error: error.message || "Internal server error" });
  }
});

export async function startServer(options = {}) {
  const port = Number(options.port || process.env.OPENCLAW_CONTROL_PORT || 3218);
  await new Promise((resolve) => server.listen(port, "127.0.0.1", resolve));
  const url = `http://127.0.0.1:${port}/`;
  console.log(`OpenClaw control UI listening on ${url}`);
  if (options.openBrowser === false || process.env.OPENCLAW_CONTROL_NO_OPEN === "1") {
    return { port, url, server };
  }
  if (process.platform === "darwin") {
    spawnResolved("open", [url], { stdio: ["ignore", "ignore", "ignore"] });
  } else if (process.platform === "win32") {
    const shell = process.env.ComSpec || "cmd.exe";
    spawn(shell, ["/d", "/s", "/c", "start", "", url], {
      stdio: "ignore",
      windowsHide: true,
    });
  }

  return { port, url, server };
}

export async function stopServer() {
  if (!server.listening) {
    return;
  }
  await new Promise((resolve, reject) => {
    server.close((error) => {
      if (error) {
        reject(error);
        return;
      }
      resolve();
    });
  });
}

const isEntrypoint = process.argv[1] && path.resolve(process.argv[1]) === __filename;
if (isEntrypoint) {
  startServer().catch((error) => {
    console.error(error);
    process.exitCode = 1;
  });
}
