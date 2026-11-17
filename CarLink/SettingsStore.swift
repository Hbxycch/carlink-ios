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
    /// 外观：跟随系统（默认）/ 浅色 / 深色
    @AppStorage("appAppearance") var appearance: AppAppearance = .auto

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
