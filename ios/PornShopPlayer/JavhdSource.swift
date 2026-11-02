import Foundation
import Security

/// JAVHD 目录与完整 MP4 适配。
///
/// 列表接口回的是服务端渲染好的 `thumb-component` 片段，`/zh/id/{n}` 里的 n 不是播放器 ID，
/// 要先进视频页读 `content-id` 才能换到 `player_api`。`player_api` 会把试看片段混在同一份
/// `sources` 里返回，试看在 `/share2/trailers/` 下，只保留完整片源。
struct JavhdListing: Sendable {
    let items: [VideoItem]
    let page: Int
    let totalPage: Int
}

struct JavhdSourceStream: Sendable {
    let res: Int
    let url: String
    let mime: String
}

enum JavhdHTML {
    private static let thumbPattern = #"<thumb-component\b([^>]*)>"#
    private static let sizeDirectory = #"/(374x233|300x169|320x180|360x203|468x264|480x270|640x360)/"#
    private static let slugPattern = #"^[a-z0-9]+(?:-[a-z0-9]+)*$"#
    private static let numericEntity = #"&#([xX]?[0-9a-fA-F]+);"#
    /// 清晰度排序优先级，不在表里的分辨率排在后面按数字降序。
    private static let prefer = [1080, 720, 480, 240]
    private static let trailerMarker = "/share2/trailers/"

    // MARK: - 路径

    static func listPath(type: String, page: Int) throws -> String {
        let current = max(1, page)
        switch type {
        case "new":
            return current == 1
                ? "/zh/japanese-porn-videos"
                : "/zh/japanese-porn-videos/justadded/all/\(current)"
        case "popular":
            return current == 1
                ? "/zh/japanese-porn-videos/popular?content=all"
                : "/zh/japanese-porn-videos/popular/all/\(current)?content=all"
        case "top":
            return current == 1
                ? "/zh/japanese-porn-videos/top?content=all"
                : "/zh/japanese-porn-videos/top/all/\(current)?content=all"
        default:
            // 分类 slug 直接拼进路径，先按站点允许的字符集校验，避免拼出别的路径。
            guard type.range(of: slugPattern, options: .regularExpression) != nil else {
                throw RepositoryError.invalidResponse("未知分区")
            }
            return current == 1
                ? "/zh/japanese-porn-videos/category/\(type)"
                : "/zh/japanese-porn-videos/category/\(type)/justadded/all/\(current)"
        }
    }

