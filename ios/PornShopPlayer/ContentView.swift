import AVKit
import Combine
import SafariServices
import SwiftUI
import UIKit

@MainActor
final class AppModel: ObservableObject {
    @Published var unlocked = false
    @Published var site = SiteProfile.pornShop
    @Published var mode: BrowseMode = .home
    @Published var items: [VideoItem] = []
    @Published var query = ""
    @Published var loading = false
    @Published var loadingMore = false
    @Published var error: String?
    @Published var page = 1
    @Published var canLoadMore = false
    @Published var playerItem: VideoItem?
    @Published var playable: Playable?
    @Published var playerError: String?
    @Published var favorites: [VideoItem] = []
    @Published var history: [VideoItem] = []
    @Published var tangXinFeed: TangXinFeed = .home
    @Published var tangXinArtists: [TangXinArtist] = []
    @Published var publicWebsiteFeed: PublicWebsiteFeed?
    @Published var publicWebsiteFeeds: [PublicWebsiteFeed] = []
    @Published var haijiaoNodes: [Choice] = []
    /// 海角账号状态文案（已登录昵称 / 未登录）。账号只在本机保存，
    /// 用于站点自己的成员通道，不参与任何绕过验证的逻辑。
    @Published var haijiaoAccount = "未登录"
    @Published var websitePlayback: WebsitePlayback?
    /// PornShop / 好色TV 的目录接口用 type 区分，不应再固定把所有来源都当成 hot。
    @Published var apiCatalogKey = "hot"

    let downloads = DownloadManager()
    private let repository = PornShopRepository()
    private let haijiaoSource = HaijiaoSource()
    private let thdhSource = ThdhSource()
    private let douyinSource = DouyinSource()
    private let javhdSource = JavhdSource()
    private let favoritesKey = "pornshop_favorites_ios"
    private let historyKey = "pornshop_history_ios"

    init() {
        favorites = Self.restore([VideoItem].self, key: favoritesKey)
        history = Self.restore([VideoItem].self, key: historyKey)
    }

    func reload() async {
        await load(page: 1, replacing: true)
    }

    func loadMore() async {
        guard canLoadMore, !loadingMore, !loading else { return }
        await load(page: page + 1, replacing: false)
    }

    func switchSite(_ profile: SiteProfile) async {
        guard site != profile else { return }
        site = profile
        apiCatalogKey = profile.catalogGroups.first?.items.first?.key ?? "hot"
        if profile.id == SiteProfile.tangXin.id { tangXinFeed = .home }
        if SiteProfile.publicWebsiteIDs.contains(profile.id) {
            publicWebsiteFeed = nil
            publicWebsiteFeeds = []
        }
        if profile.id == SiteProfile.haijiao.id { haijiaoNodes = [] }
        await reload()
        if profile.id == SiteProfile.haijiao.id {
            await loadHaijiaoNodes()
            await refreshHaijiaoAccount()
        }
    }

    /// 海角账号相关的界面状态全部从数据层取，避免界面自己记一份会和实际会话走散的状态。
    func refreshHaijiaoAccount() async {
        haijiaoAccount = await haijiaoSource.accountLabel()
    }

    func loginHaijiao(account: String, password: String) async {
        do {
            haijiaoAccount = try await haijiaoSource.login(account: account, password: password)
            error = nil
        } catch {
            self.error = error.localizedDescription
            haijiaoAccount = await haijiaoSource.accountLabel()
        }
    }

    func logoutHaijiao() async {
        await haijiaoSource.logout()
        await refreshHaijiaoAccount()
    }

    func selectTangXinFeed(_ feed: TangXinFeed) async {
        guard site.id == SiteProfile.tangXin.id, tangXinFeed != feed else { return }
        tangXinFeed = feed
        await reload()
    }

    func selectPublicWebsiteFeed(_ feed: PublicWebsiteFeed) async {
        guard SiteProfile.publicWebsiteIDs.contains(site.id), publicWebsiteFeed != feed else { return }
        publicWebsiteFeed = feed
        await reload()
    }

    func selectAPICatalog(_ choice: Choice) async {
        guard !site.catalogGroups.isEmpty,
              site.catalogGroups.flatMap(\.items).contains(choice),
              apiCatalogKey != choice.key else { return }
        apiCatalogKey = choice.key
        await reload()
    }

    /// 海角的二级节点由站点公开节点目录动态提供，不能套进 API 型来源的静态分类校验。
    func selectHaijiaoFeed(_ choice: Choice) async {
        guard site.id == SiteProfile.haijiao.id, apiCatalogKey != choice.key else { return }
        apiCatalogKey = choice.key
        await reload()
    }

    var apiCatalogChoice: Choice? {
        site.catalogGroups.flatMap(\.items).first { $0.key == apiCatalogKey }
    }

