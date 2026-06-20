const AUTH_STORAGE_KEY = "cheki_auth_token";
const SCANNER_AUTH_PASSED_KEY = "cheki_scanner_auth_passed";
const API_GATEWAY_BASE_URL = "https://api.chekinana.top";
const LOCAL_PREVIEW_TOKEN = "chekinana-preview";

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
  return normalizedPodId && normalizedPodId !== LOCAL_PREVIEW_TOKEN ? API_GATEWAY_BASE_URL : "";
}

function isLocalPreviewToken(value) {
  return normalizePodId(value) === LOCAL_PREVIEW_TOKEN;
}

module.exports = {
  AUTH_STORAGE_KEY,
  SCANNER_AUTH_PASSED_KEY,
  API_GATEWAY_BASE_URL,
  LOCAL_PREVIEW_TOKEN,
  normalizePodId,
  getApiBaseUrl,
  isLocalPreviewToken
};
