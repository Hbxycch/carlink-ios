import Foundation
import SwiftUI
import Network

/// 全局设置（@AppStorage 持久化）
@MainActor
final class SettingsStore: ObservableObject {
    /// 仅 WiFi 下载（避免蜂窝流量）
    @AppStorage("wifiOnlyDownload") var wifiOnlyDownload = true
    /// 下载默认存相册（关闭则存「文件」App › CarLink）
    @AppStorage("saveToPhotos") var saveToPhotos = true
    /// 相册页默认视图（false=缩略图 2 列，true=列表）
    @AppStorage("listMode") var listMode = false

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
        monitor.resume(queue: DispatchQueue(label: "carlink.pathmonitor"))
    }

    var canDownload: Bool {
        !wifiOnlyDownload || isWiFi
    }
}
