import fs from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";
import { spawn } from "node:child_process";

const __filename = fileURLToPath(import.meta.url);
const __dirname = path.dirname(__filename);
const rootDir = path.resolve(__dirname, "..");

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

async function main() {
  if (process.platform !== "darwin") {
    console.log("Skipping dmg generation outside macOS");
    return;
  }

  const pkg = JSON.parse(await fs.readFile(path.join(rootDir, "package.json"), "utf8"));
  const productName = pkg.build?.productName || pkg.name;
  const version = pkg.version;
  const distDir = path.join(rootDir, "dist");
  const entries = await fs.readdir(distDir, { withFileTypes: true });
  const appDir = entries.find((entry) => entry.isDirectory() && entry.name.startsWith("mac"));
  if (!appDir) {
    throw new Error("Could not find dist/mac* output folder");
  }

  const appPath = path.join(distDir, appDir.name, `${productName}.app`);
  const dmgRoot = path.join(distDir, "dmg-root");
  const dmgPath = path.join(distDir, `${productName}-${version}-${process.arch}-mac.dmg`);
  await fs.rm(dmgRoot, { recursive: true, force: true });
  await fs.mkdir(dmgRoot, { recursive: true });
  await fs.cp(appPath, path.join(dmgRoot, `${productName}.app`), { recursive: true });
  await fs.symlink("/Applications", path.join(dmgRoot, "Applications"));
  await fs.rm(dmgPath, { force: true });
  await run("hdiutil", [
    "create",
    "-volname",
    `${productName} ${version}`,
    "-srcfolder",
    dmgRoot,
    "-ov",
    "-format",
    "UDZO",
    dmgPath,
  ]);
  await fs.rm(dmgRoot, { recursive: true, force: true });
  console.log(`Generated ${dmgPath}`);
}

main().catch((error) => {
  console.error(error);
  process.exitCode = 1;
});
