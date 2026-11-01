package com.pornshop.player.data

import java.util.Locale

data class VideoItem(
    val id: String,
    val title: String,
    val cover: String?,
    val duration: String?,
    val views: String?,
    val user: String?,
    val vip: Boolean,
    val timeLine: String?,
    val videoType: String?,
    val tags: List<String> = emptyList(),
    val site: String = Sites.PORNSHOP,
) {
    val displayTitle: String
        get() = title.ifBlank { "视频 $id" }

    val formattedViews: String?
        get() {
            val raw = views?.trim()?.takeIf { it.isNotEmpty() } ?: return null
            val num = raw.toLongOrNull() ?: return "$raw 次观看"
            return when {
                num >= 100_000_000L -> String.format(Locale.US, "%.1f 亿次观看", num / 100_000_000.0)
                num >= 10_000L -> String.format(Locale.US, "%.1f 万次观看", num / 10_000.0)
                else -> "$num 次观看"
            }
        }

    val uploaderName: String
        get() = user?.takeIf { it.isNotBlank() } ?: "官方精选"

    val metaLine: String
        get() = listOfNotNull(
            uploaderName,
            formattedViews,
            timeLine?.takeIf { it.isNotBlank() },
        ).joinToString(" · ")
}

data class Playable(
    val id: String,
    val title: String,
    val playUrl: String,
    val streamUrls: List<String> = listOf(playUrl),
    val cover: String? = null,
    val duration: String? = null,
    val user: String? = null,
    val views: String? = null,
    val timeLine: String? = null,
    val tags: List<String> = emptyList(),
    val activeHost: String = "",
    val lineKey: String = "",
    val lines: List<Choice> = emptyList(),
    val pageOrigin: String = "https://pornshop.one/",
    val site: String = Sites.PORNSHOP,
)

data class Choice(
    val key: String,
    val label: String,
)

/**
 * Direct links to the providers' regular websites.  These do not participate
 * in the native source adapters: the app does not inject JavaScript, derive
 * media URLs, alter requests, or bypass any website access control.
 */
data class OfficialWebsite(
    val id: String,
    val label: String,
    val url: String,
)

object OfficialWebsites {
    val all: List<OfficialWebsite> = listOf(
        OfficialWebsite("avjb-official", "AVJB 官网访问", "https://avjb.cc/"),
        OfficialWebsite("91rb-official", "91rb 官网访问", "https://www.91rb.net/"),
    )
}

/**
 * 同一组 `/js` 线路，用 app 字段区分片库。
 * 好色 TV 的播放线路要带 `?server=`，脚本里的免费 / 高清对应这些 key。
 */
object Sites {
    const val PORNSHOP = "pornshop"
    const val HSTV = "hstv"

    data class Profile(
        val id: String,
        val label: String,
        val appName: String,
        val pageOrigin: String,
        val lines: List<Choice>,
    )

    val all: List<Profile> = listOf(
        Profile(
            id = PORNSHOP,
            label = "PornShop",
            appName = "pornshop.one",
            pageOrigin = "https://pornshop.one/",
            lines = emptyList(),
        ),
        Profile(
            id = HSTV,
            label = "好色TV",
            appName = "hstv.fun",
            pageOrigin = "https://hstv.fun/",
            lines = listOf(
                Choice("default1", "免费"),
                Choice("default2", "免费2"),
                Choice("hd1", "高清1"),
                Choice("hd2", "高清2"),
                Choice("hd3", "高清3"),
            ),
        ),
    )

    fun byId(id: String?): Profile = all.firstOrNull { it.id == id } ?: all.first()

    fun other(id: String): Profile = all.first { it.id != byId(id).id }
}

data class ListGroup(
    val title: String,
    val items: List<Choice>,
)

data class ListPage(
    val items: List<VideoItem>,
    val page: Int,
    val totalPage: Int,
    val total: Int,
    val openEnded: Boolean = false,
)

object Catalog {
    const val PAGE_SIZE = 24

    /** 好色 TV 首页区块接口每页 8 条，类型名以 home_ 开头、_8 结尾。 */
    fun pageSizeFor(type: String): Int =
        if (type.startsWith("home_") && type.endsWith("_8")) 8 else PAGE_SIZE

    /** 首屏只露出这两项，其余从「全部分类」进入。 */
    val shortcutTypes = listOf("hot", "recent")

    /** pornshop.one 顶栏分类，加上首页「更多」和仍可用的旧列表。 */
    val listGroups = listOf(
        ListGroup(
            "常用",
            listOf(
                Choice("hot", "国产自拍"),
                Choice("recent", "最新"),
                Choice("free", "免费试看"),
                Choice("vip", "国产影片"),
                Choice("high", "高清"),
            ),
        ),
        ListGroup(
            "AV",
            listOf(
                Choice("japan", "中文字幕"),
                Choice("av", "高清AV"),
                Choice("t_high_wuma", "无码流出"),
            ),
        ),
        ListGroup(
            "片商",
            listOf(
                Choice("bdsm0", "国产BDSM"),
                Choice("c1", "麻豆视频"),
                Choice("c2", "91制片厂"),
                Choice("c3", "玩偶姐姐"),
                Choice("c5", "糖心Vlog"),
                Choice("cc", "成人头条"),
                Choice("ci", "杏吧原创"),
                Choice("c8", "皇家华人"),
                Choice("c6", "天美传媒"),
                Choice("ca", "精东影业"),
            ),
        ),
        ListGroup(
            "更多",
            listOf(
                Choice("west", "欧美"),
                Choice("cp", "动漫"),
                Choice("pissvids", "欧美重口"),
                Choice("kink", "Kink"),
                Choice("xart", "欧美唯美"),
                Choice("lesbian", "女同"),
            ),
        ),
    )

