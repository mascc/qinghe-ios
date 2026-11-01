# 青禾学堂播放器（Android / iOS 旁加载）

对照香蕉播放器的工程结构，接入 pornshop.one 的 H5 接口。

## 功能

- 打开后是「青禾学堂」。在「课程」页输入课程码 `886` 进入播放器。播放列表按返回键回到学堂。杀掉进程后需要重新输入。封面停留期间不会请求播放接口。
- 首页：站点顶栏和首页「更多」里的全部分类，滑到底继续加载
- 搜索：关键词、分类、时间、播放量、时长、最新/最热
- 播放：向 `/js` 取详情，解密后用 ExoPlayer 播 HLS。在线分片有磁盘缓存
- 下载：播放页或封面可以下载整片，片库「下载」里暂停、继续、删除，完成后断网播放
- 线路失败自动换下一台 CDN

## iOS

原工程是 Kotlin / Jetpack Compose 和 Android Media3 的单平台实现，不能由 APK 直接转换成 IPA。现已新增独立的 SwiftUI / AVFoundation 实现，迁移目录、搜索、线路切换、收藏/历史、OpenSSL `Salted__` AES-CBC 协议解密、HLS 下载与本地播放；iOS 不包含 ExoPlayer 或 Android 前台下载服务。

与上游 `源码v1.9.2` 的源站对齐情况：除 PornShop、好色 TV、thePorny、51视频、海角之外，本次补齐了**探花**、
**抖音**（含 `encryption.key` 的 RSA-OAEP 解包）与 **JAVHD**（完整 MP4 + 清晰度线路），并把海角从「公开预览」升级为
完整地址发现（帖子通道 / 分片反推 / 跨帖 attachment / 视频中心）与现场密钥合成；iOS 原有的糖心Vlog、rou.video、
九色、18J、91porna、懂色帝全部保留。逐项对照与仍未移植的上游能力见 [`ios/UPSTREAM-PARITY.md`](ios/UPSTREAM-PARITY.md)。

iOS 使用系统 AVFoundation 直接播放 HLS；下载在应用前台执行，返回后台后系统可能暂停，重新进入应用可继续未完成任务。最低支持 iOS 15.1。无签名 IPA 仅适用于自行签名后安装，或适用的越狱环境。需要现场还原 HLS 密钥的源（海角、抖音）走回环 HTTP 桥接，桥接只监听 `127.0.0.1`。

## 构建

需要 JDK 17+，以及本机 Android SDK（默认复用 `players/pektino/android-sdk`）。

```powershell
cd android
powershell -ExecutionPolicy Bypass -File .\build_apk.ps1
```

产物：

- `app/build/outputs/apk/release/app-release.apk`
- `release/青禾学堂-1.1.apk`

在 macOS + Xcode 上构建无签名 IPA：

```bash
./scripts/build_ios.sh
```

产物：

- `release/青禾学堂-1.9.4-ios-unsigned.ipa`
- `release/SHA256SUMS.txt`

安装前在手机上允许未知来源。自签证书，只给自己用。手机需要能访问 `pornshop.one` 的 API 线路和封面/视频 CDN。