    func open(_ item: VideoItem) async {
        if item.site == SiteProfile.haijiao.id {
            playerItem = item
            playerError = nil
            playable = nil
            if let local = downloads.localURL(for: item.id) {
                playable = localPlayable(for: item, url: local)
                remember(item)
                return
            }
            // 完整解析顺序与上游一致：卡片预览 → 帖子通道 → 分片反推 →
            // （登录后）跨帖 attachment 与视频中心通道。密钥由播放桥接层现场还原。
            do {
                let resolution = try await haijiaoSource.resolve(item)
                playable = Playable(
                    id: item.id, title: item.displayTitle, playURL: resolution.url,
                    streamURLs: [resolution.url], cover: item.cover, duration: item.duration,
                    activeHost: resolution.url.host ?? "www.haijiao.com", lineKey: "", lines: [],
                    pageOrigin: SiteProfile.haijiao.pageOrigin, site: item.site,
                    sourcePageURL: item.sourcePageURL,
                    keyPlan: .haijiao(versions: resolution.keyVersions)
                )
                remember(item)
                return
            } catch {
                // 仍找不到地址时回到站点自己的页面，由原站播放器处理账号与权限。
                if let rawPage = item.sourcePageURL, let pageURL = URL(string: rawPage) {
                    playerItem = nil
                    websitePlayback = WebsitePlayback(
                        id: "haijiao-web-\(item.id)", title: item.displayTitle, address: pageURL
                    )
                    remember(item)
                    return
                }
                playerError = error.localizedDescription
                return
            }
        }
        if SiteProfile.adapterSourceIDs.contains(item.site) {
            playerItem = item
            playerError = nil
            if let local = downloads.localURL(for: item.id) {
                playable = localPlayable(for: item, url: local)
                remember(item)
                return
            }
            playable = nil
            do {
                playable = try await resolveAdapter(item, line: nil)
                remember(item)
            } catch {
                playerError = error.localizedDescription
            }
            return
        }
        if SiteProfile.publicWebsiteIDs.contains(item.site) {
            playerItem = item
            playerError = nil
            if let local = downloads.localURL(for: item.id) {
                playable = Playable(
                    id: item.id, title: item.displayTitle, playURL: local, streamURLs: [local],
                    cover: item.cover, duration: item.duration, activeHost: "本地", lineKey: "", lines: [],
                    pageOrigin: profile(for: item).pageOrigin, site: item.site, sourcePageURL: item.sourcePageURL
                )
                remember(item)
                return
            }
            playable = nil
            guard let rawPageURL = item.sourcePageURL, let pageURL = URL(string: rawPageURL) else {
                playerError = "播放页面地址无效"
                return
            }
            // 懂色帝的页面给出的相对 m3u8 并不是独立的公开媒体入口：站点的
            // 正常网页会把它交给自己的 /addons/vplayer/ 播放器，并在浏览器上下文中
            // 完成验证与请求。直接交给 AVPlayer 会被服务端拒绝（403）。因此这里
            // 打开原站视频页，让用户获得站点原有的播放与全屏控制；不猜地址、不绕过
            // Cookie、登录或人机验证。
            if item.site == SiteProfile.dsdSE.id {
                guard DsdWebsite.isPlayPage(pageURL) else {
                    playerError = "懂色帝视频页面地址无效"
                    return
                }
                playerItem = nil
                websitePlayback = WebsitePlayback(
                    id: "dsd-web-\(item.id)", title: item.displayTitle, address: pageURL
                )
                remember(item)
                return
            }
            do {
                let result = try await repository.resolvePublicWebsitePage(pageURL, site: item.site)
                playable = Playable(
                    id: item.id, title: result.title, playURL: result.streamURL, streamURLs: [result.streamURL],
                    cover: item.cover, duration: item.duration, activeHost: pageURL.host ?? profile(for: item).appName,
                    lineKey: "", lines: [], pageOrigin: profile(for: item).pageOrigin, site: item.site,
                    sourcePageURL: item.sourcePageURL, mediaHeaders: result.mediaHeaders
                )
                remember(item)
            } catch {
                playerError = error.localizedDescription
            }
            return
        }
        if item.site == SiteProfile.tangXin.id {
            playerItem = item
            playerError = nil
            if let local = downloads.localURL(for: item.id) {
                playable = Playable(
                    id: item.id, title: item.displayTitle, playURL: local, streamURLs: [local],
                    cover: item.cover, duration: item.duration, activeHost: "本地", lineKey: "", lines: [],
                    pageOrigin: SiteProfile.tangXin.pageOrigin, site: item.site, sourcePageURL: item.sourcePageURL
                )
                remember(item)
                return
            }
            playable = nil
            guard let rawPageURL = item.sourcePageURL, let pageURL = URL(string: rawPageURL) else {
                playerError = "视频页地址无效"
                return
            }
            do {
                let result = try await repository.resolveTangXinPage(pageURL)
                playable = Playable(
                    id: item.id, title: result.title, playURL: result.streamURL, streamURLs: [result.streamURL],
                    cover: item.cover, duration: item.duration, activeHost: pageURL.host ?? "糖心Vlog", lineKey: "", lines: [],
                    pageOrigin: SiteProfile.tangXin.pageOrigin, site: item.site, sourcePageURL: item.sourcePageURL
                )
                remember(item)
            } catch {
                playerError = error.localizedDescription
            }
            return
        }
        if item.site == SiteProfile.rouVideo.id {
            playerItem = item
            playerError = nil
            if let local = downloads.localURL(for: item.id) {
                playable = Playable(
                    id: item.id, title: item.displayTitle, playURL: local, streamURLs: [local],
                    cover: item.cover, duration: item.duration, activeHost: "本地", lineKey: "", lines: [],
                    pageOrigin: SiteProfile.rouVideo.pageOrigin, site: item.site, sourcePageURL: item.sourcePageURL
                )
                remember(item)
                return
            }
            playable = nil
            guard let rawPageURL = item.sourcePageURL, let pageURL = URL(string: rawPageURL) else {
                playerError = "肉视频页面地址无效"
                return
            }
            do {
                let result = try await repository.resolveRouVideoPage(pageURL)
                playable = Playable(
                    id: item.id, title: result.title, playURL: result.streamURL, streamURLs: [result.streamURL],
                    cover: item.cover, duration: item.duration, activeHost: pageURL.host ?? "rou.video", lineKey: "", lines: [],
                    pageOrigin: SiteProfile.rouVideo.pageOrigin, site: item.site, sourcePageURL: item.sourcePageURL
                )
                remember(item)
            } catch {
                playerError = error.localizedDescription
            }
            return
        }
        playerItem = item
        playerError = nil
        if let local = downloads.localURL(for: item.id) {
            playable = Playable(
                id: item.id, title: item.displayTitle, playURL: local, streamURLs: [local],
                cover: item.cover, duration: item.duration, activeHost: "本地", lineKey: "", lines: [],
                pageOrigin: profile(for: item).pageOrigin, site: item.site, sourcePageURL: item.sourcePageURL
            )
            remember(item)
            return
        }
        playable = nil
        do {
            let result = try await repository.resolvePlayable(item)
            playable = result
            remember(item)
        } catch {
            playerError = error.localizedDescription
        }
    }

