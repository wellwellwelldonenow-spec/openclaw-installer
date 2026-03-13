import path from "node:path";
import { fileURLToPath } from "node:url";
import { app, BrowserWindow, dialog, shell } from "electron";
import { startServer, stopServer } from "./server.mjs";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const iconPath = process.platform === "win32"
  ? path.join(__dirname, "assets", "icon.ico")
  : path.join(__dirname, "assets", "icon.png");

let mainWindow = null;
let controlServer = null;

const gotSingleInstanceLock = app.requestSingleInstanceLock();
if (!gotSingleInstanceLock) {
  app.quit();
}

app.on("second-instance", () => {
  if (!mainWindow) {
    return;
  }
  if (mainWindow.isMinimized()) {
    mainWindow.restore();
  }
  mainWindow.focus();
});

async function createMainWindow() {
  controlServer = await startServer({ openBrowser: false });

  mainWindow = new BrowserWindow({
    width: 1320,
    height: 920,
    minWidth: 1080,
    minHeight: 760,
    title: "OpenClaw Control",
    autoHideMenuBar: true,
    backgroundColor: "#ece4d6",
    icon: iconPath,
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  });

  mainWindow.webContents.setWindowOpenHandler(({ url }) => {
    shell.openExternal(url).catch(() => {});
    return { action: "deny" };
  });

  mainWindow.webContents.on("will-navigate", (event, url) => {
    if (url !== controlServer?.url) {
      event.preventDefault();
      shell.openExternal(url).catch(() => {});
    }
  });

  mainWindow.on("closed", () => {
    mainWindow = null;
  });

  await mainWindow.loadURL(controlServer.url);
}

app.name = "OpenClaw Control";
app.setAboutPanelOptions({
  applicationName: "OpenClaw Control",
  applicationVersion: app.getVersion(),
  copyright: "megabyai",
});

app.on("window-all-closed", async () => {
  await stopServer().catch(() => {});
  if (process.platform !== "darwin") {
    app.quit();
  }
});

app.on("before-quit", async () => {
  await stopServer().catch(() => {});
});

app.on("activate", async () => {
  if (BrowserWindow.getAllWindows().length === 0) {
    await createMainWindow();
  }
});

app.whenReady()
  .then(createMainWindow)
  .catch(async (error) => {
    await dialog.showErrorBox("OpenClaw Control Failed", String(error?.message || error));
    await stopServer().catch(() => {});
    app.exit(1);
  });
