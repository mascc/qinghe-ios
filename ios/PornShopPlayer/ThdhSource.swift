import Foundation

/// 探花（thdh.cc）源站适配。
///
/// 与上游 Kotlin `ThdhHtml` / `ThdhCatalog` 逐条对齐：列表、搜索、详情页解析，
/// 以及「详情海报与播放清单同目录」这条该站特有的播放地址推导。
/// 页面一律按纯文本解析，不加载、不执行页面里的任何脚本。
enum ThdhHTML {
    // MARK: - 站点常量

    static let siteID = "thdh"
    static let host = "www.thdh.cc"
    static let origin = "https://www.thdh.cc/"
    static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1"
    static let accept = "text/html,application/xhtml+xml"

    /// 单页上限 2MB。正常的官方列表页远小于该值，超过说明拿到的不是目录页。
    static let maximumBytes = 2 * 1024 * 1024
    /// 元素解析上限，与上游一致：超出说明页面已不是站点自己的服务端渲染结构。
    static let maximumNodes = 20_000
    static let maximumDepth = 64
    static let structureFailureMessage = "探花页面结构异常，请重试"

    // MARK: - 正则（原始字符串，避免二次转义）

    private static let videoIdentifierPattern = #"/vod/(?:play|free|detail)/id/(\d+)"#
    private static let imageFilePattern = #"/[^/?#]+\.(?:jpe?g|png|webp|gif)(?:\?.*)?$"#
    private static let pageNumberPattern = #"/page/(\d+)(?:/|\.html|[?#]|$)"#
    private static let viewsPattern = #"(\d+)"#
    private static let datePattern = #"\d{4}-\d{1,2}-\d{1,2}"#
    /// 注释与样式/脚本块先剔除：它们会打乱起止标签配对，且里面没有卡片信息。
    private static let ignoredBlockPattern = #"<!--.*?-->|<(script|style)\b[^>]*>.*?</\1\s*>"#
    private static let tagTokenPattern = #"<(?:(?:"[^"]*")|(?:'[^']*')|[^'">])*>"#
    private static let tagNamePattern = #"^<\s*(/?)\s*([A-Za-z][\w:-]*)"#
    private static let attributePattern = #"([A-Za-z_:][\w:.-]*)\s*=\s*(?:"([^"]*)"|'([^']*)'|([^\s"'=<>`]+))"#
    private static let emptyResultPattern = #"(?:没有找到|未找到|暂无|没有|无)(?:任何)?(?:相关)?(?:影片|视频|搜索结果)|(?:没有找到|未找到|暂无|没有|无)(?:任何)?相关(?:内容|结果)"#
    private static let placeholderImagePattern = #"(?:lazy(?:load)?|placeholder|loading|spacer|blank)"#

    private static let voidTags: Set<String> = [
        "area", "base", "br", "col", "embed", "hr", "img", "input",
        "link", "meta", "param", "source", "track", "wbr",
    ]
    private static let pagerClasses: Set<String> = ["pagination", "page-numbers", "mac_pages"]
    private static let pagerIdentifiers: Set<String> = ["page", "pagination"]
    private static let listingClasses: Set<String> = [
        "module-items", "module-list", "module-poster-items", "module-search-items", "module-search-item",
    ]

    // MARK: - 路由

    /// 热榜与今日更新各只有一页；分类走 `/vod/show/id/<id>` 分页。
    /// 返回 nil 表示分区 id 不合法（上游在同样情况抛「未知分区」）。
    static func listPath(type: String, page: Int) -> String? {
        let current = max(1, page)
        switch type {
        case "hot":
            return current == 1 ? "/index.php/label/hot.html" : ""
        case "new":
            return current == 1 ? "/index.php/label/new.html" : ""
        default:
            guard let identifier = Int(type.trimmingCharacters(in: .whitespacesAndNewlines)), identifier > 0 else {
                return nil
            }
            return current == 1
                ? "/index.php/vod/show/id/\(identifier).html"
                : "/index.php/vod/show/id/\(identifier)/page/\(current).html"
        }
    }

