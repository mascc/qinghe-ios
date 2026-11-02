import Foundation

/// 海角帖子的完整字段。列表与详情共用同一套解析，详情多出附件编号、
/// 分类编号与真实付费类型，地址发现需要它们。
struct HaijiaoTopic {
    let id: String
    let title: String
    let cover: String?
    let author: String?
    let views: String?
    let time: String?
    let tags: [String]
    let attachmentID: String?
    let previewURL: String?
    let sale: Bool
    let hasVideo: Bool
    let categoryID: String?
    let moneyType: Int?

    var videoType: String {
        guard hasVideo else { return "图文" }
        switch moneyType {
        case 1: return "金币片"
        case 2: return "钻石片"
        default: return sale ? "付费片" : "普通片"
        }
    }
}

/// 一次播放解析的结果：地址、是否只是预览，以及这份清单该用哪套密钥版本。
struct HaijiaoResolution {
    let url: URL
    let isPreview: Bool
    let keyVersions: [String]
}

/// 海角的目录、账号与播放地址解析。
///
/// 列表与详情走站点自己的公开接口；播放地址按 `user.txt` 的顺序发现：
/// 帖子自带预览 → 已有清单判定/分片反推 → 跨帖 attachment（可播放主题 id 作
/// resource_id）→ 视频中心通道。命中过的主题 id 会被记住，下次先试。
/// 密钥不在这里算，交给播放桥接层（`HaijiaoKeyResolver`）在密钥请求上现场还原。
actor HaijiaoSource {
    static let origin = "https://www.haijiao.com/"
    static let host = "https://www.haijiao.com"
    private static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1"
    private static let lines = ["", "normal1", "normal2", "vip"]
    private static let videoPages = 6
    private static let videoPageSize = 50
    private static let crossPages = 2
    private static let crossPageSize = 100
    private static let crossMaxTry = 12
    private static let cachedTopicLimit = 6
    private static let allCategory = "900"
    private static let maxPlaylistBytes = HaijiaoKeys.maxPlaylistBytes

    private let session: URLSession
    private let defaults = UserDefaults.standard

    private var token: String?
    private var userID: String?
    private var nickname = ""
    private var sessionVersion = 0
    private var cachedTopicIDs: [String]
    private var keyVersions: [String] = ["1", "2"]

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.timeoutIntervalForResource = 40
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: configuration)
        token = defaults.string(forKey: Self.tokenKey).flatMap { $0.isEmpty ? nil : $0 }
        userID = defaults.string(forKey: Self.userIDKey).flatMap { $0.isEmpty ? nil : $0 }
        nickname = defaults.string(forKey: Self.nickKey) ?? ""
        cachedTopicIDs = (defaults.string(forKey: Self.freeTopicKey) ?? "")
            .split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    // MARK: - 账号

    func isLoggedIn() -> Bool { token != nil && userID != nil }

    func accountLabel() -> String {
        guard token != nil, let userID else { return "未登录" }
        return "已登录 \(nickname.isEmpty ? userID : nickname)"
    }

    /// 站点登录接口的字段名在历史上换过几次，按上游顺序逐个试，
    /// 成功后立刻落盘并把主题缓存绑定到本次会话。
    func login(account: String, password: String) async throws -> String {
        let name = account.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !password.isEmpty else {
            throw RepositoryError.invalidResponse("请填写账号和密码")
        }
        let version = sessionVersion
        var last = "登录失败"
        let payloads: [[String: Any]] = [
            ["username": name, "password": password],
            ["email": name, "password": password],
            ["account": name, "password": password],
        ]
        for body in payloads {
            do {
                let root = try await requestJSON(path: "/api/login/signin", method: "POST", body: body)
                let success = (root["success"] as? Bool) ?? false
                let errorCode = Self.integer(root["errorCode"]) ?? -1
                guard success || errorCode == 0 else {
                    last = Self.text(root["message"]) ?? "登录失败"
                    continue
                }
                guard let data = root["data"] as? [String: Any] else { continue }
                let token = (Self.text(data["token"]) ?? Self.text(data["Token"]) ?? "").trimmingCharacters(in: .whitespaces)
                let rawID = Self.identifier(data["id"]) ?? Self.identifier(data["userId"])
                    ?? (data["user"] as? [String: Any]).flatMap { Self.identifier($0["id"]) }
                guard !token.isEmpty, let rawID else {
                    last = "登录信息不完整，请重试"
                    continue
                }
                guard version == sessionVersion else {
                    throw RepositoryError.invalidResponse("账号状态已改变")
                }
                let switched = self.userID != nil && self.userID != rawID
                sessionVersion += 1
                self.token = token
                self.userID = rawID
                nickname = (data["user"] as? [String: Any]).flatMap { Self.text($0["nickname"]) } ?? ""
                persistSession(clearTopicCache: switched)
                return accountLabel()
            } catch let error as RepositoryError {
                throw error
            } catch {
                last = error.localizedDescription
            }
        }
        throw RepositoryError.invalidResponse(last)
    }

    func logout() {
        sessionVersion += 1
        token = nil
        userID = nil
        nickname = ""
        cachedTopicIDs = []
        for key in [Self.tokenKey, Self.userIDKey, Self.nickKey, Self.freeTopicKey] {
            defaults.removeObject(forKey: key)
        }
    }

    // MARK: - 目录

    func catalog(feed: String, page: Int) async throws -> ListPage {
        let current = max(1, page)
        let root = try await requestJSON(path: Self.listPath(feed: feed, page: current))
        return Self.listPage(root: root, fallbackPage: current)
    }

    /// 站点没有服务端全局搜索：按上游做法在当前频道第一页做本地过滤，
    /// 界面上会明确显示这个范围。
    func search(keyword: String, feed: String) async throws -> ListPage {
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw RepositoryError.invalidResponse("搜索关键词不能为空") }
        let page = try await catalog(feed: Self.searchFeed(feed), page: 1)
        let matches = page.items.filter { item in
            item.displayTitle.localizedCaseInsensitiveContains(query)
                || item.uploaderName.localizedCaseInsensitiveContains(query)
                || item.tags.contains { $0.localizedCaseInsensitiveContains(query) }
        }
        return ListPage(items: matches, page: 1, totalPage: 1, openEnded: false)
    }

    func nodes() async throws -> [Choice] {
        let root = try await requestJSON(path: "/api/topic/nodes_by_ver/v2?ver=0")
        let data = root["data"]
        let rows: [Any]
        if let object = data as? [String: Any], let list = object["list"] as? [Any] {
            rows = list
        } else if let array = data as? [Any] {
            rows = array
        } else {
            throw RepositoryError.invalidResponse("海角节点响应不完整")
        }
        var seen = Set<String>()
        return rows.compactMap { raw -> Choice? in
            guard let row = raw as? [String: Any],
                  let parent = Self.integer(row["parentId"]), parent != 0,
                  let id = Self.identifier(row["nodeId"]), seen.insert(id).inserted else { return nil }
            let name = Self.text(row["name"])?.trimmingCharacters(in: .whitespacesAndNewlines)
            return Choice(key: Self.nodeKey(id), label: name?.isEmpty == false ? name! : "节点 \(id)")
        }
    }

    // MARK: - 播放地址

    /// 完整解析：先按站点公开的接口找全片，找不到才退回预览。
    /// 登录后才会尝试成员通道（attachment 的其它线路、跨帖与视频中心）。
    func resolve(_ item: VideoItem) async throws -> HaijiaoResolution {
        guard item.site == SiteProfile.haijiao.id, !item.id.isEmpty else {
            throw RepositoryError.invalidResponse("海角帖子编号无效")
        }
        let version = sessionVersion
        await refreshKeyVersion()
        let topic = try await detailTopic(id: item.id)
        guard version == sessionVersion else {
            throw RepositoryError.invalidResponse("海角账号已改变，请重新打开视频")
        }
        guard let attachmentID = topic.attachmentID else {
            throw RepositoryError.invalidResponse("这篇帖子没有视频附件")
        }
        let found = try await findURL(topic: topic, attachmentID: attachmentID)
        guard version == sessionVersion else {
            throw RepositoryError.invalidResponse("海角账号已改变，请重新打开视频")
        }
        if let full = found.full, let url = URL(string: full) {
            return HaijiaoResolution(url: url, isPreview: false, keyVersions: keyVersions)
        }
        if let preview = found.preview, let url = URL(string: preview) {
            return HaijiaoResolution(url: url, isPreview: true, keyVersions: keyVersions)
        }
        throw RepositoryError.invalidResponse(
            isLoggedIn() ? "暂时没有可用的播放地址，请检查账号权限后重试" : "没有公开预览，请先登录海角账号"
        )
    }

    private func findURL(topic: HaijiaoTopic, attachmentID: String) async throws -> (full: String?, preview: String?) {
        var seen = Set<String>()
        var found: [String] = []
        func append(_ values: [String]) {
            for value in values where seen.insert(value).inserted { found.append(value) }
        }
        if let preview = topic.previewURL { append([preview]) }
        if let full = Self.firstFull(found) { return (full, nil) }

        let loggedIn = isLoggedIn()
        if let root = try? await requestJSON(path: "/api/topic/att/\(attachmentID)") {
            append(Self.playURLs(in: root["data"]))
        }
        if let full = Self.firstFull(found) { return (full, nil) }

        if loggedIn {
            for line in Self.lines {
                append((try? await attachmentURLs(attachmentID: attachmentID, resourceID: topic.id, type: "topic", line: line)) ?? [])
                if let full = Self.firstFull(found) { return (full, nil) }
            }
        }
        for candidate in found {
            if let full = await discoverPlaylist(url: candidate) { return (full, nil) }
        }
        if loggedIn {
            if let full = await crossProbe(attachmentID: attachmentID, ownTopicID: topic.id) { return (full, nil) }
            if let full = await videoCenter(attachmentID: attachmentID, categoryID: topic.categoryID) { return (full, nil) }
        }
        return (nil, found.first)
    }

    /// `POST /api/attachment` 的 resource_id 是主题上下文，不必是当前帖子。
    /// 先试上次命中的 id，再从视频中心收集 can_play 主题，命中即停。
    ///
    /// 两轮探查在同一个顺序循环里完成：`tried` / `order` 都是本方法的局部状态，
    /// 不交给嵌套的 async 函数，避免 Swift 6 把跨隔离域的可变捕获判成数据竞争。
    private func crossProbe(attachmentID: String, ownTopicID: String) async -> String? {
        let skip: Set<String> = [attachmentID, ownTopicID]
        var tried = Set<String>()
        var order: [String] = []
        var batches: [[String]] = [cachedTopicIDs]
        var index = 0

        while index < batches.count {
            for id in batches[index] {
                guard !skip.contains(id), tried.insert(id).inserted else { continue }
                guard order.count < Self.crossMaxTry else { return nil }
                order.append(id)
                let urls = (try? await attachmentURLs(attachmentID: attachmentID, resourceID: id, type: "topic", line: "")) ?? []
                if let full = Self.firstFull(urls) {
                    rememberTopic(id)
                    return full
                }
            }
            index += 1
            // 第一轮（缓存主题）用完、且还没到尝试上限时，才去收集视频中心的可播放主题。
            if index == 1, order.count < Self.crossMaxTry {
                batches.append(await collectPlayableTopicIDs())
            }
        }
        return nil
    }

    private func collectPlayableTopicIDs() async -> [String] {
        var output: [String] = []
        for page in 1...Self.crossPages {
            guard let root = try? await requestJSON(path: Self.videoCenterPath(category: Self.allCategory, page: page, limit: Self.crossPageSize)),
                  let rows = Self.resultRows(root["data"]), !rows.isEmpty else { break }
            for row in rows where Self.canPlay(row) {
                guard let id = Self.identifier(row["id"]), !output.contains(id) else { continue }
                output.append(id)
            }
        }
        return output
    }

    private func videoCenter(attachmentID: String, categoryID: String?) async -> String? {
        var categories: [String] = []
        if let categoryID, !categoryID.isEmpty { categories.append(categoryID) }
        if !categories.contains(Self.allCategory) { categories.append(Self.allCategory) }
        for category in categories {
            for page in 1...Self.videoPages {
                guard let root = try? await requestJSON(path: Self.videoCenterPath(category: category, page: page, limit: Self.videoPageSize)),
                      let rows = Self.resultRows(root["data"]), !rows.isEmpty else { break }
                guard let videoID = Self.matchingVideoID(rows: rows, attachmentID: attachmentID) else { continue }
                for line in Self.lines {
                    let urls = (try? await attachmentURLs(attachmentID: attachmentID, resourceID: videoID, type: "video", line: line)) ?? []
                    if let full = Self.firstFull(urls) { return full }
                }
                break
            }
        }
        return nil
    }

    /// 预览清单里的分片只是片段：按首片名反推同名完整清单，再用分片数与时长确认。
    private func discoverPlaylist(url: String) async -> String? {
        guard let current = await readPlaylist(url: url) else { return nil }
        guard let baseline = Self.media(in: current) else { return nil }
        if baseline.isFull { return current.url }
        for candidate in Self.fullCandidates(playlistURL: current.url, firstSegment: baseline.firstSegment) {
            guard candidate != url, candidate != current.url else { continue }
            guard let playlist = await readPlaylist(url: candidate) else { continue }
            guard let parsed = Self.media(in: playlist) else { continue }
            if parsed.isFull { return playlist.url }
            if parsed.segmentCount > baseline.segmentCount,
               parsed.durationSeconds > baseline.durationSeconds + 1,
               !Self.isPreview(playlist.url) {
                return playlist.url
            }
        }
        return nil
    }

    private func readPlaylist(url: String) async -> (url: String, text: String)? {
        guard let remote = URL(string: url) else { return nil }
        var request = URLRequest(url: remote)
        request.timeoutInterval = 20
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(Self.origin, forHTTPHeaderField: "Referer")
        request.setValue(Self.host, forHTTPHeaderField: "Origin")
        guard let (data, response) = try? await session.data(for: request),
              let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode,
              data.count <= Self.maxPlaylistBytes else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        guard text.replacingOccurrences(of: "\u{FEFF}", with: "").trimmingCharacters(in: .whitespaces).hasPrefix("#EXTM3U") else {
            return nil
        }
        return (http.url?.absoluteString ?? url, text)
    }

    private func attachmentURLs(attachmentID: String, resourceID: String, type: String, line: String) async throws -> [String] {
        var body: [String: Any] = [
            "resource_id": Int(resourceID) ?? resourceID,
            "resource_type": type,
            "line": line,
        ]
        body["id"] = Int(attachmentID) ?? attachmentID
        let root = try await requestJSON(path: "/api/attachment", method: "POST", body: body)
        return Self.playURLs(in: root["data"])
    }

    private func detailTopic(id: String) async throws -> HaijiaoTopic {
        let root = try await requestJSON(path: "/api/topic/\(id)")
        guard let data = root["data"] as? [String: Any], let topic = Self.topic(data) else {
            throw RepositoryError.invalidResponse("帖子详情不完整，请重试")
        }
        return topic
    }

    private func refreshKeyVersion() async {
        guard let root = try? await requestJSON(path: "/api/login/conf"),
              let data = root["data"] as? [String: Any] else { return }
        let raw = Self.text(data["kversion"])?.trimmingCharacters(in: .whitespaces) ?? ""
        guard !raw.isEmpty, raw != "null" else { return }
        keyVersions = ([raw, "1", "2"] as [String]).reduce(into: [String]()) { result, value in
            if !result.contains(value) { result.append(value) }
        }
    }

    private func rememberTopic(_ id: String) {
        let trimmed = id.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        cachedTopicIDs = Array(([trimmed] + cachedTopicIDs.filter { $0 != trimmed }).prefix(Self.cachedTopicLimit))
        defaults.set(cachedTopicIDs.joined(separator: ","), forKey: Self.freeTopicKey)
    }

    private func persistSession(clearTopicCache: Bool) {
        defaults.set(token, forKey: Self.tokenKey)
        defaults.set(userID, forKey: Self.userIDKey)
        defaults.set(nickname, forKey: Self.nickKey)
        if clearTopicCache {
            cachedTopicIDs = []
            defaults.removeObject(forKey: Self.freeTopicKey)
        }
    }

    // MARK: - 网络

    private func requestJSON(path: String, method: String = "GET", body: [String: Any]? = nil) async throws -> [String: Any] {
        guard let url = URL(string: path, relativeTo: URL(string: Self.origin))?.absoluteURL,
              url.scheme?.lowercased() == "https",
              url.host?.lowercased() == "www.haijiao.com" else {
            throw RepositoryError.invalidResponse("海角目录地址无效")
        }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = 20
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue("application/json, text/plain, */*", forHTTPHeaderField: "Accept")
        request.setValue("2", forHTTPHeaderField: "pcVer")
        request.setValue(Self.origin, forHTTPHeaderField: "Referer")
        request.setValue(Self.host, forHTTPHeaderField: "Origin")
        if let token, let userID {
            request.setValue(token, forHTTPHeaderField: "X-User-Token")
            request.setValue(userID, forHTTPHeaderField: "X-User-Id")
        }
        if let body {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (payload, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RepositoryError.invalidResponse("海角目录请求失败")
        }
        guard 200..<300 ~= http.statusCode else {
            throw RepositoryError.invalidResponse("海角服务暂时不可用（HTTP \(http.statusCode)），请重试")
        }
        guard let raw = try JSONSerialization.jsonObject(with: payload) as? [String: Any] else {
            throw RepositoryError.invalidResponse("海角目录响应不是对象")
        }
        let root = Self.decodePayload(raw)
        if let success = root["success"] as? Bool, !success {
            let message = Self.text(root["message"]) ?? "海角请求未成功"
            throw RepositoryError.invalidResponse(String(message.prefix(120)))
        }
        if let code = Self.integer(root["errorCode"]), code != 0 {
            let message = Self.text(root["message"]) ?? "海角请求未成功"
            throw RepositoryError.invalidResponse(String(message.prefix(120)))
        }
        return root
    }

    // MARK: - 解析

    private static func listPath(feed: String, page: Int) -> String {
        let current = max(1, page)
        if let node = nodeID(feed) {
            return "/api/topic/node/topics?type=1&nodeId=\(node)&page=\(current)"
        }
        switch feed {
        case "news": return "/api/topic/node/news?page=\(current)"
        case "original": return "/api/topic/node/topics?type=7&page=\(current)"
        case "cream": return "/api/topic/node/topics?type=3&nodeId=0&page=\(current)"
        case "latest": return "/api/topic/node/topics?type=1&nodeId=0&page=\(current)"
        default: return "/api/topic/hot/topics?page=\(current)"
        }
    }

    private static func searchFeed(_ feed: String) -> String {
        if nodeID(feed) != nil { return feed }
        return ["hot", "latest", "cream", "original", "news"].contains(feed) ? feed : "hot"
    }

    private static func nodeKey(_ id: String) -> String { "node:\(id)" }

    private static func nodeID(_ feed: String) -> String? {
        guard feed.hasPrefix("node:") else { return nil }
        let id = String(feed.dropFirst("node:".count))
        return !id.isEmpty && id.allSatisfy { $0.isNumber } ? id : nil
    }

    private static func listPage(root: [String: Any], fallbackPage: Int) -> ListPage {
        let data = root["data"]
        let rows: [Any]
        let pagination: [String: Any]?
        if let object = data as? [String: Any] {
            rows = object["results"] as? [Any] ?? []
            pagination = object["page"] as? [String: Any]
        } else if let array = data as? [Any] {
            rows = array
            pagination = nil
        } else {
            return ListPage(items: [], page: max(1, fallbackPage), totalPage: 1, openEnded: false)
        }
        let items = rows.compactMap { topic($0) }.filter { $0.hasVideo }.map { item($0) }
        let current = max(1, integer(pagination?["page"]) ?? fallbackPage)
        let limit = max(1, integer(pagination?["limit"]) ?? 20)
        // 总页数来自原始帖子数：过滤掉图文之后的空页不代表后面没有视频。
        let total = max(0, integer(pagination?["total"]) ?? rows.count)
        let totalPage = max(1, (total + limit - 1) / limit)
        return ListPage(items: items, page: current, totalPage: totalPage, openEnded: current < totalPage)
    }

    private static func item(_ topic: HaijiaoTopic) -> VideoItem {
        VideoItem(
            id: topic.id,
            title: topic.title,
            cover: topic.cover,
            duration: nil,
            views: topic.views,
            user: topic.author,
            vip: topic.sale,
            timeLine: topic.time.map { String($0.prefix(16)) },
            videoType: topic.videoType,
            tags: topic.tags,
            site: SiteProfile.haijiao.id,
            sourcePageURL: topicPageURL(id: topic.id)?.absoluteString,
            previewURL: topic.previewURL
        )
    }

    static func topicPageURL(id: String) -> URL? {
        guard !id.isEmpty else { return nil }
        var components = URLComponents(string: origin)
        components?.path = "/post/details"
        components?.queryItems = [URLQueryItem(name: "topicId", value: id)]
        return components?.url
    }

    private static func topic(_ raw: Any) -> HaijiaoTopic? {
        guard let row = raw as? [String: Any], let id = identifier(row["topicId"]) else { return nil }
        var cover: String?
        var attachmentID: String?
        var preview: String?
        let attachments = row["attachments"] as? [Any] ?? []
        for attachmentRaw in attachments {
            guard let attachment = attachmentRaw as? [String: Any] else { continue }
            if text(attachment["category"])?.lowercased() != "video" {
                if cover == nil { cover = imageURL(attachment["coverUrl"]) }
                continue
            }
            // 多附件帖子始终选择同一段视频的编号、预览和封面。
            if attachmentID != nil { continue }
            guard let candidate = identifier(attachment["id"]) else { continue }
            attachmentID = candidate
            let remote = text(attachment["remoteUrl"])?.trimmingCharacters(in: .whitespaces) ?? ""
            if remote.range(of: ".m3u8", options: .caseInsensitive) != nil { preview = remote }
            cover = imageURL(attachment["coverUrl"]) ?? cover
        }
        let tags = (row["tags"] as? [Any] ?? []).compactMap { raw -> String? in
            guard let value = raw as? [String: Any] else { return nil }
            let name = text(value["tagName"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return name.isEmpty ? nil : name
        }
        let sale = row["sale"] as? [String: Any]
        // 列表的类型在顶层，详情的真实付费类型在 sale 内。
        let moneyType = integer(sale?["money_type"]) ?? integer(row["money_type"])
        let categoryID = [row["category_id"], (row["category"] as? [String: Any])?["id"]]
            .compactMap { value -> String? in
                guard let raw = identifier(value), raw != "0", raw.allSatisfy({ $0.isNumber }) else { return nil }
                return raw
            }
            .first
        let title = text(row["title"])?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return HaijiaoTopic(
            id: id,
            title: title.isEmpty ? "帖子 \(id)" : title,
            cover: cover,
            author: (row["user"] as? [String: Any]).flatMap { text($0["nickname"]) }.flatMap { $0.isEmpty ? nil : $0 },
            views: integer(row["viewCount"]).flatMap { $0 > 0 ? String($0) : nil },
            time: text(row["createTime"]).flatMap { $0.isEmpty ? nil : $0 },
            tags: tags,
            attachmentID: attachmentID,
            previewURL: preview,
            sale: sale != nil || (moneyType ?? 0) > 0,
            hasVideo: attachmentID != nil || boolean(row["hasVideo"]),
            categoryID: categoryID,
            moneyType: moneyType
        )
    }

    private static func media(in playlist: (url: String, text: String)) -> HaijiaoKeys.Media? {
        let body = playlist.text.replacingOccurrences(of: "\u{FEFF}", with: "").trimmingCharacters(in: .whitespaces)
        guard body.hasPrefix("#EXTM3U"),
              body.contains("#EXTINF:"),
              !body.contains("#EXT-X-STREAM-INF"),
              body.contains("#EXT-X-ENDLIST") else { return nil }
        guard let parsed = try? HaijiaoKeys.parse(text: playlist.text, baseURL: playlist.url),
              parsed.segmentCount > 0, parsed.durationSeconds > 0 else { return nil }
        return parsed
    }

    private static func isPreview(_ url: String) -> Bool {
        guard let path = URL(string: url)?.path else { return false }
        return path.range(of: #"(?:^|[/_.-])preview(?:[/_.-]|$)"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func firstFull(_ urls: [String]) -> String? {
        urls.first { !isPreview($0) }
    }

    /// 预览清单的两个可推导完整清单地址：去掉文件名里的 `_preview`，
    /// 或用首片名里的公共片段名换回 `_i.m3u8`。
    private static func fullCandidates(playlistURL: String, firstSegment: String?) -> [String] {
        var output: [String] = []
        var seen = Set<String>()
        func append(_ value: String?) {
            guard let value, value != playlistURL, seen.insert(value).inserted else { return }
            output.append(value)
        }
        if let range = playlistURL.range(of: #"_preview(?=\.m3u8$)"#, options: [.regularExpression, .caseInsensitive]) {
            append(playlistURL.replacingCharacters(in: range, with: ""))
        }
        if let firstSegment,
           let match = firstSegment.range(of: #"[A-Za-z0-9]{6,}_i\d+\.ts$"#, options: .regularExpression),
           let suffix = firstSegment.range(of: #"_i\d+\.ts$"#, options: .regularExpression) {
            // 首片名形如 `abc123def_i1.ts`：公共片段名加回 `_i.m3u8` 就是完整清单。
            let base = String(firstSegment[..<suffix.lowerBound])
            append(base + "_i.m3u8")
            _ = match
        }
        return output
    }

    private static func videoCenterPath(category: String, page: Int, limit: Int) -> String {
        "/api/video-center/video/list?id=\(category)&page=\(page)&limit=\(limit)"
    }

    private static func resultRows(_ data: Any?) -> [[String: Any]]? {
        if let object = data as? [String: Any] { return (object["results"] as? [Any])?.compactMap { $0 as? [String: Any] } }
        if let array = data as? [Any] { return array.compactMap { $0 as? [String: Any] } }
        return nil
    }

    private static func matchingVideoID(rows: [[String: Any]], attachmentID: String) -> String? {
        for row in rows where identifier(row["attachment_id"]) == attachmentID {
            return identifier(row["id"])
        }
        return nil
    }

    private static func canPlay(_ row: [String: Any]) -> Bool {
        guard let value = row["can_play"], !(value is NSNull) else { return false }
        return boolean(value)
    }

    private static func playURLs(in raw: Any?) -> [String] {
        var found: [String] = []
        var seen = Set<String>()
        func visit(_ value: Any?) {
            switch value {
            case let string as String:
                let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") {
                    if seen.insert(trimmed).inserted { found.append(trimmed) }
                } else if let json = jsonValue(text: trimmed) {
                    visit(json)
                }
            case let array as [Any]:
                array.forEach(visit)
            case let object as [String: Any]:
                visit(object["remoteUrl"])
                visit(object["url"])
                visit(object["data"])
            default:
                break
            }
        }
        visit(raw)
        return found
    }

    private static func decodePayload(_ root: [String: Any]) -> [String: Any] {
        var output = root
        if let data = root["data"] { output["data"] = unwrap(data) }
        return output
    }

    private static func unwrap(_ raw: Any) -> Any {
        guard var text = raw as? String else { return raw }
        for _ in 0..<5 {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            if let json = jsonValue(text: trimmed) { return json }
            let compact = trimmed.filter { !$0.isWhitespace }
            let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/=")
            guard compact.count >= 8, compact.unicodeScalars.allSatisfy({ allowed.contains($0) }),
                  let bytes = Data(base64Encoded: paddedBase64(compact)),
                  let decoded = String(data: bytes, encoding: .utf8) else { break }
            text = decoded
        }
        return jsonValue(text: text) ?? raw
    }

    private static func paddedBase64(_ text: String) -> String {
        let remainder = text.count % 4
        return remainder == 0 ? text : text + String(repeating: "=", count: 4 - remainder)
    }

    private static func jsonValue(text: String) -> Any? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.first == "{" || trimmed.first == "[",
              let data = trimmed.data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data)
    }

    private static func identifier(_ value: Any?) -> String? {
        let result = text(value)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return result.isEmpty || result == "null" ? nil : result
    }

    private static func text(_ value: Any?) -> String? {
        switch value {
        case let string as String: return string
        case let number as NSNumber: return number.stringValue
        default: return nil
        }
    }

    private static func integer(_ value: Any?) -> Int? {
        switch value {
        case let number as NSNumber: return number.intValue
        case let string as String: return Int(string)
        default: return nil
        }
    }

    private static func boolean(_ value: Any?) -> Bool {
        switch value {
        case let bool as Bool: return bool
        case let number as NSNumber: return number.intValue != 0
        case let string as String: return string == "1" || string.lowercased() == "true"
        default: return false
        }
    }

    private static func imageURL(_ value: Any?) -> String? {
        guard let raw = text(value)?.trimmingCharacters(in: .whitespacesAndNewlines),
              let url = URL(string: raw) else { return nil }
        let path = url.path.lowercased()
        return path.hasSuffix(".txt") || path.hasSuffix(".hj") ? nil : url.absoluteString
    }

    private static let tokenKey = "pornshop_haijiao_token"
    private static let userIDKey = "pornshop_haijiao_uid"
    private static let nickKey = "pornshop_haijiao_nick"
    private static let freeTopicKey = "pornshop_haijiao_free_topics"
}
