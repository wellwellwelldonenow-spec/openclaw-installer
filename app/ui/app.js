const statusPile = document.querySelector("#status-pile");
const logOutput = document.querySelector("#log-output");
const jobMeta = document.querySelector("#job-meta");
const dashboardBox = document.querySelector("#dashboard-box");
const refreshStatusButton = document.querySelector("#refresh-status");
const checkUpstreamButton = document.querySelector("#check-upstream");
const startInstallButton = document.querySelector("#start-install");
const startUninstallButton = document.querySelector("#start-uninstall");
const openDashboardButton = document.querySelector("#open-dashboard");
const feishuButton = document.querySelector("#run-feishu");
const genericChannelButton = document.querySelector("#run-channel");
const localProxyWrap = document.querySelector("#local-proxy-wrap");
const vlessWrap = document.querySelector("#vless-wrap");

let activeJobId = null;
let pollTimer = null;

function escapeHtml(text) {
  return String(text)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;");
}

function getProxyMode() {
  return document.querySelector('input[name="proxy-mode"]:checked')?.value || "none";
}

function currentInstallPayload() {
  return {
    apiKey: document.querySelector("#api-key").value.trim(),
    modelId: document.querySelector("#model-id").value.trim(),
    baseUrl: document.querySelector("#base-url").value.trim(),
    proxyMode: getProxyMode(),
    localProxyUrl: document.querySelector("#local-proxy-url").value.trim(),
    vlessUrl: document.querySelector("#vless-url").value.trim(),
  };
}

function setLog(text) {
  logOutput.innerHTML = escapeHtml(text || "");
  logOutput.scrollTop = logOutput.scrollHeight;
}

function setJobMeta(text) {
  jobMeta.textContent = text;
}

async function api(path, options = {}) {
  const response = await fetch(path, {
    method: options.method || "GET",
    headers: {
      "Content-Type": "application/json",
      ...(options.headers || {}),
    },
    body: options.body ? JSON.stringify(options.body) : undefined,
  });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) {
    throw new Error(payload.error || `Request failed: ${response.status}`);
  }
  return payload;
}

function updateProxyInputs() {
  const mode = getProxyMode();
  localProxyWrap.classList.toggle("hidden", mode !== "local");
  vlessWrap.classList.toggle("hidden", mode !== "managed");
}

function renderStatusCard(label, value, tone = "default") {
  return `
    <div class="mini-card ${tone}">
      <span class="mini-label">${escapeHtml(label)}</span>
      <strong>${escapeHtml(value || "-")}</strong>
    </div>
  `;
}

async function refreshStatus() {
  const status = await api("/api/status");
  const cards = [
    renderStatusCard("平台", `${status.platform} / ${status.arch}`),
    renderStatusCard("Node", status.nodeVersion),
    renderStatusCard("OpenClaw", status.openclawPath ? "已检测" : "未检测", status.openclawPath ? "good" : "warn"),
    renderStatusCard("curl", status.curlPath ? "可用" : "缺失", status.curlPath ? "good" : "warn"),
    renderStatusCard("代理内核", status.proxyRuntime ? `${status.proxyRuntime.type}` : "未找到", status.proxyRuntime ? "good" : "warn"),
    renderStatusCard("UI 支持", status.uiSupported ? "当前平台启用" : "当前平台仅保留脚本流程", status.uiSupported ? "good" : "warn"),
  ];
  statusPile.innerHTML = cards.join("");
}

async function followJob(jobId) {
  activeJobId = jobId;
  window.clearInterval(pollTimer);
  pollTimer = window.setInterval(async () => {
    try {
      const data = await api(`/api/jobs/${jobId}`);
      const { job } = data;
      setLog(job.logs || "");
      setJobMeta(`${job.label} · ${job.status}`);
      if (job.status !== "running") {
        window.clearInterval(pollTimer);
        pollTimer = null;
        await refreshStatus();
      }
    } catch (error) {
      window.clearInterval(pollTimer);
      pollTimer = null;
      setJobMeta(`读取日志失败: ${error.message}`);
    }
  }, 1200);
}

