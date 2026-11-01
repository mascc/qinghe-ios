import Foundation

@MainActor
final class DownloadManager: ObservableObject {
    @Published private(set) var tasks: [DownloadTask] = []
    private var jobs: [String: Task<Void, Never>] = [:]
    private let key = "pornshop_downloads_ios"

    init() {
        load()
    }

    func enqueue(_ item: VideoItem, playable: Playable) {
        guard !playable.playURL.isFileURL else { return }
        let plan = playable.keyPlan?.rawValue
        if let index = tasks.firstIndex(where: { $0.id == item.id }) {
            if tasks[index].status == .completed || tasks[index].status == .running || tasks[index].status == .queued { return }
            tasks[index].remoteURL = playable.playURL.absoluteString
            tasks[index].mediaHeaders = playable.mediaHeaders.isEmpty ? nil : playable.mediaHeaders
            tasks[index].keyPlanRaw = plan
            tasks[index].status = .queued
            tasks[index].error = nil
            tasks[index].updatedAt = .now
            start(id: item.id, origin: playable.pageOrigin)
        } else {
            tasks.insert(
                DownloadTask(
                    id: item.id, item: item, remoteURL: playable.playURL.absoluteString,
                    localURL: nil, status: .queued, done: 0, total: 0, bytes: 0, error: nil, updatedAt: .now,
                    mediaHeaders: playable.mediaHeaders.isEmpty ? nil : playable.mediaHeaders,
                    keyPlanRaw: plan
                ),
                at: 0
            )
            start(id: item.id, origin: playable.pageOrigin)
        }
        save()
    }

    func toggle(_ task: DownloadTask, origin: String) {
        switch task.status {
        case .running, .queued:
            jobs[task.id]?.cancel()
            jobs[task.id] = nil
            update(task.id) { $0.status = .paused; $0.updatedAt = .now }
        case .paused, .failed:
            update(task.id) { $0.status = .queued; $0.error = nil; $0.updatedAt = .now }
            start(id: task.id, origin: origin)
        case .completed: break
        }
        save()
    }

    func delete(_ task: DownloadTask) {
        jobs[task.id]?.cancel()
        jobs[task.id] = nil
        try? FileManager.default.removeItem(at: directory(for: task.id))
        tasks.removeAll { $0.id == task.id }
        save()
    }

    func localURL(for id: String) -> URL? {
        guard let task = tasks.first(where: { $0.id == id }), task.status == .completed,
              let value = task.localURL else { return nil }
        return URL(string: value)
    }

    private func start(id: String, origin: String) {
        guard jobs[id] == nil, let task = tasks.first(where: { $0.id == id }) else { return }
        update(id) { $0.status = .running; $0.error = nil; $0.updatedAt = .now }
        let remoteURL = task.remoteURL
        // 站点公开播放器要求的清单请求头跟随任务持久化，因此这里从任务本身读取，
        // 暂停后继续或应用重启后恢复都能带上同样的头。密钥方案同理：
        // 还原密钥需要清单本身，恢复时已经拿不到 Playable 了。
        let mediaHeaders = task.mediaHeaders ?? [:]
        let keyPlan = HLSKeyPlan.from(rawValue: task.keyPlanRaw)
        jobs[id] = Task { [weak self] in
            do {
                guard let remote = URL(string: remoteURL) else {
                    throw RepositoryError.invalidResponse("下载地址无效")
                }
                let downloader = HLSDownloader(origin: origin, mediaHeaders: mediaHeaders, keyPlan: keyPlan)
                let local = try await downloader.download(
                    remoteURL: remote, directory: self?.directory(for: id) ?? FileManager.default.temporaryDirectory,
                    progress: { done, total in
                        Task { @MainActor [weak self] in
                            self?.update(id) { task in
                                guard task.status == .running else { return }
                                task.done = done
                                task.total = total
                                task.updatedAt = .now
                            }
                            self?.save()
                        }
                    }
                )
                guard !Task.isCancelled else { return }
                self?.update(id) { item in
                    item.status = .completed
                    item.localURL = local.absoluteString
                    item.bytes = Self.bytes(at: local.deletingLastPathComponent())
                    item.done = max(item.done, item.total)
                    item.updatedAt = .now
                }
            } catch is CancellationError {
            } catch {
                self?.update(id) { item in
                    guard item.status == .running else { return }
                    item.status = .failed
                    item.error = error.localizedDescription
                    item.updatedAt = .now
                }
            }
            self?.jobs[id] = nil
            self?.save()
        }
    }

