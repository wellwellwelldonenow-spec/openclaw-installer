import path from "node:path";
import { notarize } from "@electron/notarize";

export default async function notarizeApp(context) {
  const { electronPlatformName, appOutDir, packager } = context;
  if (electronPlatformName !== "darwin") {
    return;
  }

  const appleId = process.env.APPLE_ID;
  const appleAppSpecificPassword = process.env.APPLE_APP_SPECIFIC_PASSWORD;
  const appleTeamId = process.env.APPLE_TEAM_ID;

  if (!appleId || !appleAppSpecificPassword || !appleTeamId) {
    console.log("Skipping macOS notarization because APPLE_ID / APPLE_APP_SPECIFIC_PASSWORD / APPLE_TEAM_ID are not fully configured.");
    return;
  }

  const appName = packager.appInfo.productFilename;
  const appPath = path.join(appOutDir, `${appName}.app`);
  console.log(`Submitting ${appPath} for notarization`);

  await notarize({
    appPath,
    appleId,
    appleIdPassword: appleAppSpecificPassword,
    teamId: appleTeamId,
  });

  console.log(`Notarization complete for ${appName}.app`);
}
