# iOS 与上游 v1.9.2 的源站/播放对齐说明

本文件记录本次对齐的事实依据与边界：iOS 端（`青禾学堂-1.9.4-source`）以 `源码v1.9.2`（Android/Kotlin）为上游，
只搬「源站能力」与「播放方式」，不搬 UI 结构；iOS 独有的源站全部保留。

## 一、源站对照

| 上游 v1.9.2 | iOS 对齐前 | 本次处理 | 播放方式要点 |
| --- | --- | --- | --- |
| PornShop | 已有 | 不动 | `/js` 信封 + 口令 AES，HLS |
| 好色 TV | 已有 | 不动 | 五条线路 `?server=` |
| thePorny | 已有 | 不动 | 三条线路 |
| 51视频 | 已有 | 不动 | 同 `/js` 协议 |
| 海角 | 仅「公开预览」 | **重写为完整版** | 帖子预览 → 帖子通道 → 分片反推 → 跨帖 attachment → 视频中心；AES-128 密钥现场合成 |
| 探花（thdh.cc） | 无 | **新增** | 详情页海报同目录推导 `index.m3u8`（会员播放页不参与） |
| 抖音 | 无 | **新增** | 路径/正文 AES-CBC、线路 IP + Host、访客/抽奖/金币会话、`encryption.key` RSA-OAEP 解包 |
| JAVHD | 无 | **新增** | 视频页 `content-id` → `player_api` → 完整 MP4，清晰度即线路 |
| 糖心Vlog | iOS 独有 | **保留** | 页面内联播放器地址 |
| 肉视频 rou.video | iOS 独有 | **保留** | PNG `roUd` 传输解包 + 本地桥接 |
| 九色 jiuse / 18J / 91porna / 懂色帝 | iOS 独有 | **保留** | 各自公开页解析（91porna 带 CDN 清单头） |

## 二、新增/重写文件

| 文件 | 对应上游 | 说明 |
| --- | --- | --- |
| `JavhdSource.swift` | `JavhdHtml.kt` + `JavhdCatalog.kt` | 目录/搜索/播放解析 + `actor JavhdSource` |
| `ThdhSource.swift` | `ThdhHtml.kt` + `ThdhCatalog.kt` | 自写只读 HTML 元素读取器（不执行脚本）+ 地址推导 |
| `DouyinSource.swift` | `DouyinCatalog.kt` | 加密协议、会话、抽奖、购买、详情 |
| `DouyinMediaKey.swift` | `DouyinMediaKeys.kt` | PKCS#8 → PKCS#1 → `SecKeyCreateDecryptedData`（OAEP-SHA256） |
| `MediaKeySupport.swift` | `HaijiaoKeys.kt` + `HaijiaoKeyClient.kt` 的密钥部分 | `HLSKeyPlan`、清单解析、`jquery_key` 合成、TS 同步字节校验 |
| `HaijiaoSource.swift` | `HaijiaoCatalog.kt` + `HaijiaoPlaybackResolver.kt` + `HaijiaoCodec.kt` | 账号、目录、完整地址发现、密钥版本 |
| `RouHLSHTTPProxy.swift` | `HaijiaoKeyClient` + `DouyinMediaKeyInterceptor` 的播放侧职责 | 桥接层新增 `/key` 端点与 `assetHeaders`，保留原有 PNG 解包与 TARGETDURATION 修正 |
| `DownloadManager.swift` | `HlsLocalDownloader` 的密钥侧职责 | 离线任务持久化 `keyPlanRaw`，落盘前先还原密钥 |

`Models.swift` 增加 `thdh` / `douyin` / `javhd` 三个 `SiteProfile` 与分类分组，并给 `Playable` 增加 `keyPlan`、
给 `DownloadTask` 增加 `keyPlanRaw`；`ContentView.swift` 增加三源的分派、海角账号面板，以及按源决定是否走本地桥接。
`project.pbxproj` 已把 5 个新文件加入 group 与 Sources。

## 三、播放方式差异与 iOS 的落法

1. **密钥归属**：Android 用 OkHttp 拦截器统一改写密钥响应；iOS 的 AVFoundation 自己取密钥，所以在回环 HTTP 桥接里
   增加 `/key` 端点：清单改写时一并登记 `IV` 与作用域首个分片，密钥请求到达时按方案还原成 16 字节裸密钥。
2. **海角密钥**：候选地址顺序 `原地址 → .keyv{kv} → .key{kv} → .keyv`，首个分片取 384 字节做校验；
   原样不合格时用同目录 `.jpg` 做 `key[i] xor jpg[i % n]` 合成，校验条件是解出后第 0/188 字节均为 `0x47`。
3. **抖音密钥**：`encryption.key` 是 256 字节 RSA 块，必须整块读取（不能带 Range），解包失败才换第二把私钥。
4. **JAVHD 的 `mimeType`**：iOS `Playable` 没有该字段，清晰度差异只体现在 `lines` 与所选地址上；直链 MP4 用
   `AVURLAsset` + 站点 Referer 播放，不走桥接（避免整段 MP4 被回环代理重复拉取）。
5. **探花与公开网页源**：明文 HLS 但分片要求站点头，统一走桥接；桥接对分片只做透传并补 `Referer`/`Origin`。
6. **抖音线路**：五条 `ecsvnp1.cnN-hongkong.aliyuncs.com` 走 IP 直连 + `Host` 头，`URLSession` 用
   `didReceive challenge` 放行与域名不匹配的证书，并禁止重定向跟随。

## 四、仍未对齐的上游能力（下一步）

- 聚合搜索：上游 `AggregateSearchBook` 跨站并发搜索与逐站重试；iOS 目前仍只在当前平台内搜索。
- 下载栈：上游 `HlsElementary` / `Mp4Composer` / `HlsResume` / `DownloadSchedule` 提供 fMP4 容器重建、
  MP4 导出、断点续传与任务调度；iOS 只有顺序下载 + 完成即本地播放。
- 诊断与验收：上游 `DiagnosticsLog`、`acceptance` 仪器化用例；iOS 无对应测试工程。
- 短视频信息流：上游 `ShortVideoFeedScreen` 竖屏翻页；iOS 仅抖音目录列表。

## 五、自检

`scripts/check_swift_sources.py`（本次新增）在没有 Swift 编译器的机器上做机械检查：剥离注释与字符串后配平
`(){}[]`、扫描 `try!` / `fatalError` / `URL(string:)!`、核对 `类型名.` 形式引用是否在本工程声明。
Xcode 构建必须在 macOS 上执行：`./scripts/build_ios.sh`。
