# Chekinana Cloudflare Pages Static Assets

This directory is the Cloudflare Pages static source for public, versioned Chekinana assets.

## Current Asset Contract

Lianliankan v1 assets are served from:

```text
https://chekinana.top/assets/lianliankan/v1/manifest.json
https://chekinana.top/assets/lianliankan/v1/images/*.png
https://chekinana.top/assets/lianliankan/v1/audio/muguang.m4a
```

The manifest is the Frontend contract. It includes:

- `version`: currently `v1`
- `category`: currently `lianliankan`
- `baseUrl`: the absolute public URL prefix
- `images`: 14 tile image entries with `id`, `file`, `path`, `url`, `bytes`, and `sha256`
- `audio.victory`: the remote victory audio entry with `file`, `path`, `url`, `bytes`, `sha256`, and `contentType`

The image ids match the existing lianliankan board tile ids `1` through `14`.

## Layout

```text
cloudflare-pages/
  _headers
  assets/
    lianliankan/
      v1/
        manifest.json
        images/
          pattern1r.png
          ...
          pattern14w.png
        audio/
          muguang.m4a
```

## Deploy With Cloudflare Pages

Use Cloudflare Pages static hosting for this directory. Do not enable R2 for this task.

Dashboard setup:

1. Open Cloudflare Dashboard -> Workers & Pages -> Create application -> Pages.
2. Connect the repository that contains this directory.
3. Set the Pages project root directory to `cloudflare-pages`.
4. Leave the build command empty.
5. Set the build output directory to `.` so Pages serves the contents of `cloudflare-pages`.
6. Add the custom domain `chekinana.top` to this Pages project.
7. Keep the existing API Worker route `api.chekinana.top/*` unchanged.

DNS/custom-domain requirements:

- `chekinana.top` must resolve to Cloudflare Pages-managed public addresses after the Pages custom domain is active.
- Do not leave root-domain placeholder DNS records pointing at non-public ranges such as `198.18.0.0/15`.
- Keep `api.chekinana.top/*` on the existing `chekinana-runpod-proxy` Worker route. The Pages project should serve only the root/static asset host.

Direct Upload alternative:

```powershell
npx wrangler pages deploy cloudflare-pages --project-name chekinana-assets
```

After the first deployment, add or confirm the Pages custom domain:

```text
chekinana.top
```

## Local Verification

Run from the repository root:

```powershell
python scripts\check_lianliankan_assets.py
python scripts\check_lianliankan_public_assets.py
git diff --check
```

If the Pages deployment is available, verify public URLs:

```powershell
Invoke-WebRequest https://chekinana.top/assets/lianliankan/v1/manifest.json
Invoke-WebRequest https://chekinana.top/assets/lianliankan/v1/images/pattern1r.png
Invoke-WebRequest https://chekinana.top/assets/lianliankan/v1/audio/muguang.m4a
```

Expected content types:

- `manifest.json`: `application/json` or a JSON-compatible content type
- `*.png`: `image/png`
- `muguang.m4a`: `audio/mp4` or another audio-compatible M4A content type
