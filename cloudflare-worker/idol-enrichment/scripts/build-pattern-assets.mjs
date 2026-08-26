import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile, writeFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";

const ROOT = fileURLToPath(new URL("../", import.meta.url));
const PROTOTYPE_PATH = fileURLToPath(new URL("../assets/pattern-recognition/v1/prototypes.json", import.meta.url));
const LEGACY_MAPPING_PATH = fileURLToPath(new URL("../assets/pattern-recognition/v1/idol-pattern-map.json", import.meta.url));
const LEGACY_MANIFEST_PATH = fileURLToPath(new URL("../assets/pattern-recognition/v1/manifest.json", import.meta.url));
const REVISION_MAPPING_PATH = fileURLToPath(new URL("../assets/pattern-recognition/v1/catalogue-b462a208c0d75264/idol-pattern-map.json", import.meta.url));
const REVISION_MANIFEST_PATH = fileURLToPath(new URL("../assets/pattern-recognition/v1/catalogue-b462a208c0d75264/manifest.json", import.meta.url));
const GENERATED_MODULE_PATH = fileURLToPath(new URL("../src/generated-pattern-assets.js", import.meta.url));
const IDOLS_PATH = fileURLToPath(new URL("../data/idols.json", import.meta.url));
const PUBLIC_IDOLS_PATH = fileURLToPath(new URL("../public/idols.json", import.meta.url));
const MIYA_AVATAR_PATH = fileURLToPath(new URL("../public/avatars/idol_002369.jpg", import.meta.url));
const ANCHORS_PATH = fileURLToPath(new URL("../data/catalogue-pattern-anchors.json", import.meta.url));

const ENCODER_VERSION = "pattern-6541-v1";
const EMBEDDING_DIMENSION = 256;
const EXPECTED_PATTERN_COUNT = 95;
const EXPECTED_CHECKPOINT_SHA256 = "fe5bcb95f15836ab8d664398ee7acede0fb700ce3ac85ffa0d60adf356a2fb01";
const EXPECTED_PROTOTYPE_SHA256 = "907066c4e29b059d8a4530cfe4066b75e3a496733f705c268872b40569137ea1";
const EXPECTED_LEGACY_MANIFEST_SHA256 = "7c8077cd830c03ee41cc732dd5a8501e0a30bdaa7f61244665e315b7eb0fbe48";
const EXPECTED_LEGACY_MAPPING_SHA256 = "3477b4fdae0ed76a804de28e4bfe96cad145d0b793d105901b5cfee2d15ecf9d";
const EXPECTED_MIYA_AVATAR_SHA256 = "899edf5e60175a245980e618331dd79700a36dddd9851f88d339f6feef99b759";
const EXPECTED_UNMAPPED_PATTERN_IDS = [
  "理砂Risa_極夜_P1",
];
const BASE_URL = "https://idol.chekinana.top/assets/pattern-recognition/v1";
const REVISION_NAME = "catalogue-b462a208c0d75264";
const REVISION_BASE_URL = `${BASE_URL}/${REVISION_NAME}`;

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

function jsonText(value) {
  return `${JSON.stringify(value, null, 2)}\n`;
}

function normalizeIdentityText(value) {
  return String(value ?? "")
    .normalize("NFKC")
    .toLocaleLowerCase("zh-CN")
    .replace(/[^\p{L}\p{N}]+/gu, "");
}

function canonicalWeiboIdentity(value) {
  try {
    const url = new URL(String(value ?? ""));
    const hostname = url.hostname.toLowerCase().replace(/^(?:m|www)\./, "");
    if (hostname !== "weibo.com") return "";
    const pathname = decodeURIComponent(url.pathname)
      .normalize("NFKC")
      .toLocaleLowerCase("zh-CN")
      .replace(/\/+$/, "");
    return pathname ? `${hostname}${pathname}` : "";
  } catch {
    return "";
  }
}

function sameCatalogueIdentity(anchor, candidate) {
  const anchorWeibo = canonicalWeiboIdentity(anchor.weiboUrl);
  const candidateWeibo = canonicalWeiboIdentity(candidate.weiboUrl);
  const sameWeibo = Boolean(anchorWeibo) && anchorWeibo === candidateWeibo;
  const sameNameAndGroup =
    normalizeIdentityText(anchor.idolName) === normalizeIdentityText(candidate.idolName)
    && normalizeIdentityText(anchor.groupName) === normalizeIdentityText(candidate.groupName);
  return sameWeibo || sameNameAndGroup;
}