    val listTypes = listGroups.flatMap { it.items }

    /**
     * hstv.fun 首页模块里的分类。
     * 「首页」是七个区块（每块 8 条）；其余组是区块下面的标签，type 与网站一致。
     */
    val hstvShortcutTypes = listOf("home_hot_8", "recent")

    val hstvListGroups = listOf(
        ListGroup(
            "首页",
            listOf(
                Choice("home_hot_8", "国产自拍"),
                Choice("home_vip_8", "国产视频(VIP)"),
                Choice("home_pissvids_8", "欧美(VIP)"),
                Choice("home_banana_8", "汝工作室"),
                Choice("home_swag_8", "台湾SWAG全集"),
                Choice("home_torture_8", "重口系列"),
                Choice("home_high_8", "站长推荐"),
            ),
        ),
        ListGroup(
            "国产自拍",
            listOf(
                Choice("recent", "最近更新"),
                Choice("hd", "高清视频"),
                Choice("recent_hot", "最近加精"),
                Choice("hot", "当前最热"),
                Choice("91original", "91原创"),
                Choice("10mins", "10分钟以上"),
                Choice("20mins", "20分钟以上"),
                Choice("month_discuss", "本月讨论"),
                Choice("month_favs", "本月收藏"),
                Choice("favs", "收藏最多"),
                Choice("month_hot", "本月最热"),
                Choice("last_month_hot", "上月最热"),
            ),
        ),
        ListGroup(
            "国产视频",
            listOf(
                Choice("c0", "最热"),
                Choice("c1", "麻豆视频"),
                Choice("c2", "91制片厂"),
                Choice("c3", "玩偶姐姐"),
                Choice("c4", "小鸟酱专题"),
                Choice("c5", "糖心Vlog"),
                Choice("c6", "天美传媒"),
                Choice("c7", "蜜桃传媒"),
                Choice("c8", "皇家华人"),
                Choice("c9", "星空传媒"),
                Choice("ca", "精东影业"),
                Choice("cb", "乐播传媒"),
                Choice("cc", "成人头条"),
                Choice("cd", "乌鸦传媒"),
                Choice("ce", "兔子先生"),
                Choice("cf", "PsychoPorn"),
                Choice("cg", "葫芦影业"),
                Choice("ci", "杏吧原创"),
                Choice("cj", "mimi传媒"),
                Choice("ck", "大象传媒"),
                Choice("cl", "开心鬼传媒"),
                Choice("cm", "鲸鱼传媒"),
                Choice("swag", "台湾SWAG全集"),
            ),
        ),
        ListGroup(
            "欧美",
            listOf(
                Choice("west", "欧美推荐"),
                Choice("pissvids", "欧美重口"),
                Choice("kink", "Kink精选"),
                Choice("xart", "X-art精选"),
                Choice("lesbian", "女同"),
            ),
        ),
        ListGroup(
            "日本",
            listOf(
                Choice("japan", "日本AV"),
                Choice("av", "高清AV"),
                Choice("cp", "卡通动漫"),
            ),
        ),
        ListGroup(
            "重口系列",
            listOf(
                Choice("gcsm", "国产SM"),
                Choice("torture_all", "重口系列"),
                Choice("torture_asian", "亚洲系列"),
                Choice("torture_west", "欧美系列"),
                Choice("torture_comic", "动漫专区"),
                Choice("torture_other", "其他"),
            ),
        ),
        ListGroup(
            "站长推荐",
            listOf(
                Choice("t_high_gaoqing", "高清AV"),
                Choice("t_high_zhubo", "主播福利"),
                Choice("t_high_wuma", "无码流出"),
                Choice("t_high_zipai", "自拍偷拍"),
                Choice("t_high_tanhua", "探花精选"),
                Choice("t_high_yao", "人妖伪娘"),
                Choice("t_high_lifan", "里番"),
            ),
        ),
    )

    fun groupsFor(siteId: String): List<ListGroup> =
        if (siteId == Sites.HSTV) hstvListGroups else listGroups

    fun shortcutsFor(siteId: String): List<String> =
        if (siteId == Sites.HSTV) hstvShortcutTypes else shortcutTypes

    fun typesFor(siteId: String): List<Choice> = groupsFor(siteId).flatMap { it.items }

    val categories = listOf(
        Choice("all", "全部分类"),
        Choice("91", "国产91"),
        Choice("taiwan", "台湾传媒"),
        Choice("japan", "日本"),
        Choice("eu", "欧美"),
    )

    val times = listOf(
        Choice("all", "全部时间"),
        Choice("7", "1 周内"),
        Choice("14", "2 周内"),
        Choice("30", "1 个月内"),
        Choice("90", "3 个月内"),
        Choice("183", "半年内"),
        Choice("365", "1 年内"),
    )

    val viewFilters = listOf(
        Choice("all", "全部播放"),
        Choice("1000", "> 1000"),
        Choice("5000", "> 5000"),
        Choice("10000", "> 1 万"),
        Choice("50000", "> 5 万"),
        Choice("100000", "> 10 万"),
    )

    val durations = listOf(
        Choice("all", "全部时长"),
        Choice("5", "> 5 分钟"),
        Choice("10", "> 10 分钟"),
        Choice("30", "> 30 分钟"),
        Choice("60", "> 60 分钟"),
    )

    val sorts = listOf(
        Choice("time", "最新"),
        Choice("views", "最热"),
    )

}
