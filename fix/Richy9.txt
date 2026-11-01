// ==UserScript==
// @name         18J.TV 去广告·隐私·下载
// @namespace    local.18j.tv.clean
// @version      1.2.0
// @description  桌面/手机通用：保证 18j.tv 可播、去广告、悬浮下载、阻断追踪。兼容 Tampermonkey / Violentmonkey / ScriptCat / Via / Userscripts 等
// @author       Richy
// @match        *://18j.tv/*
// @match        *://*.18j.tv/*
// @match        *://m.18j.tv/*
// @match        *://www.18j.tv/*
// @run-at       document-start
// @grant        none
// @inject-into  page
// @noframes
// @homepageURL  https://18j.tv/
// @license      MIT
// ==/UserScript==

(() => {
  'use strict';

  // 防止手机扩展重复注入 / 页面+隔离双跑
  const BOOT_FLAG = '__J18_TV_CLEAN_BOOT__';
  try {
    if (window[BOOT_FLAG]) return;
    window[BOOT_FLAG] = 1;
  } catch {
    /* ignore */
  }

  const UA = String(navigator.userAgent || '');
  const IS_MOBILE = /Android|iPhone|iPad|iPod|Mobile|webOS|BlackBerry|IEMobile|Opera Mini|HarmonyOS|MicroMessenger|Quark|UCBrowser|HuaweiBrowser|MiuiBrowser|SamsungBrowser|VivoBrowser|OppoBrowser|HeyTapBrowser/i.test(UA)
    || (navigator.maxTouchPoints > 1 && /Macintosh/i.test(UA)) // iPadOS 桌面 UA
    || (Math.min(screen.width || 0, screen.height || 0) > 0
      && Math.min(screen.width, screen.height) <= 820
      && navigator.maxTouchPoints > 0);
  const IS_IOS = /iPhone|iPad|iPod/i.test(UA) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);

  const SETTINGS = Object.freeze({
    privacyLock: true,
    strictContentPolicy: true,
    stripHlsPreRoll: true,
    blockSiteTelemetry: true,
    // 手机内存/网络更敏感，降低并发避免 OOM 与卡顿
    downloadConcurrency: IS_MOBILE ? 3 : 6,
  });

  const MAX_FILENAME_LENGTH = IS_MOBILE ? 80 : 120;
  const UI_ID = 'j18-clean-root';

  // 页面内置广告容器 + 播放器广告层
  const AD_SELECTOR = [
    '.gdhf',
    '.app-list',
    '.app-item',
    '.cate',
    '.bottomad',
    '#bottomad',
    '#mobile-sticky-ad',
    '#loader',
    '#player_pause',
    '.plyr_logo',
    '.gddp',
    '.prevideo',
    'a[href*="madouui.com"]',
    'a[href*="modelym.com"]',
    'a[href*="18j.vip"]',
    'a[href*="18link.vip"]',
    'img[alt*="广告"]',
    'img[alt*="廣告"]',
  ].join(',');

  const TRACKER_RE = /(?:googletagmanager|google-analytics|googletagservices|doubleclick|googleadservices|cloudflareinsights|hm\.baidu|cnzz\.com|umeng\.com|scorecardresearch|facebook\.net|hotjar|clarity\.ms)/i;
  const SITE_TELEMETRY_RE = /(?:\/index\.php\/ajax\/(?:hits|ulog|digg)|mac_hits|data-type=["']hits|G-\w{6,}|gtag\(|dataLayer)/i;
  const ALLOWED_MEDIA_HOST_RE = /(?:^|\.)(?:18j\.tv|cdn202511\.com|18j2026\.com)$/i;

  // 仅放行本站 + 实测媒体 CDN + Plyr 图标源，阻断广告图/统计脚本/第三方 iframe
  // 注意：Plyr 默认从 cdn.plyr.io 拉取 SVG 精灵图；拦截后中央播放键会变成空白
  const CSP = [
    "default-src 'self'",
    "script-src 'self' 'unsafe-inline' 'unsafe-eval'",
    "style-src 'self' 'unsafe-inline'",
    "img-src 'self' data: blob: https://*.cdn202511.com https://cdn.plyr.io",
    "media-src 'self' blob: https://*.cdn202511.com https://*.18j2026.com",
    "connect-src 'self' blob: https://*.cdn202511.com https://*.18j2026.com https://cdn.plyr.io",
    "font-src 'self' data:",
    "object-src 'none'",
    "frame-src 'none'",
    "child-src 'none'",
    "worker-src 'self' blob:",
    "base-uri 'self'",
    "form-action 'self'",
  ].join('; ');

  let playlistUrl = '';
  let downloadState = null;

  function securityError(api) {
    return new DOMException(`[18J Clean] blocked ${api}`, 'SecurityError');
  }

  function replaceValue(target, name, value) {
    try {
      Object.defineProperty(target, name, {
        configurable: true,
        enumerable: true,
        writable: true,
        value,
      });
    } catch {
      try { target[name] = value; } catch { /* ignore */ }
    }
  }

  function blockMethod(target, name, label) {
    if (!target || typeof target[name] !== 'function') return;
    replaceValue(target, name, function blocked() {
      throw securityError(label);
    });
  }

  function safeUrl(value) {
    try {
      return new URL(String(value), location.href);
    } catch {
      return null;
    }
  }

  function hostOf(value) {
    const url = safeUrl(value);
    return url ? url.hostname : '';
  }

  function isSameSite(value) {
    const host = hostOf(value);
    return !host || host === location.hostname || host.endsWith('.18j.tv');
  }

  function isAllowedMedia(value) {
    const host = hostOf(value);
    return !host || ALLOWED_MEDIA_HOST_RE.test(host);
  }

  function isTracker(value) {
    return TRACKER_RE.test(String(value || ''));
  }

  function isSiteTelemetry(value) {
    if (!SETTINGS.blockSiteTelemetry) return false;
    const raw = String(value || '');
    // 仅拦截浏览量/足迹类接口，不拦截播放与搜索
    return /(?:\/ajax\/(?:hits|ulog)\b|\/hits\/|type=hits|mac_ulog)/i.test(raw);
  }

  function installContentPolicy() {
    const meta = document.createElement('meta');
    meta.httpEquiv = 'Content-Security-Policy';
    meta.content = CSP;
    meta.setAttribute('data-j18', 'csp');

    const attach = () => {
      if (!document.documentElement) return false;
      const parent = document.head || document.documentElement;
      if (!meta.isConnected) parent.prepend(meta);
      return true;
    };

    if (!attach()) {
      const obs = new MutationObserver(() => {
        if (attach()) obs.disconnect();
      });
      obs.observe(document, { childList: true, subtree: true });
    }
  }

  function lockStorage() {
    try { localStorage.clear(); } catch { /* ignore */ }
    try { sessionStorage.clear(); } catch { /* ignore */ }

    // 静默空操作，避免 Plyr/页面脚本因 setItem 抛错而中断初始化
    replaceValue(Storage.prototype, 'getItem', () => null);
    replaceValue(Storage.prototype, 'key', () => null);
    replaceValue(Storage.prototype, 'setItem', () => { /* drop */ });
    replaceValue(Storage.prototype, 'removeItem', () => { /* drop */ });
    replaceValue(Storage.prototype, 'clear', () => { /* drop */ });

    try {
      Object.defineProperty(Document.prototype, 'cookie', {
        configurable: true,
        get: () => '',
        set: () => { /* drop site cookies from JS */ },
      });
    } catch { /* ignore */ }
  }

  function lockSensitiveApis() {
    blockMethod(Navigator.prototype, 'sendBeacon', 'navigator.sendBeacon');
    blockMethod(window.Geolocation?.prototype, 'getCurrentPosition', 'geolocation');
    blockMethod(window.Geolocation?.prototype, 'watchPosition', 'geolocation');
    blockMethod(window.MediaDevices?.prototype, 'getUserMedia', 'camera/microphone');
    blockMethod(window.MediaDevices?.prototype, 'enumerateDevices', 'media devices');
    blockMethod(Navigator.prototype, 'getBattery', 'battery');
    blockMethod(window.Clipboard?.prototype, 'read', 'clipboard.read');
    blockMethod(window.Clipboard?.prototype, 'readText', 'clipboard.readText');
    blockMethod(HTMLCanvasElement.prototype, 'toDataURL', 'canvas fingerprint');
    blockMethod(HTMLCanvasElement.prototype, 'toBlob', 'canvas fingerprint');
    blockMethod(window.CanvasRenderingContext2D?.prototype, 'getImageData', 'canvas fingerprint');

    const blockedRtc = function blockedRtc() { throw securityError('WebRTC'); };
    replaceValue(window, 'RTCPeerConnection', blockedRtc);
    if ('webkitRTCPeerConnection' in window) {
      replaceValue(window, 'webkitRTCPeerConnection', blockedRtc);
    }

    // 空壳 gtag，避免页面内联统计报错
    replaceValue(window, 'dataLayer', []);
    replaceValue(window, 'gtag', function gtag() { /* no-op */ });
  }

  function lockWebGlFingerprinting() {
    for (const proto of [window.WebGLRenderingContext?.prototype, window.WebGL2RenderingContext?.prototype]) {
      if (!proto?.getExtension) continue;
      const native = proto.getExtension;
      replaceValue(proto, 'getExtension', function getExtension(name) {
        if (String(name) === 'WEBGL_debug_renderer_info') return null;
        return native.call(this, name);
      });
    }
  }

  function rememberPlaylist(url) {
    const abs = safeUrl(url);
    if (!abs) return;
    if (abs.pathname.includes('.m3u8') || abs.href.includes('.m3u8')) {
      playlistUrl = abs.href;
    }
  }

  function installNetworkGuards() {
    const nativeFetch = window.fetch.bind(window);
    window.fetch = function patchedFetch(input, init) {
      const url = typeof input === 'string' || input instanceof URL
        ? String(input)
        : String(input?.url || '');
      if (isTracker(url) || isSiteTelemetry(url)) {
        return Promise.reject(securityError(`fetch ${url}`));
      }
      if (url.includes('.m3u8')) rememberPlaylist(url);
      return nativeFetch(input, init);
    };

    const nativeOpen = XMLHttpRequest.prototype.open;
    const nativeSend = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.open = function patchedOpen(method, url, ...rest) {
      this.__j18url = String(url || '');
      if (isTracker(this.__j18url) || isSiteTelemetry(this.__j18url)) {
        this.__j18block = true;
        return undefined;
      }
      if (this.__j18url.includes('.m3u8')) {
        rememberPlaylist(this.__j18url);
        if (SETTINGS.stripHlsPreRoll) exposeCleanManifest(this, safeUrl(this.__j18url)?.href || this.__j18url);
      }
      return nativeOpen.call(this, method, url, ...rest);
    };
    XMLHttpRequest.prototype.send = function patchedSend(body) {
      if (this.__j18block) {
        try { this.abort(); } catch { /* ignore */ }
        return undefined;
      }
      return nativeSend.call(this, body);
    };

    // 拦截动态 script / iframe 注入
    const nativeCreate = Document.prototype.createElement;
    Document.prototype.createElement = function patchedCreate(tagName, options) {
      const el = nativeCreate.call(this, tagName, options);
      const tag = String(tagName || '').toLowerCase();
      if (tag === 'script' || tag === 'iframe' || tag === 'embed' || tag === 'object') {
        const nativeSetAttribute = el.setAttribute.bind(el);
        el.setAttribute = function patchedSetAttribute(name, value) {
          if (String(name).toLowerCase() === 'src' && (isTracker(value) || (!isSameSite(value) && tag !== 'script'))) {
            return undefined;
          }
          // 本站播放器脚本放行；第三方脚本一律拒绝
          if (String(name).toLowerCase() === 'src' && tag === 'script' && value && !isSameSite(value)) {
            return undefined;
          }
          return nativeSetAttribute(name, value);
        };
        try {
          let currentSrc = el.src || '';
          Object.defineProperty(el, 'src', {
            configurable: true,
            get() { return currentSrc; },
            set(v) {
              const val = String(v || '');
              if (isTracker(val) || (tag === 'script' && val && !isSameSite(val)) || (tag !== 'script' && val && !isSameSite(val))) {
                currentSrc = '';
                return;
              }
              currentSrc = val;
              nativeSetAttribute('src', val);
            },
          });
        } catch { /* ignore */ }
      }
      return el;
    };
  }

  function exposeCleanManifest(xhr, url) {
    const textDesc = Object.getOwnPropertyDescriptor(XMLHttpRequest.prototype, 'responseText');
    const respDesc = Object.getOwnPropertyDescriptor(XMLHttpRequest.prototype, 'response');
    if (!textDesc?.get || !respDesc?.get) return;

    Object.defineProperty(xhr, 'responseText', {
      configurable: true,
      get() {
        return stripLeadingAd(textDesc.get.call(xhr), url);
      },
    });
    Object.defineProperty(xhr, 'response', {
      configurable: true,
      get() {
        const response = respDesc.get.call(xhr);
        return typeof response === 'string' ? stripLeadingAd(response, url) : response;
      },
    });
  }

  function installNavigationGuard() {
    const nativeOpen = window.open.bind(window);
    window.open = function patchedOpen(url, ...rest) {
      if (url && !isSameSite(url)) throw securityError(`window.open ${url}`);
      return nativeOpen(url, ...rest);
    };

    const blockExternalNav = (event) => {
      const anchor = event.target?.closest?.('a[href]');
      if (!anchor) return;
      const href = anchor.getAttribute('href') || '';
      if (!href || href.startsWith('#') || href.toLowerCase().startsWith('javascript:')) return;
      if (isSameSite(href)) return;
      event.preventDefault();
      event.stopImmediatePropagation();
    };

    // click + touch 都拦，覆盖手机点按外链广告
    document.addEventListener('click', blockExternalNav, true);
    document.addEventListener('touchend', blockExternalNav, true);

    // 禁弹窗/新窗口广告
    document.addEventListener('auxclick', (event) => {
      const anchor = event.target?.closest?.('a[href]');
      if (!anchor) return;
      if (!isSameSite(anchor.href)) {
        event.preventDefault();
        event.stopImmediatePropagation();
      }
    }, true);
  }

  function isAdAnchor(anchor) {
    const href = anchor.getAttribute('href') || '';
    if (!href || href.startsWith('#') || href.toLowerCase().startsWith('javascript:')) return false;
    if (isSameSite(href)) return false;
    return true;
  }

  function removeExternalAd(anchor) {
    const tile = anchor.closest('li, .vodlist_item, .app-item, [data-nosnippet], .list > li');
    if (tile) {
      const hasInternal = [...tile.querySelectorAll('a[href]')].some((link) => {
        const href = link.getAttribute('href') || '';
        return href && isSameSite(href);
      });
      if (!hasInternal) {
        tile.remove();
        return;
      }
    }

    const btn = anchor.closest('a.btn') || (anchor.matches('a.btn') ? anchor : null);
    if (btn && /收藏|發布|发布|地址|APP|下载APP/i.test(btn.textContent || '')) {
      btn.remove();
      return;
    }

    anchor.remove();
  }

  let playerInitScheduled = false;

  function isPlayerReady() {
    return !!(
      document.querySelector('#player .plyr, .player .plyr, .plyr__control--overlaid')
      || window.player
    );
  }

  function prepareVideoEl(video) {
    if (!video) return;
    // 手机内联播放，避免强制跳出系统全屏播放器
    video.setAttribute('playsinline', '');
    video.setAttribute('webkit-playsinline', '');
    video.setAttribute('x5-playsinline', 'true');
    video.setAttribute('x5-video-player-type', 'h5');
    video.setAttribute('x5-video-player-fullscreen', 'true');
    video.setAttribute('x5-video-orientation', 'portrait');
    video.playsInline = true;
    try { video.disableRemotePlayback = true; } catch { /* ignore */ }
    if (video.style.display === 'none') video.style.display = '';
    video.removeAttribute('hidden');
    if (!video.getAttribute('controls')) video.setAttribute('controls', '');
  }

  function ensurePlayerReady() {
    if (isPlayerReady()) {
      const readyVideo = document.querySelector('#player video, video#video, .player video, video');
      prepareVideoEl(readyVideo);
      return true;
    }

    const video = document.querySelector('#player video, video#video, .player video, video');
    if (!video) return false;

    // 站点内联脚本把初始化函数挂到全局 plyr()
    if (typeof window.plyr === 'function') {
      try {
        window.plyr();
        if (isPlayerReady() || video.closest?.('.plyr')) {
          prepareVideoEl(video);
          return true;
        }
      } catch (err) {
        console.debug('[18J Clean] plyr() failed:', err?.message || err);
      }
    }

    // 兜底：至少露出原生 video，避免一直 display:none 看不到播放按钮
    prepareVideoEl(video);
    return isPlayerReady();
  }

  function schedulePlayerInit() {
    if (playerInitScheduled) return;
    playerInitScheduled = true;
    const attempt = () => {
      if (ensurePlayerReady()) return;
      playerInitScheduled = false;
    };
    attempt();
    const delays = IS_MOBILE
      ? [50, 150, 400, 1000, 2000, 4000, 8000, 12000]
      : [50, 150, 400, 1000, 2000, 4000];
    delays.forEach((ms) => {
      setTimeout(() => {
        if (!isPlayerReady()) ensurePlayerReady();
      }, ms);
    });
  }

  function dismissPlayerPreroll(root = document) {
    const loaders = [];
    if (root?.matches?.('#loader, .loader, .prevideo')) loaders.push(root);
    root?.querySelectorAll?.('#loader, .loader').forEach((node) => loaders.push(node));

    if (!loaders.length) {
      // 暂停广告层可直接删，不影响初始化
      root?.querySelectorAll?.('#player_pause, .plyr_logo').forEach((n) => n.remove());
      return false;
    }

    let touched = false;
    for (const loader of loaders) {
      if (!loader.isConnected) continue;
      touched = true;
      // 优先点「跳过」，让站点自己 clearInterval + plyr()
      const skip = loader.querySelector?.('.skip');
      if (skip) {
        try { skip.dispatchEvent(new MouseEvent('click', { bubbles: true, cancelable: true })); } catch { /* ignore */ }
        try { skip.click(); } catch { /* ignore */ }
      }
      // 无论 skip 是否成功，都拆掉广告层，避免挡住播放器
      if (loader.isConnected) loader.remove();
    }

    root?.querySelectorAll?.('#player_pause, .plyr_logo, .prevideo').forEach((n) => n.remove());

    if (touched) schedulePlayerInit();
    return touched;
  }

  function cleanAds(root = document) {
    if (!root || (root.nodeType !== Node.ELEMENT_NODE && root !== document)) return;

    // 片头 loader 必须特殊处理：直接 remove 会导致站点倒计时脚本报错，永远不调用 plyr()
    dismissPlayerPreroll(root);

    if (root.matches?.(AD_SELECTOR)) {
      // loader 已在 dismiss 里处理；若仍匹配其它广告节点则删除
      if (!root.matches('#loader, .loader, .prevideo')) root.remove();
      return;
    }

    root.querySelectorAll?.(AD_SELECTOR).forEach((node) => {
      // loader 已处理，避免重复；其余广告节点照删
      if (node.matches?.('#loader, .loader, .prevideo, #player_pause, .plyr_logo')) return;
      node.remove();
    });

    root.querySelectorAll?.('a[href]').forEach((anchor) => {
      if (isAdAnchor(anchor)) removeExternalAd(anchor);
    });

    // 文案型广告块
    root.querySelectorAll?.('p, div, h2, h3, span').forEach((el) => {
      const text = (el.textContent || '').trim();
      if (!text) return;
      if (/福利APP|滿足你的性趣|同城约炮|点击收藏更多地址|點擊收藏更多地址|广告合作|廣告合作/i.test(text)) {
        const box = el.closest('.cate, .app-list, .gdhf, .warp, li, div') || el;
        // 避免误删主内容：仅删小块
        if (box && box !== document.body && (box.children.length < 40)) {
          if (box.classList?.contains('cate') || box.classList?.contains('app-list') || box.classList?.contains('gdhf') || box.id === 'friendlink') {
            // friendlink 实际是站内分类，保留站内链接、去掉外链后若空再删
            if (box.id === 'friendlink') return;
            box.remove();
          }
        }
      }
    });
  }

  function installAdCleaner() {
    const style = document.createElement('style');
    style.setAttribute('data-j18', 'ad-css');
    style.textContent = `
      ${AD_SELECTOR}{display:none!important;height:0!important;overflow:hidden!important;pointer-events:none!important}
      a[href*="madouui.com"],a[href*="18j.vip"],a[href*="18link.vip"]{display:none!important}
      body{padding-bottom:0!important}
      #${UI_ID},#${UI_ID} *{box-sizing:border-box}
      /* 暂停广告层可能残留占位，避免挡住中央播放键 */
      #player_pause,.plyr_logo,.loader,#loader,.prevideo{
        display:none!important;pointer-events:none!important;z-index:-1!important
      }
      /* 仅在暂停/停止时显示中央大播放键；播放中必须隐藏，避免挡住画面 */
      .plyr--paused .plyr__control--overlaid,
      .plyr--stopped .plyr__control--overlaid{
        display:flex!important; align-items:center; justify-content:center;
        opacity:.95!important; visibility:visible!important;
        width:56px!important; height:56px!important; border-radius:50%!important;
        background:#fe628e!important; color:#fff!important;
        z-index:10!important; pointer-events:auto!important;
        touch-action:manipulation;
      }
      .plyr--playing .plyr__control--overlaid{
        display:none!important; opacity:0!important; visibility:hidden!important;
        pointer-events:none!important;
      }
      .plyr__control--overlaid svg{ width:22px!important; height:22px!important; fill:currentColor!important; display:block!important }
      /* 手机端播放器与控件更易点按 */
      @media (max-width:820px){
        .plyr--paused .plyr__control--overlaid,
        .plyr--stopped .plyr__control--overlaid{
          width:64px!important; height:64px!important;
        }
        .plyr__controls{ padding-bottom:max(6px, env(safe-area-inset-bottom, 0px)) !important; }
        #player, .player, .plyr, .plyr__video-wrapper{ max-width:100vw!important; }
        video{ max-width:100%!important; height:auto!important; }
      }
    `;

    const mountStyle = () => {
      const parent = document.head || document.documentElement;
      if (parent && !style.isConnected) parent.appendChild(style);
    };
    mountStyle();

    const obs = new MutationObserver((records) => {
      mountStyle();
      for (const record of records) {
        record.addedNodes.forEach((node) => {
          if (node.nodeType === Node.ELEMENT_NODE) cleanAds(node);
        });
      }
    });
    obs.observe(document, { childList: true, subtree: true });

    const boot = () => {
      mountStyle();
      cleanAds(document);
    };
    if (document.readyState === 'loading') {
      document.addEventListener('DOMContentLoaded', boot, { once: true });
    } else {
      boot();
    }
    // 延迟广告兜底
    [300, 800, 1600, 3200, 6000].forEach((ms) => setTimeout(() => cleanAds(document), ms));
  }

  function absolutizePlaylistLine(line, baseUrl) {
    if (!line) return line;
    if (line.startsWith('#')) {
      return line.replace(/URI="([^"]+)"/g, (_, uri) => `URI="${new URL(uri, baseUrl).href}"`);
    }
    try {
      return new URL(line, baseUrl).href;
    } catch {
      return line;
    }
  }

  function stripLeadingAd(text, baseUrl) {
    if (!text || typeof text !== 'string') return text;
    const lines = text.replace(/\r/g, '').split('\n');
    const boundary = lines.indexOf('#EXT-X-DISCONTINUITY');
    const hasStreamAd = boundary > 0 && lines.slice(0, boundary)
      .some((line) => !line.startsWith('#') && /\/stream\//.test(line));

    let kept = lines;
    if (hasStreamAd) {
      const headers = lines.slice(0, boundary).filter((line) =>
        /^#EXTM3U|^#EXT-X-(?:VERSION|TARGETDURATION|MEDIA-SEQUENCE|PLAYLIST-TYPE|INDEPENDENT-SEGMENTS)/.test(line));
      kept = [...headers, ...lines.slice(boundary + 1)];
    }

    return kept.map((line) => absolutizePlaylistLine(line, baseUrl)).join('\n');
  }

  async function fetchText(url, signal) {
    const response = await fetch(url, {
      credentials: 'omit',
      referrerPolicy: 'no-referrer',
      signal,
    });
    if (!response.ok) throw new Error(`HTTP ${response.status} @ ${url}`);
    return response.text();
  }

  async function fetchBytes(url, signal) {
    const response = await fetch(url, {
      credentials: 'omit',
      referrerPolicy: 'no-referrer',
      signal,
    });
    if (!response.ok) throw new Error(`HTTP ${response.status} @ ${url}`);
    return response.arrayBuffer();
  }

  function findPlaylistUrl() {
    if (playlistUrl) return playlistUrl;

    const hlsUrl = window.hls?.url;
    if (hlsUrl && !String(hlsUrl).startsWith('blob:')) {
      playlistUrl = String(hlsUrl);
      return playlistUrl;
    }

    const media = window.hls?.media || document.querySelector('video');
    if (media?.dataset?.src && String(media.dataset.src).includes('.m3u8')) {
      playlistUrl = String(media.dataset.src);
      return playlistUrl;
    }

    const html = [...document.scripts].map((s) => s.textContent || '').join('\n');
    const match = html.match(/["'](https?:\/\/[^"']+\.m3u8[^"']*)["']/i);
    if (match) {
      playlistUrl = match[1];
      return playlistUrl;
    }

    throw new Error('未找到 m3u8 播放地址，请先等待视频开始加载');
  }

  async function replacePlayerPlaylist() {
    if (!SETTINGS.stripHlsPreRoll) return;
    if (!/^\/(?:cn\/|en\/)?v\//.test(location.pathname) && !location.pathname.includes('/vod/play')) {
      // 详情/播放页才处理；列表页跳过
      if (!document.querySelector('video#video, #player video, video')) return;
    }

    let sourceUrl;
    try {
      sourceUrl = findPlaylistUrl();
    } catch {
      // 播放器可能尚未初始化，稍后重试
      return;
    }

    const original = await fetchText(sourceUrl);
    const cleaned = stripLeadingAd(original, sourceUrl);
    if (cleaned === original) return;

    const cleanUrl = URL.createObjectURL(new Blob([cleaned], { type: 'application/vnd.apple.mpegurl' }));
    window.addEventListener('pagehide', () => URL.revokeObjectURL(cleanUrl), { once: true });

    if (window.hls && typeof window.hls.loadSource === 'function') {
      window.hls.loadSource(cleanUrl);
    } else {
      const video = document.querySelector('video');
      if (video) video.src = cleanUrl;
    }
  }

  function parseAttributes(line) {
    return Object.fromEntries([...line.matchAll(/([A-Z0-9-]+)=("[^"]*"|[^,]*)/g)]
      .map((m) => [m[1], m[2].replace(/^"|"$/g, '')]));
  }

  function selectVariant(text, baseUrl) {
    const lines = text.replace(/\r/g, '').split('\n');
    const variants = [];
    for (let i = 0; i < lines.length; i += 1) {
      if (!lines[i].startsWith('#EXT-X-STREAM-INF:')) continue;
      const attrs = parseAttributes(lines[i]);
      const uri = lines.slice(i + 1).find((line) => line && !line.startsWith('#'));
      if (!uri) continue;
      variants.push({
        bandwidth: Number(attrs.BANDWIDTH || 0),
        url: new URL(uri, baseUrl).href,
      });
    }
    variants.sort((a, b) => b.bandwidth - a.bandwidth);
    return variants[0]?.url || '';
  }

  async function loadMediaPlaylist(initialUrl, signal) {
    const visited = new Set();
    let url = initialUrl;
    while (!visited.has(url)) {
      visited.add(url);
      const text = await fetchText(url, signal);
      const variant = selectVariant(text, url);
      if (!variant) {
        return { text: stripLeadingAd(text, url), url };
      }
      url = variant;
    }
    throw new Error('HLS master 播放列表循环');
  }

  function parseSegments(text, baseUrl) {
    const lines = text.replace(/\r/g, '').split('\n');
    const segments = [];
    let sequence = Number(lines.find((l) => l.startsWith('#EXT-X-MEDIA-SEQUENCE:'))?.split(':')[1] || 0);
    let key = null;

    for (const line of lines) {
      if (line.startsWith('#EXT-X-KEY:')) {
        const attrs = parseAttributes(line);
        key = attrs.METHOD === 'NONE'
          ? null
          : {
            method: attrs.METHOD,
            uri: new URL(attrs.URI, baseUrl).href,
            iv: attrs.IV,
          };
      } else if (line && !line.startsWith('#')) {
        segments.push({
          url: new URL(line, baseUrl).href,
          key,
          sequence,
        });
        sequence += 1;
      }
    }

    if (!segments.length) throw new Error('媒体播放列表没有分片');
    return segments;
  }

  function buildIv(explicitIv, sequence) {
    if (explicitIv) {
      const hex = String(explicitIv).replace(/^0x/i, '').padStart(32, '0');
      if (!/^[0-9a-f]{32}$/i.test(hex)) throw new Error(`非法 AES IV: ${explicitIv}`);
      return Uint8Array.from(hex.match(/.{2}/g), (b) => Number.parseInt(b, 16));
    }
    const iv = new Uint8Array(16);
    let value = BigInt(sequence);
    for (let i = 15; i >= 0 && value > 0n; i -= 1) {
      iv[i] = Number(value & 255n);
      value >>= 8n;
    }
    return iv;
  }

  async function getCryptoKey(keyInfo, context) {
    if (keyInfo.method !== 'AES-128') {
      throw new Error(`不支持的加密方式: ${keyInfo.method}`);
    }
    if (!context.keyCache.has(keyInfo.uri)) {
      const promise = fetchBytes(keyInfo.uri, context.signal)
        .then((bytes) => crypto.subtle.importKey('raw', bytes, 'AES-CBC', false, ['decrypt']));
      context.keyCache.set(keyInfo.uri, promise);
    }
    return context.keyCache.get(keyInfo.uri);
  }

  async function loadSegment(segment, context) {
    const bytes = await fetchBytes(segment.url, context.signal);
    if (!segment.key) return bytes;
    const key = await getCryptoKey(segment.key, context);
    const iv = buildIv(segment.key.iv, segment.sequence);
    return crypto.subtle.decrypt({ name: 'AES-CBC', iv }, key, bytes);
  }

  async function streamSegments(segments, context) {
    const total = segments.length;
    for (let start = 0; start < total; start += SETTINGS.downloadConcurrency) {
      if (context.signal.aborted) throw new DOMException('Aborted', 'AbortError');
      const batch = segments.slice(start, start + SETTINGS.downloadConcurrency);
      const chunks = await Promise.all(batch.map((seg) => loadSegment(seg, context)));
      for (const chunk of chunks) {
        await context.writer.write(new Uint8Array(chunk));
      }
      context.onProgress(Math.min(start + batch.length, total), total);
    }
  }

  function suggestedFilename() {
    const heading = document.querySelector('h1, .play-title, .title')?.textContent
      || document.title
      || '18j-video';
    const clean = heading
      .replace(/[<>:"/\\|?*\u0000-\u001F]/g, '_')
      .replace(/\s+/g, ' ')
      .trim()
      .slice(0, MAX_FILENAME_LENGTH);
    return `${clean || '18j-video'}.ts`;
  }

  function setStatus(text, busy = false) {
    const btn = document.getElementById('j18-dl-btn');
    const status = document.getElementById('j18-dl-status');
    if (btn) {
      btn.dataset.busy = busy ? '1' : '0';
      btn.setAttribute('aria-label', text);
      btn.title = text;
      const label = btn.querySelector('.j18-label');
      if (label) label.textContent = busy ? text : '下载视频';
    }
    if (status) status.textContent = text;
  }

  function createMemoryWriter() {
    const parts = [];
    let total = 0;
    return {
      async write(chunk) {
        const buf = chunk instanceof Uint8Array ? chunk : new Uint8Array(chunk);
        parts.push(buf);
        total += buf.byteLength;
        // 手机内存告警阈值：约 512MB
        if (IS_MOBILE && total > 512 * 1024 * 1024) {
          throw new Error('文件过大，手机内存不足。请改用「复制 m3u8」到其他下载器');
        }
      },
      async close() {
        return new Blob(parts, { type: 'video/mp2t' });
      },
      async abort() { parts.length = 0; total = 0; },
      parts,
    };
  }

  async function saveBlobToDevice(blob, filename) {
    const file = new File([blob], filename, { type: blob.type || 'application/octet-stream' });

    // 手机优先系统分享（iOS/Android Chrome 等可存到文件/网盘）
    if (IS_MOBILE && navigator.canShare && navigator.canShare({ files: [file] })) {
      try {
        await navigator.share({ files: [file], title: filename, text: filename });
        return 'share';
      } catch (err) {
        if (err?.name === 'AbortError') throw err;
        // 分享失败则继续走 a[download] 兜底
      }
    }

    const url = URL.createObjectURL(blob);
    const a = document.createElement('a');
    a.href = url;
    a.download = filename;
    a.target = '_blank';
    a.rel = 'noopener';
    a.style.cssText = 'position:fixed;left:-9999px;top:0;opacity:0';
    document.body.appendChild(a);
    a.click();
    a.remove();

    // iOS 对 download 支持差：保留链接更久，并提示可长按分享
    const revokeMs = IS_IOS ? 180_000 : IS_MOBILE ? 90_000 : 30_000;
    setTimeout(() => URL.revokeObjectURL(url), revokeMs);

    if (IS_IOS) {
      setStatus('若未自动保存：可再点菜单用「复制 m3u8」', false);
    }
    return 'anchor';
  }

  async function openWriter(filename) {
    // 桌面 Chromium 才稳；手机上 showSaveFilePicker 基本不可用
    if (!IS_MOBILE && typeof window.showSaveFilePicker === 'function') {
      try {
        const handle = await window.showSaveFilePicker({
          suggestedName: filename,
          types: [{
            description: 'MPEG-TS video',
            accept: { 'video/mp2t': ['.ts'] },
          }],
        });
        const writable = await handle.createWritable();
        return {
          mode: 'fs',
          async write(chunk) { await writable.write(chunk); },
          async close() { await writable.close(); },
          async abort() { try { await writable.abort(); } catch { /* ignore */ } },
        };
      } catch (err) {
        if (err?.name === 'AbortError') throw err;
        // 用户手势/权限失败时降级 blob
      }
    }

    // 手机 / Firefox / 无 FS API：内存聚合后触发下载或系统分享
    const mem = createMemoryWriter();
    return {
      mode: 'blob',
      filename,
      async write(chunk) { await mem.write(chunk); },
      async close() {
        const blob = await mem.close();
        await saveBlobToDevice(blob, filename);
      },
      async abort() { await mem.abort(); },
    };
  }

  async function downloadVideo() {
    if (downloadState) {
      downloadState.controller.abort();
      return;
    }

    const sourceUrl = findPlaylistUrl();
    const filename = suggestedFilename();
    const controller = new AbortController();
    const writer = await openWriter(filename);
    downloadState = { controller, writer };
    setStatus('准备下载…', true);

    try {
      const playlist = await loadMediaPlaylist(sourceUrl, controller.signal);
      const segments = parseSegments(playlist.text, playlist.url);
      setStatus(`下载 0% · ${segments.length} 片`, true);

      await streamSegments(segments, {
        writer,
        signal: controller.signal,
        keyCache: new Map(),
        onProgress(done, total) {
          const pct = Math.round((done / total) * 100);
          setStatus(`下载 ${pct}%`, true);
        },
      });

      await writer.close();
      setStatus('下载完成', false);
    } catch (error) {
      try { await writer.abort(); } catch { /* ignore */ }
      if (error?.name === 'AbortError') {
        setStatus('已取消', false);
      } else {
        setStatus('下载失败', false);
        console.error('[18J Clean] download failed:', error);
        alert(`下载失败：${error?.message || error}`);
      }
    } finally {
      downloadState = null;
    }
  }

  async function copyM3u8() {
    const url = findPlaylistUrl();
    let ok = false;
    try {
      if (navigator.clipboard?.writeText) {
        await navigator.clipboard.writeText(url);
        ok = true;
      }
    } catch { /* 隐私模式/无权限时走 fallback */ }

    if (!ok) {
      const ta = document.createElement('textarea');
      ta.value = url;
      // iOS 需要 textarea 在可视区域内且可编辑才能 copy
      ta.setAttribute('readonly', '');
      ta.style.cssText = 'position:fixed;top:0;left:0;width:1px;height:1px;padding:0;border:0;opacity:0.01;';
      document.body.appendChild(ta);
      ta.focus();
      ta.setSelectionRange(0, ta.value.length);
      try {
        ok = document.execCommand('copy');
      } catch { ok = false; }
      ta.remove();
    }

    if (!ok && IS_MOBILE && navigator.share) {
      try {
        await navigator.share({ title: 'm3u8', text: url, url });
        setStatus('已分享 m3u8', false);
        return;
      } catch (err) {
        if (err?.name === 'AbortError') {
          setStatus('已取消', false);
          return;
        }
      }
    }

    if (!ok) {
      // 最后兜底：弹窗让用户手动复制
      window.prompt('复制 m3u8 链接：', url);
      setStatus('请手动复制', false);
      return;
    }
    setStatus('已复制 m3u8', false);
  }

  function bindTap(el, handler) {
    if (!el) return;
    let touched = false;
    el.addEventListener('touchend', (e) => {
      // 避免 300ms 点击延迟与幽灵 click 双触发
      if (!e.cancelable) return;
      touched = true;
      e.preventDefault();
      e.stopPropagation();
      handler(e);
      setTimeout(() => { touched = false; }, 400);
    }, { passive: false });
    el.addEventListener('click', (e) => {
      if (touched) {
        e.preventDefault();
        e.stopPropagation();
        return;
      }
      e.preventDefault();
      e.stopPropagation();
      handler(e);
    });
  }

  function createFloatingUI() {
    if (document.getElementById(UI_ID)) return;
    // 仅播放页显示下载（有 video 或 /v/ 路径）
    const onPlayPage = /^\/(?:cn\/|en\/)?v\//.test(location.pathname)
      || /\/vod\/play/i.test(location.pathname)
      || !!document.querySelector('#player, video#video, .player video');
    if (!onPlayPage) return;

    const root = document.createElement('div');
    root.id = UI_ID;
    root.setAttribute('data-mobile', IS_MOBILE ? '1' : '0');
    root.innerHTML = `
      <button id="j18-dl-btn" type="button" data-busy="0" title="下载视频" aria-label="下载视频">
        <svg viewBox="0 0 24 24" width="18" height="18" fill="currentColor" aria-hidden="true">
          <path d="M5 20h14v-2H5v2zm7-18v10.17l3.59-3.58L17 10l-5 5-5-5 1.41-1.41L11 12.17V2h1z"/>
        </svg>
        <span class="j18-label">下载视频</span>
      </button>
      <div id="j18-dl-menu" hidden>
        <button type="button" id="j18-act-download">${IS_MOBILE ? '保存/分享视频 (.ts)' : '保存完整视频 (.ts)'}</button>
        <button type="button" id="j18-act-copy">复制 m3u8 链接</button>
        <button type="button" id="j18-act-cancel" hidden>取消下载</button>
        <div id="j18-dl-status">${IS_MOBILE ? '手机可保存到文件或分享；大文件建议复制 m3u8' : '点击下载可保存去广告正片'}</div>
      </div>
    `;

    const style = document.createElement('style');
    style.textContent = `
      #${UI_ID}{
        position:fixed;
        right:max(12px, env(safe-area-inset-right, 0px));
        bottom:max(24px, calc(12px + env(safe-area-inset-bottom, 0px)));
        z-index:2147483646;
        font:600 13px/1.2 system-ui,-apple-system,BlinkMacSystemFont,Segoe UI,sans-serif;
        color:#fff; user-select:none; -webkit-user-select:none;
        touch-action:manipulation;
        -webkit-tap-highlight-color:transparent;
      }
      #j18-dl-btn{
        display:flex; align-items:center; justify-content:center; gap:8px;
        min-width:44px; min-height:44px; height:44px; padding:0 14px 0 12px; border:0; border-radius:999px;
        background:linear-gradient(135deg,#ff4d6d,#c9184a);
        color:#fff; cursor:pointer;
        box-shadow:0 8px 24px rgba(201,24,74,.35);
      }
      #j18-dl-btn:hover, #j18-dl-btn:active{ filter:brightness(1.06); }
      #j18-dl-btn[data-busy="1"]{ background:linear-gradient(135deg,#fa541c,#d4380d); }
      #j18-dl-menu{
        position:absolute; right:0; bottom:calc(100% + 8px); width:min(240px, calc(100vw - 24px));
        padding:8px; border-radius:12px; background:#141414f2;
        border:1px solid #ffffff22; backdrop-filter:blur(8px); -webkit-backdrop-filter:blur(8px);
        box-shadow:0 12px 32px #0008;
      }
      #j18-dl-menu button{
        display:block; width:100%; margin:0 0 6px; padding:12px;
        border:0; border-radius:8px; background:#2a2a2a; color:#f5f5f5;
        text-align:left; cursor:pointer; font:600 13px/1.2 system-ui,sans-serif;
        min-height:44px; touch-action:manipulation; -webkit-tap-highlight-color:transparent;
      }
      #j18-dl-menu button:hover, #j18-dl-menu button:active{ background:#3a3a3a; }
      #j18-dl-status{
        margin-top:4px; padding:4px 6px; color:#bbb; font:12px/1.4 system-ui,sans-serif;
      }
      @media (max-width:820px){
        #${UI_ID}{
          right:max(10px, env(safe-area-inset-right, 0px));
          bottom:max(72px, calc(56px + env(safe-area-inset-bottom, 0px)));
        }
        #j18-dl-btn{
          width:52px; height:52px; min-width:52px; min-height:52px; padding:0;
          border-radius:50%;
        }
        #j18-dl-btn .j18-label{ display:none; }
        #j18-dl-btn svg{ width:22px; height:22px; }
        #j18-dl-menu{ width:min(260px, calc(100vw - 20px)); }
      }
      @media (orientation: landscape) and (max-height:500px){
        #${UI_ID}{ bottom:max(12px, env(safe-area-inset-bottom, 0px)); right:max(12px, env(safe-area-inset-right, 0px)); }
      }
    `;

    const mount = () => {
      if (!document.body) return false;
      if (!style.isConnected) (document.head || document.documentElement).appendChild(style);
      if (!root.isConnected) document.body.appendChild(root);
      return true;
    };

    if (!mount()) {
      const obs = new MutationObserver(() => { if (mount()) obs.disconnect(); });
      obs.observe(document, { childList: true, subtree: true });
    }

    const menu = root.querySelector('#j18-dl-menu');
    const btn = root.querySelector('#j18-dl-btn');
    const actDownload = root.querySelector('#j18-act-download');
    const actCopy = root.querySelector('#j18-act-copy');
    const actCancel = root.querySelector('#j18-act-cancel');

    bindTap(btn, () => {
      if (downloadState) {
        downloadState.controller.abort();
        return;
      }
      menu.hidden = !menu.hidden;
    });

    bindTap(actDownload, () => {
      menu.hidden = true;
      actCancel.hidden = false;
      downloadVideo().finally(() => { actCancel.hidden = true; });
    });

    bindTap(actCopy, () => {
      try {
        copyM3u8();
      } catch (err) {
        alert(err?.message || String(err));
      }
    });

    bindTap(actCancel, () => {
      if (downloadState) downloadState.controller.abort();
    });

    const closeMenu = (e) => {
      if (!menu.hidden && !root.contains(e.target)) menu.hidden = true;
    };
    document.addEventListener('click', closeMenu, true);
    document.addEventListener('touchstart', closeMenu, { passive: true, capture: true });
  }

  function neutralizeInlineTrackers() {
    // 去掉已插入的统计节点
    document.querySelectorAll?.(
      'script[src*="googletagmanager"],script[src*="google-analytics"],script[src*="cloudflareinsights"],script[data-cf-beacon],span.mac_hits,span.mac_ulog_set'
    ).forEach((n) => n.remove());
  }

  function bootUiAndPlayer() {
    neutralizeInlineTrackers();
    cleanAds(document);
    schedulePlayerInit();
    createFloatingUI();

    // 播放器初始化有时稍晚，多次尝试去片头广告
    const tryStrip = () => replacePlayerPlaylist().catch((err) => {
      console.debug('[18J Clean] strip preroll:', err?.message || err);
    });
    tryStrip();
    // 手机网络更慢，多几次重试
    const stripDelays = IS_MOBILE ? [400, 1000, 2000, 4000, 8000, 12000] : [500, 1200, 2500, 5000];
    stripDelays.forEach((ms) => setTimeout(tryStrip, ms));

    // 手机扩展偶发晚注入：再补一轮播放器与去广告
    if (IS_MOBILE) {
      [800, 2000, 5000].forEach((ms) => {
        setTimeout(() => {
          cleanAds(document);
          schedulePlayerInit();
          createFloatingUI();
        }, ms);
      });
    }
  }

  // ---- 启动顺序：隐私/网络守卫必须最早 ----
  if (SETTINGS.strictContentPolicy) installContentPolicy();
  if (SETTINGS.privacyLock) {
    lockStorage();
    lockSensitiveApis();
    lockWebGlFingerprinting();
    installNetworkGuards();
    installNavigationGuard();
  }
  installAdCleaner();

  const startUi = () => bootUiAndPlayer();
  if (document.readyState === 'loading') {
    document.addEventListener('DOMContentLoaded', startUi, { once: true });
  } else {
    startUi();
  }

  // 手机返回/bfcache、前后台切换时再清一次广告并确保播放器
  window.addEventListener('pageshow', (ev) => {
    if (ev.persisted || IS_MOBILE) {
      cleanAds(document);
      schedulePlayerInit();
      createFloatingUI();
    }
  });
  document.addEventListener('visibilitychange', () => {
    if (document.visibilityState === 'visible') {
      cleanAds(document);
      schedulePlayerInit();
    }
  });
})();
