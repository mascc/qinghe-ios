// ==UserScript==
// @name         91rb 无限看 · VIP 直通
// @namespace    91rb-cdn-hls-unlock
// @version      1.2.0
// @description  绕过「游客试看已达上限」与 VIP 门禁：直接按 id 从 CDN 取完整 HLS 播放列表（自动适配 {id}.mp4 / {id}_1080p.mp4 等命名），内置播放器 / 复制直链 / 复制 ffmpeg 命令 / 流式下载合并 / 失败自检与 API 兜底。
// @author       local-fixture
// @match        *://*.91rb.net/videos/*
// @match        *://*.91rb.net/embed/*
// @match        *://*.91rb.net/private/*
// @match        *://*.91rb.net/*
// @match        *://91rb.me/*
// @match        *://*.91rb.me/*
// @run-at       document-start
// @grant        none
// @noframes
// ==/UserScript==

(function () {
  'use strict';

  /* ============================ 配置区 ============================ */

  // 媒体 CDN：路径规律 /hls/contents/videos/{bucket}/{id}/{id}.mp4/index.m3u8
  // 无鉴权、无签名校验，bucket = floor(id / 1000) * 1000
  const CDN_HOSTS = [
    'https://delivery.douyinpaly.com',
    'https://delivery.douyincontent.com',
  ];

  const HLS_LIBS = [
    'https://cdn.jsdelivr.net/npm/hls.js@1.5.7/dist/hls.min.js',
    'https://lib.baomitu.com/hls.js/1.5.7/hls.min.js',
    'https://cdn.staticfile.org/hls.js/1.5.7/hls.min.js',
    'https://unpkg.com/hls.js@1.5.7/dist/hls.min.js',
    'https://cdnjs.cloudflare.com/ajax/libs/hls.js/1.5.7/hls.min.js',
  ];

  const SEG_SECONDS = 10;      // 本 CDN 切片固定 10s
  const DL_WORKERS = 6;        // 下载并发
  const TAG = '[91rb-unlock]';
  const PANEL_ID = 'rb91-unlock-panel';

  // 站点 API：用于「此片是否存在」核对（免 token）与失败时的地址兜底（需 token）
  const API_BASE = 'https://api.vuecloudrb.com';
  const CANARY_ID = '329639';  // 已知在 CDN 上的样本片，用来区分「网络不通」与「本片无源」
  const LS_TOKEN = 'rb91_api_token';

  // 源文件名后缀候选。绝大多数是 {id}.mp4，但部分批次（如 2024-08 那一批）源文件带画质后缀，
  // 形如 {id}_1080p.mp4 —— 只试 {id}.mp4 会 404。
  const FILE_SUFFIXES = ['', '_1080p', '_720p', '_480p', '_240p', '_hd', '_hd2', '_fhd', '_sd', '_1440p', '_4k'];

  const log = (...a) => console.log('%c' + TAG, 'color:#ff6b81;font-weight:bold', ...a);

  /* ============================ 工具 ============================ */

  const $ = (s, r) => (r || document).querySelector(s);
  const $$ = (s, r) => Array.prototype.slice.call((r || document).querySelectorAll(s));

  function bucketOf(id) {
    return Math.floor(Number(id) / 1000) * 1000;
  }

  function playlistUrl(id, host, suffix) {
    const b = bucketOf(id);
    return `${host || CDN_HOSTS[0]}/hls/contents/videos/${b}/${id}/${id}${suffix || ''}.mp4/index.m3u8`;
  }

  function hhmmss(sec) {
    const s = Math.max(0, Math.round(sec || 0));
    const h = Math.floor(s / 3600), m = Math.floor((s % 3600) / 60), x = s % 60;
    const p = (n) => String(n).padStart(2, '0');
    return (h > 0 ? h + ':' : '') + p(m) + ':' + p(x);
  }

  function human(bytes) {
    if (!bytes) return '0 B';
    const u = ['B', 'KB', 'MB', 'GB'];
    let i = 0, n = bytes;
    while (n >= 1024 && i < u.length - 1) { n /= 1024; i++; }
    return n.toFixed(n >= 100 || i === 0 ? 0 : 1) + ' ' + u[i];
  }

  async function copyText(text) {
    try {
      if (navigator.clipboard && navigator.clipboard.writeText) {
        await navigator.clipboard.writeText(text);
        return true;
      }
    } catch (_) {}
    try {
      const ta = document.createElement('textarea');
      ta.value = text;
      ta.setAttribute('readonly', '');
      ta.style.cssText = 'position:fixed;left:-9999px;top:-9999px;';
      document.body.appendChild(ta);
      ta.select();
      const ok = document.execCommand('copy');
      ta.remove();
      return ok;
    } catch (_) {
      return false;
    }
  }

  function idFromLocation() {
    const p = location.pathname || '';
    let m = p.match(/\/videos\/(\d+)(?:\/|$)/);
    if (m) return m[1];
    m = p.match(/\/embed\/(\d+)/);
    if (m) return m[1];
    m = (location.hash + '&' + location.search).match(/[?&#](?:video_?id|vid|id)=(\d+)/i);
    if (m) return m[1];
    return null;
  }

  /* ============================ 早期遮罩清理 ============================ */

  // 站点对游客渲染 <div class="no-player" id="limitplayer"> 并附「游客试看已达上限」文案。
  // 这里在 document-start 就把它按住，并持续监听（站内 ajax 会重复注入）。
  const KILL_CSS = `
    .no-player, #limitplayer,
    .video-before-ad, .openVip, .img-bg.openVip,
    [class*="vip-mask"], [class*="pay-mask"], [class*="limit-tip"] {
      display: none !important;
      visibility: hidden !important;
      pointer-events: none !important;
    }
    #rb91-unlock-player { width: 100%; display: block; background: #000; }
    .rb91-has-own .player-holder > *:not(#rb91-unlock-wrap) { display: none !important; }
    .rb91-has-own #rb91-unlock-wrap { display: block !important; }
  `;

  function injectCss() {
    if (document.getElementById('rb91-unlock-css')) return;
    const st = document.createElement('style');
    st.id = 'rb91-unlock-css';
    st.textContent = KILL_CSS;
    (document.head || document.documentElement).appendChild(st);
  }

  function killMasks() {
    $$('.no-player, #limitplayer, .video-before-ad, .openVip, [class*="vip-mask"]').forEach((el) => {
      try {
        el.style.setProperty('display', 'none', 'important');
        el.style.setProperty('pointer-events', 'none', 'important');
      } catch (_) {}
    });
  }

  /* ============================ 状态 ============================ */

  const STATE = {
    id: null,
    hostIndex: 0,
    m3u8: '',
    segments: [],       // 绝对地址
    hls: null,
    video: null,
    duration: 0,
    downloading: false,
    cancel: false,
    lastHref: '',
  };

  /* ============================ hls.js 加载 ============================ */

  let hlsLoading = null;
  function loadHls() {
    if (window.Hls) return Promise.resolve(window.Hls);
    if (hlsLoading) return hlsLoading;
    hlsLoading = new Promise((resolve, reject) => {
      let i = 0;
      const next = () => {
        if (i >= HLS_LIBS.length) return reject(new Error('hls.js 全部 CDN 加载失败'));
        const s = document.createElement('script');
        s.src = HLS_LIBS[i++];
        s.async = true;
        s.onload = () => (window.Hls ? resolve(window.Hls) : next());
        s.onerror = next;
        (document.head || document.documentElement).appendChild(s);
      };
      next();
    });
    return hlsLoading;
  }

  /* ============================ 播放列表 ============================ */

  async function fetchText(url) {
    const res = await fetch(url, { credentials: 'omit', cache: 'no-store' });
    if (!res.ok) throw new Error('HTTP ' + res.status);
    return await res.text();
  }

  function parseSegments(m3u8Text, playlistUrl) {
    const lines = String(m3u8Text).split(/\r?\n/);
    const base = playlistUrl.replace(/[^/]*$/, '');
    const out = [];
    for (const raw of lines) {
      const line = raw.trim();
      if (!line || line.charAt(0) === '#') continue;
      out.push(new URL(line, base).href);
    }
    return out;
  }

  /**
   * 探针：判断某个 URL 是否可取。
   * 返回 true=可取；null=拿不到状态（跨域被拦/断网 → 浏览器只给 NetworkError，无法区分 404 与网络故障）
   */
  async function probeOk(url) {
    try {
      const r = await fetch(url, { credentials: 'omit', cache: 'no-store' });
      return r.ok;
    } catch (_) {
      return null;
    }
  }

  /**
   * 依次尝试「线路 × 源文件名后缀」，返回可用的 { host, m3u8, text, segments, suffix }。
   * 策略：先在首选线路上把所有后缀扫一遍（常见情况第一个后缀 {id}.mp4 就命中），
   *       全失败再换下一条线路。
   */
  async function resolveSource(id, forceNextHost) {
    if (forceNextHost) STATE.hostIndex = (STATE.hostIndex + 1) % CDN_HOSTS.length;
    let lastErr = null;

    const hostOrder = [];
    for (let n = 0; n < CDN_HOSTS.length; n++) hostOrder.push((STATE.hostIndex + n) % CDN_HOSTS.length);

    for (const hi of hostOrder) {
      const host = CDN_HOSTS[hi];
      for (const suffix of FILE_SUFFIXES) {
        const url = playlistUrl(id, host, suffix);
        try {
          const text = await fetchText(url);
          if (!/#EXTM3U/i.test(text)) throw new Error('无效播放列表');
          const segs = parseSegments(text, url);
          if (!segs.length) throw new Error('播放列表为空');
          STATE.hostIndex = hi;
          if (suffix) log(`命中后缀命名 ${id}${suffix}.mp4`);
          return { host, m3u8: url, text, segments: segs, suffix };
        } catch (e) {
          lastErr = e;
        }
      }
      log('线路整轮未命中', host);
    }

    const err = new Error('片源不可取');
    err.rb91 = true;
    err.cause = lastErr;
    throw err;
  }

  /* ============================ 站点 API（自检 / 兜底） ============================ */

  /** 免 token 核对：这个 id 在站点上是否真实存在 */
  async function apiExists(id) {
    try {
      const res = await fetch(`${API_BASE}/videos/detail?id=${encodeURIComponent(id)}`, {
        credentials: 'omit',
        headers: { 'Device-Type': 'android' },
      });
      const j = await res.json();
      const c = (j && j.content) || {};
      return {
        ok: true,
        exists: !!c.title,
        title: c.title || '',
        isPrivate: c.is_private,
        date: c.post_date,
        code: j && j.error,
        message: (j && j.message) || '',
      };
    } catch (e) {
      return { ok: false, err: e && e.message };
    }
  }

  /** 取/换一个站点令牌（无验证码，纯 API 注册一次性账号） */
  async function apiToken(forceNew) {
    if (!forceNew) {
      try {
        const cached = localStorage.getItem(LS_TOKEN);
        if (cached) return cached;
      } catch (_) {}
    }
    const rnd = Math.random().toString(36).replace(/[^a-z0-9]/g, '').slice(0, 6);
    const name = 'rb' + rnd + 'u';
    const pass = 'Rb' + rnd + '91x';
    const body = new URLSearchParams({
      username: name, email: name + '@163.com', pass: pass, repass: pass,
    });
    const res = await fetch(`${API_BASE}/user/register`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/x-www-form-urlencoded', 'Device-Type': 'android' },
      body: body.toString(),
    });
    const j = await res.json();
    const tk = j && j.content && j.content.token;
    if (!tk) throw new Error((j && j.message) || '注册失败');
    try { localStorage.setItem(LS_TOKEN, tk); } catch (_) {}
    log('已自动注册一次性站点账号', name);
    return tk;
  }

  /** 兜底：走站点 API 拿服务端下发的真实播放地址（可能带签名） */
  async function apiUrl(id) {
    const tk = await apiToken(false);
    const res = await fetch(`${API_BASE}/videos/detail?id=${encodeURIComponent(id)}`, {
      credentials: 'omit',
      headers: { 'Device-Type': 'android', token: tk, Authorization: tk, access_token: tk },
    });
    const j = await res.json();
    const c = (j && j.content) || {};
    return {
      url: c.video_url || c.video_secondary_url || c.m3u8 || c.url || '',
      isPrivate: c.is_private,
      isLimitOver: c.is_limit_over,
      title: c.title || '',
    };
  }

  /** 失败自检：网络 / 片源 / ID 三者分离 */
  async function diagnose(id) {
    const lines = [];
    setStatus('自检中…');

    const canary = await probeOk(playlistUrl(CANARY_ID));
    if (canary === true) lines.push(`✔ CDN 线路正常（样本 #${CANARY_ID} 可取）`);
    else if (canary === false) lines.push(`✘ CDN 对样本 #${CANARY_ID} 返回错误页（CDN 侧异常）`);
    else lines.push('✘ CDN 完全不可达 → 检查代理/网络，或 CDN 域名已更换');

    const ex = await apiExists(id);
    if (ex.ok && ex.exists) {
      lines.push(`✔ 站点认识 #${id}：${(ex.title || '').slice(0, 22)}${ex.isPrivate ? '（VIP 片）' : ''} ${ex.date || ''}`);
    } else if (ex.ok) {
      lines.push(`✘ API 未返回 #${id} 的资料（error=${ex.code} ${ex.message || ''}）→ 多为已删除 / ID 不存在`);
    } else {
      lines.push('? API 不可达，无法核对 ID');
    }

    if (canary === true && ex.ok && ex.exists) {
      lines.push('→ 结论：片源未命中（已试全部文件名后缀）。点「API 兜底」用站点令牌取真实地址。');
    } else if (canary === true && ex.ok && !ex.exists) {
      lines.push('→ 结论：换个 ID 就行，CDN 没问题。');
    } else if (canary !== true) {
      lines.push('→ 结论：先修网络/代理，跟脚本无关。');
    }
    return lines;
  }

  /* ============================ UI ============================ */

  function panel() {
    let p = document.getElementById(PANEL_ID);
    if (p) return p;

    p = document.createElement('div');
    p.id = PANEL_ID;
    p.innerHTML = `
      <div class="rb91-row rb91-head">
        <b>91rb 直通</b>
        <span class="rb91-id" id="rb91-id-label">—</span>
        <span class="rb91-status" id="rb91-status">初始化…</span>
      </div>
      <div class="rb91-row rb91-btns">
        <button type="button" data-act="replay">重播</button>
        <button type="button" data-act="line">换线路</button>
        <button type="button" data-act="copy-m3u8">复制 m3u8</button>
        <button type="button" data-act="copy-ffmpeg">复制 ffmpeg</button>
        <button type="button" data-act="download">下载合并</button>
        <button type="button" data-act="stop">停止下载</button>
        <button type="button" data-act="check">自检</button>
        <button type="button" data-act="api">API 兜底</button>
      </div>
      <div class="rb91-row rb91-manual">
        <input id="rb91-id-input" type="text" inputmode="numeric" placeholder="输入视频 ID 直取（任意 id，含 VIP）">
        <button type="button" id="rb91-go">打开</button>
      </div>
      <div class="rb91-row rb91-foot" id="rb91-foot"></div>
    `;

    const style = document.createElement('style');
    style.textContent = `
      #${PANEL_ID} {
        position: fixed; right: 14px; bottom: 14px; z-index: 2147483000;
        width: 372px; max-width: calc(100vw - 24px);
        background: #0d0f14; color: #e8e8ec; border: 1px solid rgba(255,255,255,.1);
        border-radius: 12px; padding: 10px 12px 8px; font: 12px/1.55 "Segoe UI", system-ui, sans-serif;
        box-shadow: 0 16px 44px rgba(0,0,0,.55); user-select: none;
      }
      #${PANEL_ID} .rb91-row { display: flex; gap: 8px; align-items: center; flex-wrap: wrap; }
      #${PANEL_ID} .rb91-head { margin-bottom: 8px; }
      #${PANEL_ID} .rb91-head b { color: #ff7a93; font-size: 13px; }
      #${PANEL_ID} .rb91-id { color: #ffd479; font-variant-numeric: tabular-nums; }
      #${PANEL_ID} .rb91-status { margin-left: auto; color: #9aa0aa; text-align: right; }
      #${PANEL_ID} button {
        appearance: none; border: 1px solid rgba(255,255,255,.12); border-radius: 8px;
        background: rgba(255,255,255,.05); color: #e8e8ec; padding: 5px 10px;
        font: 600 12px/1 "Segoe UI", system-ui, sans-serif; cursor: pointer;
      }
      #${PANEL_ID} button:hover { background: rgba(255,122,147,.18); border-color: rgba(255,122,147,.45); }
      #${PANEL_ID} input {
        flex: 1 1 160px; min-width: 120px; background: #161a21; border: 1px solid rgba(255,255,255,.1);
        border-radius: 8px; color: #e8e8ec; padding: 5px 8px; font: 12px/1.2 "Segoe UI", system-ui, sans-serif;
      }
      #${PANEL_ID} .rb91-manual { margin-top: 8px; }
      #${PANEL_ID} .rb91-foot { margin-top: 6px; color: #8b93a1; display: block; white-space: pre-wrap; word-break: break-all; }
      #${PANEL_ID} .rb91-bar { height: 4px; background: rgba(255,255,255,.08); border-radius: 4px; overflow: hidden; margin-top: 6px; }
      #${PANEL_ID} .rb91-bar > i { display: block; height: 100%; width: 0; background: linear-gradient(90deg,#ff7a93,#e11d48); transition: width .2s ease; }
      #${PANEL_ID} .rb91-mini { position: absolute; right: 10px; top: 8px; opacity: .5; cursor: pointer; }
      #${PANEL_ID} .rb91-mini:hover { opacity: 1; }
    `;
    document.documentElement.appendChild(style);

    const bar = document.createElement('div');
    bar.className = 'rb91-bar';
    bar.innerHTML = '<i id="rb91-bar-fill"></i>';
    p.appendChild(bar);

    const mini = document.createElement('span');
    mini.className = 'rb91-mini';
    mini.textContent = '－';
    mini.onclick = () => {
      const on = p.dataset.min === '1';
      p.dataset.min = on ? '0' : '1';
      $$('.rb91-row, .rb91-bar', p).forEach((el) => { el.style.display = on ? '' : 'none'; });
      mini.textContent = on ? '－' : '＋';
    };
    p.appendChild(mini);

    // 挂到 body 之外（documentElement），避免站内脚本重写 body 时被清掉
    document.documentElement.appendChild(p);

    p.addEventListener('click', (ev) => {
      const btn = ev.target.closest ? ev.target.closest('button') : null;
      if (!btn) return;
      ev.preventDefault();
      ev.stopPropagation();
      onAction(btn.getAttribute('data-act') || (btn.id === 'rb91-go' ? 'go' : ''));
    });

    return p;
  }

  function setStatus(text) {
    const el = document.getElementById('rb91-status');
    if (el) el.textContent = text;
    log(text);
  }

  function setFoot(text) {
    const el = document.getElementById('rb91-foot');
    if (el) el.textContent = text || '';
  }

  function setProgress(done, total) {
    const fill = document.getElementById('rb91-bar-fill');
    if (fill) fill.style.width = (total ? Math.round((done / total) * 100) : 0) + '%';
  }

  function onAction(act) {
    switch (act) {
      case 'replay':
        if (STATE.video) { STATE.video.currentTime = 0; STATE.video.play().catch(() => {}); }
        break;
      case 'line':
        main({ forceNextHost: true });
        break;
      case 'copy-m3u8':
        copyText(STATE.m3u8 || '').then((ok) => setStatus(ok ? 'm3u8 已复制' : '复制失败'));
        break;
      case 'copy-ffmpeg':
        copyText(ffmpegCommand()).then((ok) => setStatus(ok ? 'ffmpeg 命令已复制' : '复制失败'));
        break;
      case 'download':
        downloadAll();
        break;
      case 'stop':
        STATE.cancel = true;
        setStatus('正在停止…');
        break;
      case 'check':
        (async () => {
          const lines = await diagnose(STATE.id || idFromLocation() || '');
          setStatus('自检完成');
          setFoot(lines.join('\n'));
        })();
        break;
      case 'api':
        (async () => {
          const id = STATE.id || idFromLocation();
          if (!id) { setStatus('先给个 ID'); return; }
          setStatus('走站点 API 取真实地址…');
          setFoot('提示：免费号每 IP 每天约 1 部，用掉后会返回空地址。');
          try {
            const r = await apiUrl(id);
            if (!r.url) {
              setStatus('API 未下发地址');
              setFoot(
                `片名: ${(r.title || '').slice(0, 24)}\n` +
                `VIP 片: ${r.isPrivate} · 额度用尽: ${r.isLimitOver}\n` +
                '免费账号拿不到这条流（VIP 或本 IP 今日额度已用完）。换代理节点可重置额度。'
              );
              return;
            }
            STATE.m3u8 = r.url;
            STATE.segments = [];
            await playSource({ m3u8: r.url, host: '（API 下发）', segments: [] });
            setStatus('API 地址已挂载');
            setFoot((r.isPrivate ? '⚠ VIP 片 · ' : '') + r.url);
            // 顺便把清单抓回来，供下载使用
            fetchText(r.url).then((t) => {
              STATE.segments = parseSegments(t, r.url);
              setStatus(`已就绪 · ${STATE.segments.length} 片 ≈ ${hhmmss(STATE.segments.length * SEG_SECONDS)}`);
            }).catch(() => {});
          } catch (e) {
            setStatus('API 兜底失败');
            setFoot(String((e && e.message) || e));
          }
        })();
        break;
      case 'go': {
        const inp = document.getElementById('rb91-id-input');
        const v = inp && inp.value.replace(/\D+/g, '');
        if (v) {
          STATE.id = v;
          main({ explicitId: v });
        }
        break;
      }
      default:
        break;
    }
  }

  function ffmpegCommand() {
    return STATE.m3u8
      ? `ffmpeg -user_agent "Mozilla/5.0" -headers "Referer: https://www.91rb.net/\\r\\n" -i "${STATE.m3u8}" -c copy -bsf:a aac_adtstoasc "${STATE.id}.mp4"`
      : '';
  }

  /* ============================ 播放器 ============================ */

  function playerHost() {
    return (
      document.querySelector('.player-holder') ||
      document.querySelector('.player.video') ||
      document.querySelector('.video-inner') ||
      document.querySelector('.col-video') ||
      document.querySelector('main') ||
      document.body
    );
  }

  function mountPlayer() {
    let wrap = document.getElementById('rb91-unlock-wrap');
    let video = document.getElementById('rb91-unlock-player');

    const host = playerHost();
    if (!host) return null;

    if (!wrap) {
      wrap = document.createElement('div');
      wrap.id = 'rb91-unlock-wrap';
      wrap.style.cssText = 'position:relative;z-index:99;background:#000;';
      video = document.createElement('video');
      video.id = 'rb91-unlock-player';
      video.controls = true;
      video.playsInline = true;
      video.setAttribute('playsinline', '');
      video.setAttribute('webkit-playsinline', '');
      video.preload = 'metadata';
      video.style.cssText = 'width:100%;max-height:78vh;display:block;background:#000;';
      wrap.appendChild(video);
      host.insertBefore(wrap, host.firstChild);
      host.classList.add('rb91-has-own');
    } else if (!host.contains(wrap)) {
      try { host.insertBefore(wrap, host.firstChild); } catch (_) {}
    }

    STATE.video = document.getElementById('rb91-unlock-player');
    return STATE.video;
  }

  async function playSource(src) {
    const video = mountPlayer();
    if (!video) throw new Error('找不到播放器容器');

    if (STATE.hls) {
      try { STATE.hls.destroy(); } catch (_) {}
      STATE.hls = null;
    }

    // 原生 HLS（Safari / iOS）
    if (video.canPlayType('application/vnd.apple.mpegurl')) {
      video.src = src.m3u8;
      try { await video.play(); } catch (_) {}
      return 'native';
    }

    const Hls = await loadHls();
    if (!Hls || !Hls.isSupported()) throw new Error('hls.js 不可用');

    const hls = new Hls({ enableWorker: true, lowLatencyMode: false, maxBufferLength: 60 });
    STATE.hls = hls;
    hls.loadSource(src.m3u8);
    hls.attachMedia(video);
    hls.on(Hls.Events.MANIFEST_PARSED, () => {
      video.play().catch(() => setStatus('点一下播放器开始'));
    });
    hls.on(Hls.Events.ERROR, (_e, data) => {
      if (data && data.fatal) {
        setStatus('HLS 错误: ' + (data.details || data.type));
        try {
          if (data.type === Hls.ErrorTypes.NETWORK_ERROR) hls.startLoad();
          else if (data.type === Hls.ErrorTypes.MEDIA_ERROR) hls.recoverMediaError();
        } catch (_) {}
      }
    });
    return 'hls.js';
  }

  /* ============================ 下载合并 ============================ */

  /** 流式下载：优先写盘（File System Access API），否则退回内存 Blob */
  async function downloadAll() {
    if (STATE.downloading) { setStatus('已经有下载在进行'); return; }
    const segs = STATE.segments.slice();
    if (!segs.length) { setStatus('没有可下载的分片'); return; }

    STATE.downloading = true;
    STATE.cancel = false;
    setProgress(0, segs.length);

    const total = segs.length;
    let done = 0, bytes = 0;
    const started = Date.now();

    let handle = null, blobParts = null, writable = null;
    try {
      if (window.showSaveFilePicker) {
        handle = await window.showSaveFilePicker({
          suggestedName: `${STATE.id || 'video'}.ts`,
          types: [{ description: 'MPEG-TS', accept: { 'video/mp2t': ['.ts'] } }],
        });
        writable = await handle.createWritable();
      } else {
        blobParts = [];
      }
    } catch (e) {
      STATE.downloading = false;
      setStatus('已取消保存');
      return;
    }

    const buffers = new Map();   // 保序缓冲：idx -> ArrayBuffer
    let writeCursor = 0;         // 已写盘/已入列的分片序号
    let nextIndex = 0;           // 下一个待抓取的分片序号
    let failCount = 0;

    async function flush() {
      while (buffers.has(writeCursor)) {
        const buf = buffers.get(writeCursor);
        buffers.delete(writeCursor);
        if (writable) await writable.write(buf);
        else blobParts.push(buf);
        writeCursor++;
      }
    }

    async function worker() {
      while (!STATE.cancel) {
        const idx = nextIndex++;
        if (idx >= total) return;

        let buf = null;
        for (let attempt = 0; attempt < 3 && !buf; attempt++) {
          try {
            const res = await fetch(segs[idx], { credentials: 'omit' });
            if (!res.ok) throw new Error('HTTP ' + res.status);
            buf = await res.arrayBuffer();
          } catch (e) {
            if (attempt === 2) {
              failCount++;
              log('分片失败', idx, e && e.message);
              // 占位空片段，保证后续分片序号不错位
              buf = new ArrayBuffer(0);
            } else {
              await new Promise((r) => setTimeout(r, 400 * (attempt + 1)));
            }
          }
        }
        if (!buf) return;

        bytes += buf.byteLength;
        buffers.set(idx, buf);
        await flush();

        const n = writeCursor;
        done = n;
        setProgress(n, total);
        const speed = bytes / Math.max(0.001, (Date.now() - started) / 1000);
        const left = Math.max(0, total - n);
        setFoot(`下载中 ${n}/${total} · ${human(bytes)} · ${human(speed)}/s · 剩余约 ${hhmmss(left * 0.35)}${failCount ? ` · 失败 ${failCount}` : ''}`);
        if (n >= total) return;
      }
    }

    await Promise.all(Array.from({ length: Math.min(DL_WORKERS, total) }, worker));

    try {
      if (writable) { await writable.close(); }
      else {
        const blob = new Blob(blobParts, { type: 'video/mp2t' });
        const a = document.createElement('a');
        a.href = URL.createObjectURL(blob);
        a.download = `${STATE.id || 'video'}.ts`;
        document.body.appendChild(a);
        a.click();
        setTimeout(() => { URL.revokeObjectURL(a.href); a.remove(); }, 4000);
      }
      setStatus(STATE.cancel ? '已停止（已保留已下载部分）' : '下载完成');
      setFoot(`共 ${writeCursor}/${total} 片 · ${human(bytes)} · 输出 ${STATE.id || 'video'}.ts（可改后缀为 .mp4，或 ffmpeg -i x.ts -c copy x.mp4）`);
    } catch (e) {
      setStatus('写盘失败: ' + (e && e.message));
    } finally {
      STATE.downloading = false;
    }
  }

  /* ============================ 主流程 ============================ */

  async function main(opts) {
    opts = opts || {};
    killMasks();
    panel();

    const id = opts.explicitId || idFromLocation();
    if (!id) {
      setStatus('未识别到视频 ID');
      setFoot('在视频页打开，或用右下角输入框填 ID 直取。');
      return;
    }
    STATE.id = String(id);
    const label = document.getElementById('rb91-id-label');
    if (label) label.textContent = '#' + STATE.id;

    setStatus('解析播放列表…');
    setFoot('');

    try {
      const src = await resolveSource(STATE.id, opts.forceNextHost);
      STATE.m3u8 = src.m3u8;
      STATE.segments = src.segments;
      STATE.duration = src.segments.length * SEG_SECONDS;

      const kind = await playSource(src);
      killMasks();

      setStatus(`已就绪 · ${src.segments.length} 片 ≈ ${hhmmss(STATE.duration)}`);
      STATE.suffix = src.suffix || '';
      setFoot(
        `线路 ${src.host}\n` +
        `源文件 ${STATE.id}${STATE.suffix}.mp4${STATE.suffix ? '（该批次带画质后缀）' : ''}\n` +
        `m3u8: ${src.m3u8}\n` +
        `播放器: ${kind} · 点「复制 ffmpeg」可直接命令行下载`
      );
    } catch (e) {
      const msg = (e && e.message) || String(e);
      if (/NetworkError|Failed to fetch|Load failed/i.test(msg)) {
        // 跨域 fetch 撞上 404 时浏览器只会给一个笼统的 NetworkError，
        // 所以这里不猜，直接跑自检把「网络」「片源」「ID」三者分开。
        setStatus('取不到片源，正在自检…');
      } else {
        setStatus('失败: ' + msg);
      }
      try {
        const lines = await diagnose(STATE.id);
        setStatus(lines[lines.length - 1] ? '自检完成' : '自检完成');
        setFoot(lines.join('\n'));
      } catch (err) {
        setFoot('自检也失败了: ' + ((err && err.message) || err));
      }
    }
  }

  /* ============================ 路由与守护 ============================ */

  function route() {
    if (location.href === STATE.lastHref) return;
    STATE.lastHref = location.href;
    if (STATE.hls) { try { STATE.hls.destroy(); } catch (_) {} STATE.hls = null; }
    STATE.m3u8 = '';
    STATE.segments = [];
    setTimeout(() => main({}), 60);
  }

  (function hookHistory() {
    ['pushState', 'replaceState'].forEach((k) => {
      const raw = history[k];
      history[k] = function () {
        const r = raw.apply(this, arguments);
        try { route(); } catch (_) {}
        return r;
      };
    });
    window.addEventListener('popstate', route);
    window.addEventListener('hashchange', route);
  })();

  function boot() {
    injectCss();
    killMasks();
    route();

    // 站内 ajax 会重写 .player-holder，这里持续守护
    let busy = false;
    const mo = new MutationObserver(() => {
      if (busy) return;
      busy = true;
      requestAnimationFrame(() => {
        busy = false;
        killMasks();
        if (STATE.m3u8 && !document.getElementById('rb91-unlock-wrap')) {
          log('播放器被站点移除，重新挂载');
          playSource({ m3u8: STATE.m3u8, host: CDN_HOSTS[STATE.hostIndex], segments: STATE.segments }).catch(() => {});
        }
      });
    });
    if (document.documentElement) {
      mo.observe(document.documentElement, { childList: true, subtree: true });
    }
  }

  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', boot, { once: true });
    injectCss();
  } else {
    boot();
  }
  window.addEventListener('load', () => setTimeout(boot, 300));

  // 控制台手动入口
  window.__RB91__ = {
    state: STATE,
    playlistUrl,
    bucketOf,
    open: (id) => main({ explicitId: String(id) }),
    parse: resolveSource,
  };
})();