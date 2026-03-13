import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";
import pngToIco from "png-to-ico";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const rootDir = path.resolve(__dirname, "..");
const assetsDir = path.join(rootDir, "app", "assets");
const sourceSvg = path.join(assetsDir, "icon-source.svg");
const pngPath = path.join(assetsDir, "icon.png");
const icoPath = path.join(assetsDir, "icon.ico");
const iconsetDir = path.join(assetsDir, "icon.iconset");
const icnsPath = path.join(assetsDir, "icon.icns");

function run(command, args) {
  return new Promise((resolve, reject) => {
    const child = spawn(command, args, { stdio: "inherit" });
    child.on("error", reject);
    child.on("close", (code) => {
      if (code === 0) {
        resolve();
        return;
      }
      reject(new Error(`${command} exited with code ${code}`));
    });
  });
}

async function ensureDir(dir) {
  await fs.mkdir(dir, { recursive: true });
}

async function generatePng() {
  await run("qlmanage", ["-t", "-s", "1024", "-o", assetsDir, sourceSvg]);
  const quicklookPng = path.join(assetsDir, "icon-source.svg.png");
  await fs.rename(quicklookPng, pngPath);
}

async function generateIcns() {
  await fs.rm(iconsetDir, { recursive: true, force: true });
  await ensureDir(iconsetDir);
  const sizes = [16, 32, 64, 128, 256, 512];
  for (const size of sizes) {
    await run("sips", ["-z", String(size), String(size), pngPath, "--out", path.join(iconsetDir, `icon_${size}x${size}.png`)]);
    await run("sips", ["-z", String(size * 2), String(size * 2), pngPath, "--out", path.join(iconsetDir, `icon_${size}x${size}@2x.png`)]);
  }
  await run("iconutil", ["-c", "icns", iconsetDir, "-o", icnsPath]);
}

async function generateIco() {
  const tempFiles = [];
  const buffers = await Promise.all(
    [16, 24, 32, 48, 64, 128, 256].map(async (size) => {
      const filePath = path.join(assetsDir, `icon-${size}.png`);
      tempFiles.push(filePath);
      await run("sips", ["-z", String(size), String(size), pngPath, "--out", filePath]);
      return fs.readFile(filePath);
    }),
  );
  const icoBuffer = await pngToIco(buffers);
  await fs.writeFile(icoPath, icoBuffer);
  await Promise.all(tempFiles.map((filePath) => fs.rm(filePath, { force: true })));
}

async function main() {
  await generatePng();
  await generateIcns();
  await generateIco();
  await fs.rm(iconsetDir, { recursive: true, force: true });
  console.log("Generated icon.png, icon.icns, icon.ico");
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
