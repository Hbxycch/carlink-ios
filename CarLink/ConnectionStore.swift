import Foundation
import Network

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
}

/// 链路健康度（车机页圆点/文案/状态卡的唯一依据）
/// - online   正常通信
/// - unstable 最近一次探测失败但还没到判定掉线的次数
/// - offline  已判定掉线，保留上次数据快照并自动重连
enum LinkHealth: Equatable {
    case online
    case unstable
    case offline
}

@MainActor
final class ConnectionStore: ObservableObject {
    @Published private(set) var state: ConnectionState = .disconnected
    @Published private(set) var carInfo: CarInfo?
    @Published private(set) var status: StatusResponse?
    @Published private(set) var volumes: [VolumeInfo] = []
    @Published private(set) var lastError: String?
    @Published private(set) var savedDevices: [SavedDevice] = []

    // MARK: 链路实时健康（每 2s 探测一次 /api/status）
    /// 最后一次成功通信的时间
    @Published private(set) var lastSeenAt: Date?
    /// 最近一次探测往返耗时（ms）
    @Published private(set) var latencyMs: Int?
    /// 连续失败次数（0 = 正常）
    @Published private(set) var missedBeats: Int = 0
    /// 判定掉线的时刻（nil = 在线）
    @Published private(set) var offlineSince: Date?
    /// 掉线后已重试次数
    @Published private(set) var reconnectAttempt: Int = 0
    /// status / 计数等展示数据最后刷新的时间
    @Published private(set) var lastUpdatedAt: Date?

    let browser = BonjourBrowser()

    private(set) var client: APIClient?
    private var monitorTask: Task<Void, Never>?

    private static let savedKey = "carlink.savedDevices"