    /// 站内搜索是路径参数，因此必须按路径段编码：空格要变成 %20，不能变成 +。
    static func searchPath(keyword: String, page: Int) -> String {
        let trimmed = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: unreserved) ?? trimmed
        return "/index.php/vod/search/page/\(max(1, page))/wd/\(encoded).html"
    }

    static func detailPath(id: String) -> String {
        "/index.php/vod/detail/id/\(id.trimmingCharacters(in: .whitespacesAndNewlines)).html"
    }

    /// 详情页海报与其播放清单在同一个上传目录，只把文件名换成 `index.m3u8`，
    /// 不访问会员播放页，也不改写 CDN 目录。替换结果不以 `/index.m3u8` 结尾时视为推导失败。
    static func deriveM3u8(_ poster: String) -> String {
        let raw = unescape(poster).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty, let expression = regex(imageFilePattern, ignoreCase: true) else { return "" }
        let range = NSRange(raw.startIndex..., in: raw)
        let next = expression.stringByReplacingMatches(in: raw, range: range, withTemplate: "/index.m3u8")
        guard next != raw, next.hasSuffix("/index.m3u8") else { return "" }
        return next
    }

    // MARK: - 页面判定

    /// 拦截页：要求点击「立即进入」，且没有任何卡片或详情容器。
    static func looksLikeGate(_ html: String) throws -> Bool {
        let document = try parse(html)
        guard document.text.contains("立即进入") else { return false }
        let hasContent = document.elements.contains { element in
            isCard(element)
                || element.hasClass("module-info-main")
                || element.hasClass("module-info-poster")
        }
        return !hasContent
    }

    /// 搜索使用 `/page/N/wd/...`，分类使用 `/page/N.html`；只统计当前目录种类的分页链接。
    static func lastPage(_ html: String, searching: Bool? = nil) throws -> Int? {
        let document = try parse(html)
        let pagers = document.elements.filter { element in
            !element.classes.isDisjoint(with: pagerClasses)
                || pagerIdentifiers.contains(element.attributes["id"] ?? "")
        }
        // 分页块存在时只在其内部找链接，避免把导航/广告里的 /vod/show/ 当页码。
        let candidates = pagers.isEmpty
            ? document.elements
            : pagers.flatMap { document.descendants(of: $0) }
        var last: Int?
        for element in candidates where element.tag == "a" {
            let href = element.attributes["href"] ?? ""
            let relevant: Bool
            switch searching {
            case .some(true):
                relevant = href.contains("/vod/search/")
            case .some(false):
                relevant = href.contains("/vod/show/")
            case .none:
                relevant = href.contains("/vod/search/") || href.contains("/vod/show/")
            }
            guard relevant, let digits = firstCapture(pageNumberPattern, in: href), let value = Int(digits) else {
                continue
            }
            last = max(last ?? value, value)
        }
        return last
    }

    /// 拦截页、错误页和空响应不能冒充「成功的空搜索」。
    static func isListingPage(_ html: String) throws -> Bool {
        let document = try parse(html)
        if document.elements.contains(where: { isCard($0) || isListingContainer($0) }) { return true }
        return containsMatch(emptyResultPattern, in: document.cleanText)
    }

    /// 没有分页的完整目录就是单页；卡片片段仍保留一次后续探测的机会。
    static func isCompleteListing(_ html: String) throws -> Bool {
        let document = try parse(html)
        let hasDocumentWrapper = document.elements.contains { $0.tag == "html" || $0.tag == "body" }
        guard hasDocumentWrapper else { return false }
        if document.elements.contains(where: { isListingContainer($0) }) { return true }
        return containsMatch(emptyResultPattern, in: document.cleanText)
    }

    static func isDetailPage(_ html: String) throws -> Bool {
        let document = try parse(html)
        return document.elements.contains { element in
            element.hasClass("module-info-poster")
                || element.hasClass("module-info-main")
                || element.hasClass("module-info-heading")
        }
    }

    // MARK: - 卡片与详情

    static func parseCards(_ html: String) throws -> [VideoItem] {
        let document = try parse(html)
        var seen = Set<String>()
        var items: [VideoItem] = []
        for element in document.elements where isCard(element) {
            guard let identifier = videoIdentifier(in: element.attributes["href"] ?? "") else { continue }
            guard seen.insert(identifier).inserted else { continue }
            let rawTitle = element.attributes["title"].map { unescape($0) }
                ?? document.firstDescendant(of: element, withClass: "module-poster-item-title")?.cleanText
                ?? ""
            let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            let note = document.firstDescendant(of: element, withClass: "module-item-note")?.cleanText
            let duration = document.firstDescendant(of: element, withClass: "th-dur")?.cleanText
            let views = document.firstDescendant(of: element, withClass: "th-card-meta")?.cleanText
                .map { $0.replacingOccurrences(of: ",", with: "") }
                .flatMap { firstCapture(viewsPattern, in: $0) }
            let poster = pickPoster(document, element)
            let isVIP = document.descendants(of: element).contains { $0.hasClass("th-vip") } || note == "VIP"
            items.append(
                VideoItem(
                    id: identifier,
                    title: title.isEmpty ? "视频 \(identifier)" : title,
                    cover: poster.isEmpty ? nil : poster,
                    duration: duration,
                    views: views,
                    vip: isVIP,
                    site: siteID
                )
            )
        }
        return items
    }

    static func parseDetail(_ html: String) throws -> ThdhDetail {
        let document = try parse(html)
        let posterElement = document.elements.first { $0.hasClass("module-info-poster") }
        var title = ""
        if let heading = document.elements.first(where: { $0.hasClass("module-info-heading") }),
           let headingTitle = document.descendants(of: heading).first(where: { $0.tag == "h1" }) {
            title = headingTitle.cleanText
        } else if let fallback = document.elements.first(where: { $0.tag == "h1" }) {
            title = fallback.cleanText
        }
        // 更新日期只认详情信息条目里的那一行，页头/推荐位里的日期属于别的影片。
        let updated = document.elements
            .first { $0.hasClass("module-info-item") && $0.cleanText.contains("更新") }
            .map { firstMatch(datePattern, in: $0.cleanText) ?? "" } ?? ""
        var tags: [String] = []
        var seenTags = Set<String>()
        for element in document.elements where element.hasClass("module-info-tag-link") {
            let value = element.cleanText
            guard !value.isEmpty, seenTags.insert(value).inserted else { continue }
            tags.append(value)
        }
        let poster = posterElement.map { pickPoster(document, $0) } ?? ""
        return ThdhDetail(title: title, poster: poster, tags: tags, updated: updated)
    }

    // MARK: - 私有判定

    private static func isCard(_ element: Element) -> Bool {
        element.tag == "a"
            && element.hasClass("module-item")
            && videoIdentifier(in: element.attributes["href"] ?? "") != nil
    }

    private static func isListingContainer(_ element: Element) -> Bool {
        !element.classes.isDisjoint(with: listingClasses)
    }

    private static func videoIdentifier(in href: String) -> String? {
        firstCapture(videoIdentifierPattern, in: href)
    }

    /// 只取详情海报里的第一张图，按 `data-original` → `src` 的顺序；
    /// 懒加载占位图跳过，否则推导出的目录会落在占位图所在位置。
    private static func pickPoster(_ document: Document, _ element: Element) -> String {
        guard let image = document.descendants(of: element).first(where: { $0.tag == "img" }) else { return "" }
        for name in ["data-original", "src"] {
            let url = unescape(image.attributes[name] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard usableImage(url) else { continue }
            return url.hasPrefix("//") ? "https:" + url : url
        }
        return ""
    }

    private static func usableImage(_ url: String) -> Bool {
        let afterSlash = url.range(of: "/", options: .backwards).map { String(url[$0.upperBound...]) } ?? url
        let name = String(afterSlash.prefix { $0 != "?" })
        guard !containsMatch(placeholderImagePattern, in: name) else { return false }
        return url.hasPrefix("http://") || url.hasPrefix("https://") || url.hasPrefix("//")
    }

    // MARK: - 文本工具

    static func unescape(_ value: String) -> String {
        var result = value
        let ordered: [(String, String)] = [
            ("&amp;", "&"), ("&lt;", "<"), ("&gt;", ">"), ("&quot;", "\""),
            ("&#39;", "'"), ("&apos;", "'"), ("&nbsp;", " "),
        ]
        for (needle, replacement) in ordered {
            result = result.replacingOccurrences(of: needle, with: replacement)
        }
        return result
    }

    /// 解码实体后按空白折叠并裁剪，与上游 `cleanText` 相同。
    static func normalized(_ value: String) -> String {
        unescape(value).split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    private static func regex(
        _ pattern: String,
        ignoreCase: Bool = false,
        dotAll: Bool = false
    ) -> NSRegularExpression? {
        var options: NSRegularExpression.Options = []
        if ignoreCase { options.insert(.caseInsensitive) }
        if dotAll { options.insert(.dotMatchesLineSeparators) }
        return try? NSRegularExpression(pattern: pattern, options: options)
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard !text.isEmpty, let expression = regex(pattern) else { return nil }
        let full = NSRange(text.startIndex..., in: text)
        guard let match = expression.firstMatch(in: text, range: full),
              match.numberOfRanges > 1,
              let captured = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[captured])
    }

    private static func firstMatch(_ pattern: String, in text: String) -> String? {
        guard !text.isEmpty, let expression = regex(pattern) else { return nil }
        let full = NSRange(text.startIndex..., in: text)
        guard let match = expression.firstMatch(in: text, range: full),
              let captured = Range(match.range, in: text) else { return nil }
        return String(text[captured])
    }

    private static func containsMatch(_ pattern: String, in text: String) -> Bool {
        guard !text.isEmpty, let expression = regex(pattern) else { return false }
        return expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
    }

    // MARK: - 元素读取（不执行脚本的轻量解析器）

    /// 扁平的元素数组，顺序即文档先序；`subtreeEnd` 划定该元素的后代区间。
    struct Element: Sendable {
        let index: Int
        let tag: String
        let attributes: [String: String]
        /// 子树文本（含全部后代），等价上游 `Node.text`。
        let text: String
        let subtreeEnd: Int

        var classes: Set<String> {
            guard let raw = attributes["class"] else { return [] }
            return Set(raw.split(whereSeparator: { $0.isWhitespace }).map { String($0) })
        }

        var cleanText: String { ThdhHTML.normalized(text) }

        func hasClass(_ name: String) -> Bool { classes.contains(name) }
    }

    struct Document: Sendable {
        fileprivate let nodes: [Element]

        /// 与上游 `root.elements()` 一致：不含根节点本身。
        var elements: [Element] { Array(nodes.dropFirst()) }

        /// 整页文本（含根节点收集到的文本），拦截页判定需要未折叠的原文。
        var text: String { nodes.first?.text ?? "" }

        var cleanText: String { nodes.first?.cleanText ?? "" }

        func descendants(of node: Element) -> [Element] {
            let start = node.index + 1
            let end = min(node.subtreeEnd, nodes.count)
            guard start < end else { return [] }
            return Array(nodes[start..<end])
        }

        func firstDescendant(of node: Element, withClass name: String) -> Element? {
            descendants(of: node).first { $0.hasClass(name) }
        }
    }

    /// 手写标签扫描：接受单/双/无引号属性、class 多值和自闭合；
    /// 只为读取而遍历，不构造 DOM、不触发任何脚本或资源请求。
    static func parse(_ html: String) throws -> Document {
        let source = strippingIgnoredBlocks(html)
        let tokenExpression = regex(tagTokenPattern)
        let nameExpression = regex(tagNamePattern)
        let attributeExpression = regex(attributePattern)

        var tags: [String] = ["root"]
        var attributes: [[String: String]] = [[:]]
        var texts: [String] = [""]
        var ends: [Int] = [1]
        var stack: [Int] = [0]
        var created = 0

        func appendText(_ value: String) {
            guard !value.isEmpty else { return }
            // 与上游一致：文本同时计入每个打开中的祖先，因此每个元素的 text 就是其子树文本。
            for index in stack { texts[index] += value + " " }
        }

        var consumed = 0
        if let tokenExpression {
            let whole = NSRange(source.startIndex..., in: source)
            for match in tokenExpression.matches(in: source, range: whole) {
                if match.range.location > consumed,
                   let gap = Range(NSRange(location: consumed, length: match.range.location - consumed), in: source) {
                    appendText(String(source[gap]))
                }
                consumed = match.range.location + match.range.length
                guard let tokenRange = Range(match.range, in: source) else { continue }
                let token = String(source[tokenRange])
                let tokenLength = token.utf16.count
                guard let nameExpression,
                      let nameMatch = nameExpression.firstMatch(in: token, range: NSRange(location: 0, length: tokenLength)),
                      let tagRange = Range(nameMatch.range(at: 2), in: token) else { continue }
                let name = token[tagRange].lowercased()

                var closing = false
                if let markerRange = Range(nameMatch.range(at: 1), in: token) {
                    closing = !token[markerRange].isEmpty
                }
                if closing {
                    // 只在栈里找同名元素，错配的结束标签直接忽略。
                    if let matched = stack.lastIndex(where: { tags[$0] == name }), matched > 0 {
                        while stack.count > matched {
                            let popped = stack.removeLast()
                            ends[popped] = tags.count
                        }
                    }
                    continue
                }

                var parsed: [String: String] = [:]
                if let attributeExpression {
                    let start = nameMatch.range.location + nameMatch.range.length
                    if start < tokenLength,
                       let restRange = Range(NSRange(location: start, length: tokenLength - start), in: token) {
                        let rest = String(token[restRange])
                        let restLength = rest.utf16.count
                        for attribute in attributeExpression.matches(in: rest, range: NSRange(location: 0, length: restLength)) {
                            guard let keyRange = Range(attribute.range(at: 1), in: rest) else { continue }
                            var value = ""
                            for group in 2...4 {
                                guard let valueRange = Range(attribute.range(at: group), in: rest) else { continue }
                                if !rest[valueRange].isEmpty {
                                    value = String(rest[valueRange])
                                    break
                                }
                            }
                            parsed[rest[keyRange].lowercased()] = value
                        }
                    }
                }

                created += 1
                if created > maximumNodes || stack.count >= maximumDepth {
                    throw RepositoryError.invalidResponse(structureFailureMessage)
                }
                tags.append(name)
                attributes.append(parsed)
                texts.append("")
                ends.append(tags.count)
                let index = tags.count - 1
                let selfClosing = token.trimmingCharacters(in: .whitespacesAndNewlines).hasSuffix("/>")
                if !selfClosing && !voidTags.contains(name) {
                    stack.append(index)
                }
            }
        }

        let total = source.utf16.count
        if consumed < total,
           let tail = Range(NSRange(location: consumed, length: total - consumed), in: source) {
            appendText(String(source[tail]))
        }
        while let index = stack.popLast() {
            ends[index] = tags.count
        }

        var nodes: [Element] = []
        nodes.reserveCapacity(tags.count)
        for index in tags.indices {
            let end = min(max(ends[index], index + 1), tags.count)
            nodes.append(
                Element(
                    index: index,
                    tag: tags[index],
                    attributes: attributes[index],
                    text: texts[index],
                    subtreeEnd: end
                )
            )
        }
        return Document(nodes: nodes)
    }

    private static func strippingIgnoredBlocks(_ html: String) -> String {
        guard let expression = regex(ignoredBlockPattern, ignoreCase: true, dotAll: true) else { return html }
        return expression.stringByReplacingMatches(
            in: html,
            range: NSRange(html.startIndex..., in: html),
            withTemplate: " "
        )
    }
}

