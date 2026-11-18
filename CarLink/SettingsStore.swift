import Foundation
import SwiftUI
import Network

// MARK: - 外观主题（默认跟随系统：深浅色自动切换）

enum AppAppearance: String, CaseIterable, Identifiable {
    case auto
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "跟随系统"
        case .light: return "浅色"
        case .dark: return "深色"
        }
    }

    var scheme: ColorScheme? {
        switch self {
        case .auto: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}

// MARK: - 监控画面来源

enum MonitorSource: String, CaseIterable, Identifiable {
    /// 优先 easyNVR HLS，起播失败逐路降级到车机快照流
    case auto
    case hls
    case snapshot

    var id: String { rawValue }

    var title: String {
        switch self {
        case .auto: return "自动"
        case .hls: return "easyNVR HLS"
        case .snapshot: return "车机快照流"
        }
    }

    var shortTitle: String {
        switch self {
        case .auto: return "自动"
        case .hls: return "HLS"
        case .snapshot: return "快照"
        }
    }

    var detail: String {
        switch self {
        case .auto: return "优先 HLS，连不上时该路自动改用快照流"
        case .hls: return "连续视频、画质好，需要手机能访问 easyNVR"
        case .snapshot: return "车机每秒解码一帧，只要连上车机就能看"
        }
    }
}

/// 全局设置（@AppStorage 持久化）
@MainActor
final class SettingsStore: ObservableObject {
    /// 仅 WiFi 下载（避免蜂窝流量）
    @AppStorage("wifiOnlyDownload") var wifiOnlyDownload = true
    /// 下载默认存相册（关闭则存「文件」App › CarLink）
    @AppStorage("saveToPhotos") var saveToPhotos = true
    /// 相册页默认视图（false=缩略图 2 列，true=列表）
    @AppStorage("listMode") var listMode = false
    /// 启动 / 回前台时自动连接最近一次使用的车机
    @AppStorage("autoConnect") var autoConnect = true
    /// 视频播完自动连播下一段（按时间顺序）
    @AppStorage("autoPlayNext") var autoPlayNext = true
    /// 播放时暂停下载任务（车机弱、带宽共享，边下边看会卡）
    @AppStorage("pauseDownloadDuringPlayback") var pauseDownloadDuringPlayback = true
    /// 同时下载任务数（1~4，默认 2）；车机弱时调小更稳
    @AppStorage("maxConcurrentDownloads") var maxConcurrentDownloads = 2
    /// 外观：跟随系统（默认）/ 浅色 / 深色
    @AppStorage("appAppearance") var appearance: AppAppearance = .auto

    // MARK: 车机监控
    /// 画面来源：自动 / easyNVR HLS / 车机快照流
    @AppStorage("monitorSource") var monitorSource: MonitorSource = .auto
    /// easyNVR 服务地址，如 http://192.168.10.100:10800（留空则自动模式只用快照流）
    @AppStorage("monitorNvrBase") var monitorNvrBase = ""
    /// HLS 地址模板：{base} = 上面的服务地址，{key} = 推流流名，{host} = 车机推流的 NVR 主机
    @AppStorage("monitorHlsTemplate") var monitorHlsTemplate = "{base}/hls/{key}/{key}_live.m3u8"
    /// 快照流刷新频率（车机端上限约 1fps）
    @AppStorage("monitorSnapshotFps") var monitorSnapshotFps = 1

    /// 网络类型监测（供下载调度订阅）
    @Published var isWiFi = true
    private let monitor = NWPathMonitor()

    func startMonitoring() {
        monitor.pathUpdateHandler = { [weak self] path in
            let wifi = path.usesInterfaceType(.wifi) || path.usesInterfaceType(.wiredEthernet)
            Task { @MainActor in
                self?.isWiFi = wifi
            }
        }
        monitor.start(queue: DispatchQueue(label: "carlink.pathmonitor"))
    }

    var canDownload: Bool {
        !wifiOnlyDownload || isWiFi
    }
}
