// ==UserScript==
// @name         91porna 去广告 + 悬浮下载
// @namespace    https://91porna.com/
// @version      1.2.0
// @description  去除 91porna 全站广告，保证 HLS 正常播放；悬浮下载面板（桌面+手机浏览器插件适配）
// @author       Richy
// @match        *://91porna.com/*
// @match        *://*.91porna.com/*
// @run-at       document-start
// @grant        none
// @inject-into  page
// @homepageURL  https://91porna.com/
// @supportURL   https://91porna.com/
// ==/UserScript==

/**
 * 手机适配说明（v1.2.0）
 * - 兼容：Kiwi / Firefox 安卓 + Tampermonkey/Violentmonkey、部分 X 浏览器、Via 油猴
 * - 自动注入页面上下文，解决插件「隔离世界」钩不住 create_player 的问题
 * - 触摸拖拽、安全区、默认折叠、移动端下载兜底（分享/新开页）
 */
(function bootstrapPorna91() {
  'use strict';

  function main() {
  'use strict';

  // 页面 DOM 共享锁，防止 content + page 双注入各跑一遍
  try {
    if (typeof document !== 'undefined' && document.documentElement) {
      if (document.documentElement.getAttribute('data-porna91') === '1') return;
      document.documentElement.setAttribute('data-porna91', '1');
    }
  } catch (_) {}

  const LOG_PREFIX = '[91porna-tools]';
  const PANEL_ID = 'porna91-dl-panel';
  const STYLE_ID = 'porna91-adblock-style';
  const IS_MOBILE = detectMobile();
  const DL_CONCURRENCY = IS_MOBILE ? 2 : 4;

  function detectMobile() {
    try {
      const ua = navigator.userAgent || '';
      if (/Android|iPhone|iPod|iPad|Mobile|webOS|BlackBerry|IEMobile|Opera Mini/i.test(ua)) return true;
      if (navigator.userAgentData && navigator.userAgentData.mobile) return true;
      if (typeof window !== 'undefined' && window.matchMedia) {
        if (window.matchMedia('(max-width: 768px)').matches) return true;
        if (window.matchMedia('(pointer: coarse)').matches && window.innerWidth < 900) return true;
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /** 明确广告/统计域名（可扩展，勿加入视频 CDN） */
  const AD_HOST_RE = new RegExp(
    [
      'doubleclick\\.net',
      'googlesyndication\\.com',
      'googletagmanager\\.com',
      'google-analytics\\.com',
      'googleadservices\\.com',
      'mc\\.yandex\\.ru',
      'yandex\\.ru/metrika',
      'monetag',
      'exoclick',
      'juicyads',
      'trafficjunky',
      'tsyndicate',
      'adsterra',
      'popads',
      'popcash',
      'propellerads',
      'clickadu',
      'onclckbn',
      'mrzcd372\\.com',
      'gfdfx265\\.com',
      'xbxpq385\\.com',
      '84847295\\.com',
      'jj38132\\.vip',
      'svlpmhnz\\.cc',
      'pg930273\\.cc',
      '60pg0251\\.cc',
      '4039333\\.cc',
      '8644718\\.cc',
      'opoz6dm\\.me',
      'ddzzy4b\\.me',
      '5p7zgdg\\.com',
      '55de98cc89\\.vip',
      'hjvideo\\.com',
      'bochuang99\\.com',
      'tvtybexoe\\.com',
      'jbqfwqoxj\\.cc',
      'lksjdgsda2352\\.top',
      'kyrvrybhsovashordoblarmek\\.com',
      'skarngrovreotxnzeluglixor\\.com',
      'dhupeacd\\.com',
      'eescyrfyk\\.com',
      'tcxvexraf\\.cc',
      'upseebaa\\.cc',
      'vgjliijf\\.com',
      'qfpvlbfoh\\.cc',
      'yjjkwh\\.com',
      'tvtybexoe',
    ].join('|'),
    'i'
  );

  /** 视频/站点必要资源：绝不能拦 */
  const KEEP_HOST_RE =
    /(^|\.)(91porna\.com|utxxds\.cn|xmbvxj\.cn|eisees\.com|cloudflare\.com|cloudflareinsights\.com)$/i;

  const REMOVE_SELECTORS = [
    '.ad-dialog',
    '.dx-ad-plugin',
    '.ad-video',
    '.ad-external',
    '.ad-video-external',
    '.ad-volume',
    '.ad-time',
    '[class*="xgplayer-advertise"]',
    '[class*="dx-ad-"]',
    'a[data-ad_id]',
    'a[data-ad_slot_key]',
    'a[data-ad_slot_name]',
    '[data-ad_id]',
    '[data-ad_slot_key]',
    'iframe[src*="doubleclick"]',
    'iframe[src*="googlesyndication"]',
    'iframe[src*="yandex"]',
    'ins.adsbygoogle',
  ];

  const HIDE_CSS = `
    ${REMOVE_SELECTORS.join(',\n')},
    .modal.ad-dialog,
    #tip_modal,
    a[data-ad_id],
    a[data-ad_slot_key],
    li:has(> a[data-ad_id]),
    li:has(> a[data-ad_slot_key]),
    ul:has(> li > a[data-ad_id]):not(.video-items):not([class*="nav"]) {
      display: none !important;
      visibility: hidden !important;
      opacity: 0 !important;
      pointer-events: none !important;
      max-height: 0 !important;
      max-width: 0 !important;
      overflow: hidden !important;
      position: fixed !important;
      left: -99999px !important;
      top: -99999px !important;
      z-index: -1 !important;
    }
    /* 播放器广告层 */
    .dx-ad-plugin,
    .xgplayer .ad-video,
    .xgplayer a.ad-external {
      display: none !important;
      pointer-events: none !important;
    }
  `;

  const state = {
    m3u8: '',
    title: '',
    poster: '',
    videoId: '',
    downloading: false,
    abort: null,
  };

  const log = (...args) => {
    try {
      console.debug(LOG_PREFIX, ...args);
    } catch (_) {}
  };

  function getUrl(input) {
    try {
      if (!input) return '';
      if (typeof input === 'string') return input;
      if (typeof input.url === 'string') return input.url;
      if (typeof Request !== 'undefined' && input instanceof Request) return input.url;
      return String(input);
    } catch (_) {
      return '';
    }
  }

  function hostOf(url) {
    try {
      return new URL(url, location.href).hostname;
    } catch (_) {
      return '';
    }
  }

  function isSameSite(url) {
    try {
      const h = hostOf(url);
      return h === location.hostname || /(^|\.)91porna\.com$/i.test(h);
    } catch (_) {
      return false;
    }
  }

  function isKeepUrl(url) {
    if (!url) return true;
    try {
      const u = new URL(url, location.href);
      if (KEEP_HOST_RE.test(u.hostname)) return true;
      if (isSameSite(u.href)) return true;
      // 站内播放接口
      if (/\/(index\/)?(detail_play|embed_play)/i.test(u.pathname)) return true;
      if (/\.(m3u8|ts|key)(\?|$)/i.test(u.pathname + u.search)) return true;
      if (/\/static\/web\//i.test(u.pathname)) return true;
    } catch (_) {}
    return false;
  }

  function isAdUrl(url) {
    if (!url || typeof url !== 'string') return false;
    if (isKeepUrl(url)) return false;
    try {
      const u = new URL(url, location.href);
      if (AD_HOST_RE.test(u.hostname) || AD_HOST_RE.test(u.href)) return true;
      // 常见广告路径
      if (/\/(ads?|banner|popunder|popup|sponsor)\b/i.test(u.pathname)) return true;
      if (/monetag|adsbygoogle|pagead/i.test(u.href)) return true;
    } catch (_) {
      return AD_HOST_RE.test(url);
    }
    return false;
  }

  function isM3u8Url(url) {
    return typeof url === 'string' && /\.m3u8(\?|$)/i.test(url);
  }

  function captureStream(url, extra) {
    if (!url || !isM3u8Url(url)) return;
    try {
      const abs = new URL(url, location.href).href;
      if (state.m3u8 === abs) return;
      state.m3u8 = abs;
      if (extra && extra.title) state.title = extra.title;
      if (extra && extra.poster) state.poster = extra.poster;
      if (extra && extra.videoId) state.videoId = String(extra.videoId);
      log('capture m3u8', abs.slice(0, 120));
      updatePanelInfo();
    } catch (_) {}
  }

  function fakeEmptyResponse() {
    try {
      return new Response('[]', {
        status: 200,
        statusText: 'OK',
        headers: { 'Content-Type': 'application/json; charset=utf-8' },
      });
    } catch (_) {
      return null;
    }
  }

  // ---------- 1. 尽早屏蔽广告全局开关 ----------
  function neutralizeAdGlobals() {
    try {
      localStorage.setItem('_show_ad_dialog_at_', String(Date.now()));
      localStorage.setItem('__landing_modal_at__', new Date().toISOString().slice(0, 10));
      localStorage.setItem('__player_external_at__', new Date().toISOString().slice(0, 10));
    } catch (_) {}

    try {
      // 页面写的是 const showAd = 1，无法覆盖绑定，但可提前占位供部分脚本读取
      if (!Object.getOwnPropertyDescriptor(window, 'showAd')) {
        Object.defineProperty(window, 'showAd', {
          configurable: true,
          enumerable: false,
          get() {
            return undefined;
          },
          set() {},
        });
      }
    } catch (_) {}

    try {
      let _adConfig = { disabled: true, url: '', gif: '', href: '', duration: 0, manual_duration: 0 };
      Object.defineProperty(window, 'ad_config', {
        configurable: true,
        enumerable: true,
        get() {
          return _adConfig;
        },
        set(v) {
          // 无论站点怎么赋值，都强制禁用贴片
          _adConfig = {
            disabled: true,
            url: '',
            gif: '',
            href: '',
            duration: 0,
            manual_duration: 0,
          };
          if (v && typeof v === 'object') {
            // 保留结构但清空广告资源，避免站点代码因缺字段报错
            _adConfig = Object.assign({}, v, _adConfig);
          }
        },
      });
    } catch (_) {}

    try {
      Object.defineProperty(window, 'play_ads_url', {
        configurable: true,
        enumerable: true,
        get() {
          return '';
        },
        set() {},
      });
    } catch (_) {}
  }

  // ---------- 2. 钩住 create_player：去广告 + 抓流 ----------
  function hookCreatePlayer() {
    let raw = null;
    const wrap = function create_player_wrapped(config) {
      try {
        if (config && typeof config === 'object') {
          if (config.url) {
            captureStream(config.url, {
              title: config.title || readPageTitle(),
              poster: config.poster,
              videoId: config.last_play_time && config.last_play_time.key,
            });
          }
          config.advertise = {
            disabled: true,
            video: '',
            gif: '',
            url: '',
            play_duration: 0,
            duration: 0,
          };
          if (config.external) {
            config.external = Object.assign({}, config.external, { href: '', title: '' });
          } else {
            config.external = { href: '', title: '' };
          }
        }
      } catch (e) {
        log('wrap create_player config failed', e);
      }
      const player = raw.apply(this, arguments);
      try {
        if (player) {
          window.__porna91_player = player;
          // 再保险：卸掉广告插件
          try {
            if (typeof player.unRegisterPlugin === 'function') {
              player.unRegisterPlugin('advertise');
              player.unRegisterPlugin('external');
            }
          } catch (_) {}
          try {
            if (player.config && player.config.url) {
              captureStream(player.config.url, { title: readPageTitle() });
            }
          } catch (_) {}
        }
      } catch (_) {}
      return player;
    };

    try {
      const desc = Object.getOwnPropertyDescriptor(window, 'create_player');
      if (desc && desc.value && typeof desc.value === 'function') {
        raw = desc.value;
        Object.defineProperty(window, 'create_player', {
          configurable: true,
          enumerable: true,
          writable: true,
          value: wrap,
        });
        return;
      }
    } catch (_) {}

    try {
      Object.defineProperty(window, 'create_player', {
        configurable: true,
        enumerable: true,
        get() {
          return raw ? wrap : undefined;
        },
        set(fn) {
          raw = typeof fn === 'function' ? fn : null;
        },
      });
    } catch (e) {
      log('hook create_player failed', e);
    }
  }

  // ---------- 3. 拦截 script/iframe/img 广告资源 ----------
  function patchElementSetters() {
    const rawSetAttribute = Element.prototype.setAttribute;
    Element.prototype.setAttribute = function (name, value) {
      try {
        if (
          typeof name === 'string' &&
          typeof value === 'string' &&
          /^(src|href|data-src)$/i.test(name) &&
          isAdUrl(value)
        ) {
          log('block setAttribute', name, value.slice(0, 100));
          return;
        }
      } catch (_) {}
      return rawSetAttribute.apply(this, arguments);
    };

    for (const Tag of [HTMLScriptElement, HTMLIFrameElement, HTMLImageElement]) {
      if (!Tag || !Tag.prototype) continue;
      try {
        const desc = Object.getOwnPropertyDescriptor(Tag.prototype, 'src');
        if (!desc || !desc.set) continue;
        Object.defineProperty(Tag.prototype, 'src', {
          configurable: true,
          enumerable: desc.enumerable,
          get: desc.get,
          set(v) {
            if (isAdUrl(String(v))) {
              log('block src', Tag.name, String(v).slice(0, 100));
              return;
            }
            return desc.set.call(this, v);
          },
        });
      } catch (e) {
        log('patch src failed', Tag.name, e);
      }
    }
  }

  // ---------- 4. fetch / XHR ----------
  function patchNetwork() {
    if (typeof window.fetch === 'function') {
      const rawFetch = window.fetch.bind(window);
      window.fetch = function (input, init) {
        try {
          const url = getUrl(input);
          if (isM3u8Url(url)) captureStream(url);
          if (isAdUrl(url)) {
            log('block fetch', url.slice(0, 120));
            const fake = fakeEmptyResponse();
            if (fake) return Promise.resolve(fake);
          }
        } catch (e) {
          log('fetch patch error', e);
        }
        return rawFetch(input, init);
      };
    }

    const XO = XMLHttpRequest.prototype.open;
    const XS = XMLHttpRequest.prototype.send;
    XMLHttpRequest.prototype.open = function (method, url) {
      try {
        const u = String(url || '');
        this.__porna91Ad = isAdUrl(u);
        if (isM3u8Url(u)) captureStream(u);
      } catch (_) {
        this.__porna91Ad = false;
      }
      return XO.apply(this, arguments);
    };
    XMLHttpRequest.prototype.send = function () {
      if (this.__porna91Ad) {
        const self = this;
        setTimeout(() => {
          try {
            Object.defineProperty(self, 'readyState', { configurable: true, get: () => 4 });
            Object.defineProperty(self, 'status', { configurable: true, get: () => 200 });
            Object.defineProperty(self, 'responseText', { configurable: true, get: () => '[]' });
            Object.defineProperty(self, 'response', { configurable: true, get: () => '[]' });
            if (typeof self.onreadystatechange === 'function') self.onreadystatechange();
            if (typeof self.onload === 'function') self.onload();
          } catch (_) {}
        }, 0);
        return;
      }
      return XS.apply(this, arguments);
    };
  }

  // ---------- 5. 弹窗 / 点击广告 ----------
  function patchWindowOpen() {
    const rawOpen = window.open;
    window.open = function (url) {
      try {
        if (url != null && url !== '' && isAdUrl(String(url))) {
          log('block window.open', String(url).slice(0, 100));
          return null;
        }
        // 空白/无参 open 常被 popunder 利用，视频站也用它，仅拦明显广告域名
      } catch (_) {}
      return rawOpen.apply(this, arguments);
    };

    const blockAdClick = (e) => {
      try {
        const a = e.target && e.target.closest && e.target.closest('a[href]');
        if (!a) return;
        if (
          a.hasAttribute('data-ad_id') ||
          a.hasAttribute('data-ad_slot_key') ||
          a.hasAttribute('data-ad_slot_name') ||
          isAdUrl(a.href)
        ) {
          e.preventDefault();
          e.stopPropagation();
          e.stopImmediatePropagation();
        }
      } catch (_) {}
    };
    ['click', 'auxclick', 'mousedown', 'pointerdown'].forEach((type) => {
      document.addEventListener(type, blockAdClick, true);
    });
  }

  // ---------- 6. DOM 清理 ----------
  function injectCSS() {
    try {
      let style = document.getElementById(STYLE_ID);
      if (!style) {
        style = document.createElement('style');
        style.id = STYLE_ID;
        (document.head || document.documentElement).appendChild(style);
      }
      style.textContent = HIDE_CSS + panelCSS();
    } catch (_) {}
  }

  function removeNode(el) {
    if (!el || el.id === STYLE_ID || el.id === PANEL_ID) return false;
    try {
      if (el.tagName === 'BODY' || el.tagName === 'HTML' || el.tagName === 'MAIN') return false;
      // 绝不删播放器本体
      if (el.id === 'mse' || (el.classList && el.classList.contains('player-container'))) return false;
      if (el.closest && el.closest('#mse, .player-container, .xgplayer, #' + PANEL_ID)) {
        // 播放器内部只删广告子节点
        if (
          el.classList &&
          (el.classList.contains('dx-ad-plugin') ||
            el.classList.contains('ad-video') ||
            /ad-/i.test(el.className))
        ) {
          el.remove();
          return true;
        }
        if (el.closest && el.closest('#' + PANEL_ID)) return false;
        if (el.id === 'mse' || el.classList.contains('player-container') || el.classList.contains('xgplayer')) {
          return false;
        }
      }
      el.remove();
      return true;
    } catch (_) {
      return false;
    }
  }

  function isAdNode(el) {
    if (!el || el.nodeType !== 1) return false;
    const tag = el.tagName;
    const id = el.id || '';
    const cls = typeof el.className === 'string' ? el.className : String(el.className || '');

    if (id === 'tip_modal' || id === PANEL_ID || id === STYLE_ID) {
      return id === 'tip_modal';
    }
    if (/\bad-dialog\b/i.test(cls)) return true;
    if (/\bdx-ad-plugin\b/i.test(cls)) return true;
    if (/xgplayer-advertise/i.test(cls)) return true;
    if (el.hasAttribute && (el.hasAttribute('data-ad_id') || el.hasAttribute('data-ad_slot_key'))) {
      return true;
    }
    if (tag === 'SCRIPT') return isAdUrl(el.src || el.getAttribute('src') || '');
    if (tag === 'IFRAME' || tag === 'IMG') return isAdUrl(el.src || el.getAttribute('src') || '');
    if (tag === 'A') {
      if (el.hasAttribute('data-ad_id') || el.hasAttribute('data-ad_slot_key')) return true;
      return isAdUrl(el.href || el.getAttribute('href') || '');
    }
    return false;
  }

  function stripPlayerAdsAttr() {
    try {
      const mse = document.getElementById('mse');
      if (mse) {
        mse.removeAttribute('data-ads_url');
        mse.dataset.ads_url = '';
        if (!state.videoId && mse.dataset.video_id) state.videoId = mse.dataset.video_id;
        if (!state.title && mse.dataset.video_title) state.title = mse.dataset.video_title;
      }
    } catch (_) {}
  }

  function killPlayerAdDom() {
    try {
      document.querySelectorAll('.dx-ad-plugin, .ad-video, .ad-external, .ad-video-external').forEach((el) => {
        try {
          if (el.tagName === 'VIDEO') {
            el.pause();
            el.removeAttribute('src');
            el.load();
          }
        } catch (_) {}
        removeNode(el);
      });
      // 尝试点掉「跳过广告」
      document.querySelectorAll('.can-skip-ad .ad-skip, [class*="ad-skip"], .dx-ad-plugin button').forEach((btn) => {
        try {
          btn.click();
        } catch (_) {}
      });
    } catch (_) {}
  }

  function closeAdModals() {
    try {
      document.querySelectorAll('.ad-dialog, #tip_modal').forEach((modal) => {
        try {
          modal.classList.remove('in', 'show');
          modal.style.display = 'none';
          modal.setAttribute('aria-hidden', 'true');
        } catch (_) {}
        removeNode(modal);
      });
      document.querySelectorAll('.modal-backdrop').forEach((b) => {
        // 若只剩广告遮罩则移除
        try {
          if (!document.querySelector('.modal.in, .modal.show')) removeNode(b);
        } catch (_) {
          removeNode(b);
        }
      });
      try {
        document.body.classList.remove('modal-open');
        document.body.style.removeProperty('overflow');
        document.body.style.removeProperty('padding-right');
      } catch (_) {}
    } catch (_) {}
  }

  function sweep() {
    injectCSS();
    stripPlayerAdsAttr();
    try {
      REMOVE_SELECTORS.forEach((sel) => {
        try {
          document.querySelectorAll(sel).forEach((el) => {
            // 整卡广告 li
            const li = el.closest && el.closest('li');
            if (li && el.matches && el.matches('a[data-ad_id], a[data-ad_slot_key], [data-ad_id]')) {
              removeNode(li);
            } else {
              removeNode(el);
            }
          });
        } catch (_) {}
      });
      document.querySelectorAll('script[src], iframe[src]').forEach((el) => {
        if (isAdUrl(el.src)) removeNode(el);
      });
      killPlayerAdDom();
      closeAdModals();
    } catch (e) {
      log('sweep error', e);
    }
  }

  function observe() {
    const mo = new MutationObserver((mutations) => {
      let need = false;
      for (const m of mutations) {
        if (m.type === 'childList') {
          m.addedNodes.forEach((n) => {
            if (n.nodeType !== 1) return;
            if (isAdNode(n)) {
              removeNode(n);
              return;
            }
            if (n.querySelectorAll) {
              n.querySelectorAll(
                'a[data-ad_id], a[data-ad_slot_key], .ad-dialog, .dx-ad-plugin, iframe[src], script[src]'
              ).forEach((el) => {
                if (isAdNode(el) || (el.src && isAdUrl(el.src))) removeNode(el.closest('li') || el);
              });
            }
            need = true;
          });
        } else if (m.type === 'attributes') {
          const el = m.target;
          if (!el) continue;
          if (m.attributeName === 'src' || m.attributeName === 'href') {
            if (isAdUrl(el.src || el.href || '')) removeNode(el);
          }
          if (m.attributeName && m.attributeName.indexOf('data-ad') === 0) {
            removeNode(el.closest && el.closest('li') || el);
          }
        }
      }
      if (need) {
        stripPlayerAdsAttr();
        killPlayerAdDom();
      }
    });
    mo.observe(document.documentElement || document, {
      childList: true,
      subtree: true,
      attributes: true,
      attributeFilter: ['src', 'href', 'data-ad_id', 'data-ad_slot_key', 'data-ads_url', 'class'],
    });
  }

  // ---------- 7. 页面信息 ----------
  function readPageTitle() {
    try {
      const mse = document.getElementById('mse');
      if (mse && mse.dataset && mse.dataset.video_title) return mse.dataset.video_title;
      const h = document.querySelector('h1, .video-title, .dx-title, title');
      if (h && h.textContent) return h.textContent.trim().slice(0, 120);
      return (document.title || '91porna').replace(/\s*[-|_].*$/, '').trim();
    } catch (_) {
      return '91porna';
    }
  }

  function isDetailPage() {
    try {
      return (
        /\/comic\/index\/detail/i.test(location.pathname) ||
        /video_key=/i.test(location.search) ||
        !!document.getElementById('mse')
      );
    } catch (_) {
      return false;
    }
  }

  // ---------- 8. HLS 解析 / AES 解密下载 ----------
  function sanitizeFilename(name) {
    return (
      String(name || '91porna')
        .replace(/[\\/:*?"<>|]+/g, '_')
        .replace(/\s+/g, ' ')
        .trim()
        .slice(0, 100) || '91porna'
    );
  }

  function formatBytes(n) {
    if (!n || n < 0) return '0 B';
    const u = ['B', 'KB', 'MB', 'GB'];
    let i = 0;
    let v = n;
    while (v >= 1024 && i < u.length - 1) {
      v /= 1024;
      i += 1;
    }
    return v.toFixed(i ? 1 : 0) + ' ' + u[i];
  }

  function hexToBytes(hex) {
    const h = String(hex || '').replace(/^0x/i, '').replace(/\s+/g, '');
    const out = new Uint8Array(h.length / 2);
    for (let i = 0; i < out.length; i++) out[i] = parseInt(h.substr(i * 2, 2), 16);
    return out;
  }

  function seqToIv(sn) {
    const iv = new Uint8Array(16);
    let n = sn >>> 0;
    iv[15] = n & 0xff;
    iv[14] = (n >>> 8) & 0xff;
    iv[13] = (n >>> 16) & 0xff;
    iv[12] = (n >>> 24) & 0xff;
    return iv;
  }

  function parseM3u8(text, baseUrl) {
    const lines = String(text || '').split(/\r?\n/);
    const segs = [];
    let keyUri = '';
    let method = 'NONE';
    let ivBytes = null;
    let mediaSequence = 0;
    let expectUri = false;
    let pending = { duration: 0 };

    const sawMediaSeq = lines.some((l) => /^#EXT-X-MEDIA-SEQUENCE:/i.test(l.trim()));
    if (sawMediaSeq) {
      const m = String(text).match(/#EXT-X-MEDIA-SEQUENCE:(\d+)/i);
      if (m) mediaSequence = parseInt(m[1], 10) || 0;
    }

    let sn = mediaSequence;
    for (let i = 0; i < lines.length; i++) {
      const line = lines[i].trim();
      if (!line) continue;
      if (line.startsWith('#')) {
        if (/^#EXT-X-KEY:/i.test(line)) {
          const mu = line.match(/METHOD=([^,]+)/i);
          method = mu ? mu[1].trim() : 'NONE';
          const uu = line.match(/URI="([^"]+)"/i) || line.match(/URI=([^,]+)/i);
          keyUri = uu ? uu[1].trim() : '';
          const ivm = line.match(/IV=0x([0-9a-fA-F]+)/i);
          ivBytes = ivm ? hexToBytes(ivm[1]) : null;
        } else if (/^#EXTINF:/i.test(line)) {
          expectUri = true;
          pending = { duration: parseFloat(line.split(':')[1]) || 0 };
        }
        continue;
      }
      if (expectUri || !line.startsWith('#')) {
        let href = line;
        try {
          href = new URL(line, baseUrl).href;
        } catch (_) {}
        segs.push({
          url: href,
          sn,
          method,
          keyUri,
          iv: ivBytes ? new Uint8Array(ivBytes) : seqToIv(sn),
        });
        sn += 1;
        expectUri = false;
      }
    }
    return { segs, mediaSequence };
  }

  async function fetchBuf(url, signal) {
    const res = await fetch(url, { credentials: 'omit', signal });
    if (!res.ok) throw new Error('HTTP ' + res.status + ' ' + url.slice(0, 80));
    return res.arrayBuffer();
  }

  async function decryptAes128(data, keyBytes, ivBytes) {
    const cryptoKey = await crypto.subtle.importKey('raw', keyBytes, { name: 'AES-CBC' }, false, ['decrypt']);
    try {
      return await crypto.subtle.decrypt({ name: 'AES-CBC', iv: ivBytes }, cryptoKey, data);
    } catch (e) {
      // 部分切片非标准 PKCS7，尝试手动不校验（无法用 subtle），退回原始数据并提示
      log('AES decrypt failed, keep encrypted?', e);
      throw e;
    }
  }

  async function downloadHls(m3u8Url, { onProgress, signal } = {}) {
    const listRes = await fetch(m3u8Url, { credentials: 'omit', signal });
    if (!listRes.ok) throw new Error('获取 m3u8 失败 HTTP ' + listRes.status);
    const text = await listRes.text();
    if (!/#EXTM3U/i.test(text)) throw new Error('不是有效的 m3u8');

    // 多码率 master playlist
    if (/#EXT-X-STREAM-INF/i.test(text)) {
      const lines = text.split(/\r?\n/).map((l) => l.trim());
      let best = null;
      let lastBw = 0;
      for (let i = 0; i < lines.length; i++) {
        const line = lines[i];
        if (/^#EXT-X-STREAM-INF/i.test(line)) {
          const bm = line.match(/BANDWIDTH=(\d+)/i);
          const bw = bm ? parseInt(bm[1], 10) : 0;
          const next = lines[i + 1];
          if (next && !next.startsWith('#') && bw >= lastBw) {
            lastBw = bw;
            try {
              best = new URL(next, m3u8Url).href;
            } catch (_) {
              best = next;
            }
          }
        }
      }
      if (!best) throw new Error('主播放列表中未找到子流');
      return downloadHls(best, { onProgress, signal });
    }

    const { segs } = parseM3u8(text, m3u8Url);
    if (!segs.length) throw new Error('播放列表无分片');

    const keyCache = new Map();
    async function getKey(uri) {
      if (!uri) return null;
      let abs = uri;
      try {
        abs = new URL(uri, m3u8Url).href;
      } catch (_) {}
      if (keyCache.has(abs)) return keyCache.get(abs);
      const buf = await fetchBuf(abs, signal);
      const bytes = new Uint8Array(buf);
      keyCache.set(abs, bytes);
      return bytes;
    }

    const total = segs.length;
    const parts = new Array(total);
    let done = 0;
    let bytes = 0;
    let idx = 0;
    let failed = null;

    async function worker() {
      while (idx < total) {
        if (signal && signal.aborted) throw new DOMException('已取消', 'AbortError');
        if (failed) throw failed;
        const i = idx++;
        const seg = segs[i];
        let attempt = 0;
        while (attempt < 3) {
          try {
            let buf = await fetchBuf(seg.url, signal);
            if (seg.method && /AES-128/i.test(seg.method) && seg.keyUri) {
              const key = await getKey(seg.keyUri);
              const iv = seg.iv || seqToIv(seg.sn);
              buf = await decryptAes128(buf, key, iv);
            }
            parts[i] = buf;
            bytes += buf.byteLength;
            done += 1;
            if (onProgress) onProgress({ done, total, bytes, index: i });
            break;
          } catch (e) {
            if (e && e.name === 'AbortError') throw e;
            attempt += 1;
            if (attempt >= 3) {
              failed = new Error('分片失败 #' + i + ': ' + (e && e.message));
              throw failed;
            }
            await new Promise((r) => setTimeout(r, 400 * attempt));
          }
        }
      }
    }

    const workers = [];
    const n = Math.min(DL_CONCURRENCY, total || 1);
    for (let i = 0; i < n; i++) workers.push(worker());
    await Promise.all(workers);

    return new Blob(parts, { type: 'video/mp2t' });
  }

  async function triggerBlobDownload(blob, filename) {
    const url = URL.createObjectURL(blob);
    // 1) 标准 a[download]（桌面 / 部分安卓）
    try {
      const a = document.createElement('a');
      a.href = url;
      a.download = filename;
      a.rel = 'noopener';
      a.style.cssText = 'position:fixed;left:-9999px;top:-9999px';
      document.documentElement.appendChild(a);
      a.click();
      setTimeout(() => {
        try {
          a.remove();
        } catch (_) {}
      }, 2000);
    } catch (e) {
      log('a.download failed', e);
    }

    // 2) 手机：Web Share 传文件（支持时最稳）
    if (IS_MOBILE) {
      try {
        const file = new File([blob], filename, { type: blob.type || 'video/mp2t' });
        if (navigator.canShare && navigator.canShare({ files: [file] }) && navigator.share) {
          await navigator.share({
            files: [file],
            title: filename,
            text: filename,
          });
          setTimeout(() => {
            try {
              URL.revokeObjectURL(url);
            } catch (_) {}
          }, 60000);
          return 'share';
        }
      } catch (e) {
        // 用户取消分享不算失败
        if (e && e.name === 'AbortError') {
          setTimeout(() => {
            try {
              URL.revokeObjectURL(url);
            } catch (_) {}
          }, 60000);
          return 'share-cancel';
        }
        log('share failed', e);
      }

      // 3) 兜底：新标签打开 blob，用户可长按保存
      try {
        const opened = window.open(url, '_blank');
        if (!opened) {
          // 弹窗被拦：在面板里提示用复制 m3u8
          setStatus('请允许弹窗，或改用「复制流」到下载器', 'wait');
        }
      } catch (_) {}
    }

    setTimeout(() => {
      try {
        URL.revokeObjectURL(url);
      } catch (_) {}
    }, IS_MOBILE ? 120000 : 15000);
    return 'download';
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
      // iOS 需要可见可选区域
      ta.setAttribute('readonly', '');
      ta.style.cssText =
        'position:fixed;top:0;left:0;width:1px;height:1px;padding:0;margin:0;border:0;opacity:0;';
      document.body.appendChild(ta);
      ta.focus();
      ta.setSelectionRange(0, ta.value.length);
      const ok = document.execCommand('copy');
      ta.remove();
      return ok;
    } catch (_) {
      return false;
    }
  }

  // ---------- 9. 悬浮面板 UI（暗色影院控制台） ----------
  const ICONS = {
    logo: '<svg viewBox="0 0 24 24" fill="none" aria-hidden="true"><path d="M4 7.5A2.5 2.5 0 0 1 6.5 5h11A2.5 2.5 0 0 1 20 7.5v9a2.5 2.5 0 0 1-2.5 2.5h-11A2.5 2.5 0 0 1 4 16.5v-9Z" stroke="currentColor" stroke-width="1.6"/><path d="M10 9.2v5.6l5-2.8-5-2.8Z" fill="currentColor"/></svg>',
    download: '<svg viewBox="0 0 24 24" fill="none" aria-hidden="true"><path d="M12 4v10m0 0 3.5-3.5M12 14l-3.5-3.5M5 18h14" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>',
    copy: '<svg viewBox="0 0 24 24" fill="none" aria-hidden="true"><rect x="8" y="8" width="11" height="11" rx="2" stroke="currentColor" stroke-width="1.7"/><path d="M6 15V6.8A1.8 1.8 0 0 1 7.8 5H15" stroke="currentColor" stroke-width="1.7" stroke-linecap="round"/></svg>',
    open: '<svg viewBox="0 0 24 24" fill="none" aria-hidden="true"><path d="M14 5h5v5M10 14 19 5M18 13.5V18a1 1 0 0 1-1 1H6a1 1 0 0 1-1-1V7a1 1 0 0 1 1-1h4.5" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round"/></svg>',
    link: '<svg viewBox="0 0 24 24" fill="none" aria-hidden="true"><path d="M10 13a5 5 0 0 0 7.07 0l1.76-1.76a5 5 0 0 0-7.07-7.07L10 5" stroke="currentColor" stroke-width="1.7" stroke-linecap="round"/><path d="M14 11a5 5 0 0 0-7.07 0L5.17 12.76a5 5 0 1 0 7.07 7.07L14 19" stroke="currentColor" stroke-width="1.7" stroke-linecap="round"/></svg>',
    refresh: '<svg viewBox="0 0 24 24" fill="none" aria-hidden="true"><path d="M20 12a8 8 0 1 1-2.2-5.5" stroke="currentColor" stroke-width="1.8" stroke-linecap="round"/><path d="M20 5v5h-5" stroke="currentColor" stroke-width="1.8" stroke-linecap="round" stroke-linejoin="round"/></svg>',
    minus: '<svg viewBox="0 0 24 24" fill="none" aria-hidden="true"><path d="M6 12h12" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg>',
    plus: '<svg viewBox="0 0 24 24" fill="none" aria-hidden="true"><path d="M12 6v12M6 12h12" stroke="currentColor" stroke-width="2" stroke-linecap="round"/></svg>',
    stop: '<svg viewBox="0 0 24 24" fill="none" aria-hidden="true"><rect x="6.5" y="6.5" width="11" height="11" rx="2" fill="currentColor"/></svg>',
    grip: '<svg viewBox="0 0 24 24" fill="currentColor" aria-hidden="true"><circle cx="9" cy="8" r="1.2"/><circle cx="15" cy="8" r="1.2"/><circle cx="9" cy="12" r="1.2"/><circle cx="15" cy="12" r="1.2"/><circle cx="9" cy="16" r="1.2"/><circle cx="15" cy="16" r="1.2"/></svg>',
  };

  function panelCSS() {
    return `
      #${PANEL_ID} {
        --p91-bg: rgba(14, 15, 18, 0.92);
        --p91-bg-2: rgba(28, 22, 26, 0.88);
        --p91-line: rgba(255, 255, 255, 0.08);
        --p91-line-strong: rgba(255, 190, 170, 0.18);
        --p91-text: #f6f1ec;
        --p91-muted: #a89b96;
        --p91-faint: #6f6662;
        --p91-accent: #ff4d6d;
        --p91-accent-2: #ff8f5a;
        --p91-ok: #3ddc97;
        --p91-warn: #f5c542;
        --p91-err: #ff6b6b;
        --p91-shadow: 0 18px 50px rgba(0, 0, 0, 0.55), 0 0 0 1px rgba(255,255,255,0.04);
        position: fixed;
        right: 18px;
        bottom: 92px;
        z-index: 2147483646;
        width: 348px;
        max-width: calc(100vw - 20px);
        color: var(--p91-text);
        font-family: "Segoe UI", "PingFang SC", "Hiragino Sans GB", "Microsoft YaHei", sans-serif;
        font-size: 13px;
        line-height: 1.45;
        border-radius: 18px;
        background:
          radial-gradient(120% 90% at 0% 0%, rgba(255, 77, 109, 0.18), transparent 55%),
          radial-gradient(90% 70% at 100% 0%, rgba(255, 143, 90, 0.12), transparent 50%),
          linear-gradient(165deg, var(--p91-bg-2), var(--p91-bg) 42%, #0b0c0f 100%);
        border: 1px solid var(--p91-line-strong);
        box-shadow: var(--p91-shadow);
        backdrop-filter: blur(18px) saturate(1.2);
        -webkit-backdrop-filter: blur(18px) saturate(1.2);
        overflow: hidden;
        isolation: isolate;
        animation: porna91-in 0.38s cubic-bezier(0.22, 1, 0.36, 1) both;
        transition: width 0.25s ease, box-shadow 0.25s ease, transform 0.2s ease, bottom 0.2s ease;
        -webkit-tap-highlight-color: transparent;
        touch-action: manipulation;
        max-height: calc(100dvh - 24px);
      }
      #${PANEL_ID}.is-mobile {
        right: max(10px, env(safe-area-inset-right, 0px));
        left: auto;
        bottom: calc(12px + env(safe-area-inset-bottom, 0px) + 52px);
        width: min(380px, calc(100vw - 20px));
        max-height: calc(100dvh - env(safe-area-inset-top, 0px) - env(safe-area-inset-bottom, 0px) - 24px);
        font-size: 14px;
        /* 低端机 blur 很卡，用实色兜底 */
        backdrop-filter: blur(12px);
        -webkit-backdrop-filter: blur(12px);
      }
      #${PANEL_ID}.is-mobile.porna91-sheet {
        left: max(10px, env(safe-area-inset-left, 0px));
        right: max(10px, env(safe-area-inset-right, 0px));
        width: auto;
        bottom: calc(8px + env(safe-area-inset-bottom, 0px));
        border-radius: 18px 18px 14px 14px;
        max-height: min(78dvh, calc(100dvh - env(safe-area-inset-top, 0px) - 16px));
        display: flex;
        flex-direction: column;
      }
      #${PANEL_ID}.is-mobile.porna91-sheet .porna91-bd {
        overflow: auto;
        -webkit-overflow-scrolling: touch;
        overscroll-behavior: contain;
        flex: 1;
        min-height: 0;
      }
      #${PANEL_ID}::before {
        content: "";
        position: absolute;
        inset: 0;
        background-image: url("data:image/svg+xml,%3Csvg viewBox='0 0 200 200' xmlns='http://www.w3.org/2000/svg'%3E%3Cfilter id='n'%3E%3CfeTurbulence type='fractalNoise' baseFrequency='0.85' numOctaves='3' stitchTiles='stitch'/%3E%3C/filter%3E%3Crect width='100%25' height='100%25' filter='url(%23n)' opacity='0.045'/%3E%3C/svg%3E");
        pointer-events: none;
        mix-blend-mode: overlay;
        opacity: 0.55;
        z-index: 0;
      }
      #${PANEL_ID} > * { position: relative; z-index: 1; }
      @keyframes porna91-in {
        from { opacity: 0; transform: translateY(14px) scale(0.96); }
        to { opacity: 1; transform: translateY(0) scale(1); }
      }
      @keyframes porna91-pulse {
        0%, 100% { opacity: 1; transform: scale(1); }
        50% { opacity: 0.55; transform: scale(0.92); }
      }
      @keyframes porna91-spin {
        to { transform: rotate(360deg); }
      }
      @keyframes porna91-shimmer {
        0% { background-position: 0% 50%; }
        100% { background-position: 200% 50%; }
      }

      #${PANEL_ID}.porna91-collapsed {
        width: auto;
        min-width: 0;
        border-radius: 999px;
        background: linear-gradient(135deg, #1a1014 0%, #120c10 100%);
        max-height: none;
        left: auto !important;
      }
      #${PANEL_ID}.porna91-collapsed.is-mobile {
        bottom: calc(16px + env(safe-area-inset-bottom, 0px) + 48px);
        right: max(12px, env(safe-area-inset-right, 0px));
        box-shadow: 0 10px 28px rgba(0,0,0,0.5), 0 0 0 1px rgba(255,77,109,0.28);
      }
      #${PANEL_ID}.porna91-collapsed::before { display: none; }
      #${PANEL_ID}.porna91-collapsed .porna91-bd,
      #${PANEL_ID}.porna91-collapsed .porna91-hd-meta,
      #${PANEL_ID}.porna91-collapsed .porna91-hd-actions [data-act="refresh"] {
        display: none !important;
      }
      #${PANEL_ID}.porna91-collapsed .porna91-hd {
        padding: 10px 12px 10px 14px;
        gap: 10px;
        background: transparent;
        border: 0;
      }
      #${PANEL_ID}.is-mobile.porna91-collapsed .porna91-hd {
        padding: 12px 14px 12px 14px;
        min-height: 48px;
      }
      #${PANEL_ID}.is-mobile.porna91-collapsed .porna91-logo {
        width: 38px;
        height: 38px;
        border-radius: 12px;
      }
      #${PANEL_ID}.porna91-collapsed .porna91-brand-text { display: none; }
      #${PANEL_ID}.is-dragging {
        box-shadow: 0 28px 60px rgba(0,0,0,0.65), 0 0 0 1px rgba(255,77,109,0.25);
        cursor: grabbing;
      }

      #${PANEL_ID} .porna91-hd {
        display: flex;
        align-items: center;
        gap: 10px;
        padding: 14px 14px 12px;
        cursor: grab;
        user-select: none;
        border-bottom: 1px solid var(--p91-line);
        background: linear-gradient(180deg, rgba(255,255,255,0.03), transparent);
      }
      #${PANEL_ID} .porna91-hd:active { cursor: grabbing; }
      #${PANEL_ID} .porna91-brand {
        display: flex;
        align-items: center;
        gap: 10px;
        min-width: 0;
        flex: 1;
      }
      #${PANEL_ID} .porna91-logo {
        width: 34px;
        height: 34px;
        border-radius: 11px;
        display: grid;
        place-items: center;
        color: #fff;
        background: linear-gradient(145deg, var(--p91-accent), #c81e4a 55%, var(--p91-accent-2));
        box-shadow: 0 8px 18px rgba(255, 77, 109, 0.35), inset 0 1px 0 rgba(255,255,255,0.25);
        flex-shrink: 0;
      }
      #${PANEL_ID} .porna91-logo svg { width: 18px; height: 18px; }
      #${PANEL_ID} .porna91-brand-text {
        min-width: 0;
        display: flex;
        flex-direction: column;
        gap: 2px;
      }
      #${PANEL_ID} .porna91-brand-text strong {
        font-size: 13.5px;
        font-weight: 700;
        letter-spacing: 0.02em;
        color: #fff;
      }
      #${PANEL_ID} .porna91-brand-text span {
        font-size: 11px;
        color: var(--p91-muted);
      }
      #${PANEL_ID} .porna91-hd-actions {
        display: flex;
        align-items: center;
        gap: 6px;
        flex-shrink: 0;
      }
      #${PANEL_ID} .porna91-icon-btn {
        width: 30px;
        height: 30px;
        min-width: 30px;
        min-height: 30px;
        border: 1px solid rgba(255,255,255,0.08);
        border-radius: 10px;
        background: rgba(255,255,255,0.04);
        color: #f0e8e4;
        display: inline-grid;
        place-items: center;
        cursor: pointer;
        padding: 0;
        transition: background 0.15s ease, border-color 0.15s ease, transform 0.15s ease;
        -webkit-user-select: none;
        user-select: none;
      }
      #${PANEL_ID}.is-mobile .porna91-icon-btn {
        width: 42px;
        height: 42px;
        min-width: 42px;
        min-height: 42px;
        border-radius: 12px;
      }
      #${PANEL_ID}.is-mobile .porna91-icon-btn svg { width: 18px; height: 18px; }
      #${PANEL_ID} .porna91-icon-btn svg { width: 15px; height: 15px; }
      #${PANEL_ID} .porna91-icon-btn:hover {
        background: rgba(255,255,255,0.1);
        border-color: rgba(255,255,255,0.16);
      }
      #${PANEL_ID} .porna91-icon-btn:active { transform: scale(0.94); }
      #${PANEL_ID} .porna91-icon-btn.is-spinning svg {
        animation: porna91-spin 0.7s linear;
      }

      #${PANEL_ID} .porna91-bd {
        padding: 14px;
        display: flex;
        flex-direction: column;
        gap: 12px;
      }

      #${PANEL_ID} .porna91-status-row {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: 8px;
      }
      #${PANEL_ID} .porna91-badge {
        display: inline-flex;
        align-items: center;
        gap: 7px;
        padding: 4px 10px 4px 8px;
        border-radius: 999px;
        font-size: 11px;
        font-weight: 600;
        letter-spacing: 0.02em;
        background: rgba(255,255,255,0.05);
        border: 1px solid rgba(255,255,255,0.08);
        color: var(--p91-muted);
      }
      #${PANEL_ID} .porna91-dot {
        width: 7px;
        height: 7px;
        border-radius: 50%;
        background: var(--p91-faint);
        box-shadow: 0 0 0 3px rgba(255,255,255,0.04);
      }
      #${PANEL_ID}[data-state="ready"] .porna91-dot { background: var(--p91-ok); box-shadow: 0 0 0 3px rgba(61,220,151,0.15); }
      #${PANEL_ID}[data-state="wait"] .porna91-dot { background: var(--p91-warn); animation: porna91-pulse 1.4s ease infinite; }
      #${PANEL_ID}[data-state="busy"] .porna91-dot { background: var(--p91-accent); animation: porna91-pulse 1s ease infinite; }
      #${PANEL_ID}[data-state="ok"] .porna91-dot { background: var(--p91-ok); }
      #${PANEL_ID}[data-state="err"] .porna91-dot { background: var(--p91-err); }
      #${PANEL_ID}[data-state="ready"] .porna91-badge { color: #c9f7e2; border-color: rgba(61,220,151,0.22); background: rgba(61,220,151,0.08); }
      #${PANEL_ID}[data-state="wait"] .porna91-badge { color: #ffe7a3; border-color: rgba(245,197,66,0.22); background: rgba(245,197,66,0.08); }
      #${PANEL_ID}[data-state="busy"] .porna91-badge { color: #ffd0da; border-color: rgba(255,77,109,0.25); background: rgba(255,77,109,0.1); }
      #${PANEL_ID}[data-state="ok"] .porna91-badge { color: #c9f7e2; border-color: rgba(61,220,151,0.22); background: rgba(61,220,151,0.08); }
      #${PANEL_ID}[data-state="err"] .porna91-badge { color: #ffc9c9; border-color: rgba(255,107,107,0.25); background: rgba(255,107,107,0.1); }
      #${PANEL_ID} .porna91-vid {
        font-size: 11px;
        color: var(--p91-faint);
        font-variant-numeric: tabular-nums;
      }

      #${PANEL_ID} .porna91-title {
        margin: 0;
        font-size: 14px;
        font-weight: 650;
        color: #fff;
        letter-spacing: 0.01em;
        display: -webkit-box;
        -webkit-line-clamp: 2;
        -webkit-box-orient: vertical;
        overflow: hidden;
        line-height: 1.4;
        min-height: 1.4em;
      }

      #${PANEL_ID} .porna91-stream {
        display: grid;
        grid-template-columns: auto 1fr auto;
        gap: 8px;
        align-items: center;
        padding: 9px 10px;
        border-radius: 12px;
        background: rgba(0, 0, 0, 0.35);
        border: 1px solid rgba(255,255,255,0.06);
      }
      #${PANEL_ID} .porna91-stream-tag {
        font-size: 10px;
        font-weight: 700;
        letter-spacing: 0.08em;
        text-transform: uppercase;
        color: #ffb4c0;
        background: rgba(255, 77, 109, 0.14);
        border: 1px solid rgba(255, 77, 109, 0.22);
        border-radius: 7px;
        padding: 3px 7px;
        white-space: nowrap;
      }
      #${PANEL_ID} .porna91-url {
        font-size: 11px;
        color: var(--p91-muted);
        overflow: hidden;
        text-overflow: ellipsis;
        white-space: nowrap;
        font-family: ui-monospace, "SF Mono", Consolas, "Courier New", monospace;
      }
      #${PANEL_ID} .porna91-stream .porna91-icon-btn {
        width: 28px;
        height: 28px;
        border-radius: 8px;
      }

      #${PANEL_ID} .porna91-actions {
        display: grid;
        grid-template-columns: 1.35fr 1fr 1fr;
        gap: 8px;
      }
      #${PANEL_ID} .porna91-btn {
        appearance: none;
        -webkit-appearance: none;
        border: 0;
        border-radius: 12px;
        padding: 10px 8px;
        cursor: pointer;
        display: inline-flex;
        align-items: center;
        justify-content: center;
        gap: 6px;
        font-size: 12px;
        font-weight: 650;
        letter-spacing: 0.01em;
        color: #fff;
        transition: transform 0.15s ease, filter 0.15s ease, box-shadow 0.15s ease, opacity 0.15s ease;
        min-height: 40px;
        -webkit-user-select: none;
        user-select: none;
      }
      #${PANEL_ID}.is-mobile .porna91-btn {
        min-height: 48px;
        font-size: 14px;
        border-radius: 14px;
        padding: 12px 10px;
      }
      #${PANEL_ID} .porna91-btn svg { width: 15px; height: 15px; flex-shrink: 0; }
      #${PANEL_ID} .porna91-btn:hover { filter: brightness(1.08); }
      #${PANEL_ID} .porna91-btn:active { transform: translateY(1px) scale(0.98); }
      #${PANEL_ID} .porna91-btn:disabled {
        opacity: 0.42;
        cursor: not-allowed;
        filter: grayscale(0.25);
        transform: none;
        box-shadow: none;
      }
      #${PANEL_ID} .porna91-btn-primary {
        background: linear-gradient(135deg, #ff5a7a 0%, #e11d48 48%, #ff8f5a 160%);
        box-shadow: 0 10px 22px rgba(225, 29, 72, 0.32), inset 0 1px 0 rgba(255,255,255,0.22);
      }
      #${PANEL_ID} .porna91-btn-ghost {
        background: rgba(255,255,255,0.05);
        border: 1px solid rgba(255,255,255,0.08);
        color: #f2ebe7;
      }
      #${PANEL_ID} .porna91-btn-ghost:hover {
        background: rgba(255,255,255,0.09);
        border-color: rgba(255,255,255,0.14);
      }
      #${PANEL_ID} .porna91-btn-stop {
        width: 100%;
        background: linear-gradient(135deg, #3a1a1a, #5c1d1d);
        border: 1px solid rgba(255, 107, 107, 0.28);
        color: #ffd4d4;
        display: none;
      }
      #${PANEL_ID}.is-busy .porna91-btn-stop { display: inline-flex; }
      #${PANEL_ID}.is-busy .porna91-actions { display: none; }

      #${PANEL_ID} .porna91-progress-wrap {
        display: grid;
        gap: 7px;
      }
      #${PANEL_ID} .porna91-progress-meta {
        display: flex;
        justify-content: space-between;
        align-items: baseline;
        gap: 8px;
        font-size: 11px;
        color: var(--p91-muted);
      }
      #${PANEL_ID} .porna91-pct {
        font-variant-numeric: tabular-nums;
        font-weight: 700;
        color: #ffd0da;
      }
      #${PANEL_ID} .porna91-prog {
        height: 8px;
        border-radius: 99px;
        background: rgba(255,255,255,0.06);
        overflow: hidden;
        border: 1px solid rgba(255,255,255,0.04);
      }
      #${PANEL_ID} .porna91-prog > i {
        display: block;
        height: 100%;
        width: 0%;
        border-radius: inherit;
        background: linear-gradient(90deg, #ff8f5a, #ff4d6d, #ff8f5a);
        background-size: 200% 100%;
        box-shadow: 0 0 12px rgba(255, 77, 109, 0.45);
        transition: width 0.18s linear;
      }
      #${PANEL_ID}.is-busy .porna91-prog > i {
        animation: porna91-shimmer 1.2s linear infinite;
      }
      #${PANEL_ID} .porna91-status {
        font-size: 12px;
        color: var(--p91-muted);
        min-height: 1.35em;
        word-break: break-word;
      }
      #${PANEL_ID}[data-state="ok"] .porna91-status { color: #b8f5d8; }
      #${PANEL_ID}[data-state="err"] .porna91-status { color: #ffb4b4; }
      #${PANEL_ID}[data-state="busy"] .porna91-status { color: #ffd0da; }

      #${PANEL_ID} .porna91-foot {
        display: flex;
        align-items: center;
        justify-content: space-between;
        gap: 8px;
        padding-top: 2px;
        border-top: 1px solid rgba(255,255,255,0.05);
      }
      #${PANEL_ID} .porna91-tip {
        font-size: 11px;
        color: var(--p91-faint);
        line-height: 1.35;
      }
      #${PANEL_ID} .porna91-link-btn {
        border: 0;
        background: transparent;
        color: #ffb4c0;
        font-size: 11px;
        font-weight: 600;
        cursor: pointer;
        padding: 4px 0;
        white-space: nowrap;
        display: inline-flex;
        align-items: center;
        gap: 4px;
      }
      #${PANEL_ID} .porna91-link-btn svg { width: 12px; height: 12px; }
      #${PANEL_ID} .porna91-link-btn:hover { color: #ffd0da; text-decoration: underline; }
      #${PANEL_ID} .porna91-link-btn:disabled,
      #${PANEL_ID} .porna91-icon-btn:disabled {
        opacity: 0.35;
        cursor: not-allowed;
        pointer-events: none;
      }

      @media (max-width: 480px), (pointer: coarse) {
        #${PANEL_ID}:not(.porna91-collapsed) {
          left: max(10px, env(safe-area-inset-left, 0px));
          right: max(10px, env(safe-area-inset-right, 0px));
          width: auto;
          bottom: calc(8px + env(safe-area-inset-bottom, 0px));
          border-radius: 18px 18px 14px 14px;
        }
        #${PANEL_ID} .porna91-actions {
          grid-template-columns: 1fr;
        }
        #${PANEL_ID} .porna91-btn { min-height: 48px; font-size: 14px; }
        #${PANEL_ID} .porna91-hd {
          padding: 12px 12px 10px;
          /* 便于手指拖动 */
          min-height: 56px;
        }
        #${PANEL_ID} .porna91-stream {
          grid-template-columns: auto 1fr 42px;
          padding: 10px;
        }
        #${PANEL_ID} .porna91-foot {
          flex-wrap: wrap;
          gap: 6px;
        }
        #${PANEL_ID} .porna91-tip {
          font-size: 12px;
          flex: 1 1 100%;
        }
        #${PANEL_ID} .porna91-link-btn {
          min-height: 40px;
          padding: 8px 4px;
          font-size: 13px;
        }
      }
      @media (prefers-reduced-motion: reduce) {
        #${PANEL_ID},
        #${PANEL_ID} .porna91-prog > i,
        #${PANEL_ID} .porna91-dot,
        #${PANEL_ID} .porna91-icon-btn.is-spinning svg {
          animation: none !important;
          transition: none !important;
        }
      }
    `;
  }

  function ensurePanel() {
    if (document.getElementById(PANEL_ID)) return document.getElementById(PANEL_ID);
    if (!document.body) return null;

    const box = document.createElement('div');
    box.id = PANEL_ID;
    box.dataset.state = 'wait';
    if (IS_MOBILE) {
      box.classList.add('is-mobile', 'porna91-sheet', 'porna91-collapsed');
    }
    const sub = IS_MOBILE ? '点此展开 · 手机版' : '去广告 · HLS 直下';
    const tip = IS_MOBILE
      ? '手机可下载/分享 .ts；不行就复制 m3u8 到双开下载器'
      : '浏览器内 AES 解密合并，可用播放器直接打开 .ts';
    box.innerHTML = `
      <div class="porna91-hd" data-drag="1">
        <div class="porna91-brand">
          <div class="porna91-logo">${ICONS.logo}</div>
          <div class="porna91-brand-text">
            <strong>91 下载面板</strong>
            <span>${sub}</span>
          </div>
        </div>
        <div class="porna91-hd-actions">
          <button type="button" class="porna91-icon-btn" data-act="refresh" title="重新探测流地址" aria-label="刷新">${ICONS.refresh}</button>
          <button type="button" class="porna91-icon-btn" data-act="collapse" title="${IS_MOBILE ? '展开面板' : '折叠/展开'}" aria-label="折叠">${IS_MOBILE ? ICONS.plus : ICONS.minus}</button>
        </div>
      </div>
      <div class="porna91-bd">
        <div class="porna91-status-row">
          <div class="porna91-badge"><i class="porna91-dot" data-el="dot"></i><span data-el="badge">探测中</span></div>
          <div class="porna91-vid" data-el="vid"></div>
        </div>
        <h3 class="porna91-title" data-el="title">等待视频页…</h3>
        <div class="porna91-stream">
          <span class="porna91-stream-tag">M3U8</span>
          <div class="porna91-url" data-el="url" title="">尚未捕获到流地址</div>
          <button type="button" class="porna91-icon-btn" data-act="copy" title="复制 m3u8" aria-label="复制流地址">${ICONS.copy}</button>
        </div>
        <div class="porna91-actions">
          <button type="button" class="porna91-btn porna91-btn-primary" data-act="download">${ICONS.download}<span>${IS_MOBILE ? '下载 / 分享' : '下载 TS'}</span></button>
          <button type="button" class="porna91-btn porna91-btn-ghost" data-act="open">${ICONS.open}<span>打开</span></button>
          <button type="button" class="porna91-btn porna91-btn-ghost" data-act="copy-page">${ICONS.link}<span>页面</span></button>
        </div>
        <button type="button" class="porna91-btn porna91-btn-stop" data-act="stop" data-el="stop-btn">${ICONS.stop}<span>停止下载</span></button>
        <div class="porna91-progress-wrap">
          <div class="porna91-progress-meta">
            <span data-el="status">就绪</span>
            <span class="porna91-pct" data-el="pct">0%</span>
          </div>
          <div class="porna91-prog"><i data-el="bar"></i></div>
        </div>
        <div class="porna91-foot">
          <div class="porna91-tip">${tip}</div>
          <button type="button" class="porna91-link-btn" data-act="copy" title="复制完整 m3u8">${ICONS.copy}<span>复制流</span></button>
        </div>
      </div>
    `;
    document.body.appendChild(box);
    bindPanel(box);
    makeDraggable(box, box.querySelector('[data-drag]'));
    updatePanelInfo();
    return box;
  }

  function qs(root, sel) {
    return root.querySelector(sel);
  }

  function setPanelState(mode) {
    const panel = document.getElementById(PANEL_ID);
    if (!panel) return;
    const map = {
      wait: '探测中',
      ready: '可下载',
      busy: '下载中',
      ok: '已完成',
      err: '出错',
      idle: '待命',
    };
    const key = mode || (state.m3u8 ? 'ready' : isDetailPage() ? 'wait' : 'idle');
    panel.dataset.state = key === 'idle' ? 'wait' : key;
    panel.classList.toggle('is-busy', key === 'busy');
    const badge = qs(panel, '[data-el="badge"]');
    if (badge) badge.textContent = map[key] || map.wait;
  }

  function setStatus(text, mode) {
    const panel = document.getElementById(PANEL_ID);
    if (!panel) return;
    const el = qs(panel, '[data-el="status"]');
    if (el) el.textContent = text || '';
    if (mode) setPanelState(mode);
  }

  function setProgress(pct) {
    const panel = document.getElementById(PANEL_ID);
    if (!panel) return;
    const val = Math.max(0, Math.min(100, pct || 0));
    const bar = qs(panel, '[data-el="bar"]');
    const label = qs(panel, '[data-el="pct"]');
    if (bar) bar.style.width = val + '%';
    if (label) label.textContent = Math.round(val) + '%';
  }

  function shortUrl(url) {
    if (!url) return '';
    try {
      const u = new URL(url);
      const path = u.pathname.split('/').filter(Boolean).slice(-2).join('/') || u.pathname;
      return u.hostname.replace(/^www\./, '') + '/' + path + (u.search ? '…' : '');
    } catch (_) {
      return String(url).slice(0, 64);
    }
  }

  function updatePanelInfo() {
    const panel = document.getElementById(PANEL_ID);
    if (!panel) return;
    if (!state.title) state.title = readPageTitle();
    const t = qs(panel, '[data-el="title"]');
    const u = qs(panel, '[data-el="url"]');
    const vid = qs(panel, '[data-el="vid"]');
    const titleText = state.title || (isDetailPage() ? '视频详情页' : '请先打开视频详情页');
    if (t) {
      t.textContent = titleText;
      t.title = titleText;
    }
    if (u) {
      if (state.m3u8) {
        u.textContent = shortUrl(state.m3u8);
        u.title = state.m3u8;
      } else {
        u.textContent = isDetailPage() ? '等待播放器加载流地址…' : '进入详情页后自动捕获';
        u.title = '';
      }
    }
    if (vid) vid.textContent = state.videoId ? '#' + state.videoId : '';
    const dl = qs(panel, '[data-act="download"]');
    if (dl) dl.disabled = !state.m3u8 || state.downloading;
    panel.querySelectorAll('[data-act="copy"], [data-act="open"]').forEach((btn) => {
      btn.disabled = !state.m3u8 || state.downloading;
    });
    if (!state.downloading) {
      setPanelState(state.m3u8 ? 'ready' : isDetailPage() ? 'wait' : 'idle');
    }
  }

  function bindPanel(panel) {
    // 折叠胶囊：点整块展开（拖拽后不触发）
    panel.addEventListener('click', (e) => {
      if (!panel.classList.contains('porna91-collapsed')) return;
      if (panel.dataset.porna91Dragged === '1') return;
      if (e.target && e.target.closest && e.target.closest('[data-act="collapse"]')) return;
      if (e.target && e.target.closest && e.target.closest('[data-act="refresh"]')) return;
      const btn = panel.querySelector('[data-act="collapse"]');
      if (btn) btn.click();
    });

    panel.addEventListener('click', async (e) => {
      const btn = e.target && e.target.closest && e.target.closest('[data-act]');
      if (!btn || btn.disabled) return;
      if (panel.dataset.porna91Dragged === '1') return;
      e.preventDefault();
      e.stopPropagation();
      const act = btn.getAttribute('data-act');
      if (act === 'collapse') {
        const collapsed = panel.classList.toggle('porna91-collapsed');
        if (IS_MOBILE) {
          panel.classList.toggle('porna91-sheet', !collapsed);
          if (!collapsed) {
            panel.style.left = '';
            panel.style.right = '';
            panel.style.top = '';
            panel.style.bottom = '';
          }
        }
        btn.innerHTML = collapsed ? ICONS.plus : ICONS.minus;
        btn.title = collapsed ? '展开面板' : '折叠面板';
        btn.setAttribute('aria-label', collapsed ? '展开' : '折叠');
        return;
      }
      if (act === 'refresh') {
        btn.classList.add('is-spinning');
        setTimeout(() => btn.classList.remove('is-spinning'), 700);
        probeFromPage();
        updatePanelInfo();
        setStatus(
          state.m3u8 ? '已刷新流地址' : '仍未捕获到流，试着点一下播放',
          state.m3u8 ? 'ready' : 'wait'
        );
        return;
      }
      if (act === 'copy') {
        if (!state.m3u8) return setStatus('没有可复制的 m3u8', 'err');
        const ok = await copyText(state.m3u8);
        setStatus(ok ? 'm3u8 已复制到剪贴板' : '复制失败，请手动选择', ok ? 'ok' : 'err');
        return;
      }
      if (act === 'copy-page') {
        const ok = await copyText(location.href);
        setStatus(ok ? '页面链接已复制' : '复制失败', ok ? 'ok' : 'err');
        return;
      }
      if (act === 'open') {
        if (!state.m3u8) return setStatus('没有 m3u8', 'err');
        window.open(state.m3u8, '_blank', 'noopener');
        setStatus('已在新标签打开 m3u8', 'ok');
        return;
      }
      if (act === 'stop') {
        if (state.abort) state.abort.abort();
        setStatus('已请求停止', 'wait');
        return;
      }
      if (act === 'download') {
        startDownload();
      }
    });
  }

  function makeDraggable(box, handle) {
    if (!handle) return;
    let ox = 0;
    let oy = 0;
    let sx = 0;
    let sy = 0;
    let dragging = false;
    let moved = false;
    let pid = null;

    const onDown = (e) => {
      if (e.pointerType === 'mouse' && e.button !== 0) return;
      if (e.target && e.target.closest && e.target.closest('button, a, input')) return;
      // 手机展开态底部 sheet 不拖，避免和内部滚动冲突；折叠 FAB 可拖
      if (IS_MOBILE && !box.classList.contains('porna91-collapsed') && box.classList.contains('porna91-sheet')) {
        return;
      }
      dragging = true;
      moved = false;
      pid = e.pointerId;
      try {
        handle.setPointerCapture(pid);
      } catch (_) {}
      box.classList.add('is-dragging');
      const rect = box.getBoundingClientRect();
      ox = rect.left;
      oy = rect.top;
      sx = e.clientX;
      sy = e.clientY;
      box.style.left = ox + 'px';
      box.style.top = oy + 'px';
      box.style.right = 'auto';
      box.style.bottom = 'auto';
      if (e.cancelable) e.preventDefault();
    };

    const onMove = (e) => {
      if (!dragging) return;
      if (pid != null && e.pointerId !== pid) return;
      const dx = e.clientX - sx;
      const dy = e.clientY - sy;
      if (Math.abs(dx) + Math.abs(dy) > 6) moved = true;
      const margin = IS_MOBILE ? 8 : 0;
      const maxX = Math.max(margin, window.innerWidth - box.offsetWidth - margin);
      const maxY = Math.max(margin, window.innerHeight - Math.min(box.offsetHeight, 56) - margin);
      box.style.left = Math.min(maxX, Math.max(margin, ox + dx)) + 'px';
      box.style.top = Math.min(maxY, Math.max(margin, oy + dy)) + 'px';
      if (e.cancelable) e.preventDefault();
    };

    const onUp = (e) => {
      if (!dragging) return;
      if (pid != null && e.pointerId !== pid) return;
      dragging = false;
      box.classList.remove('is-dragging');
      try {
        if (pid != null) handle.releasePointerCapture(pid);
      } catch (_) {}
      pid = null;
      // 拖过则吞掉随后的 click，避免误展开/折叠
      if (moved) {
        box.dataset.porna91Dragged = '1';
        setTimeout(() => {
          try {
            delete box.dataset.porna91Dragged;
          } catch (_) {}
        }, 350);
      }
    };

    handle.style.touchAction = 'none';
    handle.addEventListener('pointerdown', onDown, { passive: false });
    handle.addEventListener('pointermove', onMove, { passive: false });
    handle.addEventListener('pointerup', onUp);
    handle.addEventListener('pointercancel', onUp);
  }

  async function startDownload() {
    if (!state.m3u8) {
      setStatus('尚未捕获 m3u8，请先播放视频', 'err');
      return;
    }
    if (state.downloading) return;
    state.downloading = true;
    state.abort = typeof AbortController !== 'undefined' ? new AbortController() : null;
    updatePanelInfo();
    setPanelState('busy');
    setProgress(0);
    setStatus(IS_MOBILE ? '手机下载中，请保持页面打开…' : '开始下载…', 'busy');
    try {
      const blob = await downloadHls(state.m3u8, {
        signal: state.abort ? state.abort.signal : undefined,
        onProgress: ({ done, total, bytes }) => {
          const pct = total ? (done / total) * 100 : 0;
          setProgress(pct);
          setStatus(`下载中 ${done}/${total} · ${formatBytes(bytes)}`, 'busy');
        },
      });
      const name = sanitizeFilename(state.title || state.videoId || '91porna') + '.ts';
      const mode = await triggerBlobDownload(blob, name);
      setProgress(100);
      if (mode === 'share') {
        setStatus('已调起系统分享（' + formatBytes(blob.size) + '）', 'ok');
      } else if (mode === 'share-cancel') {
        setStatus('已取消分享，文件仍可通过下载入口获取', 'wait');
      } else {
        setStatus(
          IS_MOBILE
            ? '完成 ' + name + '（' + formatBytes(blob.size) + '）。若未保存请看新标签页长按文件'
            : '完成 ' + name + '（' + formatBytes(blob.size) + '）',
          'ok'
        );
      }
    } catch (e) {
      if (e && e.name === 'AbortError') setStatus('已取消下载', 'wait');
      else {
        setStatus('失败：' + (e && e.message ? e.message : String(e)), 'err');
        if (IS_MOBILE && state.m3u8) {
          // 内存不足等场景：引导复制流
          setTimeout(() => {
            setStatus('可改用「复制流」到 nPlayer / 双开 / Documents 下载', 'wait');
          }, 2500);
        }
      }
      log('download failed', e);
    } finally {
      state.downloading = false;
      state.abort = null;
      updatePanelInfo();
    }
  }

  function probeFromPage() {
    try {
      stripPlayerAdsAttr();
      const mse = document.getElementById('mse');
      if (mse) {
        if (mse.dataset.video_title) state.title = mse.dataset.video_title;
        if (mse.dataset.video_id) state.videoId = mse.dataset.video_id;
      }
      // xgplayer 实例
      const p = window.__porna91_player;
      if (p) {
        try {
          if (p.config && p.config.url) captureStream(p.config.url);
          if (p.src) captureStream(String(p.src));
        } catch (_) {}
      }
      // DOM video / source
      document.querySelectorAll('video source[src], video[src]').forEach((el) => {
        const src = el.src || el.getAttribute('src') || '';
        if (isM3u8Url(src)) captureStream(src);
      });
      // 扫描 script 文本里的 m3u8（兜底）
      document.querySelectorAll('script:not([src])').forEach((s) => {
        const t = s.textContent || '';
        const m = t.match(/https?:\/\/[^\s"'\\]+\.m3u8[^\s"']*/i);
        if (m) captureStream(m[0].replace(/\\u0026/g, '&').replace(/&amp;/g, '&'));
      });
    } catch (e) {
      log('probe failed', e);
    }
  }

  // ---------- 10. 启动 ----------
  function onReady(fn) {
    if (document.readyState === 'loading') {
      document.addEventListener('DOMContentLoaded', fn, { once: true });
    } else {
      fn();
    }
  }

  try {
    neutralizeAdGlobals();
    hookCreatePlayer();
    patchElementSetters();
    patchNetwork();
    patchWindowOpen();
  } catch (e) {
    log('early patch failed', e);
  }

  injectCSS();
  if (document.documentElement) observe();
  else document.addEventListener('DOMContentLoaded', observe, { once: true });

  function patchJqueryModalWhenReady() {
    let tries = 0;
    const timer = setInterval(() => {
      tries += 1;
      try {
        const $ = window.jQuery || window.$;
        if ($ && $.fn && $.fn.modal) {
          const raw = $.fn.modal;
          $.fn.modal = function (option) {
            try {
              const el = this && this[0];
              if (
                el &&
                (el.classList.contains('ad-dialog') ||
                  el.id === 'tip_modal' ||
                  (el.querySelector && el.querySelector('[data-ad_id]')))
              ) {
                log('block jquery modal ad', el.id || el.className);
                return this;
              }
            } catch (_) {}
            return raw.apply(this, arguments);
          };
          clearInterval(timer);
        }
      } catch (_) {}
      if (tries > 40) clearInterval(timer);
    }, 250);
  }

  onReady(() => {
    injectCSS();
    sweep();
    ensurePanel();
    probeFromPage();
    patchJqueryModalWhenReady();
    // 站点 5s 后弹广告，这里持续清
    let ticks = 0;
    const timer = setInterval(() => {
      sweep();
      killPlayerAdDom();
      closeAdModals();
      probeFromPage();
      if (isDetailPage()) ensurePanel();
      ticks += 1;
      if (ticks > 60) clearInterval(timer);
    }, 500);
  });

  window.addEventListener('load', () => {
    sweep();
    ensurePanel();
    probeFromPage();
    setTimeout(sweep, 1000);
    setTimeout(sweep, 3000);
    setTimeout(sweep, 6000);
  });

  // SPA / 参数变化
  const onRoute = () => {
    state.m3u8 = '';
    state.title = '';
    setTimeout(() => {
      sweep();
      probeFromPage();
      updatePanelInfo();
      ensurePanel();
    }, 300);
  };
  const wrapHist = (type) => {
    const raw = history[type];
    if (typeof raw !== 'function') return;
    history[type] = function () {
      const ret = raw.apply(this, arguments);
      onRoute();
      return ret;
    };
  };
  wrapHist('pushState');
  wrapHist('replaceState');
  window.addEventListener('popstate', onRoute);

  // 对外调试
  try {
    window.__porna91Tools = {
      version: '1.2.0',
      mobile: IS_MOBILE,
      sweep,
      probeFromPage,
      getState: () => Object.assign({}, state, { mobile: IS_MOBILE }),
      captureStream,
    };
  } catch (_) {}

  } // end main()

  // ---------- 引导：注入页面上下文（手机插件隔离世界必需） ----------
  function injectIntoPage(fn) {
    try {
      const root = document.documentElement || document.head || document.body;
      if (!root) return false;
      const s = document.createElement('script');
      s.id = 'porna91-bridge';
      s.textContent = '(' + fn.toString() + ')();';
      root.appendChild(s);
      // 部分环境保留节点会导致重复执行风险，执行后移除
      s.remove();
      return true;
    } catch (e) {
      try {
        console.debug('[91porna-tools] inject failed', e);
      } catch (_) {}
      return false;
    }
  }

  function scheduleInject() {
    // DOM 属性锁在 main 内设置；若已跑过则跳过
    try {
      if (document.documentElement && document.documentElement.getAttribute('data-porna91') === '1') {
        return;
      }
    } catch (_) {}

    const ok = injectIntoPage(main);
    // CSP 拦截或注入失败：退回当前上下文（@grant none / @inject-into page 时通常可用）
    if (!ok) {
      try {
        main();
      } catch (e) {
        try {
          console.error('[91porna-tools] main failed', e);
        } catch (_) {}
      }
      return;
    }

    // 注入“看似成功”但实际被 CSP 吃掉：短暂后检查锁
    setTimeout(() => {
      try {
        if (document.documentElement && document.documentElement.getAttribute('data-porna91') === '1') {
          return;
        }
      } catch (_) {}
      try {
        main();
      } catch (e) {
        try {
          console.error('[91porna-tools] main fallback failed', e);
        } catch (_) {}
      }
    }, 30);
  }

  try {
    if (document.documentElement) scheduleInject();
    else {
      const mo = new MutationObserver(() => {
        if (document.documentElement) {
          mo.disconnect();
          scheduleInject();
        }
      });
      mo.observe(document, { childList: true, subtree: true });
      // 兜底
      setTimeout(() => {
        try {
          mo.disconnect();
        } catch (_) {}
        scheduleInject();
      }, 0);
    }
  } catch (_) {
    try {
      main();
    } catch (e2) {}
  }
})();
