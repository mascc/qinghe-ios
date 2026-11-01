import Foundation

struct VideoItem: Codable, Hashable, Identifiable {
    let id: String
    var title: String
    var cover: String?
    var duration: String?
    var views: String?
    var user: String?
    var vip: Bool
    var timeLine: String?
    var videoType: String?
    var tags: [String]
    var site: String
    /// 仅供「糖心Vlog 视频页」来源保存原始页面地址，以便历史和收藏能重新解析。
    var sourcePageURL: String?
    /// 海角公开列表随卡片返回的预览媒体地址。它不是账号、Cookie 或付费资源：
    /// 没有地址时应用只提供站点自己的详情页，不尝试猜测、探测或改写播放地址。
    var previewURL: String?

    init(
        id: String,
        title: String,
        cover: String? = nil,
        duration: String? = nil,
        views: String? = nil,
        user: String? = nil,
        vip: Bool = false,
        timeLine: String? = nil,
        videoType: String? = nil,
        tags: [String] = [],
        site: String = SiteProfile.pornShop.id,
        sourcePageURL: String? = nil,
        previewURL: String? = nil
    ) {
        self.id = id
        self.title = title
        self.cover = cover
        self.duration = duration
        self.views = views
        self.user = user
        self.vip = vip
        self.timeLine = timeLine
        self.videoType = videoType
        self.tags = tags
        self.site = site
        self.sourcePageURL = sourcePageURL
        self.previewURL = previewURL
    }

    var displayTitle: String { title.isEmpty ? "视频 \(id)" : title }
    var uploaderName: String { user?.isEmpty == false ? user! : "官方精选" }
    var metaLine: String {
        [uploaderName, views.map { "\($0) 次观看" }, timeLine]
            .compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " · ")
    }
}

struct Choice: Identifiable, Hashable {
    let key: String
    let label: String
    var id: String { key }
}

/// A first-party website shortcut that is deliberately kept separate from the
/// native catalog/playback adapters.  It opens the provider's normal website
/// without injecting scripts, extracting media URLs, or altering its access
/// controls.  Authentication and playback therefore remain entirely under the
/// provider's own page.
struct OfficialWebsite: Identifiable, Hashable {
    let id: String
    let label: String
    let address: URL

    static let all: [OfficialWebsite] = [
        OfficialWebsite(id: "avjb-official", label: "AVJB 官网访问", address: URL(string: "https://avjb.cc/")!),
        OfficialWebsite(id: "91rb-official", label: "91rb 官网访问", address: URL(string: "https://www.91rb.net/")!),
    ]
}

/// 以网站自己的播放器打开视频页。此模式不抽取、改写或猜测媒体地址，
/// 由站点的正常网页播放器处理 Cookie、验证与播放控制。
struct WebsitePlayback: Identifiable, Hashable {
    let id: String
    let title: String
    let address: URL
}

/// 由 API 型播放源直接支持的列表分组。公开网页型播放源保留各自解析出的
/// 浏览频道，二者在界面上以同一处“浏览”菜单呈现。
struct CatalogGroup: Identifiable, Hashable {
    let title: String
    let items: [Choice]
    var id: String { title }
}

struct SiteProfile: Identifiable, Hashable {
    let id: String
    let label: String
    let appName: String
    let pageOrigin: String
    let lines: [Choice]
    let catalogGroups: [CatalogGroup]

