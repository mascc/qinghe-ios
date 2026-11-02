import CommonCrypto
import Foundation
import Security

/// 抖音沙箱片库的播放结果。上层自己拼 Playable，这里只交付流地址与元信息，
/// 免得源站适配跟播放器接线互相耦合。
struct DouyinPlayback {
    let title: String
    /// 全片优先放前面；只有全片地址为空时才是预览地址。
    let streamURLs: [URL]
    let isPreview: Bool
    let cover: String?
    let duration: String?
    let timeLine: String?
    let videoType: String?
    let activeHost: String
    let pageOrigin: String
}

/// 五条线路都是 IP 直连 + Host 头，证书上的域名跟 IP 对不上，只能由这条线路自己放行；
/// 类内部没有任何可变状态，跨线程共享都是只读，所以 @unchecked Sendable 成立。
final class DouyinLineDelegate: NSObject, URLSessionDelegate, URLSessionTaskDelegate, @unchecked Sendable {
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
        // 先走系统默认校验：按线路域名请求时证书本来就对得上，只有 IP 直连的兜底
        // 才会因为域名不匹配而失败，那时才放行这一条线路自己的 trust。
        var error: CFError?
        if SecTrustEvaluateWithError(trust, &error) {
            completionHandler(.performDefaultHandling, nil)
        } else {
            completionHandler(.useCredential, URLCredential(trust: trust))
        }
    }

    /// 线路上的跳转会把 Host 头换成 IP 的真实域名，请求就落到错误的虚拟主机；
    /// 所以这里直接不给新请求，让本次线路失败去换下一条。
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        willPerformHTTPRedirection response: HTTPURLResponse,
        newRequest request: URLRequest,
        completionHandler: @escaping @Sendable (URLRequest?) -> Void
    ) {
        completionHandler(nil)
    }
}

