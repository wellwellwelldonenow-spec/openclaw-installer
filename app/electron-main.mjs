import path from "node:path";
import { fileURLToPath } from "node:url";
import { app, BrowserWindow, dialog } from "electron";
import { startServer, stopServer } from "./server.mjs";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);

let mainWindow = null;
let controlServer = null;

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
    webPreferences: {
      contextIsolation: true,
      nodeIntegration: false,
      sandbox: true,
    },
  });

  mainWindow.on("closed", () => {
    mainWindow = null;
  });

  await mainWindow.loadURL(controlServer.url);
}

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