async function checkUpstream() {
  setJobMeta("上游检测中");
  setLog("正在检测上游...\n");
  const payload = currentInstallPayload();
  const result = await api("/api/check-upstream", {
    method: "POST",
    body: payload,
  });
  setLog(result.logs || "");
  setJobMeta(`检测完成 · models ${result.modelsStatus} · responses ${result.responsesStatus}`);
}

async function startInstall() {
  const payload = currentInstallPayload();
  const result = await api("/api/install", {
    method: "POST",
    body: payload,
  });
  setLog("安装作业已创建...\n");
  setJobMeta("安装已启动");
  await followJob(result.jobId);
}

async function startUninstall() {
  const result = await api("/api/uninstall", {
    method: "POST",
    body: {},
  });
  setLog("卸载作业已创建...\n");
  setJobMeta("卸载已启动");
  await followJob(result.jobId);
}

async function runMappedCommand(command) {
  const result = await api("/api/command", {
    method: "POST",
    body: { command },
  });
  setLog("命令作业已创建...\n");
  setJobMeta("命令执行中");
  await followJob(result.jobId);
}

async function openDashboard() {
  const result = await api("/api/dashboard", {
    method: "POST",
    body: {},
  });
  dashboardBox.innerHTML = `<a href="${escapeHtml(result.url)}" target="_blank" rel="noreferrer">${escapeHtml(result.url)}</a>`;
  window.open(result.url, "_blank", "noopener,noreferrer");
  if (result.output) {
    setLog(result.output);
    setJobMeta("Dashboard 已解析");
  }
}

async function runFeishu() {
  const payload = {
    channel: "feishu",
    guideMode: document.querySelector("#feishu-guide-mode").value,
    appId: document.querySelector("#feishu-app-id").value.trim(),
    appSecret: document.querySelector("#feishu-app-secret").value.trim(),
    test: document.querySelector("#feishu-test").checked,
    restart: true,
  };
  const result = await api("/api/channel", {
    method: "POST",
    body: payload,
  });
  setLog("飞书配置作业已创建...\n");
  setJobMeta("飞书配置中");
  await followJob(result.jobId);
}

async function runGenericChannel() {
  const channel = document.querySelector("#channel-type").value;
  const token = document.querySelector("#channel-token").value.trim();
  const extraId = document.querySelector("#channel-extra-id").value.trim();
  const appToken = document.querySelector("#channel-app-token").value.trim();
  const payload = {
    channel,
    test: document.querySelector("#channel-test").checked,
    restart: true,
  };

  if (channel === "telegram") {
    payload.token = token;
    payload.userId = extraId;
  } else if (channel === "discord") {
    payload.token = token;
    payload.channelId = extraId;
  } else if (channel === "slack") {
    payload.botToken = token;
    payload.appToken = appToken;
  } else if (channel === "wechat") {
    payload.pluginId = extraId || "wechat";
  }

  const result = await api("/api/channel", {
    method: "POST",
    body: payload,
  });
  setLog(`${channel} 配置作业已创建...\n`);
  setJobMeta(`${channel} 配置中`);
  await followJob(result.jobId);
}

refreshStatusButton.addEventListener("click", () => refreshStatus().catch((error) => setJobMeta(error.message)));
checkUpstreamButton.addEventListener("click", () => checkUpstream().catch((error) => setJobMeta(error.message)));
startInstallButton.addEventListener("click", () => startInstall().catch((error) => setJobMeta(error.message)));
startUninstallButton.addEventListener("click", () => startUninstall().catch((error) => setJobMeta(error.message)));
openDashboardButton.addEventListener("click", () => openDashboard().catch((error) => setJobMeta(error.message)));
feishuButton.addEventListener("click", () => runFeishu().catch((error) => setJobMeta(error.message)));
genericChannelButton.addEventListener("click", () => runGenericChannel().catch((error) => setJobMeta(error.message)));

document.querySelectorAll('input[name="proxy-mode"]').forEach((node) => {
  node.addEventListener("change", updateProxyInputs);
});

document.querySelectorAll("[data-command]").forEach((node) => {
  node.addEventListener("click", () => runMappedCommand(node.dataset.command).catch((error) => setJobMeta(error.message)));
});

updateProxyInputs();
refreshStatus().catch((error) => setJobMeta(error.message));