function validatePrototypeBank(prototypeBank, prototypeText) {
  assert.equal(sha256(prototypeText), EXPECTED_PROTOTYPE_SHA256, "prototype JSON SHA-256 changed");
  assert.equal(prototypeBank.format, "pattern_prototype_bank_v1");
  assert.equal(prototypeBank.embedding_dim, EMBEDDING_DIMENSION);
  assert.equal(prototypeBank.encoder_checkpoint_sha256, EXPECTED_CHECKPOINT_SHA256);
  assert.equal(prototypeBank.pattern_ids.length, EXPECTED_PATTERN_COUNT);
  assert.equal(new Set(prototypeBank.pattern_ids).size, EXPECTED_PATTERN_COUNT, "pattern IDs must be unique");

  for (const field of ["pattern_names", "image_counts", "source_group_counts", "prototypes"]) {
    assert.equal(prototypeBank[field].length, EXPECTED_PATTERN_COUNT, `${field} length mismatch`);
  }

  prototypeBank.prototypes.forEach((prototype, index) => {
    assert.equal(prototype.length, EMBEDDING_DIMENSION, `prototype ${index} dimension mismatch`);
    assert.ok(prototype.every(Number.isFinite), `prototype ${index} contains a non-finite value`);
    const norm = Math.sqrt(prototype.reduce((sum, value) => sum + value * value, 0));
    assert.ok(Math.abs(norm - 1) <= 1e-5, `prototype ${index} is not unit normalized: ${norm}`);
  });
}

function buildIdolPatternMap(idols, anchors, prototypeBank, catalogueText) {
  assert.equal(anchors.format, "chekinana-pattern-catalogue-anchors-v1");
  assert.equal(anchors.encoderVersion, ENCODER_VERSION);
  assert.equal(anchors.anchors.length, EXPECTED_PATTERN_COUNT);

  const idolsById = new Map(idols.map((idol) => [idol.id, idol]));
  assert.equal(idolsById.size, idols.length, "catalogue IDs must be unique");

  const patternIndex = new Map(prototypeBank.pattern_ids.map((patternId, index) => [patternId, index]));
  const idolPatternIDs = new Map();
  const unmappedPatternIds = [];

  anchors.anchors.forEach((anchor, index) => {
    assert.equal(anchor.index, index, `anchor index mismatch at ${index}`);
    assert.equal(anchor.patternId, prototypeBank.pattern_ids[index], `anchor pattern mismatch at ${index}`);

    if (anchor.catalogueId === null) {
      assert.equal(anchor.idolName, null);
      assert.equal(anchor.groupName, null);
      unmappedPatternIds.push(anchor.patternId);
      return;
    }

    const catalogueAnchor = idolsById.get(anchor.catalogueId);
    assert.ok(catalogueAnchor, `unknown catalogue anchor ${anchor.catalogueId}`);
    assert.equal(catalogueAnchor.idolName, anchor.idolName, `idol name changed for ${anchor.catalogueId}`);
    assert.equal(catalogueAnchor.groupName, anchor.groupName, `group name changed for ${anchor.catalogueId}`);

    const identityRecords = idols.filter((idol) => sameCatalogueIdentity(catalogueAnchor, idol));
    assert.ok(identityRecords.length > 0, `no catalogue identity records for ${anchor.patternId}`);

    for (const idol of identityRecords) {
      const patternIds = idolPatternIDs.get(idol.id) ?? new Set();
      patternIds.add(anchor.patternId);
      idolPatternIDs.set(idol.id, patternIds);
    }
  });

  assert.deepEqual(unmappedPatternIds, EXPECTED_UNMAPPED_PATTERN_IDS);

  const orderedMappings = [...idolPatternIDs.entries()]
    .sort(([left], [right]) => left.localeCompare(right, "en"))
    .map(([sourceId, patternIds]) => [
      sourceId,
      [...patternIds].sort((left, right) => patternIndex.get(left) - patternIndex.get(right)),
    ]);

  const mappedPatternIds = new Set(orderedMappings.flatMap(([, patternIds]) => patternIds));
  assert.equal(mappedPatternIds.size, EXPECTED_PATTERN_COUNT - EXPECTED_UNMAPPED_PATTERN_IDS.length);
  for (const patternId of EXPECTED_UNMAPPED_PATTERN_IDS) {
    assert.ok(!mappedPatternIds.has(patternId), `${patternId} must remain unmapped`);
  }

  return {
    format: "idol_pattern_map_v1",
    version: ENCODER_VERSION,
    catalogue: {
      url: "https://idol.chekinana.top/idols.json",
      recordCount: idols.length,
      snapshotSha256: sha256(catalogueText),
      idField: "id",
      clientSourceIdField: "sourceId",
    },
    prototypeBankUrl: `${BASE_URL}/prototypes.json`,
    idolPatternIDs: Object.fromEntries(orderedMappings),
    unmappedPatternIds,
  };
}

