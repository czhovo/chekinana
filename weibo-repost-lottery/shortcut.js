(async () => {
  const finishShortcut = (value) => {
    if (typeof completion === "function") {
      completion(value);
    }
  };

  const currentHost = location.hostname.toLowerCase();

  document.getElementById("__weibo_repost_lottery__")?.remove();

  const host = document.createElement("div");
  host.id = "__weibo_repost_lottery__";
  host.style.cssText = "position:fixed;inset:0;z-index:2147483647;";
  document.documentElement.appendChild(host);

  const root = host.attachShadow({ mode: "open" });
  root.innerHTML = `
    <style>
      *{box-sizing:border-box}
      button,input{font:inherit}
      .backdrop{position:absolute;inset:0;display:grid;align-items:end;padding:12px;padding-bottom:max(12px,env(safe-area-inset-bottom));background:rgba(0,0,0,.48);backdrop-filter:blur(8px);font-family:-apple-system,BlinkMacSystemFont,"PingFang SC",sans-serif;color:#1d1d1f}
      .panel{width:min(680px,100%);max-height:calc(100dvh - 24px);margin:0 auto;overflow:auto;overscroll-behavior:contain;border-radius:22px;background:#fff;box-shadow:0 24px 80px rgba(0,0,0,.32)}
      .top{position:sticky;top:0;z-index:1;padding:18px;border-bottom:1px solid #e5e5e5;background:rgba(255,255,255,.96);backdrop-filter:blur(14px)}
      .title{font-size:18px;font-weight:800;letter-spacing:-.02em}
      .body{display:grid;gap:16px;padding:18px}
      .input{width:100%;height:48px;padding:0 13px;border:1px solid #c7c7cc;border-radius:12px;outline:0;color:#1d1d1f;background:#fff;font-size:16px}
      .input:focus{border-color:#1d1d1f;box-shadow:0 0 0 3px rgba(29,29,31,.12)}
      .row{display:grid;grid-template-columns:1fr 1fr;gap:10px}
      .primary{height:48px;border:0;border-radius:12px;color:#fff;background:#1d1d1f;font-weight:800;cursor:pointer}
      .primary:disabled{opacity:.52;cursor:not-allowed}
      .error{display:none;margin:0;padding:12px 13px;border:1px solid #d2d2d7;border-radius:12px;color:#1d1d1f;background:#f5f5f7;font-size:13px;line-height:1.55}
      .error.show{display:block}
      .status{display:none;padding:14px;border:1px solid #d2d2d7;border-radius:13px;background:#f5f5f7}
      .status.show{display:block}
      .status-head{display:flex;justify-content:space-between;gap:12px;margin-bottom:10px;font-size:12px;font-weight:800}
      .track{height:9px;overflow:hidden;border-radius:999px;background:#d2d2d7}
      .bar{width:0;height:100%;border-radius:inherit;background:#1d1d1f;transition:width .16s ease}
      .meta{margin-top:9px;color:#6e6e73;font-size:12px;line-height:1.45}
      .result{display:none;gap:10px}
      .result.show{display:grid}
      .result-head{display:flex;align-items:center;justify-content:space-between;gap:10px}
      .result-head strong{font-size:13px;line-height:1.45}
      .secondary{min-height:38px;padding:0 12px;border:1px solid #c7c7cc;border-radius:10px;color:#1d1d1f;background:#fff;font-size:12px;font-weight:800;cursor:pointer}
      .output{width:100%;min-height:108px;padding:14px;border:1px dashed #c7c7cc;border-radius:13px;color:#1d1d1f;background:#fff;font-size:15px;font-weight:700;line-height:1.75;text-align:left;word-break:break-all;cursor:pointer}
      .exclusions{display:grid;gap:10px}
      .exclusion{display:grid;gap:6px;padding:12px 13px;border:1px solid #d2d2d7;border-radius:12px;background:#f5f5f7}
      .exclusion strong{font-size:13px}
      .exclusion-users{color:#6e6e73;font-size:13px;line-height:1.65;word-break:break-all}
      .manage{justify-self:center;padding:0;border:0;color:#6e6e73;background:transparent;font-size:13px;cursor:pointer}
      .block-inline{display:none;min-height:0}
      .block-inline.show{display:grid}
      .block-terms{display:flex;max-height:160px;min-height:0;flex-wrap:wrap;align-content:flex-start;gap:8px;margin-top:12px;overflow:auto;overscroll-behavior:contain}
      .block-term{min-height:32px;padding:0 10px;border:1px solid #c7c7cc;border-radius:999px;color:#1d1d1f;background:#fff;cursor:pointer}
      @media(min-width:700px){.backdrop{align-items:center}.panel{max-height:calc(100dvh - 48px)}}
    </style>
    <div class="backdrop">
      <section class="panel" role="dialog" aria-modal="true" aria-labelledby="wrl-title">
        <header class="top">
          <div id="wrl-title" class="title">微博抽奖工具v4</div>
        </header>
        <div class="body">
          <div class="row">
            <input id="wrl-count" class="input" type="number" min="1" step="1" placeholder="请输入中奖人数" inputmode="numeric" aria-label="中奖人数" />
            <button id="wrl-start" class="primary" type="button">执行抽奖</button>
          </div>
          <p id="wrl-error" class="error" role="alert"></p>
          <div id="wrl-status" class="status" aria-live="polite">
            <div class="status-head"><span id="wrl-stage">准备获取</span><span id="wrl-pages">0 / 0 页</span></div>
            <div class="track"><div id="wrl-bar" class="bar"></div></div>
            <div id="wrl-meta" class="meta">尚未开始</div>
          </div>
          <div id="wrl-result" class="result">
            <div class="result-head"><strong id="wrl-summary">抽取结果</strong><button id="wrl-copy" class="secondary" type="button">复制</button></div>
            <button id="wrl-output" class="output" type="button" title="点击复制"></button>
            <div class="exclusions">
              <div class="exclusion"><strong id="wrl-lottery-account-title">抽奖号排除（0）</strong><div id="wrl-lottery-account-users" class="exclusion-users">无</div></div>
              <div class="exclusion"><strong id="wrl-blocked-term-title">屏蔽词排除（0）</strong><div id="wrl-blocked-term-users" class="exclusion-users">无</div></div>
            </div>
            <button id="wrl-redraw" class="secondary" type="button">从当前名单重新抽取</button>
          </div>
          <button id="wrl-manage-blocked" class="manage" type="button" aria-expanded="false" aria-controls="wrl-block-inline">管理屏蔽词</button>
          <div id="wrl-block-inline" class="block-inline">
            <input id="wrl-block-input" class="input" type="text" aria-label="屏蔽词" />
            <div id="wrl-block-terms" class="block-terms"></div>
          </div>
        </div>
      </section>
    </div>`;

  const $ = (selector) => root.querySelector(selector);
  const sleep = (milliseconds) => new Promise((resolve) => setTimeout(resolve, milliseconds));
  const MAX_PARALLEL_PAGES = 6;
  const BLOCKED_TERMS_KEY = "weibo-repost-lottery-blocked-terms";
  const state = {
    candidates: [],
    names: [],
    output: "",
    preflight: null,
    relationChecks: new Map(),
    profileChecks: new Map(),
    longTextChecks: new Map(),
    blockedTerms: [],
    resume: null,
  };
  const errorBox = $("#wrl-error");
  const statusBox = $("#wrl-status");
  const resultBox = $("#wrl-result");
  const startButton = $("#wrl-start");

  const showError = (message) => {
    errorBox.textContent = message;
    errorBox.classList.add("show");
  };

  const clearError = () => {
    errorBox.textContent = "";
    errorBox.classList.remove("show");
  };

  const termKey = (term) => term.toLowerCase();

  const loadBlockedTerms = () => {
    try {
      const parsed = JSON.parse(localStorage.getItem(BLOCKED_TERMS_KEY) || "[]");
      if (!Array.isArray(parsed)) return [];
      const seen = new Set();
      const terms = [];
      for (const value of parsed) {
        if (typeof value !== "string") continue;
        const term = value.trim();
        const key = termKey(term);
        if (!term || seen.has(key)) continue;
        seen.add(key);
        terms.push(term);
      }
      return terms;
    } catch {
      return [];
    }
  };

  const saveBlockedTerms = () => {
    try {
      localStorage.setItem(BLOCKED_TERMS_KEY, JSON.stringify(state.blockedTerms));
    } catch {
      // Storage may be unavailable in Safari private contexts.
    }
  };

  const renderBlockedTerms = () => {
    const container = $("#wrl-block-terms");
    container.replaceChildren();
    for (const term of state.blockedTerms) {
      const button = document.createElement("button");
      button.type = "button";
      button.className = "block-term";
      button.textContent = term;
      button.addEventListener("click", () => {
        const key = termKey(term);
        state.blockedTerms = state.blockedTerms.filter((value) => termKey(value) !== key);
        saveBlockedTerms();
        renderBlockedTerms();
      });
      container.appendChild(button);
    }
  };

  state.blockedTerms = loadBlockedTerms();
  renderBlockedTerms();

  const manageBlockedButton = $("#wrl-manage-blocked");
  const blockedInline = $("#wrl-block-inline");
  const blockedInput = $("#wrl-block-input");
  manageBlockedButton.addEventListener("click", () => {
    const opening = !blockedInline.classList.contains("show");
    blockedInline.classList.toggle("show", opening);
    manageBlockedButton.setAttribute("aria-expanded", String(opening));
    if (!opening) blockedInput.blur();
  });
  blockedInput.addEventListener("keydown", (event) => {
    if (event.key !== "Enter") return;
    event.preventDefault();
    const term = blockedInput.value.trim();
    if (!term || state.blockedTerms.some((value) => termKey(value) === termKey(term))) return;
    state.blockedTerms.push(term);
    blockedInput.value = "";
    saveBlockedTerms();
    renderBlockedTerms();
  });

  const parseCurrentPage = () => {
    const url = new URL(location.href);
    const hostname = url.hostname.toLowerCase();
    const parts = url.pathname.split("/").filter(Boolean);
    let ownerId = "";
    let statusId = "";

    if (hostname !== "m.weibo.cn") {
      throw new Error("请先在 Safari 打开 m.weibo.cn 的具体微博，再运行本工具。");
    }
    const marker = parts.findIndex((part) => part === "detail" || part === "status");
    if (marker >= 0) statusId = parts[marker + 1] || "";

    if (!/^[A-Za-z0-9]+$/.test(statusId)) {
      throw new Error("请先在 Safari 打开需要抽奖的具体微博，再运行本工具。");
    }
    return { ownerId, statusId };
  };

  const loginError = () => {
    const error = new Error("请先在 Safari 登录微博，再回到这条微博重新运行本工具。");
    error.noRetry = true;
    return error;
  };

  const looksLikeLoginError = (value) => /(?:登录|未登录|login|passport)/i.test(String(value));

  const looksLikeRateLimit = (value) => /(?:频繁|限流|访问次数|访问过多|请求过多|too\s*many|rate\s*limit)/i.test(String(value));

  const rateLimitError = (source) => {
    const error = new Error(`${source}触发限流，请稍后再试，已停止本次抽奖。`);
    error.noRetry = true;
    error.rateLimited = true;
    return error;
  };

  const normalizePage = (payload, page) => {
    if (payload?.ok !== 1 && payload?.ok !== true) {
      throw new Error(payload?.msg || payload?.message || "微博接口未返回成功状态");
    }

    const pageData = payload.data;
    if (!pageData || !Array.isArray(pageData.data)) {
      throw new Error(`第 ${page} 页缺少转发数组`);
    }
    return {
      items: pageData.data,
      maxPage: Number(pageData.max),
      total: Number(pageData.total_number),
    };
  };

  const requestPage = async ({ statusId }, page) => {
    const query = new URLSearchParams({ id: statusId, page: String(page) });
    const endpoint = "/api/statuses/repostTimeline?" + query;
    let lastError = "请求失败";

    for (let attempt = 1; attempt <= 4; attempt += 1) {
      try {
        const options = {
          credentials: "same-origin",
          headers: {
            Accept: "application/json, text/plain, */*",
            "X-Requested-With": "XMLHttpRequest",
          },
        };
        const response = await fetch(endpoint, options);
        const responseUrl = response.url || "";
        if (response.status === 401 || (response.redirected && /(?:passport|login|signin)/i.test(responseUrl))) {
          throw loginError();
        }
        if ([403, 418, 429, 432].includes(response.status)) {
          throw rateLimitError("转发列表接口（repostTimeline）");
        }
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        const contentType = response.headers?.get?.("content-type") || "";
        if (contentType && !contentType.toLowerCase().includes("json")) {
          throw new Error("微博接口返回了网页而不是转发数据");
        }
        const payload = await response.json();
        const payloadMessage = payload?.msg || payload?.message || "";
        if (looksLikeRateLimit(payloadMessage)) {
          throw rateLimitError("转发列表接口（repostTimeline）");
        }
        if (looksLikeLoginError(payloadMessage)) throw loginError();
        return normalizePage(payload, page);
      } catch (error) {
        if (error?.noRetry) throw error;
        lastError = error instanceof Error ? error.message : String(error);
        if (attempt < 4) await sleep(700 * 2 ** (attempt - 1));
      }
    }

    throw new Error(`第 ${page} 页请求失败：${lastError}。请确认当前微博登录有效。`);
  };

  const normalizeProfilePage = (payload) => {
    if (payload?.ok !== 1 && payload?.ok !== true) {
      throw new Error(payload?.msg || payload?.message || "微博主页接口未返回成功状态");
    }

    if (!payload.data || !Array.isArray(payload.data.cards)) {
      throw new Error("微博主页接口缺少卡片数组");
    }
    return payload.data.cards
      .filter((card) => card?.card_type === 9
        && card.mblog
        && typeof card.mblog === "object"
        && !Array.isArray(card.mblog))
      .map((card) => card.mblog);
  };

  const requestProfilePage = async (uid) => {
    const query = new URLSearchParams({ containerid: `107603${uid}`, page: "1", count: "10" });
    const endpoint = "/api/container/getIndex?" + query;
    let lastError = "请求失败";

    for (let attempt = 1; attempt <= 2; attempt += 1) {
      try {
        const response = await fetch(endpoint, {
          credentials: "same-origin",
          headers: {
            Accept: "application/json, text/plain, */*",
            "X-Requested-With": "XMLHttpRequest",
          },
        });
        const responseUrl = response.url || "";
        if (response.status === 401 || (response.redirected && /(?:passport|login|signin)/i.test(responseUrl))) {
          throw loginError();
        }
        if ([403, 418, 429, 432].includes(response.status)) {
          throw rateLimitError("用户微博列表接口（107603）");
        }
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        const contentType = response.headers?.get?.("content-type") || "";
        if (contentType && !contentType.toLowerCase().includes("json")) {
          throw new Error("微博主页接口返回了网页而不是微博数据");
        }
        const payload = await response.json();
        const payloadMessage = payload?.msg || payload?.message || "";
        if (looksLikeRateLimit(payloadMessage)) throw rateLimitError("用户微博列表接口（107603）");
        if (looksLikeLoginError(payloadMessage)) throw loginError();
        return normalizeProfilePage(payload);
      } catch (error) {
        if (error?.noRetry) throw error;
        lastError = error instanceof Error ? error.message : String(error);
        if (attempt < 2) await sleep(500);
      }
    }

    throw new Error(`用户主页请求失败：${lastError}`);
  };

  const normalizeUserRelation = (payload) => {
    if (payload?.ok !== 1 && payload?.ok !== true) {
      throw new Error(payload?.msg || payload?.message || "微博用户关系接口未返回成功状态");
    }
    const relation = payload?.data?.userInfo?.friendships_relation;
    if (!Number.isInteger(relation)) {
      throw new Error("微博用户关系接口缺少有效关系值");
    }
    return relation;
  };

  const requestUserRelation = async (uid) => {
    const query = new URLSearchParams({ containerid: `100505${uid}` });
    const endpoint = "/api/container/getIndex?" + query;
    let lastError = "请求失败";

    for (let attempt = 1; attempt <= 2; attempt += 1) {
      try {
        const response = await fetch(endpoint, {
          credentials: "same-origin",
          headers: {
            Accept: "application/json, text/plain, */*",
            "X-Requested-With": "XMLHttpRequest",
          },
        });
        const responseUrl = response.url || "";
        if (response.status === 401 || (response.redirected && /(?:passport|login|signin)/i.test(responseUrl))) {
          throw loginError();
        }
        if ([403, 418, 429, 432].includes(response.status)) {
          throw rateLimitError("用户关系接口（100505）");
        }
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        const contentType = response.headers?.get?.("content-type") || "";
        if (contentType && !contentType.toLowerCase().includes("json")) {
          throw new Error("微博用户关系接口返回了网页而不是用户数据");
        }
        const payload = await response.json();
        const payloadMessage = payload?.msg || payload?.message || "";
        if (looksLikeRateLimit(payloadMessage)) throw rateLimitError("用户关系接口（100505）");
        if (looksLikeLoginError(payloadMessage)) throw loginError();
        return normalizeUserRelation(payload);
      } catch (error) {
        if (error?.noRetry) throw error;
        lastError = error instanceof Error ? error.message : String(error);
        if (attempt < 2) await sleep(500);
      }
    }

    throw new Error(`用户关系请求失败：${lastError}`);
  };

  const visibleHtmlText = (value) => {
    const parsed = new DOMParser().parseFromString(String(value), "text/html");
    if (typeof parsed.body?.innerText === "string") return parsed.body.innerText;
    return parsed.body?.textContent || "";
  };

  const requestLongText = async (postId) => {
    if (currentHost !== "m.weibo.cn") {
      throw new Error("桌面端无法读取该条微博所需的完整长正文");
    }

    const endpoint = "/statuses/extend?" + new URLSearchParams({ id: postId });
    let lastError = "请求失败";

    for (let attempt = 1; attempt <= 2; attempt += 1) {
      try {
        const response = await fetch(endpoint, {
          credentials: "same-origin",
          headers: {
            Accept: "application/json, text/plain, */*",
            "X-Requested-With": "XMLHttpRequest",
          },
        });
        const responseUrl = response.url || "";
        if (response.status === 401 || (response.redirected && /(?:passport|login|signin)/i.test(responseUrl))) {
          throw loginError();
        }
        if ([403, 418, 429, 432].includes(response.status)) {
          throw rateLimitError("长微博正文接口（statuses/extend）");
        }
        if (!response.ok) throw new Error(`HTTP ${response.status}`);
        const contentType = response.headers?.get?.("content-type") || "";
        if (contentType && !contentType.toLowerCase().includes("json")) {
          throw new Error("微博长文本接口返回了网页而不是正文数据");
        }
        const payload = await response.json();
        const payloadMessage = payload?.msg || payload?.message || "";
        if (looksLikeRateLimit(payloadMessage)) throw rateLimitError("长微博正文接口（statuses/extend）");
        if (looksLikeLoginError(payloadMessage)) throw loginError();
        if (payload?.ok !== 1 && payload?.ok !== true) {
          throw new Error(payloadMessage || "微博长文本接口未返回成功状态");
        }
        if (typeof payload?.data?.longTextContent !== "string") {
          throw new Error("微博长文本接口缺少完整正文");
        }
        return visibleHtmlText(payload.data.longTextContent);
      } catch (error) {
        if (error?.noRetry) throw error;
        lastError = error instanceof Error ? error.message : String(error);
        if (attempt < 2) await sleep(500);
      }
    }

    throw new Error(`微博长文本请求失败：${lastError}`);
  };

  const checkLoginOnOpen = async () => {
    clearError();
    startButton.disabled = true;
    startButton.textContent = "检查登录…";

    try {
      const target = parseCurrentPage();
      const first = await requestPage(target, 1);
      state.preflight = { target, first };
    } catch (error) {
      state.preflight = null;
      showError(error instanceof Error ? error.message : String(error));
    } finally {
      startButton.disabled = false;
      startButton.textContent = "执行抽奖";
    }
  };

  const randomInt = (maximum) => {
    if (!Number.isSafeInteger(maximum) || maximum <= 0) throw new Error("随机范围无效");
    const ceiling = Math.floor(0x100000000 / maximum) * maximum;
    const bucket = new Uint32Array(1);
    do {
      crypto.getRandomValues(bucket);
    } while (bucket[0] >= ceiling);
    return bucket[0] % maximum;
  };

  const shuffledCandidates = () => {
    const pool = state.candidates.slice();
    for (let index = pool.length - 1; index > 0; index -= 1) {
      const swapIndex = randomInt(index + 1);
      [pool[index], pool[swapIndex]] = [pool[swapIndex], pool[index]];
    }
    return pool;
  };

  const textOf = (mblog) => {
    if (typeof mblog?.text_raw === "string") return mblog.text_raw;
    return typeof mblog?.text === "string" ? visibleHtmlText(mblog.text) : "";
  };

  const needsLongText = (mblog) => Boolean(mblog?.isLongText || mblog?.is_long_text);

  const completeTextOf = async (mblog) => {
    if (!needsLongText(mblog)) return textOf(mblog);
    const postId = String(mblog?.idstr || mblog?.id || mblog?.mid || mblog?.mblogid || "");
    if (!postId) throw new Error("需要完整长正文的微博缺少 ID");

    if (state.longTextChecks.has(postId)) {
      const cached = state.longTextChecks.get(postId);
      if (cached.ok) return cached.text;
      throw new Error(cached.message);
    }

    try {
      const text = await requestLongText(postId);
      state.longTextChecks.set(postId, { ok: true, text });
      return text;
    } catch (error) {
      if (error?.noRetry) throw error;
      const message = error instanceof Error ? error.message : String(error);
      state.longTextChecks.set(postId, { ok: false, message });
      throw error;
    }
  };

  const isRetweet = (mblog) => Boolean(
    mblog?.retweeted_status
    && typeof mblog.retweeted_status === "object"
    && !Array.isArray(mblog.retweeted_status)
  );

  const containsBlockedTerm = (value, blockedTerms) => {
    const text = value.toLowerCase();
    return blockedTerms.some((term) => text.includes(term.toLowerCase()));
  };

  const exclusionResult = (reason = null) => ({ passes: false, reason });

  const profilePasses = async (mblogs, blockedTerms) => {
    if (!mblogs.length) return exclusionResult("lottery-account");
    let originalCount = 0;
    let lotteryCount = 0;

    for (const mblog of mblogs) {
      if (!isRetweet(mblog)) {
        originalCount += 1;
        if (blockedTerms.length && containsBlockedTerm(await completeTextOf(mblog), blockedTerms)) {
          return exclusionResult("blocked-term");
        }
        continue;
      }
      const outerText = await completeTextOf(mblog);
      if (blockedTerms.length && containsBlockedTerm(outerText, blockedTerms)) {
        return exclusionResult("blocked-term");
      }
      const nestedText = await completeTextOf(mblog.retweeted_status);
      if (blockedTerms.length && containsBlockedTerm(nestedText, blockedTerms)) {
        return exclusionResult("blocked-term");
      }
      const combinedText = outerText + nestedText;
      if (combinedText.includes("抽")) lotteryCount += 1;
    }

    if (originalCount < 1 || lotteryCount / mblogs.length > 1 / 2) {
      return exclusionResult("lottery-account");
    }
    return { passes: true, reason: null };
  };

  const candidatePasses = async (candidate) => {
    const blockedTerms = state.blockedTerms.slice();
    if (!candidate.uid) return exclusionResult();
    let relationCheck = state.relationChecks.get(candidate.uid);

    if (!relationCheck) {
      try {
        const relation = await requestUserRelation(candidate.uid);
        relationCheck = { ok: true, blocked: relation === 4 };
        state.relationChecks.set(candidate.uid, relationCheck);
      } catch (error) {
        if (error?.rateLimited || error?.noRetry) throw error;
        state.relationChecks.set(candidate.uid, { ok: false });
        return exclusionResult();
      }
    }

    if (!relationCheck.ok || relationCheck.blocked) return exclusionResult();
    if (blockedTerms.length && containsBlockedTerm(candidate.name, blockedTerms)) {
      return exclusionResult("blocked-term");
    }
    let cached = state.profileChecks.get(candidate.uid);

    if (!cached) {
      try {
        cached = { ok: true, mblogs: await requestProfilePage(candidate.uid) };
        state.profileChecks.set(candidate.uid, cached);
      } catch (error) {
        if (error?.rateLimited || error?.noRetry) throw error;
        state.profileChecks.set(candidate.uid, { ok: false });
        return exclusionResult();
      }
    }

    if (!cached.ok) return exclusionResult();
    try {
      return await profilePasses(cached.mblogs, blockedTerms);
    } catch (error) {
      if (error?.rateLimited || error?.noRetry) throw error;
      return exclusionResult();
    }
  };

  const updateScreeningProgress = (checked, passed, total) => {
    statusBox.classList.add("show");
    $("#wrl-stage").textContent = "筛选候选人";
    $("#wrl-pages").textContent = `${checked} / ${total} 人`;
    $("#wrl-bar").style.width = `${total ? Math.min(100, (checked / total) * 100) : 0}%`;
    $("#wrl-meta").textContent = `已检查 ${checked} 人 · 已通过 ${passed} 人`;
  };

  const recordExclusion = (session, reason, candidate) => {
    const group = reason === "lottery-account"
      ? session.lotteryAccountExclusions
      : reason === "blocked-term"
        ? session.blockedTermExclusions
        : null;
    if (group && !group.some((item) => item.name === candidate.name)) group.push(candidate);
  };

  const renderExclusions = (session) => {
    const renderGroup = (titleSelector, usersSelector, label, candidates) => {
      $(titleSelector).textContent = `${label}（${candidates.length}）`;
      $(usersSelector).textContent = candidates.length
        ? candidates.map((candidate) => "@" + candidate.name).join(" ")
        : "无";
    };
    renderGroup(
      "#wrl-lottery-account-title",
      "#wrl-lottery-account-users",
      "抽奖号排除",
      session.lotteryAccountExclusions,
    );
    renderGroup(
      "#wrl-blocked-term-title",
      "#wrl-blocked-term-users",
      "屏蔽词排除",
      session.blockedTermExclusions,
    );
  };

  const draw = async (count, resumeSession = null) => {
    if (!Number.isInteger(count) || count < 1) throw new Error("抽取人数必须是正整数。");
    if (count > state.candidates.length) {
      throw new Error(`抽取人数不能超过去重用户名数量 ${state.candidates.length}。`);
    }

    const session = resumeSession || {
      pool: shuffledCandidates(),
      index: 0,
      winners: [],
      count,
      lotteryAccountExclusions: [],
      blockedTermExclusions: [],
    };
    state.resume = null;
    updateScreeningProgress(session.index, session.winners.length, session.pool.length);

    while (session.index < session.pool.length && session.winners.length < session.count) {
      const candidate = session.pool[session.index];
      try {
        const result = await candidatePasses(candidate);
        session.index += 1;
        if (result.passes) session.winners.push(candidate);
        else recordExclusion(session, result.reason, candidate);
        updateScreeningProgress(session.index, session.winners.length, session.pool.length);
      } catch (error) {
        if (error?.rateLimited) state.resume = session;
        else state.resume = null;
        throw error;
      }
    }

    if (session.winners.length < session.count) {
      state.resume = null;
      throw new Error(`符合条件的候选人不足：需要 ${session.count} 人，仅找到 ${session.winners.length} 人。`);
    }

    state.resume = null;
    $("#wrl-stage").textContent = "筛选完成";
    state.output = session.winners.map((candidate) => "@" + candidate.name).join(" ");
    $("#wrl-output").textContent = state.output;
    $("#wrl-summary").textContent = `从 ${state.candidates.length} 个去重用户名中抽取 ${session.count} 个`;
    renderExclusions(session);
    resultBox.classList.add("show");
  };

  const copyResult = async () => {
    if (!state.output) return;
    try {
      await navigator.clipboard.writeText(state.output);
    } catch {
      const textarea = document.createElement("textarea");
      textarea.value = state.output;
      document.body.appendChild(textarea);
      textarea.select();
      document.execCommand("copy");
      textarea.remove();
    }
    $("#wrl-copy").textContent = "已复制";
    setTimeout(() => {
      $("#wrl-copy").textContent = "复制";
    }, 1500);
  };

  $(".backdrop").addEventListener("click", (event) => {
    if (event.target === event.currentTarget) host.remove();
  });
  $("#wrl-copy").addEventListener("click", copyResult);
  $("#wrl-output").addEventListener("click", copyResult);
  $("#wrl-redraw").addEventListener("click", async () => {
    clearError();
    try {
      await draw(Number($("#wrl-count").value));
    } catch (error) {
      showError(error instanceof Error ? error.message : String(error));
    } finally {
      startButton.textContent = state.resume ? "尝试继续" : "执行抽奖";
    }
  });

  startButton.addEventListener("click", async () => {
    clearError();
    resultBox.classList.remove("show");
    startButton.disabled = true;
    startButton.textContent = state.resume ? "正在继续…" : "正在获取…";

    try {
      if (state.resume) {
        const resumeSession = state.resume;
        await draw(resumeSession.count, resumeSession);
        return;
      }

      const target = parseCurrentPage();
      const drawCount = Number($("#wrl-count").value);
      if (!Number.isInteger(drawCount) || drawCount < 1) {
        throw new Error("抽取人数必须是正整数。");
      }

      statusBox.classList.add("show");
      $("#wrl-stage").textContent = "读取分页信息";
      const first = state.preflight?.target.ownerId === target.ownerId
        && state.preflight?.target.statusId === target.statusId
        ? state.preflight.first
        : await requestPage(target, 1);
      state.preflight = null;
      if (!Number.isInteger(first.maxPage) || first.maxPage < 1) {
        throw new Error("接口没有返回有效的总页数。");
      }
      if (!first.items.length) {
        throw new Error("接口第 1 页为空，无法确认转发列表。");
      }

      const reposts = new Map();
      const consume = (items, page) => {
        for (const item of items) {
          const name = item?.user?.screen_name || item?.user?.name;
          if (typeof name !== "string" || !name.trim()) {
            throw new Error(`第 ${page} 页存在缺少用户名的可见转发，已停止以避免输出不完整名单。`);
          }
          const uid = String(item?.user?.idstr || item?.user?.id || item?.user?.uid || "");
          const id = String(item.idstr || item.id || item.mid || item.mblogid || "");
          const key = id || "json:" + JSON.stringify(item);
          reposts.set(key, { uid, name: name.trim() });
        }
      };

      let completedPages = 0;
      const consumePage = (pageData, page) => {
        if (!pageData.items.length) {
          throw new Error(`第 ${page}/${first.maxPage} 页提前为空，已停止以避免输出截断名单。`);
        }
        consume(pageData.items, page);
        completedPages += 1;
        $("#wrl-bar").style.width = `${Math.min(100, (completedPages / first.maxPage) * 100)}%`;
        $("#wrl-pages").textContent = `${completedPages} / ${first.maxPage} 页`;
        $("#wrl-stage").textContent = completedPages === first.maxPage ? "获取完成" : "逐页获取转发";
        const reportedTotal = Number.isFinite(first.total) && first.total >= 0 ? ` · 微博计数 ${first.total}` : "";
        $("#wrl-meta").textContent = `已取得 ${reposts.size} 条不同转发${reportedTotal}`;
      };

      consumePage(first, 1);

      let nextPage = 2;
      let fatalError = null;
      const worker = async () => {
        while (!fatalError) {
          const page = nextPage;
          if (page > first.maxPage) return;
          nextPage += 1;

          try {
            const pageData = await requestPage(target, page);
            if (fatalError) return;
            consumePage(pageData, page);
          } catch (error) {
            if (!fatalError) fatalError = error;
            return;
          }
        }
      };

      const workerCount = Math.min(MAX_PARALLEL_PAGES, first.maxPage - 1);
      await Promise.all(Array.from({ length: workerCount }, () => worker()));
      if (fatalError) {
        throw fatalError;
      }

      const candidatesByName = new Map();
      for (const candidate of reposts.values()) {
        if (!candidate.uid) continue;
        const existing = candidatesByName.get(candidate.name);
        if (!existing || (!existing.uid && candidate.uid)) {
          candidatesByName.set(candidate.name, candidate);
        }
      }
      state.candidates = [...candidatesByName.values()];
      state.names = state.candidates.map((candidate) => candidate.name);
      if (!state.candidates.length) throw new Error("接口没有返回可用用户名。");
      await draw(drawCount);
    } catch (error) {
      showError(error instanceof Error ? error.message : String(error));
    } finally {
      startButton.disabled = false;
      startButton.textContent = state.resume ? "尝试继续" : "执行抽奖";
    }
  });

  await checkLoginOnOpen();
  $("#wrl-count").focus();
  finishShortcut({ ok: true, message: "微博抽奖工具v4已打开" });
})();
