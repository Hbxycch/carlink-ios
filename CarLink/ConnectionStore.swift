import Foundation
import Network

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
}

@MainActor
final class ConnectionStore: ObservableObject {
    @Published private(set) var state: ConnectionState = .disconnected
    @Published private(set) var carInfo: CarInfo?
    @Published private(set) var status: StatusResponse?
    @Published private(set) var volumes: [VolumeInfo] = []
    @Published private(set) var lastError: String?
    @Published private(set) var savedDevices: [SavedDevice] = []

    let browser = BonjourBrowser()

    private(set) var client: APIClient?
    private var monitorTask: Task<Void, Never>?

    private static let savedKey = "carlink.savedDevices"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.savedKey),
           let list = try? JSONDecoder().decode([SavedDevice].self, from: data) {
            savedDevices = list
        }
    }

    var isConnected: Bool { state == .connected }

    var deviceName: String { carInfo?.deviceName ?? "车机" }

    // MARK: - 连接

    private var connectGeneration = 0

    /// source 仅用于日志标注：manual / auto / qr
    func connect(host: String, port: Int, source: String = "manual") {
        // 手动连接允许打断上一次（含自动连接）：旧的 .connecting 状态不再阻塞新请求
        connectGeneration += 1
        let gen = connectGeneration
        state = .connecting
        lastError = nil
        let t0 = Date()
        ConnLogStore.shared.log(source, "开始连接 \(host):\(port)")
        let api = APIClient(host: host, port: port)
        Task {
            do {
                let info = try await api.info()
                guard gen == self.connectGeneration else {
                    ConnLogStore.shared.log(source, "连接被更新的请求取代，丢弃结果 \(host):\(port)")
                    return
                }
                self.client = api
                self.carInfo = info
                self.state = .connected
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                ConnLogStore.shared.log(source, "已连接 \(info.deviceName) v\(info.version)（\(host):\(port)，\(ms)ms）")
                self.remember(SavedDevice(host: host, port: port, name: info.deviceName))
                self.volumes = (try? await api.volumes()) ?? []
                self.startMonitor()
            } catch {
                guard gen == self.connectGeneration else { return }
                let detail = ConnLogStore.describe(error)
                let ms = Int(Date().timeIntervalSince(t0) * 1000)
                ConnLogStore.shared.log("ERR", "连接失败 \(host):\(port) \(detail)（\(ms)ms）")
                if self.state == .connecting {
                    self.state = .disconnected
                    self.lastError = Self.describe(error)
                }
            }
        }
    }

    func connect(device: SavedDevice) {
        connect(host: device.host, port: device.port)
    }

    // MARK: 自动连接

    private var lastAutoConnectAt: Date?

    /// 启动 / 回到前台时自动连接最近一次使用的车机（20s 冷却，避免反复重试不可达设备）
    func autoConnectIfPossible() {
        guard state == .disconnected, let device = savedDevices.first else { return }
        if let last = lastAutoConnectAt, Date().timeIntervalSince(last) < 20 {
            ConnLogStore.shared.log("AUTO", "冷却中（20s），跳过自动连接")
            return
        }
        lastAutoConnectAt = Date()
        ConnLogStore.shared.log("AUTO", "自动连接上次设备 \(device.name) \(device.host):\(device.port)")
        connect(host: device.host, port: device.port, source: "auto")
    }

    /// 解析车机二维码内容（http://192.168.1.100:8080/web）
    func connectQR(_ text: String) -> Bool {
        guard let comps = URLComponents(string: text.trimmingCharacters(in: .whitespacesAndNewlines)),
              let h = comps.host else { return false }
        let p = comps.port ?? 8080
        connect(host: h, port: p, source: "qr")
        return true
    }

    func disconnect() {
        ConnLogStore.shared.log("CONN", "主动断开")
        monitorTask?.cancel()
        monitorTask = nil
        client = nil
        carInfo = nil
        status = nil
        volumes = []
        state = .disconnected
    }

    func forget(_ device: SavedDevice) {
        savedDevices.removeAll { $0 == device }
        persist()
    }

    private func remember(_ device: SavedDevice) {
        if let i = savedDevices.firstIndex(where: { $0.id == device.id }) {
            savedDevices[i] = device
        } else {
            savedDevices.insert(device, at: 0)
            if savedDevices.count > 8 { savedDevices.removeLast() }
        }
        persist()
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(savedDevices) {
            UserDefaults.standard.set(data, forKey: Self.savedKey)
        }
    }

    // MARK: - 连接保活

    private func startMonitor() {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            var failures = 0
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 5_000_000_000)
                guard !Task.isCancelled else { break }
                guard let self, let api = self.client else { break }
                do {
                    _ = try await api.info()
                    failures = 0
                } catch {
                    failures += 1
                    ConnLogStore.shared.log("MON", "心跳失败 #\(failures)/3 \(ConnLogStore.describe(error))")
                    if failures >= 3 {
                        self.lastError = "与车机的连接已断开"
                        ConnLogStore.shared.log("MON", "连续 3 次心跳失败，判定断开")
                        self.disconnect()
                        break
                    }
                    continue
                }
                if let s = try? await api.status() {
                    self.status = s
                }
                // 存储余量变化较慢，每 5s 一起刷新（代价很小，卡片保持实时）
                if let v = try? await api.volumes() {
                    self.volumes = v
                }
            }
        }
    }

    /// 主动刷新一次信息（下拉刷新等）
    func refreshNow() async {
        guard let api = client else { return }
        carInfo = try? await api.info()
        status = try? await api.status()
        volumes = (try? await api.volumes()) ?? volumes
    }

    // MARK: - 存储卷便捷访问

    /// 内置存储
    var internalVolume: VolumeInfo? {
        volumes.first { ($0.type ?? "") == "internal" && $0.isMounted }
            ?? volumes.first { !($0.removable ?? false) }
    }

    /// SD 卡 / U 盘（可移动）
    var externalVolume: VolumeInfo? {
        volumes.first { ($0.type ?? "") == "sd" && $0.isMounted }
            ?? volumes.first { ($0.removable ?? false) && $0.isMounted }
    }

    static func describe(_ error: Error) -> String {
        if let e = error as? APIError { return e.message }
        let ns = error as NSError
        switch ns.domain {
        case NSURLErrorDomain:
            switch ns.code {
            case NSURLErrorTimedOut: return "连接超时，请确认车机端服务已开启、手机与车机在同一网络"
            case NSURLErrorCannotFindHost, NSURLErrorCannotConnectToHost: return "无法连接到车机，请检查 IP 地址或热点连接"
            case NSURLErrorNetworkConnectionLost: return "网络连接已断开"
            default: return "网络错误：\(ns.localizedDescription)"
            }
        default: return ns.localizedDescription
        }
    }
}