    private func directory(for id: String) -> URL {
        let root = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("offline", isDirectory: true)
        return root.appendingPathComponent(id.replacingOccurrences(of: "[^A-Za-z0-9._-]", with: "_", options: .regularExpression), isDirectory: true)
    }

    private func update(_ id: String, _ block: (inout DownloadTask) -> Void) {
        guard let index = tasks.firstIndex(where: { $0.id == id }) else { return }
        block(&tasks[index])
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: key),
              let restored = try? JSONDecoder().decode([DownloadTask].self, from: data) else { return }
        tasks = restored.map { task in
            task.status == .running || task.status == .queued
                // 重新排队时把清单请求头与密钥方案一起带上：恢复后拿不到 Playable，只能靠任务里存的这份。
                ? DownloadTask(
                    id: task.id, item: task.item, remoteURL: task.remoteURL, localURL: task.localURL,
                    status: .paused, done: task.done, total: task.total, bytes: task.bytes, error: nil,
                    updatedAt: task.updatedAt, mediaHeaders: task.mediaHeaders, keyPlanRaw: task.keyPlanRaw
                )
                : task
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(tasks) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }

    private static func bytes(at directory: URL) -> Int64 {
        (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey], options: [.skipsHiddenFiles]))?
            .reduce(0) { total, url in total + Int64((try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0) } ?? 0
    }
}

