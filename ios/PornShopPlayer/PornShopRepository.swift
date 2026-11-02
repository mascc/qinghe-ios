import Foundation

enum RepositoryError: LocalizedError {
    case invalidResponse(String)
    case missingPlaybackURL

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let message): message
        case .missingPlaybackURL: "没有可播放的地址"
        }
    }
}

actor PornShopRepository {
    static let apiVersion = "260901"
    static let aesPassphrase = "xxx"
    static let hosts = [
        "https://v2.cdn199.com", "https://v2.kekecdn.net", "https://v2.luchu.org",
        "https://v2.madou.ws", "https://v2.papapa.biz", "https://v2.tianmtv.com",
        "https://v2.xiaoshuo.info", "https://v2.xiaoshuo.la",
    ]

    private var preferredHost = hosts[0]
    private let session: URLSession

    init() {
        let config = URLSessionConfiguration.default
        config.timeoutIntervalForRequest = 30
        config.timeoutIntervalForResource = 60
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: config)
    }

    func currentHost() -> String { preferredHost }

    func cycleHost() -> String {
        let index = Self.hosts.firstIndex(of: preferredHost) ?? -1
        preferredHost = Self.hosts[(index + 1) % Self.hosts.count]
        return preferredHost
    }

    func listVideos(type: String, page: Int, profile: SiteProfile) async throws -> ListPage {
        let current = max(1, page)
        let response = try await call(path: "/sevenVideos?page=\(current)&type=\(type)", profile: profile)
        guard case .array(let values) = response else {
            throw RepositoryError.invalidResponse("列表响应不是数组")
        }
        let items = parseVideos(values, site: profile.id)
        let full = items.count >= pageSize(for: type)
        return ListPage(items: items, page: current, totalPage: full ? current + 1 : current, openEnded: full)
    }

    func search(
        keyword: String,
        page: Int,
        profile: SiteProfile,
        category: String = "all",
        timeInDays: String = "all",
        views: String = "all",
        durationMins: String = "all",
        sortBy: String = "time",
        keywordLogic: String = "or"
    ) async throws -> ListPage {
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { throw RepositoryError.invalidResponse("搜索关键词不能为空") }
        let current = max(1, page)
        let response = try await call(path: "/searchSevenVideos", profile: profile, fields: [
            "page": current, "keywords": query, "filterCategory": category,
            "filterTimeInDays": timeInDays, "filterViews": views,
            "filterDurationMins": durationMins, "sortBy": sortBy,
            "keywordLogic": keywordLogic,
        ])
        guard case .array(let values) = response else {
            throw RepositoryError.invalidResponse("搜索响应不是数组")
        }
        let items = parseVideos(values, site: profile.id)
        let full = items.count >= 24
        return ListPage(items: items, page: current, totalPage: full ? current + 1 : current, openEnded: full)
    }

    func resolvePlayable(_ item: VideoItem, line: String? = nil) async throws -> Playable {
        let profile = SiteProfile.all.first(where: { $0.id == item.site }) ?? .pornShop
        let chosen = line.flatMap { value in profile.lines.contains(where: { $0.key == value }) ? value : nil }
            ?? profile.lines.first?.key
        let response = try await call(path: "/sevenVideos/\(item.id)", profile: profile, fields: [
            "userId": NSNull(),
            "url_search": chosen.map { "?server=\($0)" } ?? "",
            "token": "ufd",
        ])
        guard case .object(let object) = response else {
            throw RepositoryError.invalidResponse("详情响应不是对象")
        }
        let rawStreams = (object["m3u8s"] as? [Any] ?? []).compactMap { $0 as? String }
            + [object["m3u8"] as? String].compactMap { $0 }
        var seen = Set<String>()
        let streams = rawStreams.compactMap { URL(string: $0.trimmingCharacters(in: .whitespacesAndNewlines)) }
            .filter { seen.insert($0.absoluteString).inserted }
        guard let url = streams.first else { throw RepositoryError.missingPlaybackURL }
        return Playable(
            id: item.id,
            title: string(object, "title") ?? item.displayTitle,
            playURL: url,
            streamURLs: streams,
            cover: firstThumb(object) ?? item.cover,
            duration: string(object, "durationStr") ?? item.duration,
            activeHost: preferredHost.replacingOccurrences(of: "https://", with: ""),
            lineKey: chosen ?? "",
            lines: profile.lines,
            pageOrigin: profile.pageOrigin,
            site: profile.id,
            sourcePageURL: item.sourcePageURL
        )
    }

    /// 读取糖心Vlog公开网页目录。首页含最新视频与博主，全部视频页支持站方公开分页，
    /// 博主页按站方页面列出该博主的作品；未猜测或调用站方未公开的搜索 API。
    func tangXinCatalog(feed: TangXinFeed, page: Int) async throws -> TangXinCatalog {
        let current = max(1, page)
        let path: String
        switch feed {
        case .home:
            path = "/"
        case .videos:
            path = current == 1 ? "/videos/" : "/videos/\(current)/"
        case .artist(let artist):
            path = artist.path
        }
        let html = try await tangXinHTML(path: path)
        let items = Self.tangXinVideoCards(in: html)
        guard !items.isEmpty else { throw RepositoryError.invalidResponse("页面没有可用的视频列表") }
        let hasNext = feed == .videos && Self.hasTangXinNextPage(in: html)
        let artists = feed == .home ? Self.tangXinArtists(in: html) : []
        return TangXinCatalog(
            page: ListPage(items: items, page: current, totalPage: hasNext ? current + 1 : current, openEnded: hasNext),
            artists: artists
        )
    }

    /// 从糖心Vlog公开“具体视频页”读取页面已经提供给浏览器播放器的 HLS 地址。
    /// 这刻意不包含 Richy (1).txt 中的下载、AES 分片解密、跨域权限或任何会员/会话处理。
    func resolveTangXinPage(_ pageURL: URL) async throws -> (title: String, streamURL: URL) {
        // Foundation 会将 https://host/videos/id/ 的 URL.path 规范化为 /videos/id，
        // 所以路径校验必须接受末尾斜线存在或被移除的两种等价形式。
        guard Self.isTangXinURL(pageURL), pageURL.path.range(of: #"^/videos/[A-Za-z0-9_-]+/?$"#, options: .regularExpression) != nil else {
            throw RepositoryError.invalidResponse("糖心Vlog 视频页地址无效")
        }
        let html = try await tangXinHTML(url: pageURL)
        guard let source = Self.playerSource(in: html),
              let streamURL = URL(string: source, relativeTo: pageURL)?.absoluteURL,
              ["https", "http"].contains(streamURL.scheme?.lowercased() ?? ""),
              streamURL.path.lowercased().contains(".m3u8") else {
            throw RepositoryError.missingPlaybackURL
        }
        return (Self.pageTitle(in: html) ?? "糖心Vlog", streamURL)
    }

    /// Richy-6 对应 rou.video 的公开首页/搜索目录。列表由站点服务端直接渲染，
    /// 因而不需要加载网页广告脚本或访问账号接口。
    func rouVideoCatalog(page: Int, query: String?) async throws -> ListPage {
        let current = max(1, page)
        guard current == 1 else {
            return ListPage(items: [], page: current, totalPage: current, openEnded: false)
        }
        let trimmed = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        var components = URLComponents(string: SiteProfile.rouVideo.pageOrigin)
        components?.path = trimmed.isEmpty ? "/home" : "/search"
        if !trimmed.isEmpty { components?.queryItems = [URLQueryItem(name: "q", value: trimmed)] }
        guard let url = components?.url else { throw RepositoryError.invalidResponse("肉视频目录地址无效") }
        let html = try await rouVideoHTML(url: url)
        let items = Self.rouVideoCards(in: html)
        guard !items.isEmpty else { throw RepositoryError.invalidResponse("页面没有可用的视频列表") }
        return ListPage(items: items, page: current, totalPage: current, openEnded: false)
    }

    /// 从公开视频页中读取站点客户端已经接收的播放入口。`ev` 只是页面内的
    /// base64 偏移编码；解出后得到站方自己的 /api/hls/ 地址，由播放器适配层请求。
    func resolveRouVideoPage(_ pageURL: URL) async throws -> (title: String, streamURL: URL) {
        guard Self.isRouVideoURL(pageURL),
              pageURL.path.range(of: #"^/v/[A-Za-z0-9_-]+/?$"#, options: .regularExpression) != nil else {
            throw RepositoryError.invalidResponse("肉视频页面地址无效")
        }
        let html = try await rouVideoHTML(url: pageURL)
        guard let source = Self.rouPlayerSource(in: html),
              let streamURL = URL(string: source, relativeTo: pageURL)?.absoluteURL,
              streamURL.scheme?.lowercased() == "https",
              streamURL.host?.lowercased() == "rou.video" else {
            throw RepositoryError.missingPlaybackURL
        }
        return (Self.rouPageTitle(in: html) ?? "肉视频", streamURL)
    }

    /// Richy8/9/10/17 对应网站的公开目录与站内公开搜索。这里不加载原网页的广告、
    /// 跟踪或下载脚本，也不会请求登录、会员或私有接口。
    func publicWebsiteCatalog(
        site: String,
        feed: PublicWebsiteFeed?,
        page: Int,
        query: String?
    ) async throws -> PublicWebsiteCatalog {
        let current = max(1, page)
        guard current == 1 else {
            return PublicWebsiteCatalog(
                page: ListPage(items: [], page: current, totalPage: current, openEnded: false), feeds: []
            )
        }
        guard let profile = SiteProfile.all.first(where: { $0.id == site }),
              SiteProfile.publicWebsiteIDs.contains(site),
              let url = Self.publicCatalogURL(profile: profile, feed: feed, query: query) else {
            throw RepositoryError.invalidResponse("播放源目录地址无效")
        }
        let html = try await publicWebsiteText(url: url, profile: profile)
        let items: [VideoItem]
        switch site {
        case SiteProfile.jiuse.id:
            items = Self.jiuseCards(in: html)
        case SiteProfile.eighteenJ.id:
            items = Self.eighteenJCards(in: html)
        case SiteProfile.porna91.id:
            items = Self.porna91Cards(in: html)
        case SiteProfile.dsdSE.id:
            items = DsdWebsite.cards(in: html)
        default:
            items = []
        }
        guard !items.isEmpty else { throw RepositoryError.invalidResponse("页面没有可用的视频列表") }
        return PublicWebsiteCatalog(
            page: ListPage(items: items, page: current, totalPage: current, openEnded: false),
            feeds: Self.publicWebsiteFeeds(in: html, site: site)
        )
    }

    /// 从各家站点自己已公开提供给浏览器播放器的页面/配置中取得 HLS 地址。
    /// 只适配普通公开页；不包含 Richy 脚本里的广告屏蔽、会员遮罩或登录规避逻辑。
    func resolvePublicWebsitePage(_ pageURL: URL, site: String) async throws -> PublicWebsitePlayable {
        guard let profile = SiteProfile.all.first(where: { $0.id == site }),
              SiteProfile.publicWebsiteIDs.contains(site),
              Self.isPublicWebsiteURL(pageURL, site: site) else {
            throw RepositoryError.invalidResponse("播放页面地址无效")
        }
        let html = try await publicWebsiteText(url: pageURL, profile: profile)
        switch site {
        case SiteProfile.jiuse.id:
            guard pageURL.path.range(of: #"^/video/view/[A-Za-z0-9_-]+/?$"#, options: .regularExpression) != nil,
                  let source = Self.jiusePlayerSource(in: html),
                  let streamURL = URL(string: source, relativeTo: pageURL)?.absoluteURL,
                  streamURL.scheme?.lowercased() == "https",
                  streamURL.path.lowercased().contains(".m3u8") else {
                throw RepositoryError.missingPlaybackURL
            }
            return PublicWebsitePlayable(title: Self.websiteTitle(in: html) ?? "九色", streamURL: streamURL)

        case SiteProfile.eighteenJ.id:
            guard pageURL.path.range(of: #"^/v/[0-9]+/?$"#, options: .regularExpression) != nil,
                  let source = Self.capture(#"const\s+source\s*=\s*['\"]([^'\"]+\.m3u8[^'\"]*)['\"]"#, in: html),
                  let streamURL = URL(string: Self.decodeHTMLEntities(source), relativeTo: pageURL)?.absoluteURL,
                  streamURL.scheme?.lowercased() == "https",
                  streamURL.path.lowercased().contains(".m3u8") else {
                throw RepositoryError.missingPlaybackURL
            }
            return PublicWebsitePlayable(title: Self.websiteTitle(in: html) ?? "18J.TV", streamURL: streamURL)

        case SiteProfile.porna91.id:
            guard pageURL.path == "/comic/index/detail" else {
                throw RepositoryError.invalidResponse("91porna 视频页面地址无效")
            }
            let headers = Self.porna91Headers(in: html)
            let title = Self.websiteTitle(in: html) ?? "91porna"
            // 主路径：详情页公开播放器使用的 bootstrap 配置。
            var bootstrapFailure: Error?
            if let bootstrapURL = Self.porna91BootstrapURL(in: html, origin: profile.pageOrigin) {
                do {
                    let config = try await publicWebsiteText(url: bootstrapURL, profile: profile)
                    if let source = Self.capture(#"(https?://[^'\"\\\s]+\.m3u8[^'\"\\\s]*)"#, in: config),
                       let streamURL = URL(string: Self.decodeHTMLEntities(source)),
                       streamURL.scheme?.lowercased() == "https" {
                        return PublicWebsitePlayable(title: title, streamURL: streamURL, mediaHeaders: headers)
                    }
                } catch {
                    bootstrapFailure = error
                }
            }
            // 回退：Richy10 走的是被动读取——详情页自身内联脚本里出现的同一条 m3u8。
            // bootstrap 拿不到时（页面结构变化、时间桶被拒）仍能用站点已下发的地址；
            // 两条都失败时优先报 bootstrap 的具体原因，便于定位。
            guard let inline = Self.capture(#"(https?://[^'\"\\\s]+\.m3u8[^'\"\\\s]*)"#, in: html),
                  let streamURL = URL(string: Self.decodeHTMLEntities(inline)),
                  streamURL.scheme?.lowercased() == "https" else {
                if let bootstrapFailure { throw bootstrapFailure }
                throw RepositoryError.missingPlaybackURL
            }
            return PublicWebsitePlayable(title: title, streamURL: streamURL, mediaHeaders: headers)

        case SiteProfile.dsdSE.id:
            // `DsdWebsite.playerSource` 已经保证返回值含 .m3u8，这里只校验它能落到
            // 一个 http(s) 绝对地址上，不再重复按 path 判定，避免地址只在查询串里
            // 带 .m3u8 时被这里二次否掉、连带吃掉页面回退的机会。
            guard DsdWebsite.isPlayPage(pageURL),
                  let source = DsdWebsite.playerSource(in: html),
                  let streamURL = URL(string: source, relativeTo: pageURL)?.absoluteURL,
                  ["https", "http"].contains(streamURL.scheme?.lowercased() ?? "") else {
                throw RepositoryError.missingPlaybackURL
            }
            return PublicWebsitePlayable(title: DsdWebsite.title(in: html) ?? "懂色帝", streamURL: streamURL)

        default:
            throw RepositoryError.invalidResponse("不支持的播放源")
        }
    }

    /// 91porna 详情页公开声明的 CDN 清单校验头。三项任一缺失就不附加任何头，
    /// 与站点播放器自己的判断保持一致。
    private static func porna91Headers(in html: String) -> [String: String] {
        guard let headerName = capture(#"data-video_cdn_auth_key=[\"']([^\"']+)[\"']"#, in: html),
              let headerValue = capture(#"data-video_cdn_auth_value=[\"']([^\"']+)[\"']"#, in: html),
              let app = capture(#"data-cdn_app=[\"']([^\"']+)[\"']"#, in: html),
              !headerName.isEmpty, !headerValue.isEmpty, !app.isEmpty else { return [:] }
        return [headerName: headerValue, "x-cdn-app": app]
    }

    private func call(path: String, profile: SiteProfile, fields: [String: Any] = [:]) async throws -> ResponseValue {
        var payload: [String: Any] = [
            "deviceInfo": [:], "app": profile.appName, "version": Self.apiVersion,
            "isStandalone": false, "theLink": "novaluenull", "uuid": "novalue", "url": path,
        ]
        fields.forEach { payload[$0.key] = $0.value }
        let data = try JSONSerialization.data(withJSONObject: payload)
        let ordered = [preferredHost] + Self.hosts.filter { $0 != preferredHost }
        var lastError: Error?
        for host in ordered {
            do {
                var request = URLRequest(url: try endpoint(host))
                request.httpMethod = "POST"
                request.httpBody = data
                request.timeoutInterval = 30
                request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
                request.setValue("application/json,text/plain,*/*", forHTTPHeaderField: "Accept")
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.setValue("Bearer undefined", forHTTPHeaderField: "Authorization")
                request.setValue(profile.pageOrigin.trimmingCharacters(in: CharacterSet(charactersIn: "/")), forHTTPHeaderField: "Origin")
                request.setValue(profile.pageOrigin, forHTTPHeaderField: "Referer")
                let (body, response) = try await session.data(for: request)
                guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
                    throw RepositoryError.invalidResponse("HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1) \(host)")
                }
                let envelope = try JSONSerialization.jsonObject(with: body) as? [String: Any] ?? [:]
                guard let cipher = envelope["r"] as? String, !cipher.isEmpty else {
                    throw RepositoryError.invalidResponse("响应缺少 r")
                }
                let plain = try OpenSSLAES.decryptToString(cipher, passphrase: Self.aesPassphrase)
                let json = try JSONSerialization.jsonObject(with: Data(plain.utf8))
                preferredHost = host
                if let array = json as? [[String: Any]] { return .array(array) }
                if let object = json as? [String: Any] { return .object(object) }
                throw RepositoryError.invalidResponse("解密结果不是 JSON")
            } catch {
                lastError = error
            }
        }
        throw lastError ?? RepositoryError.invalidResponse("所有线路均失败")
    }

    private func endpoint(_ host: String) throws -> URL {
        guard let url = URL(string: host + "/js") else {
            throw RepositoryError.invalidResponse("线路地址无效")
        }
        return url
    }

    private func tangXinHTML(path: String) async throws -> String {
        guard let url = URL(string: path, relativeTo: URL(string: SiteProfile.tangXin.pageOrigin))?.absoluteURL,
              Self.isTangXinURL(url) else {
            throw RepositoryError.invalidResponse("糖心Vlog 页面地址无效")
        }
        return try await tangXinHTML(url: url)
    }

    private func tangXinHTML(url: URL) async throws -> String {
        guard Self.isTangXinURL(url) else { throw RepositoryError.invalidResponse("糖心Vlog 页面地址无效") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(SiteProfile.tangXin.pageOrigin, forHTTPHeaderField: "Referer")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw RepositoryError.invalidResponse("网页请求失败")
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func rouVideoHTML(url: URL) async throws -> String {
        guard Self.isRouVideoURL(url) else { throw RepositoryError.invalidResponse("肉视频页面地址无效") }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(SiteProfile.rouVideo.pageOrigin, forHTTPHeaderField: "Referer")
        request.setValue("text/html,application/xhtml+xml", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw RepositoryError.invalidResponse("肉视频网页请求失败")
        }
        return String(decoding: data, as: UTF8.self)
    }

    private func publicWebsiteText(url: URL, profile: SiteProfile) async throws -> String {
        guard Self.isPublicWebsiteURL(url, site: profile.id) else {
            throw RepositoryError.invalidResponse("播放源网页地址无效")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 30
        request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(profile.pageOrigin, forHTTPHeaderField: "Referer")
        request.setValue(profile.pageOrigin.trimmingCharacters(in: CharacterSet(charactersIn: "/")), forHTTPHeaderField: "Origin")
        request.setValue("text/html,application/xhtml+xml,text/javascript,*/*", forHTTPHeaderField: "Accept")
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            throw RepositoryError.invalidResponse("播放源网页请求失败（HTTP \((response as? HTTPURLResponse)?.statusCode ?? -1)）")
        }
        return String(decoding: data, as: UTF8.self)
    }

    private static func isTangXinURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return host == "tangxinvlog.pro" || host.hasSuffix(".tangxinvlog.pro")
    }

    private static func isRouVideoURL(_ url: URL) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        return host == "rou.video" || host.hasSuffix(".rou.video")
    }

    private static func isPublicWebsiteURL(_ url: URL, site: String) -> Bool {
        guard url.scheme?.lowercased() == "https", let host = url.host?.lowercased() else { return false }
        switch site {
        case SiteProfile.jiuse.id:
            return host == "jiuse.tv" || host.hasSuffix(".jiuse.tv") || host == "91porny.com" || host.hasSuffix(".91porny.com")
        case SiteProfile.eighteenJ.id:
            return host == "18j.tv" || host.hasSuffix(".18j.tv")
        case SiteProfile.porna91.id:
            return host == "91porna.com" || host.hasSuffix(".91porna.com")
        case SiteProfile.dsdSE.id:
            return host == "dsd.com.se" || host.hasSuffix(".dsd.com.se")
        default:
            return false
        }
    }

    private static func publicCatalogURL(profile: SiteProfile, feed: PublicWebsiteFeed?, query: String?) -> URL? {
        let trimmed = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty, let feed,
           let url = URL(string: feed.path, relativeTo: URL(string: profile.pageOrigin))?.absoluteURL,
           isPublicWebsiteURL(url, site: profile.id) {
            return url
        }
        switch profile.id {
        case SiteProfile.jiuse.id:
            var components = URLComponents(string: profile.pageOrigin)
            if !trimmed.isEmpty { components?.path = "/search"; components?.queryItems = [URLQueryItem(name: "keywords", value: trimmed)] }
            return components?.url
        case SiteProfile.eighteenJ.id:
            guard !trimmed.isEmpty else { return URL(string: profile.pageOrigin) }
            var allowed = CharacterSet.urlPathAllowed
            allowed.remove(charactersIn: "/")
            guard let encoded = trimmed.addingPercentEncoding(withAllowedCharacters: allowed) else { return nil }
            return URL(string: "https://18j.tv/s/wd/\(encoded)/")
        case SiteProfile.porna91.id:
            var components = URLComponents(string: profile.pageOrigin)
            if !trimmed.isEmpty {
                components?.path = "/comic/index/search"
                components?.queryItems = [URLQueryItem(name: "keyword", value: trimmed)]
            }
            return components?.url
        case SiteProfile.dsdSE.id:
            // 站方没有可由 Richy-17 证明的公开搜索入口，因此只走首页与「浏览」频道；
            // 有关键词时返回 nil，由上层给出明确的“无公开搜索入口”提示而不是拼一个猜的地址。
            guard trimmed.isEmpty else { return nil }
            return URL(string: profile.pageOrigin)
        default:
            return nil
        }
    }

    private static func rouVideoCards(in html: String) -> [VideoItem] {
        let pattern = #"<a\b[^>]*\bhref=[\"']/v/([A-Za-z0-9_-]+)[\"'][^>]*>(.*?)</a>"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        var seen = Set<String>()
        var output: [VideoItem] = []
        expression.enumerateMatches(in: html, range: range) { match, _, _ in
            guard let match,
                  let rawID = matchText(match, index: 1, in: html),
                  seen.insert(rawID).inserted,
                  let body = matchText(match, index: 2, in: html) else { return }
            let title = (cleanHTML(capture(#"<h3\b[^>]*>(.*?)</h3>"#, in: body))
                ?? cleanHTML(capture(#"<img[^>]*\balt=[\"']([^\"']+)[\"']"#, in: body)))
                ?? "视频 \(rawID)"
            let cover = capture(#"<img[^>]*\bsrc=[\"']([^\"']+)[\"']"#, in: body)
            let duration = cleanHTML(capture(#"<span[^>]*>([0-9]+分[0-9]+秒)</span>"#, in: body))
            let views = cleanHTML(capture(#"<span>([^<]+)<!--\s*-->次觀看</span>"#, in: body))
            let time = cleanHTML(capture(#"<span>([^<]+)<!--\s*-->前</span>"#, in: body))
            let tag = cleanHTML(capture(#"<div[^>]*text-xs[^>]*>\s*<span[^>]*>(.*?)</span>"#, in: body))
            let quality = cleanHTML(capture(#">([0-9]+)<!--\s*-->P</span>"#, in: body)).map { "\($0)P" }
            output.append(
                VideoItem(
                    id: "rou-\(rawID)", title: title, cover: cover, duration: duration, views: views,
                    timeLine: time, videoType: quality, tags: tag.map { [$0] } ?? [],
                    site: SiteProfile.rouVideo.id,
                    sourcePageURL: absoluteRouVideoURL("/v/\(rawID)")
                )
            )
        }
        return output
    }

    private static func rouPlayerSource(in html: String) -> String? {
        // Richy-6 读的是 Next.js 预渲染数据 `props.pageProps.ev`；页面改用客户端路由后，
        // 同一份数据以内联 `$R` 引用的形式下发。两条路径拿到的是同一个 {d,k} 偏移编码
        // JSON，站点播放器用的也是同一种解码方式，所以任一条命中即可。
        guard let encoded = rouNextDataEv(in: html) ?? rouInlineEv(in: html) else { return nil }
        guard let bytes = Data(base64Encoded: encoded.data) else { return nil }
        let decoded = Data(bytes.map { UInt8((Int($0) - encoded.key + 256) % 256) })
        guard let object = try? JSONSerialization.jsonObject(with: decoded) as? [String: Any] else { return nil }
        return (object["videoUrl"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    /// `<script id="__NEXT_DATA__">` → `props.pageProps.ev` → `{d, k}`。
    private static func rouNextDataEv(in html: String) -> (data: String, key: Int)? {
        guard let raw = capture(#"<script[^>]*\bid=[\"']__NEXT_DATA__[\"'][^>]*>(.*?)</script>"#, in: html),
              let encoded = raw.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: encoded) as? [String: Any],
              let props = root["props"] as? [String: Any],
              let pageProps = props["pageProps"] as? [String: Any],
              let ev = pageProps["ev"] as? [String: Any],
              let value = ev["d"] as? String,
              let number = ev["k"] as? NSNumber else { return nil }
        return (value, number.intValue)
    }

    /// 内联 `ev:$R[n]={d:"…",k:N}`。
    private static func rouInlineEv(in html: String) -> (data: String, key: Int)? {
        let pattern = #"ev:\$R\[\d+\]=\{d:\"([^\"]+)\",k:(\d+)\}"#
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: html, range: NSRange(html.startIndex..., in: html)),
              let value = matchText(match, index: 1, in: html),
              let keyText = matchText(match, index: 2, in: html),
              let key = Int(keyText) else { return nil }
        return (value, key)
    }

    private static func rouPageTitle(in html: String) -> String? {
        if let heading = cleanHTML(capture(#"<h1\b[^>]*>(.*?)</h1>"#, in: html)) { return heading }
        guard let raw = capture(#"<title>(.*?)</title>"#, in: html) else { return nil }
        return cleanHTML(raw)?.replacingOccurrences(of: " - 肉視頻,您的私人AV影院", with: "").nilIfEmpty
    }

    private static func jiuseCards(in html: String) -> [VideoItem] {
        // Cards from outside sites can be interleaved with promotions. Match
        // only the internal /video/view/ path and deliberately exclude the
        // separate /video/viewhd/ (member) pages.
        let pattern = #"<div\b[^>]*\bclass=[\"'][^\"']*\bvideo-elem\b[^\"']*[\"'][^>]*>(?:(?!<div\b[^>]*\bclass=[\"'][^\"']*\bvideo-elem\b).)*?<a\b[^>]*\bclass=[\"'][^\"']*\btitle\b[^\"']*[\"'][^>]*\bhref=[\"']/video/view/([A-Za-z0-9_-]+)[\"'][^>]*>(.*?)</a>"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        var seen = Set<String>()
        var out: [VideoItem] = []
        expression.enumerateMatches(in: html, range: range) { match, _, _ in
            guard let match,
                  let rawID = matchText(match, index: 1, in: html),
                  seen.insert(rawID).inserted,
                  let card = matchText(match, index: 0, in: html),
                  let rawTitle = matchText(match, index: 2, in: html) else { return }
            let title = cleanHTML(rawTitle) ?? "视频 \(rawID)"
            let background = capture(#"background-image:\s*url\(\s*['\"]?([^'\")]+)"#, in: card)
            let cover = background.flatMap(absoluteJiuseURL)
            let duration = cleanHTML(capture(#"<small\b[^>]*\bclass=[\"'][^\"']*\blayer\b[^\"']*[\"'][^>]*>(.*?)</small>"#, in: card))
            let author = cleanHTML(capture(#"作者:\s*<a[^>]*>(.*?)</a>"#, in: card))
            let stats = cleanHTML(capture(#"([0-9]+(?:\.[0-9]+)?[万千]?)次播放"#, in: card))
            out.append(VideoItem(
                id: "jiuse-\(rawID)", title: title, cover: cover, duration: duration, views: stats,
                user: author, site: SiteProfile.jiuse.id,
                sourcePageURL: absoluteJiuseURL("/video/view/\(rawID)")
            ))
        }
        return out
    }

    private static func jiusePlayerSource(in html: String) -> String? {
        // Richy8 的 probeDomStreams 依次看 `#video-play[data-src]`、`video[data-src]`、
        // `video[src]`、`source[src]`、`[data-src*=".m3u8"]`，每个候选都先用 isM3u8Url
        // 过滤，不合格就继续往后找。这里同样只接受带 .m3u8 的值，因此某个节点放的是
        // 占位图或相对路径时不会让整次解析直接失败。取到的仍是站点自己下发的地址
        // （含它的 t= / m= 时效参数，所以只在本次请求内使用，不跨请求缓存）。
        if let playerTag = capture(#"(<video\b[^>]*\bid=[\"']video-play[\"'][^>]*>)"#, in: html) {
            let attributes = [#"\bdata-src=[\"']([^\"']+)[\"']"#, #"\bsrc=[\"']([^\"']+)[\"']"#]
            for attribute in attributes {
                if let value = capture(attribute, in: playerTag), looksLikePlaylist(value) {
                    return decodeHTMLEntities(value)
                }
            }
        }
        let patterns = [
            #"<video\b[^>]*\b(?:data-src|src)=[\"']([^\"']+)[\"']"#,
            #"<source\b[^>]*\b(?:data-src|src)=[\"']([^\"']+)[\"']"#,
            #"\bdata-src=[\"']([^\"']*\.m3u8[^\"']*)[\"']"#,
        ]
        for pattern in patterns {
            if let value = capture(pattern, in: html), looksLikePlaylist(value) {
                return decodeHTMLEntities(value)
            }
        }
        return nil
    }

    /// 站点的媒体地址一律是 HLS；用它过滤掉懒加载占位图与站点其他静态资源。
    private static func looksLikePlaylist(_ value: String) -> Bool {
        value.lowercased().contains(".m3u8")
    }

    private static func eighteenJCards(in html: String) -> [VideoItem] {
        let pattern = #"<a\b[^>]*\bhref=[\"']/v/([0-9]+)/[\"'][^>]*\btitle=[\"']([^\"']+)[\"'][^>]*>\s*<div\b[^>]*\bclass=[\"'][^\"']*\bvodlist_img\b[^\"']*[\"'][^>]*>(.*?)</div>"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        var seen = Set<String>()
        var out: [VideoItem] = []
        expression.enumerateMatches(in: html, range: range) { match, _, _ in
            guard let match,
                  let rawID = matchText(match, index: 1, in: html),
                  seen.insert(rawID).inserted,
                  let rawTitle = matchText(match, index: 2, in: html),
                  let image = matchText(match, index: 3, in: html) else { return }
            let cover = (capture(#"\bdata-original=[\"']([^\"']+)[\"']"#, in: image)
                ?? capture(#"\bsrc=[\"']([^\"']+)[\"']"#, in: image)).flatMap(absoluteEighteenJURL)
            let category = cleanHTML(capture(#"<span\b[^>]*>(.*?)</span>"#, in: image))
            out.append(VideoItem(
                id: "18j-\(rawID)", title: decodeHTMLEntities(rawTitle), cover: cover,
                videoType: category, tags: category.map { [$0] } ?? [], site: SiteProfile.eighteenJ.id,
                sourcePageURL: absoluteEighteenJURL("/v/\(rawID)/")
            ))
        }
        return out
    }

    private static func porna91Cards(in html: String) -> [VideoItem] {
        // The card's image and title links are adjacent. The poster link carries its title and cover.
        // link gives a stable ID, then use only its short preceding card block
        // for the public lazy-loaded poster URL.
        let pattern = #"<a\b[^>]*\bhref=[\"']/comic/index/detail\?video_key=([0-9]+)[\"'][^>]*>(.*?)</a>"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        var seen = Set<String>()
        var out: [VideoItem] = []
        expression.enumerateMatches(in: html, range: range) { match, _, _ in
            guard let match,
                  let rawID = matchText(match, index: 1, in: html),
                  let body = matchText(match, index: 2, in: html),
                  body.range(of: #"<img\b"#, options: .regularExpression) != nil,
                  seen.insert(rawID).inserted else { return }
            let title = cleanHTML(capture(#"\balt=[\"']([^\"']+)[\"']"#, in: body)) ?? "视频 \(rawID)"
            let cover = capture(#"\bdata-src=[\"']([^\"']+)[\"']"#, in: body).flatMap(absolutePorna91URL)
            let duration = lastCapture(#">\s*([0-9]{1,3}:[0-9]{2})\s*<"#, in: body)
            out.append(VideoItem(
                id: "91p-\(rawID)", title: title, cover: cover, duration: duration, site: SiteProfile.porna91.id,
                sourcePageURL: absolutePorna91URL("/comic/index/detail?video_key=\(rawID)")
            ))
        }
        return out
    }

    private static func publicWebsiteFeeds(in html: String, site: String) -> [PublicWebsiteFeed] {
        let home = PublicWebsiteFeed(path: "/", label: "首页最新")
        var seen = Set([home.path])
        var feeds = [home]

        func append(path: String, label: String) {
            guard !path.isEmpty, !label.isEmpty, seen.insert(path).inserted else { return }
            feeds.append(PublicWebsiteFeed(path: path, label: label))
        }

        switch site {
        case SiteProfile.jiuse.id:
            // 站方首页的热搜链接指向普通公开搜索结果，仍使用 /video/view/
            // 卡片与公开 HLS；比只展示全部混合首页更接近站方的分类浏览。
            for (path, name) in linkPairs(
                #"<a\b[^>]*\bhref=[\"'](/search\?keywords=[^\"']+)[\"'][^>]*>(.*?)</a>"#, in: html
            ).prefix(10) {
                append(path: path, label: "热搜 · \(name)")
            }
            // 其他导航页多为不同播放器或会员页，不能安全地复用公开 HLS
            // 适配器；作者页则是同一套普通公开视频卡片。
            for (path, name) in linkPairs(
                #"<a\b[^>]*\bhref=[\"'](/author/[^\"']+)[\"'][^>]*>(.*?)</a>"#, in: html
            ).prefix(10) {
                append(path: path, label: "作者 · \(name)")
            }

        case SiteProfile.eighteenJ.id:
            append(path: "/label/hot/by/time/", label: "近期更新")
            append(path: "/label/hot/by/hits_day/", label: "日榜")
            append(path: "/label/hot/by/hits_week/", label: "周榜")
            append(path: "/label/hot/by/hits_month/", label: "月榜")
            for (path, name) in linkPairs(#"<a\b[^>]*\bhref=[\"'](/tags/[^\"']+/)[\"'][^>]*>(.*?)</a>"#, in: html).prefix(16) {
                append(path: path, label: "标签 · \(name)")
            }

        case SiteProfile.porna91.id:
            for (path, name) in linkPairs(#"<a\b[^>]*\bhref=[\"']([^\"']+)[\"'][^>]*>(.*?)</a>"#, in: html) {
                guard path.hasPrefix("/comic/index/video?category=") || path.hasPrefix("/comic/index/search?keyword=") else { continue }
                append(path: path, label: name)
                if feeds.count >= 16 { break }
            }

        case SiteProfile.dsdSE.id:
            // Richy-17 不解析目录页；这里只做站内导航发现，收的是站方自己的
            // /vod/type/ 与 /vod/show/ 频道，同源校验仍由 publicCatalogURL 负责。
            for feed in DsdWebsite.feeds(in: html) {
                append(path: feed.path, label: feed.label)
            }

        default:
            break
        }
        return feeds
    }

    private static func linkPairs(_ pattern: String, in html: String) -> [(String, String)] {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        var pairs: [(String, String)] = []
        expression.enumerateMatches(in: html, range: range) { match, _, _ in
            guard let match,
                  let path = matchText(match, index: 1, in: html),
                  let label = cleanHTML(matchText(match, index: 2, in: html)) else { return }
            pairs.append((decodeHTMLEntities(path), label))
        }
        return pairs
    }

    private static func porna91BootstrapURL(in html: String, origin: String) -> URL? {
        // The detail page's normal public player bootstrap uses the poster's
        // site-relative path, a page-provided opaque value, and a short-lived
        // time bucket. We reproduce that documented browser request without
        // evaluating the page's unrelated inline advertising scripts.
        guard let imagePath = capture(#"(?:https?:)?//[^/\"']+(/upload_01/[^?\"']+)"#, in: html)
                ?? capture(#"['\"](/upload_01/[^?\"']+)"#, in: html),
              let opaque = capture(#"\b([a-f0-9]{128,})\b"#, in: html) else { return nil }
        var components = URLComponents(string: origin)
        components?.path = "/index/detail_play"
        // Matches the public page script's `parseInt(Date.now()/2100/1000)`.
        let bucket = Int(Date().timeIntervalSince1970 / 2_100)
        components?.queryItems = [
            URLQueryItem(name: "img", value: imagePath),
            URLQueryItem(name: "ads", value: ""),
            URLQueryItem(name: "u", value: opaque),
            URLQueryItem(name: "h", value: ""),
            URLQueryItem(name: "t", value: String(bucket)),
        ]
        return components?.url
    }

    private static func websiteTitle(in html: String) -> String? {
        if let heading = cleanHTML(capture(#"<h1\b[^>]*>(.*?)</h1>"#, in: html)) { return heading }
        guard let raw = capture(#"<title\b[^>]*>(.*?)</title>"#, in: html) else { return nil }
        return cleanHTML(raw)?.replacingOccurrences(of: " - 在线观看", with: "").nilIfEmpty
    }

    private static func tangXinVideoCards(in html: String) -> [VideoItem] {
        let pattern = #"<a\s+class=[\"']video-card[\"']\s+href=[\"']([^\"']+)[\"'][^>]*>(.*?)</a>"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        var seen = Set<String>()
        var out: [VideoItem] = []
        expression.enumerateMatches(in: html, range: range) { match, _, _ in
            guard let match,
                  let path = matchText(match, index: 1, in: html),
                  let id = capture(#"^/videos/([A-Za-z0-9_-]+)/$"#, in: path),
                  seen.insert(id).inserted,
                  let body = matchText(match, index: 2, in: html) else { return }
            let title = cleanHTML(capture(#"<h3\s+class=[\"']title[\"'][^>]*>(.*?)</h3>"#, in: body)
                ?? capture(#"<img[^>]*\balt=[\"']([^\"']+)[\"']"#, in: body)) ?? "视频 \(id)"
            let cover = capture(#"<img[^>]*\bsrc=[\"']([^\"']+)[\"']"#, in: body).flatMap(absoluteTangXinURL)
            let duration = cleanHTML(capture(#"<span\s+class=[\"']duration[\"'][^>]*>(.*?)</span>"#, in: body))
            let quality = cleanHTML(capture(#"<span\s+class=[\"']quality[\"'][^>]*>(.*?)</span>"#, in: body))
            let user = cleanHTML(capture(#"<div\s+class=[\"']meta[\"'][^>]*>\s*<span[^>]*>(.*?)</span>"#, in: body))
            out.append(
                VideoItem(
                    id: "tx-\(id)", title: title, cover: cover, duration: duration, user: user,
                    vip: false, videoType: quality, site: SiteProfile.tangXin.id,
                    sourcePageURL: absoluteTangXinURL(path)
                )
            )
        }
        return out
    }

    private static func tangXinArtists(in html: String) -> [TangXinArtist] {
        let pattern = #"<a\s+class=[\"']artist-chip[\"']\s+href=[\"']([^\"']+)[\"'][^>]*>(.*?)</a>"#
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return [] }
        let range = NSRange(html.startIndex..., in: html)
        var seen = Set<String>()
        var out: [TangXinArtist] = []
        expression.enumerateMatches(in: html, range: range) { match, _, _ in
            guard let match,
                  let path = matchText(match, index: 1, in: html),
                  path.range(of: #"^/artists/[^/]+/$"#, options: .regularExpression) != nil,
                  seen.insert(path).inserted,
                  let body = matchText(match, index: 2, in: html),
                  let name = cleanHTML(capture(#"<span\s+class=[\"']artist-name[\"'][^>]*>(.*?)</span>"#, in: body)) else { return }
            let avatar = capture(#"<img[^>]*\bsrc=[\"']([^\"']+)[\"']"#, in: body).flatMap(absoluteTangXinURL)
            out.append(TangXinArtist(path: path, name: name, avatar: avatar))
        }
        return out
    }

    private static func hasTangXinNextPage(in html: String) -> Bool {
        html.range(of: #"<a[^>]+\brel=[\"']next[\"'][^>]*\bhref=[\"'][^\"']+[\"']"#, options: [.regularExpression, .caseInsensitive]) != nil ||
            html.range(of: #"<a[^>]+\bhref=[\"'][^\"']+[\"'][^>]+\brel=[\"']next[\"']"#, options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func matchText(_ match: NSTextCheckingResult, index: Int, in source: String) -> String? {
        guard let range = Range(match.range(at: index), in: source) else { return nil }
        return String(source[range])
    }

    private static func lastCapture(_ pattern: String, in text: String) -> String? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        return expression.matches(in: text, range: range).last.flatMap { matchText($0, index: 1, in: text) }
    }

    private static func absoluteTangXinURL(_ reference: String) -> String? {
        URL(string: reference, relativeTo: URL(string: SiteProfile.tangXin.pageOrigin))?.absoluteURL.absoluteString
    }

    private static func absoluteRouVideoURL(_ reference: String) -> String? {
        URL(string: reference, relativeTo: URL(string: SiteProfile.rouVideo.pageOrigin))?.absoluteURL.absoluteString
    }

    private static func absoluteJiuseURL(_ reference: String) -> String? {
        let normalized = reference.hasPrefix("//") ? "https:" + reference : reference
        return URL(string: normalized, relativeTo: URL(string: SiteProfile.jiuse.pageOrigin))?.absoluteURL.absoluteString
    }

    private static func absoluteEighteenJURL(_ reference: String) -> String? {
        URL(string: reference, relativeTo: URL(string: SiteProfile.eighteenJ.pageOrigin))?.absoluteURL.absoluteString
    }

    private static func absolutePorna91URL(_ reference: String) -> String? {
        URL(string: reference, relativeTo: URL(string: SiteProfile.porna91.pageOrigin))?.absoluteURL.absoluteString
    }

    private static func cleanHTML(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let stripped = raw.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        return decodeHTMLEntities(stripped).trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private static func playerSource(in html: String) -> String? {
        let playerTag = capture(#"<[^>]*\bid\s*=\s*[\"']player[\"'][^>]*>"#, in: html)
        if let playerTag {
            for attribute in [#"\bdata-src\s*=\s*[\"']([^\"']+)[\"']"#, #"\bsrc\s*=\s*[\"']([^\"']+)[\"']"#] {
                if let value = capture(attribute, in: playerTag) { return decodeHTMLEntities(value) }
            }
        }
        return capture(#"(https?://[^\"'\\\s>]+\.m3u8[^\"'\\\s>]*)"#, in: html)
            .map(decodeHTMLEntities)
    }

    private static func pageTitle(in html: String) -> String? {
        guard let raw = capture(#"<h1\b[^>]*>(.*?)</h1>"#, in: html) else { return nil }
        let stripped = raw.replacingOccurrences(of: #"<[^>]+>"#, with: "", options: .regularExpression)
        return decodeHTMLEntities(stripped).trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    private static func capture(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .dotMatchesLineSeparators]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              match.numberOfRanges > 1,
              let captured = Range(match.range(at: 1), in: text) else { return nil }
        return String(text[captured])
    }

    private static func decodeHTMLEntities(_ value: String) -> String {
        value
            .replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#x2F;", with: "/", options: .caseInsensitive)
            .replacingOccurrences(of: "&#47;", with: "/")
    }

    /// 以下解析辅助函数都不读写 actor 状态，全部标 nonisolated：
    /// `compactMap` 闭包里的 `[String: Any]` 不是 Sendable，只有留在同一隔离域内
    /// 才能满足 Swift 6 的严格并发检查。
    nonisolated private func parseVideos(_ values: [[String: Any]], site: String) -> [VideoItem] {
        var seen = Set<String>()
        return values.compactMap { object in
            guard let id = string(object, "id") ?? string(object, "vId"), !id.isEmpty, seen.insert(id).inserted else { return nil }
            let meta = readMeta(object)
            return VideoItem(
                id: id,
                title: string(object, "title") ?? string(object, "title_en") ?? "视频 \(id)",
                cover: firstThumb(object), duration: string(object, "durationStr"), views: meta.views,
                user: string(object, "user"), vip: bool(object, "vip"), timeLine: meta.timeLine,
                videoType: string(object, "videoType"), tags: meta.tags, site: site
            )
        }
    }

    nonisolated private func readMeta(_ object: [String: Any]) -> (views: String?, timeLine: String?, tags: [String]) {
        let stats = string(object, "tags")
        let timeFromStats = stats?.split(separator: "|").first.map(String.init)
            .flatMap { ($0.contains("前") || $0.contains("刚刚") || $0.localizedCaseInsensitiveContains("ago")) ? $0.trimmingCharacters(in: .whitespaces) : nil }
        let timeField = string(object, "time")
        let timeFromField = timeField?.rangeOfCharacter(from: .letters) != nil ? timeField : nil
        let time = timeFromStats ?? timeFromField
        let tags: [String]
        if let values = object["keywords_gem"] as? [Any] {
            tags = values.compactMap { $0 as? String }
        } else if let text = string(object, "keywords_gem") {
            tags = text.split(whereSeparator: { ",，|、".contains($0) }).map(String.init)
        } else {
            tags = []
        }
        let views: String?
        if let value = object["views"] {
            views = String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        } else {
            views = nil
        }
        return (views, time, Array(Set(tags.map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "# ")) }.filter { !$0.isEmpty && $0.count <= 24 })))
    }

    nonisolated private func firstThumb(_ object: [String: Any]) -> String? {
        for key in ["thumbnails", "thumbNails", "covers"] {
            if let values = object[key] as? [Any], let url = values.compactMap({ normalizeURL(String(describing: $0)) }).first { return url }
        }
        for key in ["thumbnails", "thumb", "cover", "pic", "image", "poster"] {
            if let url = normalizeURL(string(object, key) ?? "") { return url }
        }
        return nil
    }

    nonisolated private func normalizeURL(_ value: String) -> String? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("https://") || trimmed.hasPrefix("http://") { return trimmed }
        if trimmed.hasPrefix("//") { return "https:" + trimmed }
        return nil
    }

    nonisolated private func string(_ object: [String: Any], _ key: String) -> String? {
        guard let value = object[key], !(value is NSNull), !(value is [Any]), !(value is [String: Any]) else { return nil }
        return String(describing: value).trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
    }

    nonisolated private func bool(_ object: [String: Any], _ key: String) -> Bool {
        switch object[key] {
        case let value as Bool: value
        case let value as NSNumber: value.boolValue
        case let value as String: value == "1" || value.lowercased() == "true"
        default: false
        }
    }

    nonisolated private func pageSize(for type: String) -> Int {
        type.hasPrefix("home_") && type.hasSuffix("_8") ? 8 : 24
    }

    private var userAgent: String {
        "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1"
    }

    private enum ResponseValue {
        case array([[String: Any]])
        case object([String: Any])
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty || self == "null" ? nil : self }
}
