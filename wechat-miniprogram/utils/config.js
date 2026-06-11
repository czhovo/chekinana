const API_BASE_URL = "https://f8inzam03uy2c4-8080.proxy.runpod.net";
const AUTH_STORAGE_KEY = "cheki_auth_token";
const API_BASE_URL_STORAGE_KEY = "cheki_api_base_url";

function normalizeApiBaseUrl(url) {
  return (url || "").trim().replace(/\/+$/, "");
}

function getApiBaseUrl() {
  const stored = wx.getStorageSync(API_BASE_URL_STORAGE_KEY);
  return normalizeApiBaseUrl(stored || API_BASE_URL);
}

function setApiBaseUrl(url) {
  const normalized = normalizeApiBaseUrl(url);
  if (normalized) {
    wx.setStorageSync(API_BASE_URL_STORAGE_KEY, normalized);
  }
  return normalized;
}

module.exports = {
  API_BASE_URL,
  AUTH_STORAGE_KEY,
  API_BASE_URL_STORAGE_KEY,
  getApiBaseUrl,
  setApiBaseUrl
};