    static let pornShop = SiteProfile(
        id: "pornshop", label: "PornShop", appName: "pornshop.one",
        pageOrigin: "https://pornshop.one/", lines: [],
        catalogGroups: [
            CatalogGroup(title: "常用", items: [
                Choice(key: "hot", label: "国产自拍"), Choice(key: "recent", label: "最新"),
                Choice(key: "free", label: "免费试看"), Choice(key: "vip", label: "国产影片"),
                Choice(key: "high", label: "高清"),
            ]),
            CatalogGroup(title: "AV", items: [
                Choice(key: "japan", label: "中文字幕"), Choice(key: "av", label: "高清AV"),
                Choice(key: "t_high_wuma", label: "无码流出"),
            ]),
            CatalogGroup(title: "片商", items: [
                Choice(key: "bdsm0", label: "国产BDSM"), Choice(key: "c1", label: "麻豆视频"),
                Choice(key: "c2", label: "91制片厂"), Choice(key: "c3", label: "玩偶姐姐"),
                Choice(key: "c5", label: "糖心Vlog"), Choice(key: "cc", label: "成人头条"),
                Choice(key: "ci", label: "杏吧原创"), Choice(key: "c8", label: "皇家华人"),
                Choice(key: "c6", label: "天美传媒"), Choice(key: "ca", label: "精东影业"),
            ]),
            CatalogGroup(title: "更多", items: [
                Choice(key: "west", label: "欧美"), Choice(key: "cp", label: "动漫"),
                Choice(key: "pissvids", label: "欧美重口"), Choice(key: "kink", label: "Kink"),
                Choice(key: "xart", label: "欧美唯美"), Choice(key: "lesbian", label: "女同"),
            ]),
        ]
    )
    static let hsTV = SiteProfile(
        id: "hstv", label: "好色TV", appName: "hstv.fun",
        pageOrigin: "https://hstv.fun/",
        lines: [
            Choice(key: "default1", label: "免费"),
            Choice(key: "default2", label: "免费2"),
            Choice(key: "hd1", label: "高清1"),
            Choice(key: "hd2", label: "高清2"),
            Choice(key: "hd3", label: "高清3"),
        ],
        catalogGroups: [
            CatalogGroup(title: "首页", items: [
                Choice(key: "home_hot_8", label: "国产自拍"), Choice(key: "home_vip_8", label: "国产视频(VIP)"),
                Choice(key: "home_pissvids_8", label: "欧美(VIP)"), Choice(key: "home_banana_8", label: "汝工作室"),
                Choice(key: "home_swag_8", label: "台湾SWAG全集"), Choice(key: "home_torture_8", label: "重口系列"),
                Choice(key: "home_high_8", label: "站长推荐"),
            ]),
            CatalogGroup(title: "国产自拍", items: [
                Choice(key: "recent", label: "最近更新"), Choice(key: "hd", label: "高清视频"),
                Choice(key: "recent_hot", label: "最近加精"), Choice(key: "hot", label: "当前最热"),
                Choice(key: "91original", label: "91原创"), Choice(key: "10mins", label: "10分钟以上"),
                Choice(key: "20mins", label: "20分钟以上"), Choice(key: "month_discuss", label: "本月讨论"),
                Choice(key: "month_favs", label: "本月收藏"), Choice(key: "favs", label: "收藏最多"),
                Choice(key: "month_hot", label: "本月最热"), Choice(key: "last_month_hot", label: "上月最热"),
            ]),
            CatalogGroup(title: "国产视频", items: [
                Choice(key: "c0", label: "最热"), Choice(key: "c1", label: "麻豆视频"),
                Choice(key: "c2", label: "91制片厂"), Choice(key: "c3", label: "玩偶姐姐"),
                Choice(key: "c4", label: "小鸟酱专题"), Choice(key: "c5", label: "糖心Vlog"),
                Choice(key: "c6", label: "天美传媒"), Choice(key: "c7", label: "蜜桃传媒"),
                Choice(key: "c8", label: "皇家华人"), Choice(key: "c9", label: "星空传媒"),
                Choice(key: "ca", label: "精东影业"), Choice(key: "cb", label: "乐播传媒"),
                Choice(key: "cc", label: "成人头条"), Choice(key: "cd", label: "乌鸦传媒"),
                Choice(key: "ce", label: "兔子先生"), Choice(key: "cf", label: "PsychoPorn"),
                Choice(key: "cg", label: "葫芦影业"), Choice(key: "ci", label: "杏吧原创"),
                Choice(key: "cj", label: "mimi传媒"), Choice(key: "ck", label: "大象传媒"),
                Choice(key: "cl", label: "开心鬼传媒"), Choice(key: "cm", label: "鲸鱼传媒"),
                Choice(key: "swag", label: "台湾SWAG全集"),
            ]),
            CatalogGroup(title: "欧美", items: [
                Choice(key: "west", label: "欧美推荐"), Choice(key: "pissvids", label: "欧美重口"),
                Choice(key: "kink", label: "Kink精选"), Choice(key: "xart", label: "X-art精选"),
                Choice(key: "lesbian", label: "女同"),
            ]),
            CatalogGroup(title: "日本", items: [
                Choice(key: "japan", label: "日本AV"), Choice(key: "av", label: "高清AV"),
                Choice(key: "cp", label: "卡通动漫"),
            ]),
            CatalogGroup(title: "重口系列", items: [
                Choice(key: "gcsm", label: "国产SM"), Choice(key: "torture_all", label: "重口系列"),
                Choice(key: "torture_asian", label: "亚洲系列"), Choice(key: "torture_west", label: "欧美系列"),
                Choice(key: "torture_comic", label: "动漫专区"), Choice(key: "torture_other", label: "其他"),
            ]),
            CatalogGroup(title: "站长推荐", items: [
                Choice(key: "t_high_gaoqing", label: "高清AV"), Choice(key: "t_high_zhubo", label: "主播福利"),
                Choice(key: "t_high_wuma", label: "无码流出"), Choice(key: "t_high_zipai", label: "自拍偷拍"),
                Choice(key: "t_high_tanhua", label: "探花精选"), Choice(key: "t_high_yao", label: "人妖伪娘"),
                Choice(key: "t_high_lifan", label: "里番"),
            ]),
        ]
    )
    /// thePorny 与 PornShop / 好色TV 共用公开的 `/js` 目录协议，但使用自己的
    /// app 字段和三条站点播放器线路。分类对应 1.7.3 的站方侧栏，不包含个人收藏。
    static let thePorny = SiteProfile(
        id: "theporny", label: "thePorny", appName: "theporny.com",
        pageOrigin: "https://theporny.com/",
        lines: [
            Choice(key: "default2", label: "国内线路"),
            Choice(key: "hd1", label: "高速线路1"),
            Choice(key: "hd2", label: "高速线路2"),
        ],
        catalogGroups: [
            CatalogGroup(title: "视频分类", items: [
                Choice(key: "recent", label: "国产91大神"), Choice(key: "c0", label: "国产传媒全集"),
                Choice(key: "japan", label: "日本高清AV"), Choice(key: "banana", label: "汝工作室"),
                Choice(key: "swag", label: "台湾Swag全集"), Choice(key: "torture_all", label: "重口系列"),
                Choice(key: "gcsm", label: "国产SM[全集]"), Choice(key: "pissvids", label: "欧美重口 (pissvids)"),
                Choice(key: "c1", label: "麻豆视频"), Choice(key: "c2", label: "91制片厂"),
                Choice(key: "c3", label: "玩偶姐姐"), Choice(key: "c4", label: "小鸟酱专题"),
                Choice(key: "c5", label: "糖心Vlog"), Choice(key: "c6", label: "天美传媒"),
                Choice(key: "c7", label: "蜜桃传媒"), Choice(key: "c8", label: "皇家华人"),
                Choice(key: "c9", label: "星空传媒"), Choice(key: "ca", label: "精东影业"),
                Choice(key: "cc", label: "成人头条"), Choice(key: "cd", label: "乌鸦传媒"),
                Choice(key: "cl", label: "开心鬼传媒"),
            ])
        ]
    )
    /// 51视频与 PornShop / 好色TV / thePorny 使用同一套公开 `/js` 目录协议，
    /// 仅以站点自己的 app 字段、来源页和分类区分。因此可以复用现有的列表、
    /// 搜索、详情、播放、收藏与历史记录流程，而不需要额外的网页脚本或账号状态。
    static let p51 = SiteProfile(
        id: "51porn", label: "51视频", appName: "51porn.com",
        pageOrigin: "https://51porn.com/", lines: [],
        catalogGroups: [
            CatalogGroup(title: "导航", items: [
                Choice(key: "hot", label: "91Porn"), Choice(key: "c1", label: "麻豆视频"),
                Choice(key: "japan", label: "日本"), Choice(key: "west", label: "欧美"),
            ]),
            CatalogGroup(title: "片商", items: [
                Choice(key: "banana", label: "汝工作室"), Choice(key: "c2", label: "91制片厂"),
                Choice(key: "c3", label: "玩偶姐姐"), Choice(key: "c4", label: "小鸟酱专题"),
                Choice(key: "c5", label: "糖心Vlog"), Choice(key: "c6", label: "天美传媒"),
                Choice(key: "c7", label: "蜜桃传媒"), Choice(key: "c8", label: "皇家华人"),
                Choice(key: "c9", label: "星空传媒"), Choice(key: "ca", label: "精东影业"),
                Choice(key: "cc", label: "成人头条"), Choice(key: "cd", label: "乌鸦传媒"),
                Choice(key: "cl", label: "开心鬼传媒"), Choice(key: "cq", label: "BDSM"),
            ]),
            CatalogGroup(title: "欧美", items: [
                Choice(key: "pissvids", label: "欧美重口 (pissvids)"), Choice(key: "lesbian", label: "女同系列"),
                Choice(key: "xart", label: "欧美唯美"), Choice(key: "kink", label: "欧美重口"),
            ]),
        ]
    )
    /// 海角目录接入站点公开返回的帖子，并按上游顺序发现播放地址：
    /// 卡片预览 → 帖子通道 → 分片反推 → （登录后）跨帖 attachment 与视频中心；
    /// 密钥由播放桥接层按站点规则现场合成。
    static let haijiao = SiteProfile(
        id: "haijiao", label: "海角", appName: "haijiao.com",
        pageOrigin: "https://www.haijiao.com/", lines: [],
        catalogGroups: [
            CatalogGroup(title: "海角", items: [
                Choice(key: "hot", label: "热帖"), Choice(key: "latest", label: "最新"),
                Choice(key: "cream", label: "精华"), Choice(key: "original", label: "原创"),
                Choice(key: "news", label: "新闻"),
            ])
        ]
    )
    /// 探花（thdh.cc）：热榜与今日更新是单页，其余走 `/index.php/vod/show/` 分页。
    /// 分类编号与站点自己的筛选项一致。
    static let thdh = SiteProfile(
        id: "thdh", label: "探花", appName: "thdh.cc",
        pageOrigin: "https://www.thdh.cc/", lines: [],
        catalogGroups: [
            CatalogGroup(title: "推荐", items: [
                Choice(key: "hot", label: "热榜"), Choice(key: "new", label: "今日更新"),
            ]),
            CatalogGroup(title: "精品国产", items: [
                Choice(key: "34", label: "精品国产"), Choice(key: "50", label: "网曝黑料"),
                Choice(key: "45", label: "国产视频"), Choice(key: "39", label: "国产传媒"),
                Choice(key: "59", label: "国产主播"), Choice(key: "58", label: "网红头条"),
                Choice(key: "48", label: "抖阴视频"),
            ]),
            CatalogGroup(title: "精品日韩", items: [
                Choice(key: "35", label: "精品日韩"), Choice(key: "49", label: "女优明星"),
                Choice(key: "38", label: "中文字幕"), Choice(key: "43", label: "强奸乱伦"),
                Choice(key: "44", label: "制服诱惑"), Choice(key: "40", label: "日本有码"),
                Choice(key: "41", label: "日本无码"), Choice(key: "54", label: "SM调教"),
                Choice(key: "61", label: "VR视角"), Choice(key: "60", label: "韩国主播"),
            ]),
            CatalogGroup(title: "精品综合", items: [
                Choice(key: "36", label: "精品综合"), Choice(key: "42", label: "欧美无码"),
                Choice(key: "47", label: "明星换脸"), Choice(key: "53", label: "AV解说"),
                Choice(key: "46", label: "激情动漫"), Choice(key: "57", label: "女同性恋"),
                Choice(key: "56", label: "极品媚黑"), Choice(key: "51", label: "人妖系列"),
                Choice(key: "52", label: "伦理三级"),
            ]),
        ]
    )
    /// 抖音沙箱片库：`c` 前缀是分类编号，短视频单独走 `short`。
    static let douyin = SiteProfile(
        id: "douyin", label: "抖音", appName: "np1",
        pageOrigin: "https://ecsvnp1.cn1-hongkong.aliyuncs.com/", lines: [],
        catalogGroups: [
            CatalogGroup(title: "推荐", items: [
                Choice(key: "new", label: "最新"), Choice(key: "short", label: "短视频"),
            ]),
            CatalogGroup(title: "分类", items: [
                Choice(key: "c5", label: "推荐"), Choice(key: "c24", label: "变态重口"),
                Choice(key: "c6", label: "丰乳肥臀"), Choice(key: "c7", label: "家庭伦理"),
                Choice(key: "c27", label: "网红名人"), Choice(key: "c1", label: "角色扮演"),
                Choice(key: "c2", label: "主播探花"), Choice(key: "c10", label: "同人动漫"),
                Choice(key: "c11", label: "日韩欧美"), Choice(key: "c12", label: "国产大厂"),
                Choice(key: "c13", label: "成人三级"),
            ]),
        ]
    )
    /// JAVHD：列表页 POST 自身地址，播放走播放页线路给出的完整 MP4，
    /// 清晰度（1080p/720p/480p/240p）作为线路选项，不使用试看片段。
    static let javhd = SiteProfile(
        id: "javhd", label: "JAVHD", appName: "javhd.com",
        pageOrigin: "https://javhd.com/zh/", lines: [],
        catalogGroups: [
            CatalogGroup(title: "推荐", items: [
                Choice(key: "new", label: "最新"), Choice(key: "popular", label: "热门"),
                Choice(key: "top", label: "排行"),
            ]),
            CatalogGroup(title: "分类", items: [
                Choice(key: "creampie", label: "内射"), Choice(key: "big-tits", label: "巨乳"),
                Choice(key: "hardcore", label: "重口味"), Choice(key: "anal", label: "肛交"),
                Choice(key: "group-sex", label: "群交"), Choice(key: "blowjob", label: "口交"),
                Choice(key: "milf", label: "熟女"), Choice(key: "amateur", label: "业余"),
                Choice(key: "cumshot", label: "射精"), Choice(key: "pov", label: "第一人称"),
                Choice(key: "bikini", label: "比基尼"), Choice(key: "lingerie", label: "内衣"),
                Choice(key: "threesome", label: "三人行"), Choice(key: "squirting", label: "喷水"),
                Choice(key: "cosplay", label: "角色扮演"), Choice(key: "uncensored", label: "无码"),
            ]),
        ]
    )
    /// 糖心Vlog使用公开网页的服务端渲染目录，不依赖 Richy (1).txt 中的下载脚本。
    static let tangXin = SiteProfile(
        id: "tangxin", label: "糖心Vlog（视频页）", appName: "tangxinvlog.pro",
        pageOrigin: "https://tangxinvlog.pro/", lines: [], catalogGroups: []
    )
    /// Richy-6 对应的 rou.video 公开目录与播放页适配。原生客户端不加载其网页中的广告脚本。
    static let rouVideo = SiteProfile(
        id: "rouvideo", label: "肉视频（Richy-6）", appName: "rou.video",
        pageOrigin: "https://rou.video/", lines: [], catalogGroups: []
    )
    /// Richy8：仅使用 jiuse.tv 正常公开的视频页与其服务端输出的 HLS 地址。
    static let jiuse = SiteProfile(
        id: "jiuse", label: "九色（Richy8）", appName: "jiuse.tv",
        pageOrigin: "https://jiuse.tv/", lines: [], catalogGroups: []
    )
    /// Richy9：仅使用 18j.tv 正常公开的目录、搜索和播放页。
    static let eighteenJ = SiteProfile(
        id: "18j", label: "18J.TV（Richy9）", appName: "18j.tv",
        pageOrigin: "https://18j.tv/", lines: [], catalogGroups: []
    )
    /// Richy10：详情页公开加载的播放器配置要求初始 HLS 请求带 CDN 认证头。
    static let porna91 = SiteProfile(
        id: "91porna", label: "91porna（Richy10）", appName: "91porna.com",
        pageOrigin: "https://91porna.com/", lines: [], catalogGroups: []
    )
    /// Richy-17：懂色帝使用 MacCMS 服务端渲染的公开目录页与播放页。播放地址只取
    /// 播放页自身渲染给浏览器的播放器配置（`var player_aaaa`），不使用脚本里那条
    /// 从海报路径推导 CDN 目录的猜路径。
    static let dsdSE = SiteProfile(
        id: "dsd", label: "懂色帝（Richy-17）", appName: "dsd.com.se",
        pageOrigin: "https://www.dsd.com.se/", lines: [], catalogGroups: []
    )