    /// 连续失败多少次判定掉线
    private static let offlineThreshold = 2

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.savedKey),
           let list = try? JSONDecoder().decode([SavedDevice].self, from: data) {
            savedDevices = list
        }
    }

    /// 会话是否存在（掉线时会话保留，页面继续显示并自动重连）
    var hasSession: Bool { client != nil }

    /// 有会话且当前判定为已连接（注意：掉线时仍为 true，页面不会跳回连接页）
    var isConnected: Bool { state == .connected }

    /// 当前通信是否正常（真正可用的判断都用这个）
    var isOnline: Bool { state == .connected && offlineSince == nil && missedBeats == 0 }

    /// 链路可用（单次探测抖动不算掉线，仍允许发起请求）
    var isLinkUsable: Bool { state == .connected && offlineSince == nil }

    var health: LinkHealth {
        if state != .connected { return .offline }
        if offlineSince != nil { return .offline }
        if missedBeats > 0 { return .unstable }
        return .online
    }

    /// 设备卡副标题里的链路文案（按秒刷新，掉线时显示「x 秒前在线」）
    var linkText: String {
        switch health {
        case .online:
            guard let ms = latencyMs else { return "已连接" }
            return ms >= 800 ? "已连接 · 网络较慢 \(ms)ms" : "已连接 · \(ms)ms"
        case .unstable:
            return "连接不稳定 · 重试中"
        case .offline:
            guard let seen = lastSeenAt else { return "已断开" }
            let sec = max(0, Int(Date().timeIntervalSince(seen)))
            if sec < 60 { return "已断开 · \(sec) 秒前在线" }
            if sec < 3600 { return "已断开 · \(sec / 60) 分钟前在线" }
            return "已断开 · \(sec / 3600) 小时前在线"
        }
    }

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
        resetLinkHealth()
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
                let ms = max(1, Int(Date().timeIntervalSince(t0) * 1000))
                self.client = api
                self.carInfo = info
                self.state = .connected
                self.latencyMs = ms
                self.lastSeenAt = Date()
                self.missedBeats = 0
                self.offlineSince = nil
                self.reconnectAttempt = 0
                ConnLogStore.shared.log(source, "已连接 \(info.deviceName) v\(info.version)（\(host):\(port)，\(ms)ms）")
                self.remember(SavedDevice(host: host, port: port, name: info.deviceName))
                // 连上立刻拉一轮数据，避免首页出现「状态获取中」
                self.status = try? await api.status()
                self.lastUpdatedAt = Date()
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
        resetLinkHealth()
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

    // MARK: - 连接保活（2s 一探测，掉线自动重连）

    private func resetLinkHealth() {
        lastSeenAt = nil
        latencyMs = nil
        missedBeats = 0
        offlineSince = nil
        reconnectAttempt = 0
        lastUpdatedAt = nil
    }

    private func startMonitor() {
        monitorTask?.cancel()
        monitorTask = Task { [weak self] in
            var tick = 0
            while !Task.isCancelled {
                guard let self, let api = self.client else { break }
                // 在线：2s 一次；掉线：2s→4s→…→12s 退避重连
                let offline = self.offlineSince != nil
                let seconds = offline ? min(2 + self.reconnectAttempt * 2, 12) : 2
                try? await Task.sleep(nanoseconds: UInt64(seconds) * 1_000_000_000)
                guard !Task.isCancelled else { break }

                do {
                    let (s, ms) = try await api.ping()
                    let wasOffline = self.offlineSince != nil
                    self.applyProbeSuccess(s, latency: ms)
                    if wasOffline {
                        ConnLogStore.shared.log("MON", "连接已恢复（\(ms)ms）")
                    }
                    tick += 1
                    // 机型 / WiFi / 文件计数：每 6s 刷一次
                    if tick % 3 == 0, let info = try? await api.info(), !Task.isCancelled {
                        self.carInfo = info
                        self.lastUpdatedAt = Date()
                    }
                    // 存储余量：每 10s 刷一次
                    if tick % 5 == 0, let v = try? await api.volumes(), !Task.isCancelled {
                        self.volumes = v
                        self.lastUpdatedAt = Date()
                    }
                } catch {
                    self.applyProbeFailure(error)
                }
            }
        }
    }

    private func applyProbeSuccess(_ s: StatusResponse, latency: Int) {
        status = s
        lastSeenAt = Date()
        lastUpdatedAt = Date()
        latencyMs = latency
        missedBeats = 0
        reconnectAttempt = 0
        if offlineSince != nil {
            offlineSince = nil
            lastError = nil
        }
        if state != .connected { state = .connected }
    }

    private func applyProbeFailure(_ error: Error) {
        missedBeats += 1
        ConnLogStore.shared.log("MON", "心跳失败 #\(missedBeats) \(ConnLogStore.describe(error))")
        guard missedBeats >= Self.offlineThreshold else { return }
        if offlineSince == nil {
            offlineSince = Date()
            reconnectAttempt = 0
            lastError = "与车机的连接已断开"
            ConnLogStore.shared.log("MON", "连续 \(missedBeats) 次心跳失败 → 判定掉线，开始自动重连")
        } else {
            reconnectAttempt += 1
        }
    }

    /// 主动探测一次（下拉刷新 / 回到前台 / 「立即重连」按钮）
    func probeNow() async {
        guard let api = client else { return }
        do {
            let (s, ms) = try await api.ping()
            let wasOffline = offlineSince != nil
            applyProbeSuccess(s, latency: ms)
            if wasOffline { ConnLogStore.shared.log("MON", "手动重连成功（\(ms)ms）") }
        } catch {
            applyProbeFailure(error)
        }
    }

    /// 主动刷新一次信息（下拉刷新等）
    func refreshNow() async {
        guard let api = client else { return }
        // 掉线状态下先走 4s 短超时探测，别让下拉刷新卡 15s 主超时
        if offlineSince != nil {
            await probeNow()
            if offlineSince != nil { return }
        }
        let t0 = Date()
        if let info = try? await api.info() {
            carInfo = info
            latencyMs = max(1, Int(Date().timeIntervalSince(t0) * 1000))
            lastSeenAt = Date()
            lastUpdatedAt = Date()
            if offlineSince != nil {
                offlineSince = nil
                missedBeats = 0
                reconnectAttempt = 0
                lastError = nil
            }
        }
        status = (try? await api.status()) ?? status
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
