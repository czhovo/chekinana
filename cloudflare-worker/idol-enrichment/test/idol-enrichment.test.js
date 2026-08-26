import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import { readFile } from "node:fs/promises";
import test from "node:test";
import worker from "../src/index.js";

const ASSET_ROOT = new URL("../assets/pattern-recognition/v1/", import.meta.url);
const REVISION_ROOT = new URL("catalogue-b462a208c0d75264/", ASSET_ROOT);
const EXPECTED_CHECKPOINT_SHA256 = "fe5bcb95f15836ab8d664398ee7acede0fb700ce3ac85ffa0d60adf356a2fb01";
const EXPECTED_PROTOTYPE_SHA256 = "907066c4e29b059d8a4530cfe4066b75e3a496733f705c268872b40569137ea1";
const EXPECTED_LEGACY_MANIFEST_SHA256 = "7c8077cd830c03ee41cc732dd5a8501e0a30bdaa7f61244665e315b7eb0fbe48";
const EXPECTED_LEGACY_MAPPING_SHA256 = "3477b4fdae0ed76a804de28e4bfe96cad145d0b793d105901b5cfee2d15ecf9d";
const EXPECTED_UNMAPPED = ["理砂Risa_極夜_P1"];
const EXPECTED_CATALOGUE_SHA256 = "b462a208c0d752648a10ce881c966d981553500f5da1c4532ddc59558d7e006c";
const MIYA_AVATAR_SHA256 = "899edf5e60175a245980e618331dd79700a36dddd9851f88d339f6feef99b759";

function sha256(value) {
  return createHash("sha256").update(value).digest("hex");
}

async function fetchPath(path, env = {}) {
  return worker.fetch(new Request(`https://idol.chekinana.top${path}`), env);
}

async function fetchJson(path, env = {}) {
  const response = await fetchPath(path, env);
  assert.equal(response.status, 200);
  assert.equal(response.headers.get("access-control-allow-origin"), "*");
  return response.json();
}

test("production static routing keeps the complete ASSETS collection asset-first", async () => {
  const config = JSON.parse(await readFile(
    new URL("../data/production-static-assets-config.json", import.meta.url),
    "utf8",
  ));
  assert.deepEqual(config, {
    assets: {
      config: {
        html_handling: "auto-trailing-slash",
        not_found_handling: "none",
        run_worker_first: false,
      },
    },
  });
});