    static let publicWebsiteIDs: Set<String> = [jiuse.id, eighteenJ.id, porna91.id, dsdSE.id]
    /// 站方没有公开搜索入口的网页型来源。界面改为引导用户走「浏览」频道，
    /// 而不是由客户端拼一个未经证实的搜索地址。
    static let searchUnavailableIDs: Set<String> = [tangXin.id, dsdSE.id]
    /// 有自己站内搜索、但播放方式与公开网页源不同的适配型来源。
    static let adapterSourceIDs: Set<String> = [thdh.id, douyin.id, javhd.id]
    static let all = [
        pornShop, hsTV, thePorny, p51, haijiao, thdh, douyin, javhd,
        tangXin, rouVideo, jiuse, eighteenJ, porna91, dsdSE,
    ]
}

struct TangXinArtist: Identifiable, Hashable {
    /// 站点内以编码后的 artist 路径作为稳定标识，例：/artists/%E9%A5%BC.../
    let path: String
    let name: String
    let avatar: String?
    var id: String { path }
}

enum TangXinFeed: Hashable {
    case home
    case videos
    case artist(TangXinArtist)

    var label: String {
        switch self {
        case .home: "首页最新"
        case .videos: "全部视频"
        case .artist(let artist): artist.name
        }
    }
}