    func selectLine(_ choice: Choice) async {
        guard let item = playerItem else { return }
        playerError = nil
        do {
            // JAVHD 的「线路」就是清晰度，必须重新解析播放页才能拿到对应 MP4。
            if SiteProfile.adapterSourceIDs.contains(item.site) {
                playable = try await resolveAdapter(item, line: choice.key)
            } else {
                playable = try await repository.resolvePlayable(item, line: choice.key)
            }
        } catch {
            playerError = error.localizedDescription
        }
    }

    func nextStream() {
        guard let current = playable, let index = current.streamURLs.firstIndex(of: current.playURL), index + 1 < current.streamURLs.count else { return }
        playable = Playable(
            id: current.id, title: current.title, playURL: current.streamURLs[index + 1], streamURLs: current.streamURLs,
            cover: current.cover, duration: current.duration, activeHost: current.activeHost, lineKey: current.lineKey,
            lines: current.lines, pageOrigin: current.pageOrigin, site: current.site,
            sourcePageURL: current.sourcePageURL, mediaHeaders: current.mediaHeaders, keyPlan: current.keyPlan
        )
    }

    func downloadCurrent() {
        guard let item = playerItem, let playable else { return }
        downloads.enqueue(item, playable: playable)
    }

    func toggleFavorite(_ item: VideoItem) {
        if favorites.contains(where: { $0.id == item.id && $0.site == item.site }) {
            favorites.removeAll { $0.id == item.id && $0.site == item.site }
        } else {
            favorites.insert(item, at: 0)
        }
        save(favorites, key: favoritesKey)
    }

    func isFavorite(_ item: VideoItem) -> Bool {
        favorites.contains { $0.id == item.id && $0.site == item.site }
    }

    func closePlayer() {
        playerItem = nil
        playable = nil
        playerError = nil
    }

    private func load(page requestedPage: Int, replacing: Bool) async {
        if replacing { loading = true } else { loadingMore = true }
        error = nil
        do {
            let result: ListPage
            if site.id == SiteProfile.haijiao.id {
                if mode == .search {
                    result = try await haijiaoSource.search(keyword: query, feed: apiCatalogKey)
                } else {
                    result = try await haijiaoSource.catalog(feed: apiCatalogKey, page: requestedPage)
                }
            } else if site.id == SiteProfile.tangXin.id {
                let catalog = try await repository.tangXinCatalog(feed: tangXinFeed, page: requestedPage)
                result = catalog.page
                if replacing && tangXinFeed == .home { tangXinArtists = catalog.artists }
            } else if site.id == SiteProfile.rouVideo.id {
                let searchQuery = mode == .search ? self.query : nil
                result = try await repository.rouVideoCatalog(page: requestedPage, query: searchQuery)
            } else if SiteProfile.adapterSourceIDs.contains(site.id) {
                let keyword = query.trimmingCharacters(in: .whitespacesAndNewlines)
                if mode == .search, !keyword.isEmpty {
                    result = try await searchAdapter(site: site, keyword: keyword, page: requestedPage)
                } else {
                    result = try await listAdapter(site: site, type: apiCatalogKey, page: requestedPage)
                }
            } else if SiteProfile.publicWebsiteIDs.contains(site.id) {
                let searchQuery = mode == .search ? self.query : nil
                let catalog = try await repository.publicWebsiteCatalog(
                    site: site.id, feed: publicWebsiteFeed, page: requestedPage, query: searchQuery
                )
                result = catalog.page
                // Do not replace the menu while a search or selected channel is open.
                if replacing,
                   mode != .search,
                   (publicWebsiteFeed == nil || publicWebsiteFeeds.isEmpty) {
                    publicWebsiteFeeds = catalog.feeds
                }
            } else if mode == .search, !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                result = try await repository.search(keyword: query, page: requestedPage, profile: site)
            } else {
                result = try await repository.listVideos(type: apiCatalogKey, page: requestedPage, profile: site)
            }
            if replacing {
                items = result.items
            } else {
                let known = Set(items.map { "\($0.site):\($0.id)" })
                items += result.items.filter { !known.contains("\($0.site):\($0.id)") }
            }
            page = result.page
            canLoadMore = result.openEnded
        } catch {
            self.error = error.localizedDescription
        }
        loading = false
        loadingMore = false
    }

    private func loadHaijiaoNodes() async {
        do {
            let nodes = try await haijiaoSource.nodes()
            guard site.id == SiteProfile.haijiao.id else { return }
            haijiaoNodes = nodes
        } catch {
            // 节点是扩展导航；目录、搜索和公开预览不应因它暂时不可用而失效。
            haijiaoNodes = []
        }
    }

    private func profile(for item: VideoItem) -> SiteProfile {
        SiteProfile.all.first(where: { $0.id == item.site }) ?? .pornShop
    }

    /// 探花 / 抖音 / JAVHD 各自有独立目录与播放协议，这里按站点分派，
    /// 与上游 `PornShopRepository` 的分派表一一对应。
    private func listAdapter(site profile: SiteProfile, type: String, page: Int) async throws -> ListPage {
        switch profile.id {
        case SiteProfile.thdh.id:
            return try await thdhSource.list(type: type, page: page)
        case SiteProfile.douyin.id:
            return try await douyinSource.list(type: type, page: page)
        case SiteProfile.javhd.id:
            return try await javhdSource.list(type: type, page: page)
        default:
            throw RepositoryError.invalidResponse("不支持的播放源")
        }
    }

    private func searchAdapter(site profile: SiteProfile, keyword: String, page: Int) async throws -> ListPage {
        switch profile.id {
        case SiteProfile.thdh.id:
            return try await thdhSource.search(keyword: keyword, page: page)
        case SiteProfile.douyin.id:
            return try await douyinSource.search(keyword: keyword, page: page)
        case SiteProfile.javhd.id:
            return try await javhdSource.search(keyword: keyword, page: page)
        default:
            throw RepositoryError.invalidResponse("不支持的播放源")
        }
    }

    private func resolveAdapter(_ item: VideoItem, line: String?) async throws -> Playable {
        let profile = profile(for: item)
        switch item.site {
        case SiteProfile.thdh.id:
            return try await thdhSource.resolve(item)
        case SiteProfile.javhd.id:
            return try await javhdSource.resolve(item, resolution: line)
        case SiteProfile.douyin.id:
            let playback = try await douyinSource.resolve(item)
            guard let first = playback.streamURLs.first else { throw RepositoryError.missingPlaybackURL }
            return Playable(
                id: item.id, title: playback.title, playURL: first,
                streamURLs: playback.streamURLs, cover: playback.cover ?? item.cover,
                duration: playback.duration ?? item.duration, activeHost: playback.activeHost,
                lineKey: "", lines: [], pageOrigin: profile.pageOrigin, site: item.site,
                sourcePageURL: item.sourcePageURL,
                mediaHeaders: [:],
                keyPlan: .douyinRSA
            )
        default:
            throw RepositoryError.invalidResponse("不支持的播放源")
        }
    }

    private func localPlayable(for item: VideoItem, url: URL) -> Playable {
        Playable(
            id: item.id, title: item.displayTitle, playURL: url, streamURLs: [url],
            cover: item.cover, duration: item.duration, activeHost: "本地", lineKey: "", lines: [],
            pageOrigin: profile(for: item).pageOrigin, site: item.site, sourcePageURL: item.sourcePageURL
        )
    }

    private func remember(_ item: VideoItem) {
        history = [item] + history.filter { $0.id != item.id || $0.site != item.site }
        history = Array(history.prefix(50))
        save(history, key: historyKey)
    }

    private func save<T: Encodable>(_ value: T, key: String) {
        if let data = try? JSONEncoder().encode(value) { UserDefaults.standard.set(data, forKey: key) }
    }

    private static func restore<T: Decodable>(_ type: T.Type, key: String) -> T where T: ExpressibleByArrayLiteral {
        guard let data = UserDefaults.standard.data(forKey: key), let value = try? JSONDecoder().decode(type, from: data) else { return [] }
        return value
    }
}