@MainActor
struct HLSDownloader {
    let origin: String
    /// 站点公开播放器要求附带的清单请求头。与播放路径上的桥接层保持同样的边界：
    /// 只发给 m3u8 清单，不发给分片、密钥等无关主机。
    var mediaHeaders: [String: String] = [:]
    /// 密钥需要现场还原的方案。离线时同样要走同一套规则，否则存下来的
    /// `key_0.bin` 会是 RSA 密文块或未合成的候选密钥。
    var keyPlan: HLSKeyPlan?
    private let session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = 60
        config.timeoutIntervalForResource = 120
        return URLSession(configuration: config)
    }()

    init(origin: String, mediaHeaders: [String: String] = [:], keyPlan: HLSKeyPlan? = nil) {
        self.origin = origin
        self.mediaHeaders = mediaHeaders
        self.keyPlan = keyPlan
    }

    func download(remoteURL: URL, directory: URL, progress: @escaping (Int, Int) -> Void) async throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let (mediaURL, body) = try await resolveMedia(remoteURL)
        let plan = try rewrite(mediaURL: mediaURL, body: body)
        guard !plan.assets.isEmpty else { throw RepositoryError.invalidResponse("播放列表里没有分片") }
        progress(0, plan.assets.count)
        var completed = 0
        for asset in plan.assets {
            try Task.checkCancellation()
            let destination = directory.appendingPathComponent(asset.localName)
            if !FileManager.default.fileExists(atPath: destination.path) {
                let data: Data
                if let iv = asset.keyIV, let keyPlan {
                    data = try await resolveKey(asset: asset, iv: iv, plan: keyPlan, playlistURL: mediaURL)
                } else {
                    data = try await fetch(asset.remote)
                }
                try data.write(to: destination, options: .atomic)
            }
            completed += 1
            progress(completed, plan.assets.count)
        }
        let index = directory.appendingPathComponent("index.m3u8")
        try Data(plan.playlist.utf8).write(to: index, options: .atomic)
        return index
    }

    /// 把一个 `#EXT-X-KEY` 还原成 16 字节 AES 密钥。
    private func resolveKey(asset: Asset, iv: Data, plan: HLSKeyPlan, playlistURL: URL) async throws -> Data {
        switch plan {
        case .douyinRSA:
            let raw = try await fetch(asset.remote)
            guard let key = DouyinMediaKey.unwrap(raw), key.count == 16 else {
                throw RepositoryError.invalidResponse("抖音播放密钥解密失败，请重新解析视频")
            }
            return key
        case .haijiao(let versions):
            let resolver = HaijiaoKeyResolver(origin: origin, userAgent: Self.userAgent)
            return try await resolver.key(
                keyURL: asset.remote, iv: iv, segmentURL: asset.keySegment, playlistURL: playlistURL, versions: versions
            )
        }
    }

    private func resolveMedia(_ url: URL, depth: Int = 0) async throws -> (URL, String) {
        let body = try await fetchText(url)
        guard depth < 3, body.contains("#EXT-X-STREAM-INF") else { return (url, body) }
        let lines = lines(body)
        var candidate: (url: URL, score: Int)?
        var score = 0
        var expectsURL = false
        for line in lines {
            if line.hasPrefix("#EXT-X-STREAM-INF") {
                score = Int(line.range(of: "BANDWIDTH=\\d+", options: .regularExpression)
                    .map { String(line[$0]).split(separator: "=").last! } ?? "0") ?? 0
                expectsURL = true
            } else if expectsURL, !line.isEmpty, !line.hasPrefix("#") {
                let url = urlFor(line, relativeTo: url)
                if candidate == nil || score >= candidate!.score { candidate = (url, score) }
                expectsURL = false
            }
        }
        guard let variant = candidate?.url else { throw RepositoryError.invalidResponse("没有可下载的视频流") }
        return try await resolveMedia(variant, depth: depth + 1)
    }

    private func rewrite(mediaURL: URL, body: String) throws -> (playlist: String, assets: [Asset]) {
        var assets: [Asset] = []
        var names: [String: String] = [:]
        var sequence: Int64 = 0
        let source = lines(body)
        var output: [String] = []
        output.reserveCapacity(source.count)

        for (index, line) in source.enumerated() {
            if line.hasPrefix("#EXT-X-MEDIA-SEQUENCE") {
                let raw = line.split(separator: ":", maxSplits: 1).last.map(String.init) ?? ""
                sequence = Int64(raw.trimmingCharacters(in: .whitespaces)) ?? sequence
                output.append(line)
                continue
            }
            if line.hasPrefix("#EXT-X-KEY"), !line.contains("METHOD=NONE") {
                let key = try replaceKeyURI(
                    in: line, lines: source, from: index + 1, mediaURL: mediaURL, sequence: sequence,
                    names: &names, assets: &assets
                )
                output.append(key)
                continue
            }
            if line.hasPrefix("#EXT-X-MAP") {
                output.append(try replaceURI(in: line, mediaURL: mediaURL, prefix: "init", suffix: "mp4", names: &names, assets: &assets))
                continue
            }
            if line.isEmpty || line.hasPrefix("#") {
                output.append(line)
                continue
            }
            let remote = urlFor(line, relativeTo: mediaURL)
            var name = names[remote.absoluteString]
            if name == nil {
                name = "seg_\(assets.filter { $0.localName.hasSuffix(".ts") }.count).ts"
                names[remote.absoluteString] = name
                assets.append(Asset(remote: remote, localName: name!))
            }
            output.append(name ?? line)
            sequence += 1
        }

        var text = output.joined(separator: "\n")
        // rou.video's browser-oriented manifests currently under-declare
        // TARGETDURATION (8 despite 8.333333-second segments). AVFoundation
        // correctly rejects that form, so make the offline/native copy comply
        // with the HLS ceiling rule before handing it to AVPlayer.
        if text.contains("#EXTM3U") {
            let longest = lines(text).compactMap { line -> Int? in
                guard line.hasPrefix("#EXTINF:") else { return nil }
                let raw = line.dropFirst("#EXTINF:".count).split(separator: ",", maxSplits: 1).first ?? ""
                guard let duration = Double(raw) else { return nil }
                return Int(ceil(duration))
            }.max()
            if let longest {
                text = text.replacingOccurrences(
                    of: #"#EXT-X-TARGETDURATION:\d+"#,
                    with: "#EXT-X-TARGETDURATION:\(longest)",
                    options: .regularExpression
                )
            }
        }
        return (text.contains("#EXT-X-ENDLIST") ? text + "\n" : text + "\n#EXT-X-ENDLIST\n", assets)
    }

    /// 密钥行需要额外记住 IV 与作用域内的首个分片，下载完成后才能还原密钥。
    private func replaceKeyURI(
        in line: String,
        lines: [String],
        from index: Int,
        mediaURL: URL,
        sequence: Int64,
        names: inout [String: String],
        assets: inout [Asset]
    ) throws -> String {
        let pattern = "URI=(?:\\\"([^\\\"]+)\\\"|'([^']+)'|([^,\\s]+))"
        let expression = try NSRegularExpression(pattern: pattern)
        let range = NSRange(line.startIndex..., in: line)
        guard let match = expression.firstMatch(in: line, range: range) else { return line }
        let value = (1...3).compactMap { index -> String? in
            guard let swiftRange = Range(match.range(at: index), in: line) else { return nil }
            return String(line[swiftRange])
        }.first ?? ""
        let remote = urlFor(value, relativeTo: mediaURL)

        var segment: URL?
        for candidate in lines[index...] {
            if candidate.isEmpty || candidate.hasPrefix("#") { continue }
            segment = urlFor(candidate, relativeTo: mediaURL)
            break
        }

        var iv: Data?
        if let hexRange = line.range(of: #"IV=0x([0-9a-fA-F]+)"#, options: .regularExpression) {
            iv = HaijiaoKeys.hexIV(line[hexRange].replacingOccurrences(of: "IV=0x", with: ""))
        } else if line.contains("METHOD=AES-128") {
            iv = HaijiaoKeys.sequenceIV(sequence)
        }

        let existing = names[remote.absoluteString]
        let name = existing ?? "key_\(assets.filter { $0.localName.hasPrefix("key") }.count).bin"
        if existing == nil {
            names[remote.absoluteString] = name
            assets.append(
                Asset(
                    remote: remote, localName: name,
                    keyIV: keyPlan == nil ? nil : iv,
                    keySegment: keyPlan == nil ? nil : segment
                )
            )
        }
        guard let replaceRange = Range(match.range, in: line) else { return line }
        return line.replacingCharacters(in: replaceRange, with: "URI=\"\(name)\"")
    }

    private func replaceURI(in line: String, mediaURL: URL, prefix: String, suffix: String, names: inout [String: String], assets: inout [Asset]) throws -> String {
        let pattern = "URI=(?:\\\"([^\\\"]+)\\\"|'([^']+)'|([^,\\s]+))"
        let expression = try NSRegularExpression(pattern: pattern)
        let range = NSRange(line.startIndex..., in: line)
        guard let match = expression.firstMatch(in: line, range: range) else { return line }
        let value = (1...3).compactMap { index -> String? in
            guard let swiftRange = Range(match.range(at: index), in: line) else { return nil }
            return String(line[swiftRange])
        }.first ?? ""
        let remote = urlFor(value, relativeTo: mediaURL)
        let existing = names[remote.absoluteString]
        let count = assets.filter { $0.localName.hasPrefix(prefix) }.count
        let name = existing ?? "\(prefix)_\(count).\(suffix)"
        if names[remote.absoluteString] == nil {
            names[remote.absoluteString] = name
            assets.append(Asset(remote: remote, localName: name, keyIV: nil, keySegment: nil))
        }
        guard let replaceRange = Range(match.range, in: line) else { return line }
        return line.replacingCharacters(in: replaceRange, with: "URI=\"\(name)\"")
    }

    private func fetchText(_ url: URL) async throws -> String {
        String(decoding: try await fetch(url), as: UTF8.self).replacingOccurrences(of: "\u{feff}", with: "")
    }

    private func fetch(_ url: URL) async throws -> Data {
        var request = URLRequest(url: url)
        request.setValue(Self.userAgent, forHTTPHeaderField: "User-Agent")
        request.setValue(origin, forHTTPHeaderField: "Referer")
        request.setValue(origin.trimmingCharacters(in: CharacterSet(charactersIn: "/")), forHTTPHeaderField: "Origin")
        // Richy10 对应的站点只在清单请求上校验这几个公开 CDN 头；分片与密钥主机
        // 不接受它们，所以和循环桥接层一样按扩展名限定。
        if url.path.lowercased().contains(".m3u8") {
            mediaHeaders.forEach { request.setValue($0.value, forHTTPHeaderField: $0.key) }
        }
        let (data, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse, 200..<300 ~= http.statusCode else {
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            let host = response.url?.host ?? url.host ?? "未知主机"
            throw RepositoryError.invalidResponse("媒体请求失败（HTTP \(status) · 请求 \(url.host ?? "未知主机")\(url.path) · 响应 \(host)）")
        }
        // rou.video 的公开 HLS 响应是 PNG 容器，下载时也需要和播放器一样还原其中的
        // m3u8/TS 数据；其他来源不是该容器，会保持原样返回。
        return try RouHLSPayload.unwrapIfNeeded(data)
    }

    private func lines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\u{feff}", with: "").split(separator: "\n", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    private func urlFor(_ reference: String, relativeTo base: URL) -> URL {
        URL(string: reference, relativeTo: base)?.absoluteURL ?? base
    }

    private struct Asset: Sendable {
        let remote: URL
        let localName: String
        var keyIV: Data? = nil
        var keySegment: URL? = nil
    }

    private static let userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1"
}