struct TangXinCatalog {
    let page: ListPage
    let artists: [TangXinArtist]
}

/// A safe, same-site public channel URL discovered from the provider's own
/// homepage. It deliberately stores a relative path, never an external link.
struct PublicWebsiteFeed: Identifiable, Hashable {
    let path: String
    let label: String
    var id: String { path }
}

struct PublicWebsiteCatalog {
    let page: ListPage
    let feeds: [PublicWebsiteFeed]
}

struct ListPage {
    let items: [VideoItem]
    let page: Int
    let totalPage: Int
    let openEnded: Bool
}

struct Playable: Equatable {
    let id: String
    let title: String
    let playURL: URL
    let streamURLs: [URL]
    let cover: String?
    let duration: String?
    let activeHost: String
    let lineKey: String
    let lines: [Choice]
    let pageOrigin: String
    let site: String
    /// Some public video gateways issue one-time media URLs. Keep the original
    /// page so the native cache player can obtain a fresh public media URL if
    /// the page was opened a few seconds earlier.
    let sourcePageURL: String?
    /// 站点公开播放器本身要求附带的媒体请求头。只由本机 HLS 桥接用于对应的
    /// m3u8 清单请求，不作为用户身份、会话或登录信息保存。
    let mediaHeaders: [String: String]
    /// 这份清单的 `#EXT-X-KEY` 需要现场还原时携带的方案（海角合成、抖音 RSA 解包）。
    /// 密钥请求由 AVFoundation 发起，桥接层按方案转换为真正的 16 字节 AES 密钥。
    let keyPlan: HLSKeyPlan?