struct RootView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        Group {
            if model.unlocked {
                PlayerLibraryView()
            } else {
                StudyGateView()
            }
        }
        .tint(.mint)
    }
}

private struct StudyGateView: View {
    @EnvironmentObject private var model: AppModel
    @State private var code = ""
    @State private var denied = false

    var body: some View {
        NavigationView {
            VStack(spacing: 22) {
                Spacer()
                Image(systemName: "books.vertical.fill")
                    .font(.system(size: 62))
                    .foregroundStyle(.mint)
                Text("青禾学堂")
                    .font(.system(size: 32, weight: .semibold, design: .serif))
                Text("课程学习与学习资料管理")
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 12) {
                    Text("加入课程")
                        .font(.headline)
                    TextField("输入课程码", text: $code)
                        .textInputAutocapitalization(.never)
                        .keyboardType(.numberPad)
                        .textFieldStyle(.roundedBorder)
                    if denied { Text("课程码无效").font(.footnote).foregroundStyle(.red) }
                    Button("进入课程") {
                        if code == "886" { model.unlocked = true } else { denied = true }
                    }
                    .buttonStyle(.borderedProminent)
                    .frame(maxWidth: .infinity)
                }
                .padding(20)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 22))
                Spacer()
            }
            .padding(28)
            .background(Color(.systemGroupedBackground))
        }
    }
}

private struct PlayerLibraryView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        TabView(selection: $model.mode) {
            FeedView()
                .tabItem { Label("首页", systemImage: "house") }
                .tag(BrowseMode.home)
            SearchView()
                .tabItem { Label("搜索", systemImage: "magnifyingglass") }
                .tag(BrowseMode.search)
            LibraryView()
                .tabItem { Label("片库", systemImage: "square.stack") }
                .tag(BrowseMode.library)
        }
        .sheet(item: Binding(get: { model.playerItem }, set: { if $0 == nil { model.closePlayer() } })) { item in
            PlayerSheet(item: item)
        }
        .sheet(item: Binding(get: { model.websitePlayback }, set: { model.websitePlayback = $0 })) { playback in
            WebsitePlaybackSheet(playback: playback)
        }
    }
}

private struct FeedView: View {
    @EnvironmentObject private var model: AppModel
    /// 同一处 sheet 承载官网访问与海角账号，避免在一个视图上叠多个 sheet 修饰符。
    @State private var sheet: FeedSheet?

    private enum FeedSheet: Identifiable {
        case website(OfficialWebsite)
        case haijiaoAccount

        var id: String {
            switch self {
            case .website(let website): "website-\(website.id)"
            case .haijiaoAccount: "haijiao-account"
            }
        }
    }

