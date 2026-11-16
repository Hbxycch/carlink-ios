# CarLink 车机互传 · iOS 客户端

车机文件互传 App 的 iPhone 客户端。与车机端 Android App（`com.zood.carlink`，建议 **v1.1.9+**）配合使用：

- 自动发现（mDNS `_carlink._tcp`）/ 扫码 / 手动 IP 三种方式连接车机
- 浏览与下载车机截图、行车记录仪视频（循环 / 抓拍 / 锁影分类）
- 视频边下边播（VLC 内核，直接播 .ts）、±10 秒、五档倍速（0.5×/1.0×/1.5×/2.0×/3.0×）、前/后/自由三路互切
- 下载时车机端自动转存 .mp4（画质不变），存入系统相册「CarLink 车机互传」相簿；坏文件自动回退保存原始 .ts
- 已下载文件绿色 ✓ 标识，防止重复下载；支持批量下载、断点续传、暂停/取消/重试
- 手机照片/视频/文件分片上传到车机
- 连接质量：2.4G/5G 频段、信号强度、链路测速

## 功能地图（四 Tab）

| Tab | 内容 |
|---|---|
| 🚗 车机 | 连接页（发现/记忆/手动/扫码）、主页（设备/WiFi 频段/流量/快捷入口）、测速 |
| 📁 文件 | 截图 / 本地文件（循环·抓拍·锁影）/ 记录仪文件（循环·抓拍·锁影·下载中） |
| ⇄ 传输 | 上传（相册/文件 App）、下载队列管理 |
| ⚙️ 设置 | 连接管理、保存位置、仅 WiFi 下载、版本信息 |

## 构建（GitHub Actions，自动）

推送到本仓库即自动触发 `.github/workflows/build.yml`：

1. macOS Runner 安装 `xcodegen` 并由 `project.yml` 生成 Xcode 工程
2. CocoaPods 拉取 MobileVLCKit
3. `xcodebuild` Release 构建出**未签名 IPA**
4. 产物挂在 Actions Artifacts（`CarLink-unsigned-ipa`）；打 `v*` tag 时同时创建 Release

本地构建（需 Mac）：

```bash
brew install xcodegen
xcodegen generate
pod install
open CarLink.xcworkspace
```

## 安装到 iPhone（Sideloadly 自签，无需 Mac）

1. 从 GitHub Actions 的 Artifacts 下载 `CarLink-unsigned-ipa`（打 tag 时从 Releases 下载）
2. 电脑安装 [Sideloadly](https://sideloadly.io/)（Windows 需同时装 iTunes 或 Apple 设备驱动）
3. iPhone USB 连电脑，Sideloadly 里选择 IPA，输入 **免费 Apple ID**
4. 点 Start 完成安装；iPhone 上 设置 → 通用 → VPN与设备管理 → 信任该开发者
5. 首次启动按提示允许：本地网络、相册、相机权限

**免费账号限制**：最多 3 个自签 App、证书 **7 天过期**需重签（Sideloadly 重装约 2 分钟，App 数据不受影响）。日后想免重签可升级 TestFlight（$99/年开发者账号）。

## 隐私权限说明

| 权限 | 用途 |
|---|---|
| 本地网络 + Bonjour | 自动发现车机（`_carlink._tcp`） |
| 相机 | 扫车机二维码 |
| 相册（添加） | 下载的截图/视频存入「CarLink 车机互传」相簿 |
| 相册（读取） | 选择照片/视频上传到车机 |

## 技术要点

- **播放内核**：流式预览 MobileVLCKit（.ts 直播）；本地回看 AVPlayer（mp4）——混合策略
- **下载转存**：`/api/download?path=…&format=mp4` 由车机端 MediaExtractor/MediaMuxer 转封装（不转码）；响应头 `X-CarLink-Format: fallback-ts` 表示回退原始 .ts
- **防重复下载**：本地库按「源路径 + 源文件大小」匹配车机列表项
- **上传**：三段式（init → 2MB 分片 PUT → complete），对应车机端 `/api/upload/*`
- **ATS**：Info.plist 开启 `NSAllowsLocalNetworking` 允许 http 访问局域网车机

## 对接的车机端接口（v1.1.9）

```
GET  /api/info                        设备名/版本/IP/WiFi 频段信号/计数
GET  /api/files?type=screenshot       截图列表
GET  /api/files?type=dashcam&category=loop|snapshot|locked
GET  /api/download?path=…[&format=mp4]  下载/流式播放（支持 Range）
GET  /api/status                      实时流量/客户端
POST /api/upload/init                 上传初始化 {name,size}
PUT  /api/upload?id=…&offset=…        分片上传（raw body）
POST /api/upload/{id}/complete        完成上传
```

## 目录结构

```
CarLink-iOS/
├── project.yml                  # XcodeGen 工程定义（构建时生成 .xcodeproj）
├── Podfile                      # MobileVLCKit
├── .github/workflows/build.yml  # CI：构建未签名 IPA
└── CarLink/
    ├── Info.plist
    ├── CarLinkApp.swift         # 入口 + 四 Tab
    ├── Models.swift             # 数据模型（对应车机端 JSON）
    ├── APIClient.swift          # HTTP 接口封装
    ├── Bonjour.swift            # mDNS 发现
    ├── ConnectionStore.swift    # 连接管理/保活
    ├── DownloadManager.swift    # 下载队列（断点续传/暂停恢复）
    ├── UploadManager.swift      # 分片上传
    ├── LibraryStore.swift       # 本地库（防重复下载匹配）
    ├── PhotoSaver.swift         # 相册相簿操作
    ├── SettingsStore.swift      # 设置（@AppStorage）
    ├── Formatting.swift         # 格式化/摄像头角标
    ├── CarTabView.swift         # 车机主页
    ├── ConnectView.swift        # 连接页
    ├── QRScannerView.swift      # 扫码
    ├── SpeedTestView.swift      # 测速
    ├── FilesTabView.swift       # 文件 Tab 顶层路由
    ├── RemoteBrowserView.swift  # 远端相册（截图+记录仪三分类）
    ├── LocalAlbumView.swift     # 本地文件页
    ├── DownloadsListView.swift  # 下载中
    ├── DatePickerSheet.swift    # 日期选择器（蓝点=有文件）
    ├── PlayerView.swift         # VLC 播放页
    ├── TransferTabView.swift    # 传输（上传+队列）
    └── SettingsView.swift       # 设置
```