    static func searchPath(keyword: String, page: Int) throws -> String {
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw RepositoryError.invalidResponse("搜索关键词不能为空") }
        // 只保留字母数字与 `-._*`，其余（含中文与空格）一律按 UTF-8 百分号编码。
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._*")
        guard let encoded = query.addingPercentEncoding(withAllowedCharacters: allowed), !encoded.isEmpty else {
            throw RepositoryError.invalidResponse("搜索关键词无效")
        }
        return "/zh/search?page=\(max(1, page))&q=\(encoded)"
    }

    static func watchPath(id: String) throws -> String {
        let number = id.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isDigits(number) else { throw RepositoryError.invalidResponse("未知视频") }
        return "/zh/id/\(number)"
    }

    static func apiPath(playerId: String) throws -> String {
        let number = playerId.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isDigits(number) else { throw RepositoryError.invalidResponse("未知视频") }
        return "/zh/player_api?videoId=\(number)"
    }

    // MARK: - 列表

    static func parseListing(_ body: String) throws -> JavhdListing {
        guard let root = jsonObject(body) else {
            throw RepositoryError.invalidResponse("JAVHD 列表暂不可用，请重试")
        }
        // 未登录/被挡时站点回的是 HTML 或 status=0 的壳，得当成失败而不是空列表。
        if let status = integer(root["status"]), status != 1 {
            throw RepositoryError.invalidResponse("JAVHD 列表暂不可用，请重试")
        }
        guard let template = root["template"] as? String else {
            throw RepositoryError.invalidResponse("JAVHD 列表暂不可用，请重试")
        }
        let pagination = root["pagination_params"] as? [String: Any]
        let page = max(1, integer(pagination?["current_page"]) ?? 1)
        let total = max(page, integer(pagination?["total_pages"]) ?? page)
        return JavhdListing(items: parseThumbs(template), page: page, totalPage: total)
    }

    static func parseThumbs(_ template: String) -> [VideoItem] {
        var items: [VideoItem] = []
        var seen = Set<String>()
        for row in rows(thumbPattern, in: template) {
            guard row.count > 1, let attributeText = row[1] else { continue }
            let fields = attributes(in: attributeText)
            let kind = (fields["type-thumb"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            // 列表里混着分类、演员卡片，只有 video 才是片子。
            guard kind.isEmpty || kind.lowercased() == "video" else { continue }
            let id = (fields["video-id"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            guard isDigits(id), seen.insert(id).inserted else { continue }
            let title = unescape(fields["title"] ?? "")
            items.append(
                VideoItem(
                    id: id,
                    title: title.isEmpty ? "视频 \(id)" : title,
                    cover: upgradeThumb(unescape(fields["url-thumb"] ?? "")),
                    vip: (fields["has-label"] ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "premium",
                    site: "javhd"
                )
            )
        }
        return items
    }

    /// 播放器 ID 以视频页的 `content-id` 为准，列表上的 `/id/{n}` 不能直接拿去换片。
    static func playerId(html: String) -> String? {
        if let id = firstCapture(#"content-id\s*=\s*["']?(\d+)"#, in: html) { return id }
        if let id = firstCapture(#"[?&]videoId=(\d+)"#, in: html) { return id }
        return firstCapture(#"cms_id=(\d+)"#, in: html)
    }

    // MARK: - 片源

    static func parseSources(_ body: String) -> [JavhdSourceStream] {
        guard let root = jsonObject(body), let list = root["sources"] as? [Any] else { return [] }
        var streams: [JavhdSourceStream] = []
        for raw in list {
            guard let item = raw as? [String: Any] else { continue }
            let url = (item["src"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let lowered = url.lowercased()
            // 只接受站点自己给出的绝对地址；试看片段必须整条丢掉，播放器不回退试看。
            guard lowered.hasPrefix("http"), !lowered.contains(trailerMarker) else { continue }
            let res: Int
            if let value = integer(item["res"]), value > 0 {
                res = value
            } else {
                let digits = (item["label"] as? String ?? "").filter { $0 >= "0" && $0 <= "9" }
                res = Int(digits) ?? 0
            }
            let head = (item["type"] as? String ?? "").components(separatedBy: ";").first ?? ""
            let mime = head.trimmingCharacters(in: .whitespacesAndNewlines)
            streams.append(JavhdSourceStream(res: res, url: url, mime: mime.isEmpty ? "video/mp4" : mime))
        }
        var seen = Set<String>()
        let unique = streams.filter { seen.insert($0.url).inserted }
        return unique.sorted { left, right in
            let leftRank = prefer.firstIndex(of: left.res) ?? prefer.count
            let rightRank = prefer.firstIndex(of: right.res) ?? prefer.count
            if leftRank != rightRank { return leftRank < rightRank }
            return left.res > right.res
        }
    }

    /// 卡片给小尺寸封面目录，换成站点同一份大图目录，避免列表封面发虚。
    static func upgradeThumb(_ url: String) -> String? {
        let raw = url.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !raw.isEmpty else { return nil }
        return raw.replacingOccurrences(of: sizeDirectory, with: "/728x413/", options: .regularExpression)
    }

    // MARK: - 解析工具

    /// 上游只认「有引号」的属性，站点一旦写成无引号，整张卡片会被静默丢掉。
    /// 这里自己扫一遍标签属性，单引号、双引号、无引号都取，键统一转小写。
    static func attributes(in raw: String) -> [String: String] {
        var result: [String: String] = [:]
        var index = raw.startIndex
        while index < raw.endIndex {
            let character = raw[index]
            if character.isWhitespace || character == "/" || character == "=" {
                index = raw.index(after: index)
                continue
            }
            var name = ""
            while index < raw.endIndex {
                let current = raw[index]
                if current.isWhitespace || current == "=" || current == "/" { break }
                name.append(current)
                index = raw.index(after: index)
            }
            while index < raw.endIndex, raw[index].isWhitespace { index = raw.index(after: index) }
            var value = ""
            if index < raw.endIndex, raw[index] == "=" {
                index = raw.index(after: index)
                while index < raw.endIndex, raw[index].isWhitespace { index = raw.index(after: index) }
                if index < raw.endIndex {
                    let quote = raw[index]
                    if quote == "\"" || quote == "'" {
                        index = raw.index(after: index)
                        while index < raw.endIndex, raw[index] != quote {
                            value.append(raw[index])
                            index = raw.index(after: index)
                        }
                        if index < raw.endIndex { index = raw.index(after: index) }
                    } else {
                        // 无引号时地址里的 `/` 要保留，只在标签末尾把自闭合斜杠退掉。
                        while index < raw.endIndex, !raw[index].isWhitespace {
                            value.append(raw[index])
                            index = raw.index(after: index)
                        }
                        if index == raw.endIndex, value.hasSuffix("/") { value = String(value.dropLast()) }
                    }
                }
            }
            if !name.isEmpty { result[name.lowercased()] = value }
        }
        return result
    }

    static func unescape(_ raw: String) -> String {
        // 命名实体先按上游顺序替换，数字实体留到最后统一处理，避免二次解码。
        var text = raw
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
        guard let expression = try? NSRegularExpression(pattern: numericEntity) else {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        let matches = expression.matches(in: text, range: NSRange(text.startIndex..., in: text))
        // 从后往前替换，前面的匹配区间才不会失效。
        for match in matches.reversed() {
            guard let fullRange = Range(match.range(at: 0), in: text),
                  let tokenRange = Range(match.range(at: 1), in: text) else { continue }
            let token = String(text[tokenRange])
            let code: UInt32?
            if token.hasPrefix("x") || token.hasPrefix("X") {
                code = UInt32(token.dropFirst(), radix: 16)
            } else {
                code = UInt32(token, radix: 10)
            }
            guard let code, code > 0, code <= 0x10FFFF, let scalar = UnicodeScalar(code) else { continue }
            text.replaceSubrange(fullRange, with: String(scalar))
        }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func rows(
        _ pattern: String,
        in text: String,
        options: NSRegularExpression.Options = [.caseInsensitive, .dotMatchesLineSeparators]
    ) -> [[String?]] {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: options) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).map { match in
            (0..<match.numberOfRanges).map { index -> String? in
                guard let slice = Range(match.range(at: index), in: text) else { return nil }
                return String(text[slice])
            }
        }
    }

    private static func firstCapture(_ pattern: String, in text: String) -> String? {
        guard let row = rows(pattern, in: text, options: [.dotMatchesLineSeparators]).first, row.count > 1 else {
            return nil
        }
        return row[1]
    }

    private static func jsonObject(_ body: String) -> [String: Any]? {
        guard let data = body.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func integer(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber: return number.intValue
        case let text as String: return Int(text.trimmingCharacters(in: .whitespacesAndNewlines))
        default: return nil
        }
    }

    /// 只认 ASCII 数字：站点的 ID 与分区 slug 都是半角，全角数字拼进路径会 404。
    private static func isDigits(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0 >= "0" && $0 <= "9" }
    }
}

/// javhd.com 在部分网络下返回的证书链不完整，iOS 会按系统规则直接拒绝握手，
/// 表现为 `-1200 / -9802` 一类网络层错误。这里先按系统默认规则校验；只有默认
/// 校验失败时才接受站点自己出示的 trust，正常证书不受影响。
/// 类内部没有可变状态，跨线程共享都是只读，因此 @unchecked Sendable 成立。
final class JavhdTrustDelegate: NSObject, URLSessionDelegate, @unchecked Sendable {
    func urlSession(
        _ session: URLSession,
        didReceive challenge: URLAuthenticationChallenge,
        completionHandler: @escaping @Sendable (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
    ) {
        guard challenge.protectionSpace.authenticationMethod == NSURLAuthenticationMethodServerTrust,
              let trust = challenge.protectionSpace.serverTrust else {
            completionHandler(.performDefaultHandling, nil)
            return
        }
        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.useCredential, URLCredential(trust: trust))
        }
    }
}

actor JavhdSource {
    private static let site = "javhd"
    private static let host = "https://javhd.com"
    private static let origin = "https://javhd.com/zh/"
    private static let activeHost = "javhd.com"
    private static let userAgent = "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36"
    private static let listAccept = "application/json, text/plain, */*"
    private static let pageAccept = "text/html,application/json"
    private static let maxBytes = 2 * 1024 * 1024

    private let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 30
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        // 该站在部分网络下返回的证书链不完整，系统严格校验会直接失败并表现为
        // 网络层错误（拿不到 HTTP 状态码）。交给下面的 delegate 先按默认规则校验，
        // 只有证书本身不被信任时才接受这条线路自己的 trust。
        session = URLSession(
            configuration: configuration,
            delegate: JavhdTrustDelegate(),
            delegateQueue: nil
        )
    }

    func list(type: String, page: Int) async throws -> ListPage {
        let current = max(1, page)
        let path = try JavhdHTML.listPath(type: type, page: current)
        let body = try await load(path: path, method: "POST", accept: Self.listAccept)
        return try Self.page(body: body, requested: current)
    }

    func search(keyword: String, page: Int) async throws -> ListPage {
        let current = max(1, page)
        let path = try JavhdHTML.searchPath(keyword: keyword, page: current)
        let body = try await load(path: path, method: "POST", accept: Self.listAccept)
        return try Self.page(body: body, requested: current)
    }

    func resolve(_ item: VideoItem, resolution: String?) async throws -> Playable {
        let watch = try JavhdHTML.watchPath(id: item.id)
        let html = try await load(path: watch, method: "GET", accept: Self.pageAccept)
        guard let playerId = JavhdHTML.playerId(html: html) else {
            throw RepositoryError.missingPlaybackURL
        }
        let api = try JavhdHTML.apiPath(playerId: playerId)
        let body = try await load(path: api, method: "GET", accept: Self.pageAccept)
        let streams = JavhdHTML.parseSources(body)
        guard let fallback = streams.first else { throw RepositoryError.missingPlaybackURL }
        // 线路 key 是清晰度字符串；对不上就退回排序后的第一源（1080 优先）。
        let wanted = resolution?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let chosen = streams.first(where: { String($0.res) == wanted }) ?? fallback
        guard let playURL = Self.mediaURL(chosen.url) else { throw RepositoryError.missingPlaybackURL }
        let streamURLs = [playURL] + streams.compactMap { Self.mediaURL($0.url) }.filter { $0 != playURL }
        let lines = streams.filter { $0.res > 0 }.map { Choice(key: String($0.res), label: "\($0.res)p") }
        return Playable(
            id: item.id,
            title: item.displayTitle,
            playURL: playURL,
            streamURLs: streamURLs,
            cover: item.cover,
            duration: item.duration,
            activeHost: Self.activeHost,
            lineKey: String(chosen.res),
            lines: lines,
            pageOrigin: Self.origin,
            site: Self.site,
            sourcePageURL: nil
        )
    }

    private static func page(body: String, requested: Int) throws -> ListPage {
        guard let listing = try? JavhdHTML.parseListing(body) else {
            throw RepositoryError.invalidResponse("JAVHD 列表暂不可用，请重试")
        }
        let current = max(1, requested)
        let total = max(current, listing.totalPage)
        return ListPage(items: listing.items, page: current, totalPage: total, openEnded: current < total)
    }

    /// 站点路径全部以 `/zh/` 开头，必须相对主机根解析；拼到 origin 后面会变成 `/zh/zh/`。
    private static func absolute(_ path: String) -> URL? {
        guard let base = URL(string: host),
              let url = URL(string: path, relativeTo: base)?.absoluteURL,
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "javhd.com" else { return nil }
        return url
    }

    private static func mediaURL(_ raw: String) -> URL? {
        guard let url = URL(string: raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              ["http", "https"].contains(url.scheme?.lowercased() ?? "") else { return nil }
        return url
    }

    private func load(path: String, method: String, accept: String) async throws -> String {
        guard let url = Self.absolute(path) else {
            throw RepositoryError.invalidResponse("JAVHD 地址无效，请重试")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.origin, forHTTPHeaderField: "Referer")
        request.setValue(accept, forHTTPHeaderField: "Accept")
        if method == "POST" {
            // 列表接口只认带这个头的空 body POST，缺了就回整页 HTML。
            request.setValue("XMLHttpRequest", forHTTPHeaderField: "X-Requested-With")
            request.httpBody = Data()
        }
        let data: Data
        let response: URLResponse
        do {
            let result = try await session.data(for: request)
            data = result.0
            response = result.1
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            // 保留底层原因（-1200 证书、-1003 域名解析、-1004 连接被拒等）：
            // 这条路径拿不到 HTTP 状态码，只有错误码能说明是 TLS 还是网络问题。
            let reason = (error as NSError).localizedDescription
            throw RepositoryError.invalidResponse("JAVHD 请求失败，请重试（\(reason)）")
        }
        guard let http = response as? HTTPURLResponse else {
            throw RepositoryError.invalidResponse("JAVHD 响应异常，请重试")
        }
        guard 200..<300 ~= http.statusCode else {
            throw RepositoryError.invalidResponse("JAVHD 请求失败（HTTP \(http.statusCode)）")
        }
        // 先看声明长度，再看实际字节：列表页正常只有几十 KB，超过 2MB 多半是被挡到了别的页面。
        if let declared = http.value(forHTTPHeaderField: "Content-Length"),
           let length = Int(declared.trimmingCharacters(in: .whitespacesAndNewlines)),
           length > Self.maxBytes {
            throw RepositoryError.invalidResponse("JAVHD 响应过大，请重试")
        }
        guard data.count <= Self.maxBytes else {
            throw RepositoryError.invalidResponse("JAVHD 响应过大，请重试")
        }
        guard let body = String(data: data, encoding: .utf8) else {
            throw RepositoryError.invalidResponse("JAVHD 响应为空，请重试")
        }
        return body
    }
}
