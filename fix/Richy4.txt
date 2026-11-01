// ==UserScript==
// @name         BestJavPorn 去广告与原生播放修复
// @name:zh-CN   BestJavPorn 去广告与原生播放修复
// @namespace    bestjavporn-clean-player
// @version      2.5.0
// @description  阻止桌面与移动端外链、延迟广告和前贴片，并让完整视频覆盖原播放器区域播放。
// @author       Richy
// 网站：https://www.bestjavporn.com/
// @include      /^https?:\/\/(?:[^./]+\.)*bestjavporn\.com\/.*$/
// @include      /^blob:https?:\/\/(?:[^./]+\.)*bestjavporn\.com\/.*$/
// @run-at       document-start
// @grant        none
// @inject-into  page
// @sandbox      raw
// ==/UserScript==

(function () {
  "use strict";

  const VERSION = "2.5.0";
  const MAX_LOG_URL_LENGTH = 180;
  const MAX_AD_TEXT_LENGTH = 1200;
  const SITE_HOST_RE = /(?:^|\.)bestjavporn\.com$/i;
  const BLOCKED_HOST_RE =
    /(?:^|\.)(?:proceedflow|magsrv|whitetrafsa|xlviiirdr|sacdnssedge|mavrtracktor|godkc|marzaent|hotzcam|elastic-sync|snaptrckr|javhd-trk|tapioni|tsyndicate|stripchat|chaturbate|livejasmin|bongacams|trafficshop|trafficfactory|trafficjunky|exoclick|juicyads|faphouse4k|wotheat|viicjgxn)\./i;
  const BLOCKED_URL_RE =
    /proceedflow\.com|smartpop|popunder|trafficType=popunder|sandwichconscientiousroadside|bestjavporn\.live|\/files\/banner_|\/300x250\.html/i;
  const AD_CREATIVE_SIZE_RE =
    /(?:^|[\/_-])(?:300x250|440x250)(?=[./?&_-]|$)/i;
  const PLAYER_IFRAME_ID = "playeriframe";
  const PLAYER_SANDBOX =
    "allow-scripts allow-forms allow-pointer-lock allow-presentation";
  const PLAYER_REFERRER_POLICY = "origin";
  const PLAYER_CONTAINER_SELECTOR =
    "#video-player-area, #video-player, .responsive-player";
  const REMOVE_AD_FRAME_MESSAGE = "BJP_CLEAN_REMOVE_AD_FRAME";
  const PLAYER_AD_TEXT_RE = /(?:is\s+)?waiting\s+for\s+(?:a\s+)?reply|proceedflow\.com/i;
  const PLAYER_AD_SOURCE_RE =
    /proceedflow|magsrv|snaptrckr|tsyndicate|sacdnssedge|xlviiirdr|whitetrafsa|exoclick|juicyads|smartpop|popunder|sandwichconscientiousroadside/i;
  const PLAYER_AD_IDENTITY_RE =
    /(?:^|[\s_-])(?:ima(?:-ad)?-container|vast(?:-ad)?|video-ad|ad-overlay|ad-container|interstitial-ad|popup-ad|popunder-ad|preroll|exo-ad)(?:$|[\s_-])/i;
  const PLAYER_EXO_AD_IDENTITY_RE =
    /(?:^|[\s_-])exo-(?:sticky|(?:mobile-)?im|video(?:-slider)?|content)(?:$|[\s_-])/i;
  const PLAYER_TS_IM_AD_IDENTITY_RE =
    /(?:^|[\s_-])ts-im-(?:container|video|video-wrapper|ad-link|button(?:-close|-close-delay|-cta-wrapper)?)(?:$|[\s_-])/i;
  const PLAYER_AD_REMOVAL_CONTAINER_SELECTOR = [
    "#vast-pre",
    '[id^="exo-sticky-container-"]',
    '[id*="exo-im-container-wrapper"]',
    '[id*="exo-mobile-im-container-wrapper"]',
    ".exo-video-slider-container-wrapper",
    ".ts-im-container",
  ].join(",");
  const PLAYER_PRIMARY_VIDEO_RE =
    /(?:^|[\s_-])(?:vjs-tech|jw-video|html5-main-video|plyr__video|fp-engine)(?:$|[\s_-])/i;
  const PLAYER_AD_UI_SELECTOR = [
    ".ima-ad-container",
    ".ima-container",
    ".jw-ad",
    ".jw-ad-container",
    ".jw-ad-media",
    ".jwplayer.jw-flag-ads .jw-skip",
    ".vjs-ad-playing",
    ".vjs-ad-loading",
    ".vast-ad",
    ".video-ad",
    ".ad-overlay",
    "[class*='preroll']",
    "[id*='preroll']",
  ].join(",");
  const PLAYER_ACTIVE_AD_SELECTOR = [
    ".vjs-ad-playing",
    ".jw-flag-ads",
    ".jw-ad",
    "[class*='preroll']",
    "[id*='preroll']",
  ].join(",");
  const PLAYER_SKIP_CONTROL_SELECTOR = [
    ".ima-ad-skip-button",
    ".videoAdUiSkipButton",
    ".jw-skip",
    ".jw-skip-button",
    "[class*='jw-skip']",
    ".vjs-ad-skip-button",
    "[class*='skip'][class*='ad']",
    "[id*='skip'][id*='ad']",
  ].join(",");
  const PLAYER_JW_AD_SELECTOR =
    ".jw-flag-ads, .jw-ad, .jw-ad-container, .jw-ad-media";
  const PLAYER_JW_PRESERVE_SELECTOR = [
    ".jwplayer.jw-flag-ads",
    ".jw-ad",
    ".jw-ad-container",
    ".jw-ad-media",
    ".jw-skip",
    "video.jw-video",
    "video.jw-video source",
  ].join(",");
  const PLAYER_SKIP_CONTEXT_SELECTOR = [
    ".jwplayer",
    PLAYER_JW_AD_SELECTOR,
    ".ima-ad-container",
    ".ima-container",
    ".vjs-ad-playing",
    ".vast-ad",
    ".video-ad",
    ".ad-overlay",
    "[class*='preroll']",
    "[id*='preroll']",
  ].join(",");
  const SKIP_AD_TEXT_RE = /(?:skip\s+(?:this\s+)?ad|跳过广告|关闭广告)/i;
  const CHILD_AD_STYLE_SELECTOR = [
    PLAYER_AD_REMOVAL_CONTAINER_SELECTOR,
    "iframe",
    ".ima-ad-container",
    ".ima-container",
    ".vast-ad",
    ".video-ad",
    ".ad-overlay",
    ".jw-ad-container",
    ".jw-ad-media",
    ".jwplayer.jw-flag-ads .jw-skip",
    ".ts-im-video-wrapper",
    ".ts-im-video",
    ".ts-im-ad-link",
    ".ts-im-button-close",
    ".ts-im-button-close-delay",
    ".ts-im-button-cta-wrapper",
    'video[id^="exo-video-"]',
  ].join(",");
  const AD_END_EPSILON_SECONDS = 0.01;
  const AD_SEEK_TOLERANCE_SECONDS = 0.25;
  const AD_FAST_PLAYBACK_RATE = 16;
  const MAX_SKIP_LABEL_LENGTH = 80;
  const PLAYER_OVERLAY_Z_INDEX = 2147483645;
  const PLAYER_ASPECT_RATIO_PROPERTY = "--bjp-player-aspect-ratio";
  const PLAYER_MARKUP_RE =
    /<iframe\b[^>]*(?:playeriframe|src\s*=\s*["']?blob:)/i;
  const PLAYER_TARGET_SELECTOR = ".play-button";
  const EARLY_INPUT_EVENTS = Object.freeze([
    "pointerdown",
    "mousedown",
    "touchstart",
    "pointerup",
    "mouseup",
    "touchend",
    "auxclick",
  ]);
  const PLAYER_MEDIA_EVENTS = Object.freeze([
    "loadstart",
    "loadedmetadata",
    "durationchange",
    "canplay",
    "playing",
  ]);
  const JW_AD_END_EVENTS = Object.freeze([
    "adComplete",
    "adSkipped",
    "adError",
    "adBreakEnd",
  ]);
  const AD_CONTAINER_SELECTOR = [
    ".happy-under-player",
    ".happy-under-player-mobile",
    ".happy-inside-player",
    ".mobile-ad-nav",
    ".mobile-ad-item",
    ".sidebar-ads",
    ".player-ads",
    ".video-ads",
    ".under-player-ads",
    ".ads-player",
    "#player-ads",
    "ins.adsbygoogle",
    "[data-ad]",
    "[data-ad-client]",
    'iframe[width="1"][height="1"]',
    'iframe[src*="bestjavporn.live"]',
    'iframe[src*="whitetrafsa"]',
    'iframe[src*="javhd-trk"]',
    'iframe[src*="magsrv"]',
    'iframe[src*="snaptrckr"]',
    'iframe[src*="pornfhd.com/files/banner"]',
    'iframe[srcdoc*="snaptrckr"]',
    '[id^="exo-sticky-container-"]',
    '[id*="exo-im-container-wrapper"]',
    '[id*="exo-mobile-im-container-wrapper"]',
    'video[id^="exo-video-"]',
    ".exo-sticky-close-button",
    ".exo-content-wrapper",
    ".exo-video-slider-container-wrapper",
    ".ts-im-container",
    ".ts-im-video-wrapper",
    ".ts-im-video",
    ".ts-im-ad-link",
    ".ts-im-button-close",
    ".ts-im-button-close-delay",
    ".ts-im-button-cta-wrapper",
  ].join(",");
  const AD_CANDIDATE_SELECTOR = [
    AD_CONTAINER_SELECTOR,
    "script[src]",
    "iframe",
    "a[href]",
  ].join(",");
  const FLOAT_CSS = `
    .bjp-player-anchor {
      position: relative !important;
      aspect-ratio: var(--bjp-player-aspect-ratio) !important;
      overflow: hidden !important;
    }

    #playeriframe.bjp-floating-player {
      position: absolute !important;
      inset: 0 !important;
      width: 100% !important;
      height: 100% !important;
      min-width: 0 !important;
      min-height: 0 !important;
      max-width: none !important;
      max-height: none !important;
      margin: 0 !important;
      padding: 0 !important;
      border: 0 !important;
      box-sizing: border-box !important;
      display: block !important;
      z-index: ${PLAYER_OVERLAY_Z_INDEX} !important;
    }
  `;

  const isTopLevelWindow = window.top === window.self;
  if (window.__BJP_CLEAN_BOOT__) {
    console.info("[BJP-CLEAN] 跳过重复注入", window.__BJP_CLEAN_BOOT__);
    return;
  }
  Object.defineProperty(window, "__BJP_CLEAN_BOOT__", {
    value: VERSION,
    writable: false,
    configurable: false,
  });

  let state = Object.freeze({
    blockedPopups: 0,
    blockedNavigations: 0,
    removedAds: 0,
    protectedPlayerClicks: 0,
    floatingActivations: 0,
    floatingRestores: 0,
    securedPlayerFrames: 0,
    blockedSandboxChanges: 0,
    skippedVideoAds: 0,
    errors: 0,
  });
  let floatState = Object.freeze({
    iframe: null,
    anchor: null,
    active: false,
  });
  const securedPlayerIframes = new WeakSet();
  const protectedIframeNavigations = new WeakSet();
  const knownAdMedia = new WeakSet();
  const handledSkipControls = new WeakSet();
  const knownSkipControls = new WeakSet();
  const finishingAdVideos = new WeakSet();
  const preservedJwAdTrees = new WeakSet();
  const adMediaPlaybackStates = new WeakMap();
  const reportedAdSources = new WeakMap();
  const nativeSetAttribute = Element.prototype.setAttribute;
  const nativeRemoveAttribute = Element.prototype.removeAttribute;
  const nativeInnerHtmlDescriptor = Object.getOwnPropertyDescriptor(
    Element.prototype,
    "innerHTML",
  );
  let childAdDocumentReported = false;
  let skipControlRetryScheduled = false;
  const jwAdPlayers = new WeakMap();
  let primaryPlayerVideo = null;

  function log(event, detail) {
    console.info("[BJP-CLEAN]", event, detail ?? "");
  }

  function increment(field, event, detail) {
    state = Object.freeze({ ...state, [field]: state[field] + 1 });
    log(event, detail);
  }

  function recordError(context, error) {
    state = Object.freeze({ ...state, errors: state.errors + 1 });
    console.error(`[BJP-CLEAN] ${context}`, error);
  }

  function runAtDomReady(callback) {
    if (document.readyState !== "loading") {
      callback();
      return;
    }
    document.addEventListener("DOMContentLoaded", callback, { once: true });
  }

  if (isTopLevelWindow && !SITE_HOST_RE.test(location.hostname)) {
    log("已跳过非站点顶层页面", location.hostname);
    return;
  }

  if (!isTopLevelWindow) {
    installChildFrameProtection();
    log("播放器子帧保护已启动", {
      version: VERSION,
      url: location.href.slice(0, MAX_LOG_URL_LENGTH),
    });
    return;
  }

  function parseUrl(rawUrl) {
    if (typeof rawUrl !== "string" || rawUrl.trim() === "") return null;
    try {
      return new URL(rawUrl, location.href);
    } catch (error) {
      console.warn("[BJP-CLEAN] 无法解析 URL", rawUrl, error);
      return null;
    }
  }

  function isBlockedUrl(rawUrl) {
    const url = parseUrl(rawUrl);
    if (!url) return false;
    if (["blob:", "about:", "data:"].includes(url.protocol)) return false;
    if (SITE_HOST_RE.test(url.hostname)) return false;
    return (
      BLOCKED_HOST_RE.test(url.hostname) ||
      BLOCKED_URL_RE.test(url.href) ||
      AD_CREATIVE_SIZE_RE.test(url.href)
    );
  }

  function readPlayerAdUrls(element) {
    const sources = [
      element.getAttribute("src"),
      element.getAttribute("href"),
      element.getAttribute("srcdoc"),
      element.getAttribute("data-src"),
      element.currentSrc,
    ];
    if (element.tagName === "VIDEO" || element.tagName === "AUDIO") {
      for (const source of element.querySelectorAll("source[src]")) {
        sources.push(source.getAttribute("src"));
      }
    }
    return sources.filter(Boolean);
  }

  function readPlayerAdSource(element) {
    return readPlayerAdUrls(element).join(" ");
  }

  function isAdMediaSource(rawUrl) {
    if (typeof rawUrl !== "string" || !rawUrl) return false;
    return PLAYER_AD_SOURCE_RE.test(rawUrl) || isBlockedUrl(rawUrl);
  }

  function readElementIdentity(element) {
    return `${element?.id || ""} ${element?.className || ""}`;
  }

  function hasExplicitAdIdentity(element) {
    const identity = readElementIdentity(element);
    return (
      PLAYER_EXO_AD_IDENTITY_RE.test(identity) ||
      PLAYER_TS_IM_AD_IDENTITY_RE.test(identity) ||
      PLAYER_AD_IDENTITY_RE.test(identity)
    );
  }

  function hasPrimaryVideoIdentity(video) {
    return PLAYER_PRIMARY_VIDEO_RE.test(readElementIdentity(video));
  }

  function isKnownAdVideo(video) {
    if (video?.tagName !== "VIDEO") return false;
    if (knownAdMedia.has(video) || hasExplicitAdIdentity(video)) return true;
    for (const source of video.querySelectorAll("source")) {
      if (knownAdMedia.has(source)) return true;
    }
    return readPlayerAdUrls(video).some(isAdMediaSource);
  }

  function videoRenderArea(video) {
    const rect = video.getBoundingClientRect();
    return Math.max(0, rect.width) * Math.max(0, rect.height);
  }

  function selectLargestVideo(videos) {
    return videos.reduce((largest, video) => {
      if (!largest) return video;
      return videoRenderArea(video) > videoRenderArea(largest) ? video : largest;
    }, null);
  }

  function rememberPrimaryVideo(video) {
    primaryPlayerVideo = video;
    if (!video) return null;
    video.playsInline = true;
    nativeSetAttribute.call(video, "playsinline", "");
    nativeSetAttribute.call(video, "webkit-playsinline", "");
    return video;
  }

  function refreshPrimaryVideo() {
    const videos = [...document.querySelectorAll("video")];
    if (!videos.length) return rememberPrimaryVideo(null);
    const identified = videos.filter(hasPrimaryVideoIdentity);
    if (identified.length) {
      return rememberPrimaryVideo(selectLargestVideo(identified));
    }
    if (videos.includes(primaryPlayerVideo)) {
      return rememberPrimaryVideo(primaryPlayerVideo);
    }
    const candidates = videos.filter((video) => !hasExplicitAdIdentity(video));
    const selected = selectLargestVideo(candidates.length ? candidates : videos);
    return rememberPrimaryVideo(selected);
  }

  function containsPrimaryVideo(element) {
    const videos = element.tagName === "VIDEO"
      ? [element]
      : element.querySelectorAll("video");
    const primary = refreshPrimaryVideo();
    return [...videos].some(
      (video) =>
        video === primary ||
        hasPrimaryVideoIdentity(video) ||
        !isKnownAdVideo(video),
    );
  }

  function resolveMediaVideo(element) {
    if (element?.tagName === "VIDEO") return element;
    if (element?.tagName === "SOURCE") return element.closest("video");
    return null;
  }

  function restoreAdMediaPlayback(video) {
    const playback = adMediaPlaybackStates.get(video);
    if (!playback) return;
    video.muted = playback.muted;
    video.playbackRate = playback.playbackRate;
    adMediaPlaybackStates.delete(video);
  }

  function clearTrackedAdVideo(video) {
    knownAdMedia.delete(video);
    reportedAdSources.delete(video);
    restoreAdMediaPlayback(video);
  }

  function hasAdSourceChild(video) {
    return [...video.querySelectorAll("source")].some((source) => {
      return (
        knownAdMedia.has(source) ||
        isAdMediaSource(source.getAttribute("src") || "")
      );
    });
  }

  function armAdMediaPlayback(video) {
    if (!adMediaPlaybackStates.has(video)) {
      adMediaPlaybackStates.set(
        video,
        Object.freeze({ muted: video.muted, playbackRate: video.playbackRate }),
      );
    }
    video.muted = true;
    video.playbackRate = AD_FAST_PLAYBACK_RATE;
  }

  function trackMediaSource(element, rawUrl) {
    const source = String(rawUrl ?? "");
    const video = resolveMediaVideo(element);
    if (!isAdMediaSource(source)) {
      knownAdMedia.delete(element);
      if (element.tagName === "VIDEO") clearTrackedAdVideo(element);
      if (element.tagName === "SOURCE" && video && !hasAdSourceChild(video)) {
        clearTrackedAdVideo(video);
      }
      return;
    }
    knownAdMedia.add(element);
    if (!video) return;
    knownAdMedia.add(video);
    armAdMediaPlayback(video);
  }

  function installMediaSrcPropertyGuard(prototype) {
    const descriptor = Object.getOwnPropertyDescriptor(prototype, "src");
    if (!descriptor?.get || !descriptor.set) {
      throw new Error("无法读取媒体 src 接口");
    }
    Object.defineProperty(prototype, "src", {
      ...descriptor,
      set(value) {
        descriptor.set.call(this, value);
        trackMediaSource(this, value);
      },
    });
  }

  function installMediaSetAttributeGuard(prototype) {
    Object.defineProperty(prototype, "setAttribute", {
      configurable: true,
      writable: true,
      value(name, value) {
        const result = nativeSetAttribute.call(this, name, value);
        if (String(name).toLowerCase() === "src") {
          trackMediaSource(this, value);
        }
        return result;
      },
    });
  }

  function installMediaRemoveAttributeGuard(prototype) {
    Object.defineProperty(prototype, "removeAttribute", {
      configurable: true,
      writable: true,
      value(name) {
        const result = nativeRemoveAttribute.call(this, name);
        if (String(name).toLowerCase() === "src") {
          trackMediaSource(this, "");
        }
        return result;
      },
    });
  }

  function installMediaSourceTracking() {
    const prototypes = [
      HTMLMediaElement.prototype,
      HTMLSourceElement.prototype,
    ];
    for (const prototype of prototypes) {
      installMediaSrcPropertyGuard(prototype);
      installMediaSetAttributeGuard(prototype);
      installMediaRemoveAttributeGuard(prototype);
    }
  }

  function hasSkipControlText(control) {
    if (!control.matches("button, a, [role=button]")) return false;
    const label = (control.textContent || "").trim();
    if (label.length > MAX_SKIP_LABEL_LENGTH) return false;
    return SKIP_AD_TEXT_RE.test(label);
  }

  function isSkipControlCandidate(control) {
    if (!(control instanceof Element)) return false;
    return (
      control.matches(PLAYER_SKIP_CONTROL_SELECTOR) ||
      hasSkipControlText(control)
    );
  }

  function findEventSkipControl(event) {
    const path = typeof event.composedPath === "function"
      ? event.composedPath()
      : [event.target];
    return path.find(isSkipControlCandidate) || null;
  }

  function findKnownSkipControl(event) {
    const control = findEventSkipControl(event);
    return control && knownSkipControls.has(control) ? control : null;
  }

  function findPlayerSkipControls() {
    const controls = new Set(
      document.querySelectorAll(PLAYER_SKIP_CONTROL_SELECTOR),
    );
    const textCandidates = document.querySelectorAll(
      "button, a, [role=button]",
    );
    for (const control of textCandidates) {
      if (hasSkipControlText(control)) controls.add(control);
    }
    const playerControls = [...controls].filter((control) => {
      return Boolean(control.closest(PLAYER_SKIP_CONTEXT_SELECTOR));
    });
    for (const control of playerControls) knownSkipControls.add(control);
    return playerControls;
  }

  function clickPlayerSkipControls() {
    for (const control of findPlayerSkipControls()) {
      if (handledSkipControls.has(control)) continue;
      handledSkipControls.add(control);
      control.removeAttribute("disabled");
      control.removeAttribute("aria-disabled");
      control.click();
      log("已触发播放器广告跳过控件", readElementIdentity(control));
    }
  }

  function listenerTargetContainsControl(target, control) {
    if (target === window || target === document) return true;
    return target instanceof Node && (
      target === control || target.contains(control)
    );
  }

  function scheduleSkipControlRetry(listenerTarget) {
    let shouldRetry = false;
    for (const control of findPlayerSkipControls()) {
      if (!listenerTargetContainsControl(listenerTarget, control)) continue;
      handledSkipControls.delete(control);
      shouldRetry = true;
    }
    if (!shouldRetry || skipControlRetryScheduled) return;
    skipControlRetryScheduled = true;
    queueMicrotask(() => {
      skipControlRetryScheduled = false;
      clickPlayerSkipControls();
    });
  }

  function installSkipAddEventListenerTracking() {
    const descriptor = Object.getOwnPropertyDescriptor(
      EventTarget.prototype,
      "addEventListener",
    );
    if (!descriptor?.value) throw new Error("无法跟踪跳过按钮事件绑定");
    Object.defineProperty(EventTarget.prototype, "addEventListener", {
      ...descriptor,
      value(type, listener, options) {
        const result = descriptor.value.call(this, type, listener, options);
        if (String(type).toLowerCase() === "click") {
          scheduleSkipControlRetry(this);
        }
        return result;
      },
    });
  }

  function installSkipOnclickTracking() {
    const descriptor = Object.getOwnPropertyDescriptor(
      HTMLElement.prototype,
      "onclick",
    );
    if (!descriptor?.get || !descriptor.set) {
      throw new Error("无法跟踪跳过按钮 onclick 绑定");
    }
    Object.defineProperty(HTMLElement.prototype, "onclick", {
      ...descriptor,
      set(value) {
        descriptor.set.call(this, value);
        scheduleSkipControlRetry(this);
      },
    });
  }

  function installSkipControlBindingTracking() {
    installSkipAddEventListenerTracking();
    installSkipOnclickTracking();
  }

  function hasConfirmedAdPlayback(video) {
    if (isKnownAdVideo(video)) return true;
    // JW 复用同一个 video 播放广告和主片；JW 只能由已知广告源或
    // adStarted/adTime 事件确认，不能依据可能滞留的 DOM 状态判断。
    if (video.closest(".jwplayer")) return false;
    const localContext = video.closest(PLAYER_ACTIVE_AD_SELECTOR);
    if (localContext) return true;
    const activeContext = document.querySelector(PLAYER_ACTIVE_AD_SELECTOR);
    return Boolean(activeContext?.contains(video));
  }

  function finishConfirmedAdVideo(video, reason, confirmed = false) {
    if (!confirmed && !hasConfirmedAdPlayback(video)) return false;
    if (finishingAdVideos.has(video)) return false;
    const duration = video.duration;
    if (!Number.isFinite(duration) || duration <= 0) return false;
    const signature = `${video.currentSrc || video.src}|${duration}`;
    const wasReported = reportedAdSources.get(video) === signature;
    finishingAdVideos.add(video);
    try {
      armAdMediaPlayback(video);
      const targetTime = Math.max(0, duration - AD_END_EPSILON_SECONDS);
      video.currentTime = targetTime;
      if (video.currentTime < targetTime - AD_SEEK_TOLERANCE_SECONDS) {
        return false;
      }
      if (!wasReported) {
        reportedAdSources.set(video, signature);
        increment("skippedVideoAds", `已直接结束播放器广告：${reason}`, signature);
      }
      return true;
    } finally {
      finishingAdVideos.delete(video);
    }
  }

  function handlePlayerMediaEvent(event) {
    const video = event.target;
    if (!(video instanceof HTMLVideoElement)) return;
    refreshPrimaryVideo();
    finishConfirmedAdVideo(video, event.type);
    clickPlayerSkipControls();
  }

  function finishJwAdVideos(root, reason, eventConfirmed = false) {
    if (!eventConfirmed && !root.matches(".jw-flag-ads")) return;
    const videos = root.querySelectorAll("video");
    for (const video of videos) {
      finishConfirmedAdVideo(video, reason, true);
    }
    clickPlayerSkipControls();
  }

  function restoreJwMedia(root) {
    for (const video of root.querySelectorAll("video")) {
      clearTrackedAdVideo(video);
    }
  }

  function subscribeJwAdEvents(root) {
    const player = root.id ? window.jwplayer(root.id) : window.jwplayer();
    if (jwAdPlayers.get(root) === player) return;
    if (typeof player?.on !== "function") {
      throw new Error("无法订阅 JW Player 广告事件");
    }
    player.on("adStarted", () => finishJwAdVideos(root, "JW adStarted", true));
    player.on("adTime", () => finishJwAdVideos(root, "JW adTime"));
    for (const eventName of JW_AD_END_EVENTS) {
      player.on(eventName, () => restoreJwMedia(root));
    }
    jwAdPlayers.set(root, player);
    log("已订阅 JW Player 前贴片事件", root.id);
  }

  function installJwAdEventBridge() {
    if (typeof window.jwplayer !== "function") return;
    for (const root of document.querySelectorAll(".jwplayer")) {
      subscribeJwAdEvents(root);
    }
  }

  function isPlayerAdTextOverlay(element) {
    if ([document.body, document.documentElement].includes(element)) return false;
    if (containsPrimaryVideo(element)) return false;
    const text = (element.innerText || element.textContent || "").trim();
    if (!text || text.length > MAX_AD_TEXT_LENGTH) return false;
    if (!PLAYER_AD_TEXT_RE.test(text)) return false;
    const style = getComputedStyle(element);
    return (
      element.getAttribute("role") === "dialog" ||
      ["absolute", "fixed", "sticky"].includes(style.position)
    );
  }

  function isPlayerFrameAdElement(element) {
    if (!(element instanceof Element)) return false;
    if (readPlayerAdUrls(element).some(isAdMediaSource)) return true;
    if (element instanceof HTMLIFrameElement) {
      // 正片由当前子文档中的 JW video 直接播放。所有后代 iframe 都是
      // 延迟广告容器，常先保持 about:blank，再在内部跳转到广告域。
      return true;
    }
    const identity = readElementIdentity(element);
    if (
      PLAYER_EXO_AD_IDENTITY_RE.test(identity) ||
      PLAYER_TS_IM_AD_IDENTITY_RE.test(identity)
    ) {
      return true;
    }
    if (element.tagName === "VIDEO") return isKnownAdVideo(element);
    if (["AUDIO", "SOURCE", "TRACK", "CANVAS"].includes(element.tagName)) {
      return false;
    }
    return (
      (PLAYER_AD_IDENTITY_RE.test(identity) && !containsPrimaryVideo(element)) ||
      (element.matches(PLAYER_AD_UI_SELECTOR) && !containsPrimaryVideo(element)) ||
      isPlayerAdTextOverlay(element)
    );
  }

  function resolvePlayerAdRemovalTarget(element) {
    const adContainer = element.closest(PLAYER_AD_REMOVAL_CONTAINER_SELECTOR);
    if (adContainer) return adContainer;
    if (element.tagName !== "SOURCE") return element;
    const video = element.closest("video");
    return isKnownAdVideo(video) ? video : element;
  }

  function preserveJwAdPlayback(element, reason) {
    if (!element.matches(PLAYER_JW_PRESERVE_SELECTOR)) return false;
    const tree = element.closest(PLAYER_JW_AD_SELECTOR);
    if (!tree) return false;
    const videos = tree.tagName === "VIDEO"
      ? [tree]
      : tree.querySelectorAll("video");
    for (const video of videos) {
      finishConfirmedAdVideo(video, reason);
    }
    clickPlayerSkipControls();
    if (!preservedJwAdTrees.has(tree)) {
      preservedJwAdTrees.add(tree);
      log("已保留 JW 播放器结构并结束广告片段", readElementIdentity(tree));
    }
    return true;
  }

  function readTargetMedia(target) {
    if (["VIDEO", "AUDIO"].includes(target.tagName)) return [target];
    return [...target.querySelectorAll("video, audio")];
  }

  function stopRemovedAdMedia(target) {
    for (const media of readTargetMedia(target)) {
      media.pause();
      media.removeAttribute("src");
      for (const source of media.querySelectorAll("source")) source.remove();
      media.load();
    }
  }

  function removePlayerFrameAd(element, reason) {
    if (preserveJwAdPlayback(element, reason)) return;
    const target = resolvePlayerAdRemovalTarget(element);
    if (!target.isConnected) return;
    const videos = target.tagName === "VIDEO"
      ? [target]
      : [...target.querySelectorAll("video")];
    for (const video of videos) finishConfirmedAdVideo(video, reason);
    if (
      target.tagName === "VIDEO" &&
      !hasExplicitAdIdentity(target) &&
      (target === refreshPrimaryVideo() || hasPrimaryVideoIdentity(target))
    ) {
      log("已保留主视频并结束其广告片段", readPlayerAdSource(target));
      return;
    }
    stopRemovedAdMedia(target);
    const identity =
      readPlayerAdSource(target) ||
      `${target.tagName}#${target.id}.${target.className}`;
    target.remove();
    increment(
      "removedAds",
      `已移除播放器内广告：${reason}`,
      String(identity).slice(0, MAX_LOG_URL_LENGTH),
    );
  }

  function sweepPlayerFrameAds(root) {
    refreshPrimaryVideo();
    if (root instanceof Element && isPlayerFrameAdElement(root)) {
      removePlayerFrameAd(root, "节点命中");
      return;
    }
    if (!root.querySelectorAll) return;
    const selector =
      "iframe,script[src],a[href],video,source[src],[id],[class],[role=dialog],[style]";
    for (const element of root.querySelectorAll(selector)) {
      if (isPlayerFrameAdElement(element)) {
        removePlayerFrameAd(element, "子节点命中");
      }
    }
  }

  function installChildAdStyle() {
    const style = document.createElement("style");
    style.id = "bjp-child-ad-style";
    style.textContent = `${CHILD_AD_STYLE_SELECTOR}{display:none!important;visibility:hidden!important;pointer-events:none!important}`;
    const append = () => {
      if (!document.documentElement) return false;
      document.documentElement.appendChild(style);
      return true;
    };
    if (append()) return;
    const observer = new MutationObserver(() => {
      if (!append()) return;
      observer.disconnect();
    });
    observer.observe(document, { childList: true });
  }

  function isCurrentFrameAdDocument() {
    if (isBlockedUrl(location.href)) return true;
    const body = document.body;
    if (!body || body.querySelector("video, audio")) return false;
    const text = (body.innerText || body.textContent || "").trim();
    if (text && text.length <= MAX_AD_TEXT_LENGTH) {
      if (PLAYER_AD_TEXT_RE.test(text)) return true;
    }
    if (!location.href.startsWith("about:")) return false;
    return PLAYER_AD_SOURCE_RE.test(document.documentElement?.innerHTML || "");
  }

  function reportCurrentAdFrame() {
    if (parent === top) return;
    if (childAdDocumentReported || !isCurrentFrameAdDocument()) return;
    childAdDocumentReported = true;
    log("已识别广告子帧，请求父帧移除", location.href);
    parent.postMessage(
      Object.freeze({ type: REMOVE_AD_FRAME_MESSAGE, version: VERSION }),
      "*",
    );
  }

  function findSourceIframe(sourceWindow) {
    for (const iframe of document.querySelectorAll("iframe")) {
      if (iframe.contentWindow === sourceWindow) return iframe;
    }
    return null;
  }

  function handleAdFrameMessage(event) {
    if (event.data?.type !== REMOVE_AD_FRAME_MESSAGE) return;
    if (event.data?.version !== VERSION) return;
    const iframe = findSourceIframe(event.source);
    if (!iframe) {
      recordError("广告子帧定位失败", new Error(String(event.origin)));
      return;
    }
    if (isTrustedPlayerIframe(iframe)) {
      log("已保留主播放器 iframe", iframe.src);
      return;
    }
    removePlayerFrameAd(iframe, "子帧自检命中");
  }

  function findPlayerAdClickTarget(target) {
    if (!(target instanceof Element)) return null;
    const anchor = target.closest("a[href]");
    if (anchor && shouldBlockAnchorInteraction({ isTrusted: false }, anchor)) {
      return anchor;
    }
    if (isCurrentFrameAdDocument()) return document.documentElement;
    for (let element = target; element && element !== document.body; ) {
      if (isPlayerFrameAdElement(element)) return element;
      element = element.parentElement;
    }
    return null;
  }

  function blockPlayerAdInteraction(event) {
    const skipControl = findEventSkipControl(event);
    if (skipControl) {
      if (knownSkipControls.has(skipControl)) return;
      blockUnknownSkipControlInteraction(event, skipControl);
      return;
    }
    const adTarget = findPlayerAdClickTarget(event.target);
    if (!adTarget) return;
    if (event.cancelable) event.preventDefault();
    event.stopImmediatePropagation();
    increment(
      "blockedNavigations",
      "已阻止播放器广告交互",
      event.type,
    );
  }

  function handleChildFrameMutations(mutations) {
    for (const mutation of mutations) {
      if (mutation.type === "attributes" && mutation.attributeName === "onclick") {
        scheduleSkipControlRetry(mutation.target);
      }
      if (mutation.type === "characterData") {
        sweepPlayerFrameAds(mutation.target.parentElement);
        continue;
      }
      sweepPlayerFrameAds(mutation.target);
      for (const node of mutation.addedNodes) sweepPlayerFrameAds(node);
    }
    clickPlayerSkipControls();
    installJwAdEventBridge();
    reportCurrentAdFrame();
  }

  function installChildAdObserver() {
    const observer = new MutationObserver(handleChildFrameMutations);
    observer.observe(document, {
      attributes: true,
      attributeFilter: [
        "class",
        "id",
        "href",
        "onclick",
        "src",
        "srcdoc",
        "sandbox",
        "style",
      ],
      childList: true,
      characterData: true,
      subtree: true,
    });
    const scanReadyDocument = () => {
      sweepPlayerFrameAds(document);
      clickPlayerSkipControls();
      installJwAdEventBridge();
      reportCurrentAdFrame();
    };
    scanReadyDocument();
    if (document.readyState === "loading") runAtDomReady(scanReadyDocument);
  }

  function installChildFrameProtection() {
    installMediaSourceTracking();
    installChildAdStyle();
    installPopupGuard();
    installNavigationGuard();
    installNavigationInteractionGuard();
    window.addEventListener("message", handleAdFrameMessage);
    for (const eventName of EARLY_INPUT_EVENTS) {
      window.addEventListener(eventName, blockPlayerAdInteraction, true);
    }
    window.addEventListener("click", blockPlayerAdInteraction, true);
    for (const eventName of PLAYER_MEDIA_EVENTS) {
      document.addEventListener(eventName, handlePlayerMediaEvent, true);
    }
    installSkipControlBindingTracking();
    installChildAdObserver();
  }

  function shouldBlockNavigation(event) {
    const url = parseUrl(event.destination?.url || "");
    if (!url) return false;
    if (["blob:", "about:", "data:"].includes(url.protocol)) return false;
    if (isBlockedUrl(url.href)) return true;
    if (SITE_HOST_RE.test(url.hostname)) return false;

    const source = event.sourceElement;
    const isExplicitLink = source instanceof HTMLAnchorElement;
    if (
      isTopLevelWindow &&
      event.userInitiated &&
      isExplicitLink &&
      source.href === url.href
    ) {
      return false;
    }
    return true;
  }

  function shouldBlockAnchorInteraction(event, anchor) {
    const url = parseUrl(anchor?.href || "");
    if (!url || !["http:", "https:"].includes(url.protocol)) return false;
    if (isBlockedUrl(url.href)) return true;
    if (SITE_HOST_RE.test(url.hostname)) return false;
    return !isTopLevelWindow || !event.isTrusted;
  }

  function blockNavigationInteraction(event) {
    const skipControl = findEventSkipControl(event);
    if (skipControl) {
      if (knownSkipControls.has(skipControl)) return;
      blockUnknownSkipControlInteraction(event, skipControl);
      return;
    }
    const anchor = event.target?.closest?.("a[href]");
    if (!shouldBlockAnchorInteraction(event, anchor)) return;
    if (event.cancelable) event.preventDefault();
    event.stopImmediatePropagation();
    increment(
      "blockedNavigations",
      "已阻止不受信任的链接跳转",
      anchor.href.slice(0, MAX_LOG_URL_LENGTH),
    );
  }

  function blockUnknownSkipControlInteraction(event, control) {
    if (event.cancelable) event.preventDefault();
    event.stopImmediatePropagation();
    increment(
      "blockedNavigations",
      "已阻止未登记的跳过控件交互",
      readElementIdentity(control),
    );
  }

  function preventSkipControlNavigation(event) {
    const skipControl = findKnownSkipControl(event);
    if (!skipControl) return;
    if (event.cancelable) event.preventDefault();
  }

  function installNavigationInteractionGuard() {
    window.addEventListener("click", blockNavigationInteraction, true);
    window.addEventListener("click", preventSkipControlNavigation, true);
  }

  function installPopupGuard() {
    const blockedOpen = function (url) {
      const detail = String(url ?? "").slice(0, MAX_LOG_URL_LENGTH);
      increment("blockedPopups", "已阻止脚本弹窗", detail || "(空白弹窗)");
      return null;
    };

    // 广告使用“先复制本站页，再把原标签跳到广告”的 popunder 手法，
    // 因而必须阻止所有脚本式 window.open，而不能只检查传入域名。
    Object.defineProperty(window, "open", {
      value: blockedOpen,
      writable: false,
      configurable: false,
    });
  }

  function installNavigationGuard() {
    if (!window.navigation) {
      console.warn(
        "[BJP-CLEAN] 当前浏览器不支持 Navigation API，已启用点击级移动端保护",
      );
      return;
    }

    window.navigation.addEventListener("navigate", (event) => {
      const destination = event.destination?.url || "";
      if (!shouldBlockNavigation(event)) return;
      if (!event.cancelable) {
        recordError("发现不可取消的外链跳转", new Error(destination));
        return;
      }
      event.preventDefault();
      increment(
        "blockedNavigations",
        "已阻止外链跳转",
        destination.slice(0, MAX_LOG_URL_LENGTH),
      );
    });
  }

  function isInitialPlayerEvent(event) {
    return Boolean(event.target?.closest?.(PLAYER_TARGET_SELECTOR));
  }

  function invokeNativePlayer(button, nativeEvent) {
    const jquery = window.jQuery;
    if (!jquery?._data) throw new Error("站点 jQuery 播放器接口尚未加载");

    const handlers = jquery._data(button, "events")?.click || [];
    if (handlers.length !== 1) {
      throw new Error(`原生播放处理器数量异常：${handlers.length}`);
    }

    handlers[0].handler.call(button, jquery.Event(nativeEvent));
  }

  function isolateEarlyPlayerEvent(event) {
    if (!isInitialPlayerEvent(event)) return;
    event.stopImmediatePropagation();
  }

  function handlePlayerClick(event) {
    const button = event.target?.closest?.(PLAYER_TARGET_SELECTOR);
    if (!button) return;

    event.preventDefault();
    event.stopImmediatePropagation();
    increment(
      "protectedPlayerClicks",
      "已隔离播放器广告点击",
      button.className,
    );

    try {
      invokeNativePlayer(button, event);
    } catch (error) {
      recordError("启动原生播放器失败", error);
      throw error;
    }
  }

  function installPlayerGuard() {
    for (const eventName of EARLY_INPUT_EVENTS) {
      window.addEventListener(eventName, isolateEarlyPlayerEvent, true);
    }
    window.addEventListener("click", handlePlayerClick, true);
  }

  function readIframeSource(iframe, pendingSource = "") {
    return String(pendingSource || iframe.getAttribute("src") || "");
  }

  function isBlobIframeSource(iframe, pendingSource = "") {
    return readIframeSource(iframe, pendingSource).startsWith("blob:");
  }

  function isPlayerIframeCandidate(iframe, pendingSource = "") {
    if (!(iframe instanceof HTMLIFrameElement)) return false;
    if (securedPlayerIframes.has(iframe)) return true;
    return (
      iframe.id === PLAYER_IFRAME_ID &&
      isBlobIframeSource(iframe, pendingSource)
    );
  }

  function isTrustedPlayerIframe(iframe) {
    if (!isPlayerIframeCandidate(iframe)) return false;
    return Boolean(iframe.closest(PLAYER_CONTAINER_SELECTOR));
  }

  function isProvisionalPlayerIframe(iframe) {
    if (!(iframe instanceof HTMLIFrameElement)) return false;
    if (iframe.id !== PLAYER_IFRAME_ID) return false;
    if (!iframe.closest(PLAYER_CONTAINER_SELECTOR)) return false;
    if (iframe.hasAttribute("srcdoc")) return false;
    const source = iframe.getAttribute("src");
    return !source || source === "about:blank";
  }

  function applyPlayerIframeSecurity(iframe) {
    protectedIframeNavigations.add(iframe);
    if (iframe.getAttribute("sandbox") !== PLAYER_SANDBOX) {
      nativeSetAttribute.call(iframe, "sandbox", PLAYER_SANDBOX);
    }
    if (iframe.getAttribute("referrerpolicy") !== PLAYER_REFERRER_POLICY) {
      nativeSetAttribute.call(iframe, "referrerpolicy", PLAYER_REFERRER_POLICY);
    }
  }

  function securePlayerIframe(iframe, reason, pendingSource = "") {
    if (!isPlayerIframeCandidate(iframe, pendingSource)) {
      throw new TypeError("播放器 iframe 身份校验失败");
    }
    const firstProtection = !securedPlayerIframes.has(iframe);
    securedPlayerIframes.add(iframe);
    applyPlayerIframeSecurity(iframe);
    if (firstProtection) {
      increment("securedPlayerFrames", "已锁定播放器 iframe 沙箱", reason);
    }
    return iframe;
  }

  function preparePlayerIframe(iframe, pendingSource, reason) {
    const shouldProtect =
      protectedIframeNavigations.has(iframe) ||
      isBlobIframeSource(iframe, pendingSource);
    if (shouldProtect) applyPlayerIframeSecurity(iframe);
    if (isPlayerIframeCandidate(iframe, pendingSource)) {
      securePlayerIframe(iframe, reason, pendingSource);
    }
  }

  function blockSandboxAttributeChange(iframe, attribute, value) {
    if (!protectedIframeNavigations.has(iframe)) return false;
    if (!["sandbox", "referrerpolicy"].includes(attribute)) return false;
    const expected =
      attribute === "sandbox" ? PLAYER_SANDBOX : PLAYER_REFERRER_POLICY;
    if (String(value ?? "") !== expected) {
      increment("blockedSandboxChanges", "已阻止播放器沙箱变更", value);
    }
    applyPlayerIframeSecurity(iframe);
    return true;
  }

  function installPlayerAttributeGuard() {
    const iframePrototype = HTMLIFrameElement.prototype;
    const setDescriptor = Object.getOwnPropertyDescriptor(
      Element.prototype,
      "setAttribute",
    );
    const removeDescriptor = Object.getOwnPropertyDescriptor(
      Element.prototype,
      "removeAttribute",
    );
    if (!setDescriptor || !removeDescriptor) {
      throw new Error("无法读取 iframe 属性接口");
    }
    Object.defineProperty(iframePrototype, "setAttribute", {
      ...setDescriptor,
      value(name, value) {
        if (!(this instanceof HTMLIFrameElement)) {
          return setDescriptor.value.call(this, name, value);
        }
        const attribute = String(name).toLowerCase();
        if (blockSandboxAttributeChange(this, attribute, value)) return;
        if (attribute === "src") {
          preparePlayerIframe(this, value, "设置 src 前");
        }
        const result = setDescriptor.value.call(this, name, value);
        if (attribute === "id") preparePlayerIframe(this, "", "设置 id 后");
        return result;
      },
    });
    Object.defineProperty(iframePrototype, "removeAttribute", {
      ...removeDescriptor,
      value(name) {
        if (!(this instanceof HTMLIFrameElement)) {
          return removeDescriptor.value.call(this, name);
        }
        const attribute = String(name).toLowerCase();
        if (blockSandboxAttributeChange(this, attribute, "")) return;
        return removeDescriptor.value.call(this, attribute);
      },
    });
  }

  function installPlayerSourceGuard() {
    const descriptor = Object.getOwnPropertyDescriptor(
      HTMLIFrameElement.prototype,
      "src",
    );
    if (!descriptor?.get || !descriptor.set) {
      throw new Error("无法读取 iframe src 接口");
    }
    Object.defineProperty(HTMLIFrameElement.prototype, "src", {
      ...descriptor,
      set(value) {
        preparePlayerIframe(this, value, "直接设置 src 前");
        descriptor.set.call(this, value);
      },
    });
  }

  function securePlayerFramesInTree(node, reason) {
    if (!(node instanceof Node)) return;
    if (node instanceof HTMLIFrameElement) {
      preparePlayerIframe(node, "", reason);
    }
    if (!node.querySelectorAll) return;
    const selector = `iframe#${PLAYER_IFRAME_ID}, iframe[src^="blob:"]`;
    for (const iframe of node.querySelectorAll(selector)) {
      preparePlayerIframe(iframe, "", reason);
    }
  }

  function securePlayerMarkup(markup) {
    if (typeof markup !== "string") return markup;
    if (!PLAYER_MARKUP_RE.test(markup)) return markup;
    const template = document.createElement("template");
    nativeInnerHtmlDescriptor.set.call(template, markup);
    securePlayerFramesInTree(template.content, "HTML 解析插入前");
    return nativeInnerHtmlDescriptor.get.call(template);
  }

  function installPlayerMarkupGuard() {
    if (!nativeInnerHtmlDescriptor?.get || !nativeInnerHtmlDescriptor.set) {
      throw new Error("无法读取 innerHTML 接口");
    }
    Object.defineProperty(Element.prototype, "innerHTML", {
      ...nativeInnerHtmlDescriptor,
      set(value) {
        const containsPlayer =
          typeof value === "string" && PLAYER_MARKUP_RE.test(value);
        nativeInnerHtmlDescriptor.set.call(this, securePlayerMarkup(value));
        if (containsPlayer) {
          securePlayerFramesInTree(this, "HTML 解析插入后同步登记");
        }
      },
    });
  }

  function enforcePlayerIframeSecurity(mutations) {
    for (const mutation of mutations) {
      if (mutation.type === "childList") {
        for (const node of mutation.addedNodes) {
          securePlayerFramesInTree(node, "DOM 变更校验");
        }
        continue;
      }
      const iframe = mutation.target;
      const isProtected = protectedIframeNavigations.has(iframe);
      if (!isProtected && !isPlayerIframeCandidate(iframe)) continue;
      preparePlayerIframe(iframe, "", "属性变更校验");
    }
  }

  function installPlayerIframeCreationGuard() {
    installPlayerAttributeGuard();
    installPlayerSourceGuard();
    installPlayerMarkupGuard();
    const observer = new MutationObserver(enforcePlayerIframeSecurity);
    observer.observe(document, {
      attributes: true,
      attributeFilter: ["id", "src", "sandbox", "referrerpolicy"],
      childList: true,
      subtree: true,
    });
  }

  function updateFloatState(patch) {
    floatState = Object.freeze({ ...floatState, ...patch });
  }

  function findPlayerAnchor(iframe) {
    return iframe.closest(PLAYER_CONTAINER_SELECTOR);
  }

  function preservePlayerAspectRatio(anchor) {
    const rect = anchor.getBoundingClientRect();
    if (rect.width <= 0 || rect.height <= 0) return;
    anchor.style.setProperty(
      PLAYER_ASPECT_RATIO_PROPERTY,
      `${rect.width} / ${rect.height}`,
    );
  }

  function detachFloatingPlayer(iframe, anchor) {
    iframe?.classList.remove("bjp-floating-player");
    anchor?.classList.remove("bjp-player-anchor");
    anchor?.style.removeProperty(PLAYER_ASPECT_RATIO_PROPERTY);
  }

  function activateFloatingPlayer(iframe) {
    if (!iframe?.isConnected || !isTrustedPlayerIframe(iframe)) {
      throw new Error("原生完整视频 iframe 尚未创建");
    }
    securePlayerIframe(iframe, "打开完整视频小窗前");
    const anchor = findPlayerAnchor(iframe);
    if (!anchor) throw new Error("无法定位原视频播放器容器");
    if (
      floatState.active &&
      floatState.iframe === iframe &&
      floatState.anchor === anchor
    ) {
      return true;
    }
    detachFloatingPlayer(floatState.iframe, floatState.anchor);
    preservePlayerAspectRatio(anchor);
    anchor.classList.add("bjp-player-anchor");
    iframe.classList.add("bjp-floating-player");
    updateFloatState({ iframe, anchor, active: true });
    increment("floatingActivations", "完整视频已覆盖原播放器", iframe.src);
    return true;
  }

  function restoreFloatingPlayer() {
    if (!floatState.active) return;
    detachFloatingPlayer(floatState.iframe, floatState.anchor);
    updateFloatState({ anchor: null, active: false });
    increment("floatingRestores", "完整视频播放器已回到原位", "");
  }

  function disposeFloatingPlayer() {
    detachFloatingPlayer(floatState.iframe, floatState.anchor);
    floatState = Object.freeze({
      iframe: null,
      anchor: null,
      active: false,
    });
  }

  function findTrustedPlayerIframe() {
    const selector = `iframe#${PLAYER_IFRAME_ID}`;
    for (const iframe of document.querySelectorAll(selector)) {
      if (isTrustedPlayerIframe(iframe)) return iframe;
    }
    return null;
  }

  function syncFloatingPlayer() {
    const iframe = findTrustedPlayerIframe();
    if (iframe) {
      const anchor = findPlayerAnchor(iframe);
      if (
        iframe !== floatState.iframe ||
        anchor !== floatState.anchor ||
        !floatState.active
      ) {
        activateFloatingPlayer(iframe);
      }
      return;
    }
    if (floatState.iframe && !floatState.iframe.isConnected) {
      disposeFloatingPlayer();
    }
  }

  function installFloatingPlayer() {
    const observer = new MutationObserver(syncFloatingPlayer);
    observer.observe(document, {
      attributes: true,
      attributeFilter: ["id", "src"],
      childList: true,
      subtree: true,
    });
    syncFloatingPlayer();
    if (document.readyState === "loading") runAtDomReady(syncFloatingPlayer);
  }

  function isAdElement(element) {
    if (!(element instanceof Element)) return false;
    if (element.matches(AD_CONTAINER_SELECTOR)) return true;

    const tagName = element.tagName;
    if (tagName === "IFRAME") {
      return (
        !isTrustedPlayerIframe(element) &&
        !isProvisionalPlayerIframe(element)
      );
    }
    if (!["SCRIPT", "A"].includes(tagName)) return false;
    const rawUrl = element.getAttribute(tagName === "A" ? "href" : "src") || "";
    return isBlockedUrl(rawUrl);
  }

  function removeAdElement(element) {
    if (!element.isConnected) return;
    const identity =
      element.getAttribute("src") ||
      element.getAttribute("href") ||
      element.className ||
      element.tagName;
    stopRemovedAdMedia(element);
    element.remove();
    increment(
      "removedAds",
      "已移除广告节点",
      String(identity).slice(0, MAX_LOG_URL_LENGTH),
    );
  }

  function sweepAds(root) {
    if (root instanceof Element && isAdElement(root)) {
      removeAdElement(root);
      return;
    }
    if (!root.querySelectorAll) return;
    for (const element of root.querySelectorAll(AD_CANDIDATE_SELECTOR)) {
      if (isAdElement(element)) removeAdElement(element);
    }
  }

  function installAdObserver() {
    const observer = new MutationObserver((mutations) => {
      for (const mutation of mutations) {
        if (mutation.type === "attributes") {
          sweepAds(mutation.target);
          continue;
        }
        for (const node of mutation.addedNodes) sweepAds(node);
      }
    });
    observer.observe(document, {
      attributes: true,
      attributeFilter: ["id", "src", "srcdoc"],
      childList: true,
      subtree: true,
    });
    sweepAds(document);
    if (document.readyState === "loading") {
      runAtDomReady(() => sweepAds(document));
    }
  }

  function installAdStyle() {
    const style = document.createElement("style");
    style.id = "bjp-clean-style";
    style.textContent = `${AD_CONTAINER_SELECTOR}{display:none!important;visibility:hidden!important;pointer-events:none!important}\n${FLOAT_CSS}`;

    const appendStyle = () => document.documentElement.appendChild(style);
    if (document.documentElement) appendStyle();
    else runAtDomReady(appendStyle);
  }

  function exposeDiagnostics() {
    const api = Object.freeze({
      version: VERSION,
      report: () =>
        Object.freeze({
          version: VERSION,
          ...state,
          floatActive: floatState.active,
        }),
      float: () => activateFloatingPlayer(findTrustedPlayerIframe()),
      restore: restoreFloatingPlayer,
    });
    Object.defineProperty(window, "__BJP_CLEAN__", {
      value: api,
      writable: false,
      configurable: false,
    });
  }

  installPlayerIframeCreationGuard();
  installPopupGuard();
  installNavigationGuard();
  installNavigationInteractionGuard();
  installPlayerGuard();
  installAdObserver();
  installAdStyle();
  installFloatingPlayer();
  exposeDiagnostics();
  log("启动完成", { version: VERSION });
})();
