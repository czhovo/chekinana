const AUTH_STORAGE_KEY = "cheki_auth_token";
const RUNPOD_HTTP_PORT = 8080;

function normalizePodId(value) {
  const raw = (value || "").trim();
  const match = raw.match(/^https?:\/\/([a-z0-9]+)-\d+\.proxy\.runpod\.net/i);
  if (match) return match[1];
  const host = raw.replace(/^https?:\/\//i, "").split(/[/?#:\s]/)[0];
  const hostMatch = host.match(/^([a-z0-9]+)-\d+\.proxy\.runpod\.net/i);
  if (hostMatch) return hostMatch[1];
  return host;
}

function getApiBaseUrl(podId) {
  const normalizedPodId = normalizePodId(podId || wx.getStorageSync(AUTH_STORAGE_KEY));
  return normalizedPodId ? `https://${normalizedPodId}-${RUNPOD_HTTP_PORT}.proxy.runpod.net` : "";
}

module.exports = {
  AUTH_STORAGE_KEY,
  RUNPOD_HTTP_PORT,
  normalizePodId,
  getApiBaseUrl
};