/// 抖音沙箱片库适配：请求走线路 IP，Host 用域名，路径头和正文都是 AES-CBC。
/// 新号每天一次抽奖：prizeType 2 只换这一部 VIP 的全片，所以每部单独领号；
/// prizeType 0 发金币，金币片先 /purchases/purchase 购买再读详情，全片在 playUrl[].videoLink。
actor DouyinSource {
    static let siteID = "douyin"
    static let pageSize = 20
    static let activeHost = "ecsvnp1.cn1-hongkong.aliyuncs.com"
    static let pageOrigin = "https://ecsvnp1.cn1-hongkong.aliyuncs.com/"

    /// 这两个常量在上游是直接当 UTF-8 字节用的（不是 Base64 解码），各 24 字节，
    /// 因此 AES 是 192 位变体；IV 正好 16 字节。
    private static let bodyKey = Array("KivItun6MHYOU55hlQECIa==".utf8)
    private static let bodyIV = Array("efa3s7w8fbe3jae2".utf8)
    private static let pathKey = Array("WhtRldf4KJHUY22hlJRUSo==".utf8)
    private static let markPrefix = "dy:"
    /// 密文响应正常只有几十 KB，超过 4MB 的只可能是被塞了别的东西，没必要解密。
    private static let maxResponseBytes = 4 * 1024 * 1024

    private static let lines: [DouyinLine] = [
        DouyinLine(host: "ecsvnp1.cn1-hongkong.aliyuncs.com", ip: "143.92.60.55"),
        DouyinLine(host: "ecsvnp1.cn2-hongkong.aliyuncs.com", ip: "143.92.60.68"),
        DouyinLine(host: "ecsvnp1.cn3-hongkong.aliyuncs.com", ip: "143.92.60.99"),
        DouyinLine(host: "ecsvnp1.cn4-hongkong.aliyuncs.com", ip: "27.124.42.79"),
        DouyinLine(host: "ecsvnp1.cn5-hongkong.aliyuncs.com", ip: "27.124.42.98"),
    ]

    private var browse: Session?
    private var purse: Session?
    /// 访客 lane 与金币 lane 各一套连接，两套会话的鉴权头不会共用同一批连接状态。
    private let browseTransport: URLSession
    private let purseTransport: URLSession

    init() {
        let delegate = DouyinLineDelegate()
        browseTransport = Self.makeTransport(delegate: delegate)
        purseTransport = Self.makeTransport(delegate: delegate)
    }

    // MARK: - 目录

    func list(type: String, page: Int) async throws -> ListPage {
        let session = try await browseSession()
        let current = max(1, page)
        let apiType = type == "short" ? 2 : 1
        var body: [String: Any] = ["page": current, "pageSize": Self.pageSize, "type": apiType]
        if let category = Self.categoryID(of: type) {
            body["videoCategoryId"] = category
        }
        let data = try await object(path: "/video/list", body: body, session: session)
        let items = Self.parseList(data["list"] as? [Any], defaultType: apiType)
        return Self.listPage(data: data, items: items, page: current)
    }

    func search(keyword: String, page: Int) async throws -> ListPage {
        let query = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            throw RepositoryError.invalidResponse("搜索关键词不能为空")
        }
        let session = try await browseSession()
        let current = max(1, page)
        let data = try await object(
            path: "/video/list",
            body: ["page": current, "pageSize": Self.pageSize, "type": 1, "title": query],
            session: session
        )
        let items = Self.parseList(data["list"] as? [Any], defaultType: 1)
        let more = items.count >= Self.pageSize
        return ListPage(items: items, page: current, totalPage: more ? current + 1 : current, openEnded: more)
    }

    // MARK: - 播放

    func resolve(_ item: VideoItem) async throws -> DouyinPlayback {
        let mark = Self.mark(of: item)
        guard let id = Int64(item.id), id > 0 else {
            throw RepositoryError.invalidResponse("片子编号无效")
        }
        let detail: [String: Any]
        if mark.charge > 0 {
            let session = try await purseSession(need: mark.charge)
            // buyFlag 非 0 表示这个号已经买过，重复购买会白扣金币。
            if mark.buy == 0 {
                try await purchase(session, id: id, apiType: mark.apiType, charge: mark.charge)
            }
            detail = try await object(path: "/video/detail/v2", body: ["id": id], session: session)
        } else if !mark.free {
            // 抽奖配额只覆盖这一部：必须新号、领完配额立刻请求这一部，不能复用任何缓存会话。
            detail = try await unlockVIP(id: id)
        } else {
            detail = try await object(
                path: "/video/detail/v2",
                body: ["id": id],
                session: try await browseSession()
            )
        }

        let play = Self.playInfo(detail["playInfo"] as? [String: Any])
        // 免费片的全片字段为空时，服务端只给预览流。
        let full = play.full.isEmpty ? (mark.free ? play.preview : []) : play.full
        var urls: [URL] = []
        var seen = Set<String>()
        for raw in full {
            guard let url = URL(string: raw), seen.insert(url.absoluteString).inserted else { continue }
            urls.append(url)
        }
        guard !urls.isEmpty else {
            throw RepositoryError.invalidResponse("没有拿到全片地址")
        }
        return DouyinPlayback(
            title: Self.filled(Self.text(detail["title"])) ?? item.displayTitle,
            streamURLs: urls,
            isPreview: play.full.isEmpty,
            cover: play.cover ?? item.cover,
            duration: Self.filled(Self.text(detail["durationStr"])) ?? item.duration,
            timeLine: Self.filled(Self.text(detail["createdTime"])) ?? item.timeLine,
            videoType: item.videoType,
            activeHost: Self.activeHost,
            pageOrigin: Self.pageOrigin
        )
    }

    // MARK: - 购买

    private func purchase(_ session: Session, id: Int64, apiType: Int, charge: Int64) async throws {
        guard session.coin >= charge else {
            throw RepositoryError.invalidResponse("金币不够，这部需要 \(charge)")
        }
        let bought = try await post(
            path: "/purchases/purchase",
            extra: ["id": id, "type": 0, "videoType": apiType],
            session: session
        )
        guard Self.flag(bought["success"]) else {
            throw RepositoryError.invalidResponse(Self.filled(Self.text(bought["message"])) ?? "购买失败")
        }
        // 余额只在内存里跟着这个号走，避免下一次购买再拿旧余额判断。
        if var cached = purse, cached.oauth == session.oauth {
            cached.coin = max(0, cached.coin - charge)
            purse = cached
        }
    }

    // MARK: - 会话

    private func browseSession() async throws -> Session {
        if let browse { return browse }
        let created = try await openSession(prize: nil, lane: .browse)
        // await 期间别的调用可能已经建好了访客号，复用先到的那个。
        if let browse { return browse }
        browse = created
        return created
    }

    private func purseSession(need: Int64) async throws -> Session {
        if let purse, purse.coin >= need { return purse }
        let created = try await openSession(prize: 0, lane: .purse)
        if let purse, purse.coin >= need { return purse }
        // 余额不足的新号也要换掉旧号：抽奖额度是按号发的，旧号已经领过了。
        purse = created
        return created
    }

    private func unlockVIP(id: Int64) async throws -> [String: Any] {
        let session = try await openSession(prize: 2, lane: .browse)
        return try await object(path: "/video/detail/v2", body: ["id": id], session: session)
    }

    private func openSession(prize: Int?, lane: Lane = .browse) async throws -> Session {
        let oauth = UUID().uuidString
        let registered = try await object(
            path: "/user/guest/register",
            body: [:],
            oauth: oauth,
            token: nil,
            lane: lane
        )
        guard let uid = Self.int64(registered["uid"]), uid > 0 else {
            throw RepositoryError.invalidResponse("注册账号失败")
        }
        let login = try await object(path: "/user/login", body: [:], oauth: oauth, token: nil, lane: lane)
        let token = Self.text(login["token"]) ?? ""
        // 正常 token 是 32 字节以上的串；短成这样就说明返回的是错误体而不是凭证。
        guard token.count >= 40 else {
            throw RepositoryError.invalidResponse("登录失败")
        }
        var session = Session(oauth: oauth, token: token, uid: uid, coin: 0, lane: lane)
        if let prize {
            let minted = try await post(
                path: "/lottery/addClick",
                extra: ["prizeType": prize, "userUid": uid, "type": 1],
                session: session
            )
            guard Self.flag(minted["success"]) else {
                throw RepositoryError.invalidResponse(Self.filled(Self.text(minted["message"])) ?? "配额领取失败")
            }
        }
        if prize == 0 {
            let info = try await object(path: "/user/userInfo", body: [:], session: session)
            session.coin = Self.int64(info["totalCoin"]) ?? 0
        }
        return session
    }

    // MARK: - 传输

    private static func makeTransport(delegate: DouyinLineDelegate) -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 20
        config.timeoutIntervalForResource = 30
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.httpCookieStorage = nil
        // 这里的会话状态全在内存里，交给 actor 管，URLSession 不该另存一份 cookie。
        return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    }

    private func transport(_ lane: Lane) -> URLSession {
        switch lane {
        case .purse: return purseTransport
        case .browse: return browseTransport
        }
    }

    private func object(path: String, body: [String: Any], session: Session) async throws -> [String: Any] {
        try await object(
            path: path,
            body: body,
            oauth: session.oauth,
            token: session.token,
            lane: session.lane
        )
    }

    private func object(
        path: String,
        body: [String: Any],
        oauth: String,
        token: String?,
        lane: Lane
    ) async throws -> [String: Any] {
        let root = try await post(path: path, extra: body, oauth: oauth, token: token, lane: lane)
        guard let data = root["data"] as? [String: Any] else {
            throw RepositoryError.invalidResponse("缺少 data")
        }
        return data
    }

    private func post(path: String, extra: [String: Any], session: Session) async throws -> [String: Any] {
        try await post(
            path: path,
            extra: extra,
            oauth: session.oauth,
            token: session.token,
            lane: session.lane
        )
    }

    private func post(
        path: String,
        extra: [String: Any],
        oauth: String,
        token: String?,
        lane: Lane
    ) async throws -> [String: Any] {
        // 每个接口都要这四个字段，业务参数叠在上面，顺序无关但键不能互相覆盖。
        var body: [String: Any] = [
            "deviceType": 1,
            "oauthId": oauth,
            "oauthType": "android",
            "platform": "App",
        ]
        for (key, value) in extra {
            body[key] = value
        }
        guard let encoded = try? JSONSerialization.data(withJSONObject: body),
              let plain = String(data: encoded, encoding: .utf8) else {
            throw RepositoryError.invalidResponse("抖音请求体编码失败")
        }
        var lastMessage = "线路不可用"
        for line in Self.lines {
            do {
                let text = try await request(line: line, path: path, plain: plain, token: token, lane: lane)
                guard let root = Self.jsonObject(text) else {
                    throw RepositoryError.invalidResponse("抖音响应不是对象")
                }
                // 两条成功口径：显式的 success，或者 code 正好 200。
                if Self.flag(root["success"]) { return root }
                let code = Self.integer(root["code"]) ?? -1
                if code == 200 { return root }
                throw LineRejection(
                    message: Self.filled(Self.text(root["message"])) ?? "接口返回 \(code)"
                )
            } catch let rejection as LineRejection {
                // 服务端明确拒绝（没配额、没登录）换线路也没用，直接上抛。
                throw RepositoryError.invalidResponse(rejection.message)
            } catch {
                lastMessage = (error as? RepositoryError)?.localizedDescription ?? "线路 \(line.host) 请求失败"
            }
        }
        throw RepositoryError.invalidResponse(lastMessage)
    }

    private func request(
        line: DouyinLine,
        path: String,
        plain: String,
        token: String?,
        lane: Lane
    ) async throws -> String {
        let trace = Self.traceID()
        // URL 路径和 x-ph 里各用一个新的 UUID：上游就是这么发的，两者不必相同。
        let route = "/" + Self.md5Hex(UUID().uuidString)
        let proof = path + "/" + Self.base64URL(Data(Self.md5Bytes(UUID().uuidString)))
        guard let header = Self.encryptPath(proof, trace: trace) else {
            throw RepositoryError.invalidResponse("抖音路径加密失败")
        }
        guard let encryptedBody = Self.encryptBody(plain) else {
            throw RepositoryError.invalidResponse("抖音请求加密失败")
        }

        // 先按线路域名直连（证书与虚拟主机都对），DNS 被污染或解析失败时再退回
        // IP 直连 + 手写 Host。两种写法只有 Host 头不同，其余请求完全相同。
        var attempts: [(url: URL, hostHeader: String?)] = []
        if let byName = URL(string: "https://\(line.host)\(route)") { attempts.append((byName, nil)) }
        if let byAddress = URL(string: "https://\(line.ip)\(route)") { attempts.append((byAddress, line.host)) }
        guard !attempts.isEmpty else {
            throw RepositoryError.invalidResponse("抖音线路地址无效")
        }

        var lastError: Error?
        for attempt in attempts {
            var http = URLRequest(url: attempt.url)
            http.httpMethod = "POST"
            http.timeoutInterval = 20
            // 证书是线路域名的，URL 里只有 IP 时 Host 必须自己带，服务端才认虚拟主机。
            if let hostHeader = attempt.hostHeader {
                http.setValue(hostHeader, forHTTPHeaderField: "Host")
            }
            http.setValue("", forHTTPHeaderField: "User-Agent")
            http.setValue("android", forHTTPHeaderField: "CLIENT")
            http.setValue("application/json", forHTTPHeaderField: "Content-Type")
            http.setValue(trace, forHTTPHeaderField: "x-trace-id")
            http.setValue(trace, forHTTPHeaderField: "x-tp")
            http.setValue(header, forHTTPHeaderField: "x-ph")
            http.setValue("*", forHTTPHeaderField: "Accept")
            http.setValue("Bearer " + (token ?? ""), forHTTPHeaderField: "Authorization")
            // 正文是 Base64 文本，本身就是 JSON 类型的 content-type。
            http.httpBody = Data(encryptedBody.utf8)

            do {
                let outcome = try await send(http, lane: lane, host: line.host)
                let data = outcome.0
                let response = outcome.1
                guard let status = (response as? HTTPURLResponse)?.statusCode else {
                    throw RepositoryError.invalidResponse("抖音线路响应异常")
                }
                guard (200..<300).contains(status) else {
                    throw RepositoryError.invalidResponse("线路 \(line.host) 返回 HTTP \(status)")
                }
                guard data.count <= Self.maxResponseBytes else {
                    throw RepositoryError.invalidResponse("抖音响应过大")
                }
                guard let raw = String(data: data, encoding: .utf8) else {
                    throw RepositoryError.invalidResponse("抖音响应不是文本")
                }
                return try Self.decryptResponse(raw)
            } catch {
                lastError = error
            }
        }
        throw lastError ?? RepositoryError.invalidResponse("线路 \(line.host) 请求失败")
    }

    /// 网络层错误文案只能留在线路这一层：上层看到的最后一条就是它。
    private func send(_ http: URLRequest, lane: Lane, host: String) async throws -> (Data, URLResponse) {
        do {
            return try await transport(lane).data(for: http)
        } catch {
            throw RepositoryError.invalidResponse("线路 \(host) 连接失败")
        }
    }

    // MARK: - 加解密

    private static func encryptBody(_ plain: String) -> String? {
        guard let cipher = aes(Data(plain.utf8), key: bodyKey, iv: bodyIV, encrypt: true) else { return nil }
        return cipher.base64EncodedString()
    }

    private static func decryptResponse(_ raw: String) throws -> String {
        var text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.hasPrefix("\u{FEFF}") {
            text = String(text.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // 服务端有时把密文当 JSON 字符串序列化，先剥外层引号与转义，
        // 否则引号和 \/ 会混进 Base64 解码。
        if text.hasPrefix("\"") {
            guard let data = text.data(using: .utf8),
                  let parsed = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]),
                  let unwrapped = parsed as? String else {
                throw RepositoryError.invalidResponse("抖音响应格式不对，请重试")
            }
            text = unwrapped
        }
        let compact = text.filter { !$0.isWhitespace }
        guard !compact.isEmpty else {
            throw RepositoryError.invalidResponse("抖音响应为空，请重试")
        }
        guard let cipher = Data(base64Encoded: padBase64(compact)),
              let plain = aes(cipher, key: bodyKey, iv: bodyIV, encrypt: false),
              let json = String(data: plain, encoding: .utf8) else {
            throw RepositoryError.invalidResponse("抖音响应解密失败，请重试")
        }
        return json
    }

    /// 路径证明用 trace 自己当 IV：trace 是毫秒时间戳 + 3 位补零随机，正好 16 位。
    private static func encryptPath(_ plain: String, trace: String) -> String? {
        var iv = Array(trace.utf8)
        // CCCrypt 只按指针读满一个分组长度的 IV，短了就补零，长了截断，绝不让它越界读。
        if iv.count < kCCBlockSizeAES128 {
            iv += [UInt8](repeating: 0, count: kCCBlockSizeAES128 - iv.count)
        } else if iv.count > kCCBlockSizeAES128 {
            iv = Array(iv.prefix(kCCBlockSizeAES128))
        }
        guard let cipher = aes(Data(plain.utf8), key: pathKey, iv: iv, encrypt: true) else { return nil }
        return base64URL(cipher)
    }

    private static func aes(_ input: Data, key: [UInt8], iv: [UInt8], encrypt: Bool) -> Data? {
        guard !input.isEmpty, !key.isEmpty, iv.count == kCCBlockSizeAES128 else { return nil }
        // 上游用的是 "AES/CBC/PKCS5Padding"：加密时明文长度由填充补齐，不要求是
        // 分组整数倍（路径证明和 JSON 正文都落在任意长度上）。只有解密的密文
        // 必须按分组对齐，长度不对时让 CCCrypt 自己报错即可。
        if !encrypt, input.count % kCCBlockSizeAES128 != 0 { return nil }
        var output = [UInt8](repeating: 0, count: input.count + kCCBlockSizeAES128)
        var moved = 0
        let status = input.withUnsafeBytes { bytes -> CCCryptorStatus in
            CCCrypt(
                CCOperation(encrypt ? kCCEncrypt : kCCDecrypt),
                CCAlgorithm(kCCAlgorithmAES),
                CCOptions(kCCOptionPKCS7Padding),
                key,
                key.count,
                iv,
                bytes.baseAddress,
                input.count,
                &output,
                output.count,
                &moved
            )
        }
        guard status == kCCSuccess, moved > 0 else { return nil }
        return Data(output.prefix(moved))
    }

    private static func md5Bytes(_ text: String) -> [UInt8] {
        var digest = [UInt8](repeating: 0, count: Int(CC_MD5_DIGEST_LENGTH))
        let bytes = Array(text.utf8)
        let count = bytes.count
        guard count > 0 else { return digest }
        bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            _ = CC_MD5(base, CC_LONG(count), &digest)
        }
        return digest
    }

    private static func md5Hex(_ text: String) -> String {
        md5Bytes(text).map { String(format: "%02x", $0) }.joined()
    }

    private static func base64URL(_ data: Data) -> String {
        data.base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func padBase64(_ text: String) -> String {
        let remainder = text.count % 4
        return remainder == 0 ? text : text + String(repeating: "=", count: 4 - remainder)
    }

    private static func traceID() -> String {
        let millis = Int64(Date().timeIntervalSince1970 * 1000)
        return String(millis) + String(format: "%03d", Int.random(in: 0...999))
    }

    // MARK: - 解析

    private static func categoryID(of type: String) -> Int? {
        guard type.hasPrefix("c") else { return nil }
        guard let value = Int(type.dropFirst()), value > 0 else { return nil }
        return value
    }

    private static func listPage(data: [String: Any], items: [VideoItem], page: Int) -> ListPage {
        let pages = integer(data["pages"]) ?? 0
        let totalPage: Int
        if pages > 0 {
            totalPage = pages
        } else if items.count < pageSize {
            // 不满一页就到底了；服务端不给总页数时只能这样收尾。
            totalPage = page
        } else {
            totalPage = page + 1
        }
        return ListPage(
            items: items,
            page: page,
            totalPage: max(totalPage, page),
            openEnded: pages <= 0 && items.count >= pageSize
        )
    }

    private static func parseList(_ rows: [Any]?, defaultType: Int) -> [VideoItem] {
        guard let rows else { return [] }
        var items: [VideoItem] = []
        var seen = Set<String>()
        for raw in rows {
            guard let row = raw as? [String: Any], let numeric = int64(row["id"]), numeric > 0 else { continue }
            let id = String(numeric)
            guard seen.insert(id).inserted else { continue }
            let charge = int64(row["chargeAmount"]) ?? 0
            let free = (integer(row["isFree"]) ?? 0) != 0
            let apiType = (integer(row["type"]) ?? defaultType) == 2 ? 2 : 1
            let buy = integer(row["buyFlag"]) ?? 0
            let nickname = (row["appUser"] as? [String: Any]).flatMap { text($0["nickname"]) }
            // 卡片把购买信息塞在 tags 第一位，解析详情时要靠它决定走购买还是抽奖。
            var tags = ["\(markPrefix)\(charge):\(apiType):\(free ? 1 : 0):\(buy)"]
            for tag in (row["tags"] as? [Any]) ?? [] {
                guard let tag = tag as? [String: Any],
                      let name = filled(text(tag["title"])) else { continue }
                tags.append(name)
            }
            let title = filled(text(row["title"])) ?? "视频 \(id)"
            let videoType: String?
            if charge > 0 {
                videoType = "金币\(charge)"
            } else if free {
                videoType = "免费"
            } else {
                videoType = nil
            }
            items.append(
                VideoItem(
                    id: id,
                    title: title,
                    cover: httpURL(row["cover"]),
                    duration: filled(text(row["durationStr"])),
                    views: int64(row["playCount"]).flatMap { $0 > 0 ? String($0) : nil },
                    user: filled(nickname),
                    // 既不要金币也不是免费片，就是需要抽奖配额或 VIP 的那一类。
                    vip: charge <= 0 && !free,
                    timeLine: filled(text(row["createdTime"])),
                    videoType: videoType,
                    tags: tags,
                    site: siteID
                )
            )
        }
        return items
    }

    private static func playInfo(_ raw: [String: Any]?) -> PlayInfo {
        guard let raw else { return PlayInfo(cover: nil, full: [], preview: []) }
        var full: [String] = []
        var preview: [String] = []
        for element in (raw["playUrl"] as? [Any]) ?? [] {
            guard let row = element as? [String: Any] else { continue }
            if let link = httpURL(row["videoLink"]), !full.contains(link) { full.append(link) }
            if let link = httpURL(row["previewVideoLink"]), !preview.contains(link) { preview.append(link) }
        }
        return PlayInfo(cover: httpURL(raw["cover"]), full: full, preview: preview)
    }

    private static func mark(of item: VideoItem) -> Mark {
        if let raw = item.tags.first(where: { $0.hasPrefix(markPrefix) })?.dropFirst(markPrefix.count) {
            let parts = raw.split(separator: ":", omittingEmptySubsequences: false).map { String($0) }
            if parts.count >= 4 {
                return Mark(
                    charge: Int64(parts[0]) ?? 0,
                    apiType: Int(parts[1]) == 2 ? 2 : 1,
                    free: parts[2] == "1",
                    buy: Int(parts[3]) ?? 0
                )
            }
        }
        // 老收藏/历史里没有 MARK，只能从卡片上那点可见信息倒推。
        let charge: Int64
        if let type = item.videoType, type.hasPrefix("金币") {
            charge = Int64(type.dropFirst(2)) ?? 0
        } else {
            charge = 0
        }
        return Mark(charge: charge, apiType: 1, free: item.videoType == "免费", buy: 0)
    }

    private static func jsonObject(_ text: String) -> [String: Any]? {
        guard let data = text.data(using: .utf8) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }

    private static func httpURL(_ value: Any?) -> String? {
        guard let text = text(value)?.trimmingCharacters(in: .whitespacesAndNewlines),
              text.hasPrefix("http") else { return nil }
        return text
    }

    private static func filled(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines),
              !trimmed.isEmpty else { return nil }
        return trimmed
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

    private static func int64(_ value: Any?) -> Int64? {
        switch value {
        case let number as NSNumber: return number.int64Value
        case let string as String: return Int64(string)
        default: return nil
        }
    }

    private static func flag(_ value: Any?) -> Bool {
        switch value {
        case let bool as Bool: return bool
        case let number as NSNumber: return number.intValue != 0
        case let string as String: return string == "1" || string.lowercased() == "true"
        default: return false
        }
    }

    // MARK: - 内部类型

    private struct DouyinLine: Sendable {
        let host: String
        let ip: String
    }

    private enum Lane: Sendable {
        case browse
        case purse
    }

    private struct Session: Sendable {
        let oauth: String
        let token: String
        let uid: Int64
        var coin: Int64
        let lane: Lane
    }

    private struct PlayInfo {
        let cover: String?
        let full: [String]
        let preview: [String]
    }

    private struct Mark {
        let charge: Int64
        let apiType: Int
        let free: Bool
        let buy: Int
    }

    /// 服务端明确拒绝，换线路重试没有意义；只在文件内部流转，不会被上层看到。
    private struct LineRejection: Error {
        let message: String
    }
}