    private var navigationTitle: String {
        if model.site.id == SiteProfile.tangXin.id {
            return "\(model.site.label) · \(model.tangXinFeed.label)"
        }
        if SiteProfile.publicWebsiteIDs.contains(model.site.id) {
            return "\(model.site.label) · \(model.publicWebsiteFeed?.label ?? "首页最新")"
        }
        if let choice = model.apiCatalogChoice {
            return "\(model.site.label) · \(choice.label)"
        }
        return model.site.label
    }

    var body: some View {
        NavigationView {
            VideoList(items: model.items, loading: model.loading, loadingMore: model.loadingMore, error: model.error, canLoadMore: model.canLoadMore, onRefresh: { await model.reload() }, onMore: { await model.loadMore() })
                .navigationTitle(navigationTitle)
                .toolbar {
                    ToolbarItem(placement: .navigationBarTrailing) {
                        Menu {
                            Section("播放源") {
                                ForEach(SiteProfile.all) { profile in
                                    Button(profile.label) { Task { await model.switchSite(profile) } }
                                }
                            }
                            Section("官网访问") {
                                ForEach(OfficialWebsite.all) { website in
                                    Button(website.label) { sheet = .website(website) }
                                }
                            }
                            if model.site.id == SiteProfile.tangXin.id {
                                Section("糖心Vlog 浏览") {
                                    Button("首页最新") { Task { await model.selectTangXinFeed(.home) } }
                                    Button("全部视频") { Task { await model.selectTangXinFeed(.videos) } }
                                    ForEach(model.tangXinArtists) { artist in
                                        Button(artist.name) { Task { await model.selectTangXinFeed(.artist(artist)) } }
                                    }
                                }
                            }
                            if !model.site.catalogGroups.isEmpty {
                                Section("\(model.site.label) 分类") {
                                    ForEach(model.site.catalogGroups) { group in
                                        Menu(group.title) {
                                            ForEach(group.items) { choice in
                                                Button(choice.label) { Task { await model.selectAPICatalog(choice) } }
                                            }
                                        }
                                    }
                                }
                            }
                            if model.site.id == SiteProfile.haijiao.id, !model.haijiaoNodes.isEmpty {
                                Section("海角更多节点") {
                                    ForEach(model.haijiaoNodes) { choice in
                                        Button(choice.label) { Task { await model.selectHaijiaoFeed(choice) } }
                                    }
                                }
                            }
                            if model.site.id == SiteProfile.haijiao.id {
                                // 账号用于站点自己的成员通道（金币片/钻石片与完整清单），
                                // 只在本机保存，界面上同时显示当前登录状态。
                                Section("海角账号") {
                                    Button(model.haijiaoAccount) { sheet = .haijiaoAccount }
                                }
                            }
                            if SiteProfile.publicWebsiteIDs.contains(model.site.id) {
                                Section("\(model.site.label) 浏览") {
                                    ForEach(model.publicWebsiteFeeds) { feed in
                                        Button(feed.label) { Task { await model.selectPublicWebsiteFeed(feed) } }
                                    }
                                }
                            }
                        } label: {
                            Image(systemName: "arrow.left.arrow.right")
                        }
                    }
                }
                .task { if model.items.isEmpty { await model.reload() } }
        }
        .sheet(item: $sheet) { value in
            switch value {
            case .website(let website):
                OfficialWebsiteSheet(website: website)
                    .ignoresSafeArea()
            case .haijiaoAccount:
                HaijiaoAccountSheet()
            }
        }
    }
}

/// 海角账号面板：登录、退出与当前状态。密码只在提交时使用，不写入任何存储；
/// 会话只保存站点自己下发的 token、用户编号与昵称。
private struct HaijiaoAccountSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var account = ""
    @State private var password = ""
    @State private var busy = false

    var body: some View {
        NavigationView {
            Form {
                Section("当前状态") {
                    Text(model.haijiaoAccount)
                }
                Section("登录海角") {
                    TextField("账号或邮箱", text: $account)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("密码", text: $password)
                    Button(busy ? "正在登录…" : "登录") {
                        guard !busy else { return }
                        busy = true
                        Task {
                            await model.loginHaijiao(account: account, password: password)
                            busy = false
                            if model.haijiaoAccount.hasPrefix("已登录") {
                                password = ""
                                dismiss()
                            }
                        }
                    }
                    .disabled(busy || account.trimmingCharacters(in: .whitespaces).isEmpty || password.isEmpty)
                }
                if model.haijiaoAccount.hasPrefix("已登录") {
                    Section {
                        Button("退出登录", role: .destructive) {
                            Task {
                                await model.logoutHaijiao()
                                dismiss()
                            }
                        }
                    }
                }
                if let error = model.error {
                    Section("提示") {
                        Text(error).font(.footnote).foregroundStyle(.red)
                    }
                }
            }
            .navigationTitle("海角账号")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) { Button("关闭") { dismiss() } }
            }
            .task { await model.refreshHaijiaoAccount() }
        }
    }
}

/// Uses the system web view exactly as supplied by iOS.  There is no injected
/// JavaScript, URL rewriting, request interception, downloader, or attempt to
/// share cookies with the native source adapters.
private struct OfficialWebsiteSheet: UIViewControllerRepresentable {
    let website: OfficialWebsite

