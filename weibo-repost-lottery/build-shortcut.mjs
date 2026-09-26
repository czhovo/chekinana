import { execFileSync } from "node:child_process";
import { chmodSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { randomUUID } from "node:crypto";

const projectDirectory = fileURLToPath(new URL(".", import.meta.url));
const javascriptPath = join(projectDirectory, "shortcut.js");
const outputPath = join(projectDirectory, "微博抽奖工具v4.shortcut");
const temporaryDirectory = mkdtempSync(join(tmpdir(), "weibo-shortcut-"));
const sourcePath = join(temporaryDirectory, "unsigned.shortcut");

const escapeXml = (value) => value
  .replaceAll("&", "&amp;")
  .replaceAll("<", "&lt;")
  .replaceAll(">", "&gt;");

const javascript = readFileSync(javascriptPath, "utf8").trim();
const actionIdentifier = randomUUID().toUpperCase();
const plist = `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>WFQuickActionSurfaces</key>
  <array/>
  <key>WFWorkflowActions</key>
  <array>
    <dict>
      <key>WFWorkflowActionIdentifier</key>
      <string>is.workflow.actions.runjavascriptonwebpage</string>
      <key>WFWorkflowActionParameters</key>
      <dict>
        <key>WFInput</key>
        <dict>
          <key>Value</key>
          <dict>
            <key>Type</key>
            <string>ExtensionInput</string>
          </dict>
          <key>WFSerializationType</key>
          <string>WFTextTokenAttachment</string>
        </dict>
        <key>UUID</key>
        <string>${actionIdentifier}</string>
        <key>WFJavaScript</key>
        <string>${escapeXml(javascript)}</string>
      </dict>
    </dict>
  </array>
  <key>WFWorkflowClientRelease</key>
  <string>4.0</string>
  <key>WFWorkflowClientVersion</key>
  <string>4045.0.3</string>
  <key>WFWorkflowHasOutputFallback</key>
  <false/>
  <key>WFWorkflowHasShortcutInputVariables</key>
  <true/>
  <key>WFWorkflowIcon</key>
  <dict>
    <key>WFWorkflowIconGlyphNumber</key>
    <integer>59721</integer>
    <key>WFWorkflowIconStartColor</key>
    <integer>4292315391</integer>
  </dict>
  <key>WFWorkflowImportQuestions</key>
  <array/>
  <key>WFWorkflowInputContentItemClasses</key>
  <array>
    <string>WFSafariWebPageContentItem</string>
    <string>WFURLContentItem</string>
    <string>WFArticleContentItem</string>
    <string>WFStringContentItem</string>
  </array>
  <key>WFWorkflowMinimumClientVersion</key>
  <integer>900</integer>
  <key>WFWorkflowMinimumClientVersionString</key>
  <string>900</string>
  <key>WFWorkflowName</key>
  <string>微博抽奖工具v4</string>
  <key>WFWorkflowOutputContentItemClasses</key>
  <array>
    <string>WFDictionaryContentItem</string>
  </array>
  <key>WFWorkflowTypes</key>
  <array>
    <string>ActionExtension</string>
    <string>WFWorkflowTypeShowInSearch</string>
  </array>
</dict>
</plist>
`;

try {
  writeFileSync(sourcePath, plist, "utf8");
  execFileSync("plutil", ["-convert", "binary1", sourcePath]);
  rmSync(outputPath, { force: true });
  execFileSync("shortcuts", [
    "sign",
    "--mode",
    "anyone",
    "--input",
    sourcePath,
    "--output",
    outputPath,
  ], { stdio: "inherit" });
  chmodSync(outputPath, 0o644);
  process.stdout.write(`${outputPath}\n`);
} finally {
  rmSync(temporaryDirectory, { recursive: true, force: true });
}