function buildManifest(prototypeBank, prototypeText, mapping, mappingText) {
  const mappedPatternIds = new Set(Object.values(mapping.idolPatternIDs).flat());
  return {
    format: "chekinana-pattern-recognition-manifest-v1",
    version: ENCODER_VERSION,
    embeddingDimension: EMBEDDING_DIMENSION,
    patternCount: prototypeBank.pattern_ids.length,
    encoderCheckpointSHA256: EXPECTED_CHECKPOINT_SHA256,
    prototypesUrl: `${BASE_URL}/prototypes.json`,
    idolPatternMapUrl: `${REVISION_BASE_URL}/idol-pattern-map.json`,
    baseUrl: REVISION_BASE_URL,
    encoder: {
      architecture: "DINOv2 ViT-S/14 dual-view metric encoder",
      embeddingDimension: EMBEDDING_DIMENSION,
      checkpointSha256: EXPECTED_CHECKPOINT_SHA256,
    },
    prototypeBank: {
      path: "/assets/pattern-recognition/v1/prototypes.json",
      url: `${BASE_URL}/prototypes.json`,
      sha256: sha256(prototypeText),
      format: prototypeBank.format,
      patternCount: prototypeBank.pattern_ids.length,
      embeddingDimension: prototypeBank.embedding_dim,
      similarity: prototypeBank.similarity,
      manifestFingerprintSha256: prototypeBank.manifest_fingerprint_sha256,
    },
    idolPatternMap: {
      path: `/assets/pattern-recognition/v1/${REVISION_NAME}/idol-pattern-map.json`,
      url: `${REVISION_BASE_URL}/idol-pattern-map.json`,
      sha256: sha256(mappingText),
      format: mapping.format,
      mappedSourceIdCount: Object.keys(mapping.idolPatternIDs).length,
      mappedPatternCount: mappedPatternIds.size,
      unmappedPatternIds: mapping.unmappedPatternIds,
    },
  };
}

function buildGeneratedModule(
  legacyManifestText,
  prototypeText,
  legacyMappingText,
  revisionManifestText,
  revisionMappingText,
  catalogueText,
) {
  return [
    "// Generated by scripts/build-pattern-assets.mjs. Do not edit by hand.",
    `export const LEGACY_MANIFEST_JSON = ${JSON.stringify(legacyManifestText)};`,
    `export const PROTOTYPES_JSON = ${JSON.stringify(prototypeText)};`,
    `export const LEGACY_IDOL_PATTERN_MAP_JSON = ${JSON.stringify(legacyMappingText)};`,
    `export const CURRENT_MANIFEST_JSON = ${JSON.stringify(revisionManifestText)};`,
    `export const CURRENT_IDOL_PATTERN_MAP_JSON = ${JSON.stringify(revisionMappingText)};`,
    `export const CURRENT_CATALOGUE_JSON = ${JSON.stringify(catalogueText)};`,
    "",
  ].join("\n");
}

async function writeOrCheck(path, expected, checkOnly) {
  if (!checkOnly) {
    await writeFile(path, expected, "utf8");
    return;
  }
  const actual = await readFile(path, "utf8");
  assert.equal(actual, expected, `${path.slice(ROOT.length)} is stale; run npm run build:assets`);
}

async function main() {
  const checkOnly = process.argv.includes("--check");
  const [prototypeText, legacyManifestText, legacyMappingText, catalogueText, anchorsText, miyaAvatar] = await Promise.all([
    readFile(PROTOTYPE_PATH, "utf8"),
    readFile(LEGACY_MANIFEST_PATH, "utf8"),
    readFile(LEGACY_MAPPING_PATH, "utf8"),
    readFile(IDOLS_PATH, "utf8"),
    readFile(ANCHORS_PATH, "utf8"),
    readFile(MIYA_AVATAR_PATH),
  ]);
  const prototypeBank = JSON.parse(prototypeText);
  const idols = JSON.parse(catalogueText);
  const anchors = JSON.parse(anchorsText);

  validatePrototypeBank(prototypeBank, prototypeText);
  assert.equal(sha256(legacyManifestText), EXPECTED_LEGACY_MANIFEST_SHA256, "legacy manifest bytes changed");
  assert.equal(sha256(legacyMappingText), EXPECTED_LEGACY_MAPPING_SHA256, "legacy mapping bytes changed");
  assert.equal(sha256(miyaAvatar), EXPECTED_MIYA_AVATAR_SHA256, "miya avatar bytes changed");
  JSON.parse(legacyManifestText);
  JSON.parse(legacyMappingText);
  const mapping = buildIdolPatternMap(idols, anchors, prototypeBank, catalogueText);
  const mappingText = jsonText(mapping);
  const manifest = buildManifest(prototypeBank, prototypeText, mapping, mappingText);
  const manifestText = jsonText(manifest);
  const generatedModule = buildGeneratedModule(
    legacyManifestText,
    prototypeText,
    legacyMappingText,
    manifestText,
    mappingText,
    catalogueText,
  );

  await Promise.all([
    writeOrCheck(REVISION_MAPPING_PATH, mappingText, checkOnly),
    writeOrCheck(REVISION_MANIFEST_PATH, manifestText, checkOnly),
    writeOrCheck(GENERATED_MODULE_PATH, generatedModule, checkOnly),
    writeOrCheck(PUBLIC_IDOLS_PATH, catalogueText, checkOnly),
  ]);

  process.stdout.write(
    `${checkOnly ? "Verified" : "Generated"} ${prototypeBank.pattern_ids.length} prototypes, `
      + `${Object.keys(mapping.idolPatternIDs).length} mapped catalogue IDs, `
      + `${mapping.unmappedPatternIds.length} unmapped prototypes.\n`,
  );
}

await main();