    init(
        id: String,
        title: String,
        playURL: URL,
        streamURLs: [URL],
        cover: String?,
        duration: String?,
        activeHost: String,
        lineKey: String,
        lines: [Choice],
        pageOrigin: String,
        site: String,
        sourcePageURL: String?,
        mediaHeaders: [String: String] = [:],
        keyPlan: HLSKeyPlan? = nil
    ) {
        self.id = id
        self.title = title
        self.playURL = playURL
        self.streamURLs = streamURLs
        self.cover = cover
        self.duration = duration
        self.activeHost = activeHost
        self.lineKey = lineKey
        self.lines = lines
        self.pageOrigin = pageOrigin
        self.site = site
        self.sourcePageURL = sourcePageURL
        self.mediaHeaders = mediaHeaders
        self.keyPlan = keyPlan
    }
}

struct PublicWebsitePlayable {
    let title: String
    let streamURL: URL
    let mediaHeaders: [String: String]

    init(title: String, streamURL: URL, mediaHeaders: [String: String] = [:]) {
        self.title = title
        self.streamURL = streamURL
        self.mediaHeaders = mediaHeaders
    }
}

enum DownloadStatus: String, Codable {
    case queued, running, paused, completed, failed
}

struct DownloadTask: Codable, Identifiable, Hashable {
    let id: String
    var item: VideoItem
    var remoteURL: String
    var localURL: String?
    var status: DownloadStatus
    var done: Int
    var total: Int
    var bytes: Int64
    var error: String?
    var updatedAt: Date
    /// 站点公开播放器要求附带的媒体请求头（现在只有 91porna 的 CDN 清单校验头）。
    /// 必须随任务一起持久化：下载可能在应用重启后才继续，恢复时已拿不到 Playable。
    /// 可选值让旧版本已保存的任务仍能解码。
    var mediaHeaders: [String: String]? = nil
    /// 密钥方案的短标识（海角合成 / 抖音 RSA 解包）。离线任务重启后同样需要它，
    /// 否则恢复的分片会写成加密态或错误的密钥字节。
    var keyPlanRaw: String? = nil

    var percent: Int { total == 0 ? 0 : min(100, max(0, done * 100 / total)) }
    var progressLabel: String {
        switch status {
        case .queued: "排队中"
        case .running: total == 0 ? "正在解析播放列表…" : "下载中 \(percent)%"
        case .paused: total == 0 ? "已暂停" : "已暂停 \(percent)%"
        case .completed: "已完成 · 可离线播放"
        case .failed: error?.isEmpty == false ? error! : "下载失败"
        }
    }
}

enum BrowseMode: String, CaseIterable, Identifiable {
    case home, search, library
    var id: String { rawValue }
    var title: String {
        switch self {
        case .home: "首页"
        case .search: "搜索"
        case .library: "片库"
        }
    }
}
