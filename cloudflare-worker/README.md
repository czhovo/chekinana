# chekinana Cloudflare Worker

This Worker provides a fixed WeChat-compatible API domain:

```text
https://api.chekinana.top
```

The mini program sends the current RunPod Pod ID in `X-Cheki-Token`. The Worker
forwards the request to:

```text
https://<pod-id>-8080.proxy.runpod.net
```

## Deploy

```powershell
cd cloudflare-worker
npx wrangler login
npx wrangler deploy
```

After deployment, add `https://api.chekinana.top` to the WeChat Mini Program
valid domains for `request`, `uploadFile`, and `downloadFile`.