test("legacy root bytes stay fixed while the catalogue revision exposes the current mapping", async () => {
  const [prototypeText, legacyMappingText, legacyManifestText, mappingText, manifestText] = await Promise.all([
    readFile(new URL("prototypes.json", ASSET_ROOT), "utf8"),
    readFile(new URL("idol-pattern-map.json", ASSET_ROOT), "utf8"),
    readFile(new URL("manifest.json", ASSET_ROOT), "utf8"),
    readFile(new URL("idol-pattern-map.json", REVISION_ROOT), "utf8"),
    readFile(new URL("manifest.json", REVISION_ROOT), "utf8"),
  ]);
  const prototypes = JSON.parse(prototypeText);
  const mapping = JSON.parse(mappingText);
  const manifest = JSON.parse(manifestText);

  assert.equal(sha256(prototypeText), EXPECTED_PROTOTYPE_SHA256);
  assert.equal(sha256(legacyManifestText), EXPECTED_LEGACY_MANIFEST_SHA256);
  assert.equal(sha256(legacyMappingText), EXPECTED_LEGACY_MAPPING_SHA256);
  assert.equal(prototypes.pattern_ids.length, 95);
  assert.equal(new Set(prototypes.pattern_ids).size, 95);
  assert.equal(prototypes.prototypes.length, 95);
  assert.equal(prototypes.embedding_dim, 256);
  assert.equal(prototypes.encoder_checkpoint_sha256, EXPECTED_CHECKPOINT_SHA256);
  prototypes.prototypes.forEach((prototype) => {
    assert.equal(prototype.length, 256);
    const norm = Math.sqrt(prototype.reduce((sum, value) => sum + value * value, 0));
    assert.ok(Math.abs(norm - 1) <= 1e-5);
  });

  const validPatternIds = new Set(prototypes.pattern_ids);
  assert.equal(mapping.format, "idol_pattern_map_v1");
  assert.equal(mapping.version, "pattern-6541-v1");
  const mappedPatternIds = Object.values(mapping.idolPatternIDs).flat();
  assert.ok(mappedPatternIds.every((patternId) => validPatternIds.has(patternId)));
  assert.deepEqual(mapping.unmappedPatternIds, EXPECTED_UNMAPPED);
  assert.ok(EXPECTED_UNMAPPED.every((patternId) => !mappedPatternIds.includes(patternId)));
  assert.equal(new Set(mappedPatternIds).size, 94);
  assert.equal(Object.keys(mapping.idolPatternIDs).length, 92);
  assert.equal(Object.hasOwn(mapping.idolPatternIDs, "idol_000924"), false);
  assert.equal(Object.hasOwn(mapping.idolPatternIDs, "idol_000926"), false);
  assert.equal(Object.hasOwn(mapping.idolPatternIDs, "idol_001357"), false);
  assert.equal(Object.hasOwn(mapping.idolPatternIDs, "idol_001624"), false);

  assert.equal(manifest.version, "pattern-6541-v1");
  assert.equal(manifest.embeddingDimension, 256);
  assert.equal(manifest.patternCount, 95);
  assert.equal(manifest.encoderCheckpointSHA256, EXPECTED_CHECKPOINT_SHA256);
  assert.equal(
    manifest.prototypesUrl,
    "https://idol.chekinana.top/assets/pattern-recognition/v1/prototypes.json",
  );
  assert.equal(
    manifest.idolPatternMapUrl,
    "https://idol.chekinana.top/assets/pattern-recognition/v1/catalogue-b462a208c0d75264/idol-pattern-map.json",
  );
  assert.equal(manifest.prototypeBank.sha256, EXPECTED_PROTOTYPE_SHA256);
  assert.equal(manifest.prototypeBank.patternCount, 95);
  assert.equal(manifest.prototypeBank.embeddingDimension, 256);
  assert.equal(manifest.idolPatternMap.sha256, sha256(mappingText));
  assert.equal(manifest.idolPatternMap.mappedSourceIdCount, 92);
  assert.equal(manifest.idolPatternMap.mappedPatternCount, 94);

  const servedPrototype = await fetchPath("/assets/pattern-recognition/v1/prototypes.json");
  const servedLegacyMapping = await fetchPath("/assets/pattern-recognition/v1/idol-pattern-map.json");
  const servedLegacyManifest = await fetchPath("/assets/pattern-recognition/v1/manifest.json");
  const servedMapping = await fetchPath(
    "/assets/pattern-recognition/v1/catalogue-b462a208c0d75264/idol-pattern-map.json",
  );
  const servedManifest = await fetchPath(
    "/assets/pattern-recognition/v1/catalogue-b462a208c0d75264/manifest.json",
  );
  assert.equal(await servedPrototype.text(), prototypeText);
  assert.equal(await servedLegacyMapping.text(), legacyMappingText);
  assert.equal(await servedLegacyManifest.text(), legacyManifestText);
  assert.equal(await servedMapping.text(), mappingText);
  assert.equal(await servedManifest.text(), manifestText);
  for (const response of [
    servedPrototype,
    servedLegacyMapping,
    servedLegacyManifest,
    servedMapping,
    servedManifest,
  ]) {
    assert.equal(response.headers.get("cache-control"), "public, max-age=31536000, immutable");
  }
});

test("idol search adds one stable pattern ID without changing existing response fields", async () => {
  const body = await fetchJson("/api/search/idol?q=Aoyi");
  assert.deepEqual(Object.keys(body), ["query", "count", "items"]);
  assert.equal(body.count, 1);
  assert.deepEqual(Object.keys(body.items[0]), [
    "id",
    "idolName",
    "groupName",
    "color",
    "birthday",
    "weiboUrl",
    "_sourceIndex",
    "verification",
    "bio",
    "avatarPath",
    "avatarUrl",
    "patternIds",
  ]);
  assert.equal(body.items[0].id, "idol_001325");
  assert.deepEqual(body.items[0].patternIds, ["Aoyi_XII_P1"]);
});

test("Mina and the two Yuu identities receive only their own ordered prototypes", async () => {
  const mina = await fetchJson("/api/search/idol?q=Mina");
  assert.deepEqual(mina.items.map((item) => [item.id, item.patternIds]), [
    ["idol_001209", []],
    ["idol_001326", ["Mina_XII_P1", "Mina_XII_P2"]],
  ]);

  const morningYuu = await fetchJson("/api/search/idol?q=悠悠Yuu");
  assert.deepEqual(morningYuu.items[0].patternIds, ["悠悠Yuu-午前4時_P1"]);

  const starWinkYuu = await fetchJson("/api/search/idol?q=羽悠Yuu");
  assert.deepEqual(starWinkYuu.items[0].patternIds, [
    "羽悠Yuu-StarWinK_P1",
    "羽悠Yuu-StarWinK_P2",
  ]);
});