/// 详情页解析结果：标题、海报、标签与更新日期。
struct ThdhDetail: Sendable {
    let title: String
    let poster: String
    let tags: [String]
    let updated: String
}

/// 探花列表、搜索与播放地址。
///
/// 播放页本身是会员跳转，因此这里改读详情页海报，再按该站的目录规律推导 `index.m3u8`；
/// 不保存账号状态，也不请求会员/付费接口。
actor ThdhSource {
    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
    }

    func list(type: String, page: Int) async throws -> ListPage {
        let current = max(1, page)
        guard let path = ThdhHTML.listPath(type: type, page: current) else {
            throw RepositoryError.invalidResponse("探花分区不可用，请重试")
        }
        // 热榜/今日更新只有第一页：与上游 listPath 返回空串一致，直接给出空页。
        if path.isEmpty {
            return ListPage(items: [], page: current, totalPage: 1, openEnded: false)
        }
        let html = try await load(path: path)
        try ensureListing(html)
        let items = try ThdhHTML.parseCards(html)
        let singlePage = type == "hot" || type == "new"
        return try makePage(items: items, page: current, html: html, singlePage: singlePage, searching: false)
    }

    func search(keyword: String, page: Int) async throws -> ListPage {
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw RepositoryError.invalidResponse("搜索关键词不能为空") }
        let current = max(1, page)
        let html = try await load(path: ThdhHTML.searchPath(keyword: query, page: current))
        try ensureListing(html)
        let items = try ThdhHTML.parseCards(html)
        return try makePage(items: items, page: current, html: html, singlePage: false, searching: true)
    }

    func resolve(_ item: VideoItem) async throws -> Playable {
        let path = ThdhHTML.detailPath(id: item.id)
        let html = try await load(path: path)
        let gate = try ThdhHTML.looksLikeGate(html)
        if gate { throw RepositoryError.invalidResponse("探花页面还在跳转，请重试") }
        let detailPage = try ThdhHTML.isDetailPage(html)
        guard detailPage else { throw RepositoryError.invalidResponse("探花详情页面暂不可用，请重试") }

        let detail = try ThdhHTML.parseDetail(html)
        let poster = detail.poster.isEmpty ? (item.cover ?? "") : detail.poster
        let derived = ThdhHTML.deriveM3u8(poster)
        let absolute = derived.hasPrefix("//") ? "https:" + derived : derived
        guard let url = URL(string: absolute),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
            throw RepositoryError.missingPlaybackURL
        }

        let pageURL = URL(string: path, relativeTo: URL(string: ThdhHTML.origin))?.absoluteURL.absoluteString
        return Playable(
            id: item.id,
            title: detail.title.isEmpty ? item.displayTitle : detail.title,
            playURL: url,
            streamURLs: [url],
            cover: poster.isEmpty ? item.cover : poster,
            duration: item.duration,
            activeHost: ThdhHTML.host,
            lineKey: "",
            lines: [],
            pageOrigin: ThdhHTML.origin,
            site: ThdhHTML.siteID,
            sourcePageURL: pageURL
        )
    }

    // MARK: - 编排

    private func ensureListing(_ html: String) throws {
        let gate = try ThdhHTML.looksLikeGate(html)
        if gate { throw RepositoryError.invalidResponse("探花页面还在跳转，请重试") }
        let listing = try ThdhHTML.isListingPage(html)
        guard listing else { throw RepositoryError.invalidResponse("探花列表页面暂不可用，请重试") }
    }

    private func makePage(
        items: [VideoItem],
        page: Int,
        html: String,
        singlePage: Bool,
        searching: Bool
    ) throws -> ListPage {
        if singlePage { return ListPage(items: items, page: page, totalPage: 1, openEnded: false) }
        let last = try ThdhHTML.lastPage(html, searching: searching)
        let totalPage: Int
        if items.isEmpty {
            totalPage = page
        } else if let last {
            totalPage = max(last, page)
        } else {
            // 没有分页链接时：完整目录说明已到末页，卡片片段则留一次后续探测。
            let complete = try ThdhHTML.isCompleteListing(html)
            totalPage = complete ? page : page + 1
        }
        return ListPage(items: items, page: page, totalPage: totalPage, openEnded: page < totalPage)
    }

    // MARK: - 网络

    private func load(path: String) async throws -> String {
        guard let base = URL(string: ThdhHTML.origin),
              let url = URL(string: path, relativeTo: base)?.absoluteURL,
              url.host?.lowercased() == ThdhHTML.host else {
            throw RepositoryError.invalidResponse("探花页面地址无效，请重试")
        }
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = 20
        request.setValue(ThdhHTML.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(ThdhHTML.origin, forHTTPHeaderField: "Referer")
        request.setValue(ThdhHTML.accept, forHTTPHeaderField: "Accept")

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError where error.code == .cancelled {
            // 取消要原样抛出，否则界面会把「用户中止」显示成网络错误。
            throw error
        } catch {
            throw RepositoryError.invalidResponse("探花页面请求失败，请检查网络后重试")
        }
        guard let http = response as? HTTPURLResponse else {
            throw RepositoryError.invalidResponse("探花页面响应异常，请重试")
        }
        guard (200..<300).contains(http.statusCode) else {
            throw RepositoryError.invalidResponse("探花页面请求失败（HTTP \(http.statusCode)），请重试")
        }
        guard data.count <= ThdhHTML.maximumBytes else {
            throw RepositoryError.invalidResponse("探花页面过大，请重试")
        }
        guard let html = String(data: data, encoding: .utf8) else {
            throw RepositoryError.invalidResponse("探花页面响应为空，请重试")
        }
        return html
    }
}
