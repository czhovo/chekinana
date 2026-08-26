# Idol Enrichment Worker

This directory is the version-controlled source for the production
`idol-enrichment-api` Worker at `idol.chekinana.top`.

## API addition

`GET /api/search/idol` keeps its existing query, ranking, pagination, CORS, and
item fields. Each returned item additionally contains:

```json
{
  "patternIds": ["Aoyi_XII_P1"]
}
```

The array is always present, is ordered by prototype index, and is empty when
the catalogue item has no mapped prototype. Other Idol API routes keep their
existing response shapes.

## Public pattern-recognition assets

The Worker preserves the already published immutable v1 root resources byte for
byte:

```text
https://idol.chekinana.top/assets/pattern-recognition/v1/manifest.json
https://idol.chekinana.top/assets/pattern-recognition/v1/prototypes.json
https://idol.chekinana.top/assets/pattern-recognition/v1/idol-pattern-map.json
```

The current 2232-record catalogue revision is published separately:

```text
https://idol.chekinana.top/assets/pattern-recognition/v1/catalogue-b462a208c0d75264/manifest.json
https://idol.chekinana.top/assets/pattern-recognition/v1/catalogue-b462a208c0d75264/idol-pattern-map.json
```

All five URLs are served with a one-year immutable cache policy. The build
generator verifies the three legacy root SHA-256 values and never rewrites
them. It writes only the dedicated catalogue revision, the generated Worker
module, and `public/idols.json`.

`prototypes.json` is the original `pattern_prototypes_ge30.json` from the
`pattern-6541-v1` encoder release. The source-ID mapping is generated from
`data/catalogue-pattern-anchors.json` and the checked-in production catalogue
snapshot. Exact Weibo identity or exact normalized Idol name plus group expands
one curated anchor to duplicate catalogue records. The intentionally unmapped
prototype remains in the bank and is listed by the manifest.

The iOS-facing manifest contract is:

```json
{
  "version": "pattern-6541-v1",
  "embeddingDimension": 256,
  "patternCount": 95,
  "encoderCheckpointSHA256": "fe5bcb95f15836ab8d664398ee7acede0fb700ce3ac85ffa0d60adf356a2fb01",
  "prototypesUrl": "https://idol.chekinana.top/assets/pattern-recognition/v1/prototypes.json",
  "idolPatternMapUrl": "https://idol.chekinana.top/assets/pattern-recognition/v1/catalogue-b462a208c0d75264/idol-pattern-map.json"
}
```

The mapping contract is:

```json
{
  "format": "idol_pattern_map_v1",
  "version": "pattern-6541-v1",
  "idolPatternIDs": {
    "sourceId": ["patternId"]
  }
}
```

Additional metadata fields are informational and do not change those required
fields.

## Build and test

```sh
npm ci
npm run build:assets
npm run check:assets
npm test
npm run build:worker
```

`build:worker` is a dry run only. Its Wrangler config deliberately names a
non-production bundle target and has no production route.

## Production deployment contract

The current production Worker has an existing `ASSETS` binding containing
`idols.json` and avatars. Do not use `wrangler deploy` against
`idol-enrichment-api`: a normal upload can replace Worker metadata or asset
configuration.

The `public` directory retains the exact source bytes for generated
`public/idols.json` and `public/avatars/idol_002369.jpg`, but it is only a
partial overlay and must never be deployed by itself. Production uses a complete
ASSETS snapshot containing `idols.json`, every existing avatar, and the miya
avatar. The Worker keeps catalogue JSON embedded only for search and detail API
logic; `/idols.json` and all `/avatars/*` paths fall through to `env.ASSETS`.

`data/production-static-assets-config.json` records the production routing
contract. Static assets remain asset-first (`run_worker_first = false`) with the
existing `html_handling = "auto-trailing-slash"` and
`not_found_handling = "none"` values.

After backing up current content, settings, and the active deployment/version,
reconstruct and verify the complete production ASSETS snapshot. Start an
official Workers Assets upload session with the full manifest, upload only the
hashes Cloudflare requests, and use its completion JWT in the Workers Script
Upload API together with the current bindings and compatibility settings:

```text
PUT /accounts/{account_id}/workers/scripts/idol-enrichment-api
```

The multipart upload must use the bundled module as `index.js`, declare it as
`main_module`, preserve the existing `ASSETS` binding, attach the completion
JWT, and preserve the checked-in asset routing config. Do not use the partial
`public` directory as an assets upload. A content-only update is insufficient
because it cannot replace the old static `idols.json` bytes.

After upload, compare routes, bindings, compatibility settings, and ASSETS
presence with the backup, then verify all five pattern-recognition URLs,
`/api/search/idol`, `/idols.json`, the miya avatar, and at least two existing
avatar URLs. Never place the API token or account ID in tracked files or command
output.