    func makeUIViewController(context: Context) -> SFSafariViewController {
        SFSafariViewController(url: website.address)
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

/// 懂色帝站点明确通过自己的网页播放器包装媒体请求。使用 Safari Services
/// 保持该站的原始行为与访问控制；不会向网页注入脚本，也不拦截或伪造请求。
private struct WebsitePlaybackSheet: UIViewControllerRepresentable {
    let playback: WebsitePlayback

    func makeUIViewController(context: Context) -> SFSafariViewController {
        let configuration = SFSafariViewController.Configuration()
        configuration.entersReaderIfAvailable = false
        let controller = SFSafariViewController(url: playback.address, configuration: configuration)
        controller.dismissButtonStyle = .close
        return controller
    }

    func updateUIViewController(_ uiViewController: SFSafariViewController, context: Context) {}
}

private struct SearchView: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        NavigationView {
            Group {
                if SiteProfile.searchUnavailableIDs.contains(model.site.id) {
                    VStack(spacing: 12) {
                        Image(systemName: "magnifyingglass")
                            .font(.system(size: 36))
                            .foregroundStyle(.secondary)
                        Text("站方未提供公开搜索入口").font(.headline)
                        Text("请在首页右上角选择站点提供的浏览频道。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(28)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    VStack(spacing: 0) {
                        if model.site.id == SiteProfile.haijiao.id {
                            Text("海角搜索仅筛选当前频道第一页公开列表")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .padding(.horizontal)
                                .padding(.top, 6)
                        }
                        VideoList(items: model.mode == .search ? model.items : [], loading: model.loading, loadingMore: model.loadingMore, error: model.error, canLoadMore: model.canLoadMore, onRefresh: { await model.reload() }, onMore: { await model.loadMore() })
                            .searchable(text: $model.query, prompt: "关键词")
                            .onSubmit(of: .search) { Task { await model.reload() } }
                    }
                }
            }
            .navigationTitle(SiteProfile.searchUnavailableIDs.contains(model.site.id) ? model.site.label : "搜索")
        }
    }
}

private struct VideoList: View {
    @EnvironmentObject private var model: AppModel
    let items: [VideoItem]
    let loading: Bool
    let loadingMore: Bool
    let error: String?
    let canLoadMore: Bool
    let onRefresh: () async -> Void
    let onMore: () async -> Void

    var body: some View {
        List {
            if let error {
                FailureView(title: "加载失败", message: error)
            } else if loading && items.isEmpty {
                HStack { Spacer(); ProgressView(); Spacer() }
            }
            ForEach(items) { item in
                VideoRow(item: item)
                    .contentShape(Rectangle())
                    .onTapGesture { Task { await model.open(item) } }
                    .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                        Button(model.isFavorite(item) ? "取消收藏" : "收藏") { model.toggleFavorite(item) }
                            .tint(.orange)
                    }
            }
            if canLoadMore {
                Button(loadingMore ? "正在加载…" : "加载更多") { Task { await onMore() } }
                    .frame(maxWidth: .infinity)
                    .disabled(loadingMore)
            }
        }
        .refreshable { await onRefresh() }
    }
}

private struct VideoRow: View {
    let item: VideoItem

    var body: some View {
        HStack(spacing: 12) {
            VideoCover(item: item)
            .frame(width: 118, height: 72)
            .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))
            .clipShape(RoundedRectangle(cornerRadius: 10))
            VStack(alignment: .leading, spacing: 5) {
                Text(item.displayTitle).font(.headline).lineLimit(2)
                Text(item.metaLine).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                if !item.tags.isEmpty { Text(item.tags.prefix(3).joined(separator: " · ")).font(.caption2).foregroundStyle(.mint).lineLimit(1) }
            }
            if item.vip { Image(systemName: "crown.fill").foregroundStyle(.orange) }
        }
        .padding(.vertical, 3)
    }
}

/// 部分公开视频站的封面 CDN 会拒绝没有 Referer 的直连请求。
/// AsyncImage 无法附加请求头，故这些来源使用带站点 Referer 的轻量加载器。
private struct VideoCover: View {
    let item: VideoItem
    @State private var websiteImage: UIImage?

    var body: some View {
        Group {
            if needsWebsiteHeaders {
                if let websiteImage {
                    Image(uiImage: websiteImage).resizable().scaledToFill()
                } else {
                    placeholder
                }
            } else {
                AsyncImage(url: item.cover.flatMap(URL.init(string:))) { phase in
                    switch phase {
                    case .success(let image): image.resizable().scaledToFill()
                    default: placeholder
                    }
                }
            }
        }
        .task(id: item.cover) {
            guard needsWebsiteHeaders else { return }
            await loadWebsiteCover()
        }
    }

    private var needsWebsiteHeaders: Bool {
        item.site == SiteProfile.tangXin.id || item.site == SiteProfile.haijiao.id
            || SiteProfile.publicWebsiteIDs.contains(item.site)
            || SiteProfile.adapterSourceIDs.contains(item.site)
    }

    private var placeholder: some View {
        Image(systemName: "play.rectangle.fill").font(.title).foregroundStyle(.secondary)
    }

    @MainActor
    private func loadWebsiteCover() async {
        websiteImage = nil
        guard let rawURL = item.cover, let url = URL(string: rawURL) else { return }
        let origin = (SiteProfile.all.first { $0.id == item.site } ?? .pornShop).pageOrigin
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        request.setValue("Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Version/18.0 Mobile/15E148 Safari/604.1", forHTTPHeaderField: "User-Agent")
        request.setValue(origin, forHTTPHeaderField: "Referer")
        request.setValue(origin.trimmingCharacters(in: CharacterSet(charactersIn: "/")), forHTTPHeaderField: "Origin")
        do {
            let (data, response) = try await URLSession.shared.data(for: request)
            guard !Task.isCancelled,
                  let http = response as? HTTPURLResponse,
                  200..<300 ~= http.statusCode else { return }
            // Richy10 的站点会把部分公开海报以 AES-CBC 字节流下发，网页
            // 懒加载器解密后再设置给 img。先尝试普通图片，失败时只对该源
            // 使用同样的公开海报解码，避免影响其他封面 CDN。
            let image: UIImage?
            if item.site == SiteProfile.porna91.id {
                image = UIImage(data: data) ?? OpenSSLAES.decryptPorna91Poster(data).flatMap(UIImage.init(data:))
            } else {
                image = UIImage(data: data)
            }
            guard let image else { return }
            websiteImage = image
        } catch {
            // 列表仍显示视频标题；封面失败不影响播放。
        }
    }
}

