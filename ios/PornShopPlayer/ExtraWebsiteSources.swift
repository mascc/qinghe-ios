import Foundation

/// 公开网页型播放源共用的 HTML 解析工具。
///
/// 这里只做纯字符串处理，不发任何网络请求：页面仍由 `PornShopRepository` 取得，
/// 因此新增站点复用既有的公开源网络层——同样的 User-Agent、Referer、Origin、
/// 超时设置，以及同一处 `isPublicWebsiteURL` 同源校验，不会出现绕过校验的旁路。
enum WebsiteHTML {
    /// 按行返回全部匹配，每行是「整段匹配 + 各捕获组」的原始切片。
    /// 未参与匹配的可选捕获组为 nil，调用方无需区分 NSNotFound。
    static func matches(_ pattern: String, in text: String) -> [[String?]] {
        guard let expression = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]
        ) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).map { match in
            (0..<match.numberOfRanges).map { index -> String? in
                guard let found = Range(match.range(at: index), in: text) else { return nil }
                return String(text[found])
            }
        }
    }

    /// 第一个匹配的第一个捕获组。取不到、或该组未参与匹配时返回 nil。
    static func capture(_ pattern: String, in text: String) -> String? {
        guard let row = matches(pattern, in: text).first, row.count > 1 else { return nil }
        return row[1]
    }

    /// 最后一个匹配的第一个捕获组。站点把同一个值渲染多次时以最后一次为准。
    static func lastCapture(_ pattern: String, in text: String) -> String? {
        guard let row = matches(pattern, in: text).last, row.count > 1 else { return nil }
        return row[1]
    }

    /// `<a href=…>label</a>` 这类配对，用于从首页发现站内公开频道。
    static func linkPairs(_ pattern: String, in text: String) -> [(path: String, label: String)] {
        matches(pattern, in: text).compactMap { row in
            guard row.count > 2, let path = row[1], let rawLabel = row[2],
                  let label = clean(rawLabel) else { return nil }
            return (path: decodeEntities(path), label: label)
        }
    }

    /// 去掉标签、解码实体并裁剪空白；结果为空时返回 nil。
    static func clean(_ raw: String?) -> String? {
        guard let raw, !raw.isEmpty else { return nil }
        let stripped = raw.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        let value = decodeEntities(stripped).trimmingCharacters(in: .whitespacesAndNewlines)
        return value.isEmpty ? nil : value
    }

    /// 解码页面里实际会出现的实体与 JSON 转义。`&amp;` 放在最后处理，
    /// 否则 `&amp;#47;` 这类二次编码会被提前解开。
    static func decodeEntities(_ value: String) -> String {
        var result = value
        let ordered: [(String, String)] = [
            (#"\u0026"#, "&"),
            (#"\u002F"#, "/"),
            (#"\/"#, "/"),
            ("&#x2F;", "/"),
            ("&#x2f;", "/"),
            ("&#47;", "/"),
            ("&quot;", "\""),
            ("&#39;", "'"),
            ("&apos;", "'"),
            ("&lt;", "<"),
            ("&gt;", ">"),
            ("&nbsp;", " "),
            ("&amp;", "&"),
        ]
        for (needle, replacement) in ordered {
            result = result.replacingOccurrences(of: needle, with: replacement)
        }
        return result
    }

    /// 把页面里的引用解析成绝对地址，并挡掉不能作为视频页的协议。
    static func absolute(_ reference: String, base: URL) -> URL? {
        let trimmed = decodeEntities(reference).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !trimmed.hasPrefix("#"),
              !trimmed.hasPrefix("data:"),
              !trimmed.hasPrefix("javascript:") else { return nil }
        let normalized = trimmed.hasPrefix("//") ? "https:" + trimmed : trimmed
        guard let url = URL(string: normalized, relativeTo: base)?.absoluteURL,
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }
}

/// Richy-17.txt 对应的 懂色帝（MacCMS 站点）公开页面解析。
///
/// 只实现脚本里「读取站点自己交给浏览器的东西」那两条路径中的第二条：
/// 播放页服务端渲染的 `var player_aaaa` 配置。脚本里另一条 `guessFromPoster`
/// 会把海报地址的 `/1.jpg` 改写成 `/1000k/index.m3u8` 直接推导 CDN 目录，
/// 那是绕过播放页门禁的猜路径，本实现刻意不包含——因此列表卡片一律先落到
/// 播放页再解析，而不是就地拼出媒体地址。
enum DsdWebsite {
    /// 卡片与播放页链接都只认站方自己的 `/vod/play/` 路由，避免把导航项或广告位
    /// 误当视频；判定放在解析阶段，取页时的同源校验仍由 `isPublicWebsiteURL` 负责。
    private static let playLinkPattern = #"(?:index\.php/)?vod/play/"#

    private static var origin: URL {
        // `SiteProfile.dsdSE.pageOrigin` 是常量字符串，这里的兜底不可达。
        URL(string: SiteProfile.dsdSE.pageOrigin) ?? URL(fileURLWithPath: "/")
    }

    static func isPlayPage(_ url: URL) -> Bool {
        url.path.range(of: playLinkPattern, options: .regularExpression) != nil
    }

    /// 解析列表页卡片。脚本对卡片只取 href 与海报，不解析标题/时长/播放量/作者；
    /// 这里在此之上补了两个纯展示字段（清晰度标记与时长），取不到就留空。
    static func cards(in html: String) -> [VideoItem] {
        let pattern = #"(<a\b[^>]*\bclass=["'][^"']*\bvideo-(?:item|surface)\b[^"']*["'][^>]*>)(.*?)</a>"#
        let base = origin
        var seen = Set<String>()
        var output: [VideoItem] = []
        for row in WebsiteHTML.matches(pattern, in: html) {
            guard row.count > 2, let tag = row[1], let body = row[2],
                  let href = WebsiteHTML.capture(#"\bhref=["']([^"']+)["']"#, in: tag),
                  let pageURL = WebsiteHTML.absolute(href, base: base),
                  isPlayPage(pageURL) else { continue }
            let rawID = videoID(in: pageURL) ?? pageURL.lastPathComponent
            let id = rawID.isEmpty ? nil : rawID
            guard let id, seen.insert(id).inserted else { continue }
            output.append(
                VideoItem(
                    id: "dsd-\(id)",
                    title: cardTitle(tag: tag, body: body) ?? "视频 \(id)",
                    cover: poster(tag: tag, body: body, base: base),
                    duration: WebsiteHTML.capture(#"\b(\d{1,3}:\d{2}(?::\d{2})?)\b"#, in: body),
                    views: hitCount(in: body),
                    user: nil,
                    vip: false,
                    timeLine: nil,
                    videoType: qualityBadge(in: body),
                    tags: [],
                    site: SiteProfile.dsdSE.id,
                    sourcePageURL: pageURL.absoluteString
                )
            )
        }
        return output
    }

    /// 从首页发现站方自己的公开分类频道。与既有公开源一致，只收同站相对/同站绝对链接。
    static func feeds(in html: String) -> [PublicWebsiteFeed] {
        let pattern = #"<a\b[^>]*\bhref=["']([^"']*(?:index\.php/)?vod/(?:type|show)/[^"']*)["'][^>]*>(.*?)</a>"#
        var seen = Set<String>()
        var feeds: [PublicWebsiteFeed] = []
        for pair in WebsiteHTML.linkPairs(pattern, in: html) {
            guard pair.path.hasPrefix("/") || pair.path.lowercased().hasPrefix("http") else { continue }
            guard seen.insert(pair.path).inserted else { continue }
            feeds.append(PublicWebsiteFeed(path: pair.path, label: pair.label))
            if feeds.count >= 16 { break }
        }
        return feeds
    }

    /// 播放页的媒体地址。先读服务端渲染的播放器配置，再退回页面里直接出现的 m3u8。
    /// 只有带 .m3u8 的值才算命中，否则继续走后面的回退，而不是把一个非 HLS 地址
    /// 交给上层再报错。
    static func playerSource(in html: String) -> String? {
        if let value = playerAaaaURL(in: html), looksLikePlaylist(value) { return value }
        if let raw = WebsiteHTML.capture(#"((?:https?:)?//[^"'\\\s>]+\.m3u8[^"'\\\s>]*)"#, in: html) {
            return WebsiteHTML.decodeEntities(raw)
        }
        if let raw = WebsiteHTML.capture(#"["'](/[^"'\\\s>]*\.m3u8[^"'\\\s>]*)"#, in: html) {
            return WebsiteHTML.decodeEntities(raw)
        }
        return nil
    }

    private static func looksLikePlaylist(_ value: String) -> Bool {
        value.lowercased().contains(".m3u8")
    }

    /// `var player_aaaa={"url":"…"}` 里的 url 字段。
    ///
    /// 脚本用的是 `indexOf("var player_aaaa=")`，且要求 `=` 后紧跟 `{`——多一个空格、
    /// 换成单引号或 `let/const` 都会静默失败。这里保持同一个锚点，但放宽空白与 HTML
    /// 实体转义；仍然只认能解析出 url 字段的对象，避免把同名的无关变量当成播放配置。
    static func playerAaaaURL(in html: String) -> String? {
        guard let anchor = html.range(of: "player_aaaa") else { return nil }
        // 锚点到 `{` 之间只允许很短的间隔：真正的配置紧跟其后，远处的大括号属于别的脚本。
        guard let brace = html[anchor.upperBound...].prefix(400).firstIndex(of: "{") else { return nil }
        guard let object = balancedObject(in: html, from: brace) else { return nil }
        let decoded = WebsiteHTML.decodeEntities(object)
        guard let data = decoded.data(using: .utf8),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let raw = json["url"] as? String else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty, value != "null" else { return nil }
        return value
    }

    /// 播放页标题：优先 h1，其次去掉站点后缀的 `<title>`。
    static func title(in html: String) -> String? {
        if let heading = WebsiteHTML.clean(WebsiteHTML.capture(#"<h1\b[^>]*>(.*?)</h1>"#, in: html)) {
            return heading
        }
        guard let raw = WebsiteHTML.capture(#"<title\b[^>]*>(.*?)</title>"#, in: html),
              let cleaned = WebsiteHTML.clean(raw) else { return nil }
        // 站点的 <title> 形如「片名 - 站点名」。逐级切掉站点后缀；切不动就原样返回。
        for separator in [" - ", "·", "|", "_"] {
            guard let head = cleaned.components(separatedBy: separator).first else { continue }
            let trimmed = head.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty, trimmed != cleaned { return trimmed }
        }
        return cleaned
    }

    /// 大括号配平取出一整个 JSON 对象。跳过字符串字面量与反斜杠转义，
    /// 因此 url 里出现 `{}` 也不会提前收尾。
    private static func balancedObject(in text: String, from start: String.Index) -> String? {
        var depth = 0
        var inString = false
        var escaped = false
        var index = start
        while index < text.endIndex {
            let character = text[index]
            if inString {
                if escaped {
                    escaped = false
                } else if character == "\\" {
                    escaped = true
                } else if character == "\"" {
                    inString = false
                }
            } else if character == "\"" {
                inString = true
            } else if character == "{" {
                depth += 1
            } else if character == "}" {
                depth -= 1
                if depth == 0 { return String(text[start...index]) }
            }
            index = text.index(after: index)
        }
        return nil
    }

    private static func videoID(in url: URL) -> String? {
        // 站点当前路由是 `/index.php/vod/play/id/7631/sid/1/nid/1.html`。
        // 先前少了 `id/` 这一段，导致回退到末尾的 `1.html`，所有卡片又都以
        // 相同 id 去重，首页最后只剩一张无标题卡片。
        WebsiteHTML.capture(#"(?:index\.php/)?vod/play/(?:id/)?([0-9]+)"#, in: url.path)
    }

    private static func cardTitle(tag: String, body: String) -> String? {
        if let raw = WebsiteHTML.capture(#"\btitle=["']([^"']+)["']"#, in: tag),
           let cleaned = WebsiteHTML.clean(raw) {
            return cleaned
        }
        if let raw = WebsiteHTML.capture(#"<img\b[^>]*\balt=["']([^"']+)["']"#, in: body),
           let cleaned = WebsiteHTML.clean(raw) {
            return cleaned
        }
        // MacCMS 常见的标题容器。取不到就交给调用方生成「视频 <id>」占位标题，
        // 不再退回整张卡片的纯文本（那会把清晰度与时长连在一起）。
        let pattern = #"<(?:div|h3|span)\b[^>]*\bclass=["'][^"']*\b(?:title|name|video-title|video-desc)\b[^"']*["'][^>]*>(.*?)</(?:div|h3|span)>"#
        guard let raw = WebsiteHTML.capture(pattern, in: body) else { return nil }
        return WebsiteHTML.clean(raw)
    }

    private static func hitCount(in body: String) -> String? {
        // 命中 `<span class="video-item-tag video-item-tag-hits"><img …>511155</span>`。
        // `clean` 会去掉其中的图标标签，保留站方已经显示给浏览器的播放量文字。
        guard let raw = WebsiteHTML.capture(#"<span\b[^>]*\bclass=["'][^"']*\bvideo-item-tag-hits\b[^"']*["'][^>]*>(.*?)</span>"#, in: body) else {
            return nil
        }
        return WebsiteHTML.clean(raw)
    }

    /// 海报来源，顺序与脚本的 `posterOf` 一致：`data-src`（须像真实媒体路径）→
    /// `src` → 卡片内元素的 `background-image` → 卡片自身的 `background-image`。
    /// 脚本用「以 /video 或 http 开头」过滤掉懒加载占位图，这里同样保留该判据。
    private static func poster(tag: String, body: String, base: URL) -> String? {
        let looksLikeMedia = { (value: String) -> Bool in
            value.hasPrefix("/video") || value.lowercased().hasPrefix("http") || value.hasPrefix("//")
        }
        if let raw = WebsiteHTML.capture(#"\bdata-src=["']([^"']+)["']"#, in: body), looksLikeMedia(raw),
           let url = WebsiteHTML.absolute(raw, base: base) {
            return url.absoluteString
        }
        if let raw = WebsiteHTML.capture(#"\bsrc=["']([^"']+)["']"#, in: body), looksLikeMedia(raw),
           let url = WebsiteHTML.absolute(raw, base: base) {
            return url.absoluteString
        }
        let background = #"background-image:\s*url\(\s*['"]?([^'")]+)"#
        if let raw = WebsiteHTML.capture(background, in: body),
           let url = WebsiteHTML.absolute(raw, base: base) {
            return url.absoluteString
        }
        if let raw = WebsiteHTML.capture(background, in: tag),
           let url = WebsiteHTML.absolute(raw, base: base) {
            return url.absoluteString
        }
        // 懒加载实图地址兜底，同样要求它看起来像真实媒体路径。
        if let raw = WebsiteHTML.capture(#"\bdata-original=["']([^"']+)["']"#, in: body), looksLikeMedia(raw),
           let url = WebsiteHTML.absolute(raw, base: base) {
            return url.absoluteString
        }
        return nil
    }

    /// 纯展示用的清晰度标记。MacCMS 通常把它渲染成 `HD` / `超清` 这类小角标。
    private static func qualityBadge(in body: String) -> String? {
        let pattern = #">\s*(超清|高清|蓝光|HD|SD|4K|1080P|720P)\s*<"#
        return WebsiteHTML.lastCapture(pattern, in: body)
    }
}