test("lower-completeness StarRise and NightFell duplicates are deleted", async () => {
  const starRise = await fetchJson("/api/search/idol?q=小弥Mikari");
  assert.deepEqual(starRise.items.map((item) => [item.id, item.color, item.patternIds]), [
    ["idol_001066", "白色", ["小弥Mikari-StarRise_P1"]],
  ]);

  const midori = await fetchJson("/api/search/idol?q=泠Midori");
  assert.deepEqual(midori.items.map((item) => [item.id, item.color, item.patternIds]), [
    ["idol_001068", "水色", ["泠Midori-StarRise_P1"]],
  ]);

  const nightFell = await fetchJson("/api/search/idol?q=魚炳Sakaa");
  assert.deepEqual(nightFell.items.map((item) => [item.id, item.color, item.patternIds]), [
    ["idol_001728", "银色", ["魚炳Sakaa_極夜_P1"]],
  ]);

  const yura = await fetchJson("/api/search/idol?q=幽琪Yura");
  assert.deepEqual(yura.items.map((item) => [item.id, item.groupName, item.patternIds]), [
    ["idol_001995", "空白扑克BlankPoker", ["幽琪Yura_BlankPoker_P1"]],
  ]);

  for (const deletedId of ["idol_000924", "idol_000926", "idol_001357", "idol_001624"]) {
    const response = await fetchPath(`/api/idols/${deletedId}`);
    assert.equal(response.status, 404);
  }
});

test("renamed 金水 and new miya catalogue records expose their exact patterns", async () => {
  const jinshui = await fetchJson("/api/search/idol?q=金水");
  assert.deepEqual(jinshui.items.map((item) => [item.id, item.idolName, item.patternIds]), [
    ["idol_001456", "金水", ["金水金水-山海誓约_P1"]],
  ]);

  const miya = await fetchJson("/api/search/idol?q=miya");
  assert.deepEqual(miya.items.map((item) => [item.id, item.groupName, item.patternIds]), [
    ["idol_002369", "空色轨迹", ["照耀空色轨迹的miya_P1"]],
  ]);
  assert.equal(miya.items[0].avatarUrl, "https://idol.chekinana.top/avatars/idol_002369.jpg");

  const avatar = await readFile(new URL("../public/avatars/idol_002369.jpg", import.meta.url));
  assert.equal(sha256(avatar), MIYA_AVATAR_SHA256);

  const [sourceCatalogue, publicCatalogue] = await Promise.all([
    readFile(new URL("../data/idols.json", import.meta.url), "utf8"),
    readFile(new URL("../public/idols.json", import.meta.url), "utf8"),
  ]);
  assert.equal(publicCatalogue, sourceCatalogue);

  const requestedAssetUrls = [];
  const assetEnvironment = {
    ASSETS: {
      async fetch(request) {
        requestedAssetUrls.push(request.url);
        if (new URL(request.url).pathname === "/idols.json") {
          return new Response(sourceCatalogue, {
            headers: { "content-type": "application/json" },
          });
        }
        if (new URL(request.url).pathname === "/avatars/idol_002369.jpg") {
          return new Response(avatar, {
            headers: { "content-type": "image/jpeg" },
          });
        }
        return new Response(null, { status: 404 });
      },
    },
  };
  const catalogueResponse = await fetchPath("/idols.json", assetEnvironment);
  const catalogueBytes = Buffer.from(await catalogueResponse.arrayBuffer());
  assert.equal(sha256(catalogueBytes), EXPECTED_CATALOGUE_SHA256);
  assert.deepEqual(catalogueBytes, Buffer.from(sourceCatalogue, "utf8"));
  assert.match(catalogueResponse.headers.get("content-type"), /^application\/json/);

  const avatarResponse = await fetchPath("/avatars/idol_002369.jpg", assetEnvironment);
  const avatarBytes = Buffer.from(await avatarResponse.arrayBuffer());
  assert.equal(sha256(avatarBytes), MIYA_AVATAR_SHA256);
  assert.deepEqual(avatarBytes, avatar);
  assert.equal(avatarResponse.headers.get("content-type"), "image/jpeg");
  assert.deepEqual(requestedAssetUrls, [
    "https://idol.chekinana.top/idols.json",
    "https://idol.chekinana.top/avatars/idol_002369.jpg",
  ]);
});

test("unmapped idols return an empty patternIds array", async () => {
  const body = await fetchJson("/api/search/idol?q=四季");
  assert.equal(body.items[0].id, "idol_000001");
  assert.deepEqual(body.items[0].patternIds, []);
});

test("non-search API shapes and the existing ASSETS fallback remain unchanged", async () => {
  const byId = await fetchJson("/api/idols/idol_001325");
  assert.equal(Object.hasOwn(byId.item, "patternIds"), false);
  assert.equal(byId.item.avatarUrl, "https://idol.chekinana.top/avatars/idol_001325.jpg");

  const health = await fetchJson("/api/health");
  assert.deepEqual(health, { ok: true, records: 2232 });

  let fallbackRequest;
  const fallbackResponse = await fetchPath("/avatars/idol_001325.jpg", {
    ASSETS: {
      fetch(request) {
        fallbackRequest = request;
        return new Response("avatar", { status: 200, headers: { "content-type": "image/jpeg" } });
      },
    },
  });
  assert.equal(fallbackRequest.url, "https://idol.chekinana.top/avatars/idol_001325.jpg");
  assert.equal(await fallbackResponse.text(), "avatar");
});