private struct LibraryView: View {
    @EnvironmentObject private var model: AppModel
    @State private var selection = 0

    var body: some View {
        NavigationView {
            List {
                Picker("内容", selection: $selection) {
                    Text("收藏").tag(0)
                    Text("历史").tag(1)
                    Text("下载").tag(2)
                }
                .pickerStyle(.segmented)
                if selection == 2 {
                    ForEach(model.downloads.tasks) { task in
                        DownloadRow(task: task)
                    }
                } else {
                    ForEach(selection == 0 ? model.favorites : model.history) { item in
                        VideoRow(item: item)
                            .contentShape(Rectangle())
                            .onTapGesture { Task { await model.open(item) } }
                    }
                }
            }
            .navigationTitle("片库")
        }
    }
}

private struct DownloadRow: View {
    @EnvironmentObject private var model: AppModel
    let task: DownloadTask

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(task.item.displayTitle).font(.headline).lineLimit(2)
            Text(task.progressLabel).font(.caption).foregroundStyle(task.status == .failed ? .red : .secondary)
            if task.status == .running || task.status == .paused { ProgressView(value: Double(task.percent), total: 100) }
            HStack {
                if task.status == .completed {
                    Button("播放") { Task { await model.open(task.item) } }
                } else {
                    Button(task.status == .running || task.status == .queued ? "暂停" : "继续") {
                        model.downloads.toggle(task, origin: (SiteProfile.all.first { $0.id == task.item.site } ?? .pornShop).pageOrigin)
                    }
                }
                Button("删除", role: .destructive) { model.downloads.delete(task) }
            }
        }
        .padding(.vertical, 4)
    }
}

private struct PlayerSheet: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    let item: VideoItem

    var body: some View {
        NavigationView {
            Group {
                if let playable = model.playable {
                    NativePlayerView(playable: playable)
                } else if let error = model.playerError {
                    FailureView(title: "无法播放", message: error)
                } else {
                    ProgressView("正在准备播放")
                }
            }
            .navigationTitle(item.displayTitle)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) { Button("关闭") { dismiss() } }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button(model.isFavorite(item) ? "已收藏" : "收藏") { model.toggleFavorite(item) }
                }
            }
        }
    }
}

private struct NativePlayerView: View {
    @EnvironmentObject private var model: AppModel
    let playable: Playable
    @State private var player: AVPlayer?
    @State private var rouProxy: RouHLSHTTPProxy?
    @State private var rouPlaybackSetup: Task<Void, Never>?
    @State private var playbackMessage: String?
    @State private var showingFullscreen = false
    @State private var playbackRate: Float = 1

    var body: some View {
        ScrollView {
            VStack(spacing: 14) {
                CenteredPlayerSurface(player: player)
                    .frame(maxWidth: .infinity)
                if let playbackMessage {
                    ProgressView(playbackMessage).font(.footnote)
                }
                Button {
                    showingFullscreen = true
                } label: {
                    Label("全屏播放", systemImage: "arrow.up.left.and.arrow.down.right")
                }
                .buttonStyle(.bordered)
                .disabled(player == nil)
                Menu {
                    ForEach([1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                        Button {
                            setPlaybackRate(Float(rate))
                        } label: {
                            if playbackRate == Float(rate) {
                                Label(playbackRateLabel(Float(rate)), systemImage: "checkmark")
                            } else {
                                Text(playbackRateLabel(Float(rate)))
                            }
                        }
                    }
                } label: {
                    Label("倍速 \(playbackRateLabel(playbackRate))", systemImage: "speedometer")
                }
                .buttonStyle(.bordered)
                .accessibilityLabel("播放倍速 \(playbackRateLabel(playbackRate))")
            if !playable.lines.isEmpty {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack { ForEach(playable.lines) { line in Button(line.label) { Task { await model.selectLine(line) } }.buttonStyle(.bordered) } }
                }
            }
            if playable.streamURLs.count > 1 {
                Button("切换下一线路") { model.nextStream() }.buttonStyle(.bordered)
            }
            Button("下载当前视频") { model.downloadCurrent() }
                .buttonStyle(.borderedProminent)
                .padding(.bottom, 8)
            }
            .frame(maxWidth: .infinity)
        }
        .padding(.horizontal)
        .onAppear { makePlayer() }
        .onChange(of: playable.playURL) { _ in makePlayer() }
        .onDisappear {
            rouPlaybackSetup?.cancel()
            player?.pause()
            rouProxy?.stop()
            rouProxy = nil
        }
        .fullScreenCover(isPresented: $showingFullscreen) {
            if let player {
                FullscreenPlayerView(player: player, playbackRate: $playbackRate)
            }
        }
    }

    /// 走本地桥接的条件：明文 HLS 需要保留站点头（探花、公开网页源、肉视频），
    /// 或者密钥必须现场还原（海角、抖音）。
    private static func usesBridge(_ playable: Playable) -> Bool {
        if playable.keyPlan != nil { return true }
        return playable.site == SiteProfile.rouVideo.id
            || playable.site == SiteProfile.thdh.id
            || SiteProfile.publicWebsiteIDs.contains(playable.site)
    }

    /// 分片与密钥请求需要的站点头。抖音要求它自己的移动端 User-Agent。
    private static func bridgeAssetHeaders(for playable: Playable) -> [String: String] {
        playable.site == SiteProfile.douyin.id ? ["User-Agent": douyinMediaUserAgent] : [:]
    }

    private static let douyinMediaUserAgent =
        "Mozilla/5.0 (Linux; Android 14) AppleWebKit/537.36 Chrome/131.0.0.0 Mobile Safari/537.36"

    private func makePlayer() {
        rouPlaybackSetup?.cancel()
        player?.pause()
        rouProxy?.stop()
        rouProxy = nil
        if playable.playURL.isFileURL {
            playbackMessage = nil
            player = AVPlayer(url: playable.playURL)
            startPlayback()
        } else if Self.usesBridge(playable) {
            // Keep all key-bearing and header-sensitive HLS on a loopback bridge.
            // Besides rou.video PNG envelopes, it preserves page headers for CDN
            // manifests, corrects malformed TARGETDURATION declarations, and
            // restores the two key schemes (海角合成 / 抖音 RSA) before AVFoundation
            // sees a `#EXT-X-KEY` response.
            player = nil
            playbackMessage = "正在连接公开视频…"
            let proxy = RouHLSHTTPProxy(
                origin: playable.pageOrigin,
                playlistHeaders: playable.mediaHeaders,
                assetHeaders: Self.bridgeAssetHeaders(for: playable),
                keyPlan: playable.keyPlan
            )
            let remoteURL = playable.playURL
            rouProxy = proxy
            rouPlaybackSetup = Task {
                do {
                    try await proxy.start()
                    guard !Task.isCancelled,
                          rouProxy === proxy,
                          let localURL = proxy.playlistURL(for: remoteURL) else { return }
                    player = AVPlayer(url: localURL)
                    playbackMessage = nil
                    startPlayback()
                } catch is CancellationError {
                } catch {
                    guard !Task.isCancelled else { return }
                    playbackMessage = "播放器启动失败：\(error.localizedDescription)"
                }
            }
        } else {
            playbackMessage = nil
            let headers = ["Referer": playable.pageOrigin, "Origin": playable.pageOrigin.trimmingCharacters(in: CharacterSet(charactersIn: "/"))]
            let asset = AVURLAsset(url: playable.playURL, options: ["AVURLAssetHTTPHeaderFieldsKey": headers])
            player = AVPlayer(playerItem: AVPlayerItem(asset: asset))
            startPlayback()
        }
    }

    private func setPlaybackRate(_ rate: Float) {
        playbackRate = rate
        applyDefaultRate(to: player)
        guard let player, player.timeControlStatus == .playing else { return }
        player.rate = rate
    }

    private func startPlayback() {
        applyDefaultRate(to: player)
        player?.play()
        if playbackRate != 1 { player?.rate = playbackRate }
    }

    private func applyDefaultRate(to player: AVPlayer?) {
        if #available(iOS 16.0, *) { player?.defaultRate = playbackRate }
    }

    private func playbackRateLabel(_ rate: Float) -> String {
        rate.rounded() == rate ? "\(Int(rate))x" : "\(rate)x"
    }
}

/// 固定使用 16:9 的播放器画布；小屏幕按可用宽度缩放，横向与纵向都在容器中心对齐。
private struct CenteredPlayerSurface: View {
    let player: AVPlayer?

    var body: some View {
        VideoPlayer(player: player)
            .aspectRatio(16 / 9, contentMode: .fit)
            .frame(maxWidth: .infinity, alignment: .center)
            .background(Color.black)
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .accessibilityLabel("居中的视频播放画面")
    }
}

/// 用全屏 cover 保留同一个 AVPlayer，因而进入和退出全屏都不会重新解析或丢失播放进度。
private struct FullscreenPlayerView: View {
    @Environment(\.dismiss) private var dismiss
    let player: AVPlayer
    @Binding var playbackRate: Float

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .topTrailing) {
                Color.black.ignoresSafeArea()
                VideoPlayer(player: player)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                    .ignoresSafeArea()
                HStack(spacing: 12) {
                    Menu {
                        ForEach([1.0, 1.25, 1.5, 2.0], id: \.self) { rate in
                            Button {
                                playbackRate = Float(rate)
                                if #available(iOS 16.0, *) { player.defaultRate = playbackRate }
                                if player.timeControlStatus == .playing { player.rate = playbackRate }
                            } label: {
                                if playbackRate == Float(rate) {
                                    Label(playbackRateLabel(Float(rate)), systemImage: "checkmark")
                                } else {
                                    Text(playbackRateLabel(Float(rate)))
                                }
                            }
                        }
                    } label: {
                        Label("倍速 \(playbackRateLabel(playbackRate))", systemImage: "speedometer")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 9)
                            .background(.black.opacity(0.55), in: Capsule())
                    }
                    .accessibilityLabel("播放倍速 \(playbackRateLabel(playbackRate))")
                    Button {
                        dismiss()
                    } label: {
                        Label("退出全屏", systemImage: "arrow.down.right.and.arrow.up.left")
                            .labelStyle(.iconOnly)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                            .padding(12)
                            .background(.black.opacity(0.55), in: Circle())
                    }
                    .accessibilityLabel("退出全屏")
                }
                .padding(.top, max(proxy.safeAreaInsets.top, 12) + 6)
                .padding(.trailing, max(proxy.safeAreaInsets.trailing, 18))
            }
        }
        .onAppear {
            if #available(iOS 16.0, *) { player.defaultRate = playbackRate }
            player.play()
            if playbackRate != 1 { player.rate = playbackRate }
        }
    }

    private func playbackRateLabel(_ rate: Float) -> String {
        rate.rounded() == rate ? "\(Int(rate))x" : "\(rate)x"
    }
}

private struct FailureView: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle")
                .font(.largeTitle)
                .foregroundStyle(.orange)
            Text(title).font(.headline)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(28)
    }
}
