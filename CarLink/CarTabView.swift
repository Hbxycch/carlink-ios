import SwiftUI

// MARK: - 车机 Tab：已连接显示主页，未连接显示连接页

struct CarTabView: View {
    @EnvironmentObject var conn: ConnectionStore

    var body: some View {
        NavigationStack {
            // 掉线时会话仍然保留（client 未清空），主页照常显示并给出红色断线提示
            if conn.hasSession || conn.isConnected {
                CarHomeView()
            } else if conn.state == .connecting {
                VStack(spacing: 16) {
                    ProgressView()
                    Text("正在连接车机…")
                        .foregroundStyle(.secondary)
                }
                .navigationTitle("连接车机")
            } else {
                ConnectView()
            }
        }
    }
}

// MARK: - 主页（已连接 / 掉线）

struct CarHomeView: View {
    @EnvironmentObject var conn: ConnectionStore
    @EnvironmentObject var nav: AppNav
    @EnvironmentObject var settings: SettingsStore

    private var dimmed: Bool { conn.health == .offline }

    var body: some View {
        List {
            if conn.health == .offline { offlineBanner }
            deviceCard
            statusCard
            quickLinks
        }
        .listStyle(.insetGrouped)
        .navigationTitle("车机")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button("断开") { conn.disconnect() }
            }
        }
        .refreshable { await conn.refreshNow() }
    }

    // MARK: 断线横幅（红色，实时显示断开时长与重连次数）

    private var offlineBanner: some View {
        Section {
            VStack(alignment: .leading, spacing: 9) {
                HStack(spacing: 7) {
                    Image(systemName: "wifi.slash")
                        .font(.system(size: 14, weight: .bold))
                    Text("与车机的连接已断开")
                        .font(.system(size: 14.5, weight: .bold))
                    Spacer(minLength: 0)
                }
                TimelineView(.periodic(from: .now, by: 1)) { _ in
                    Text(bannerDetail)
                        .font(.system(size: 11.5))
                        .opacity(0.92)
                        .monospacedDigit()
                }
                HStack(spacing: 8) {
                    Button {
                        Task { await conn.probeNow() }
                    } label: {
                        Text("立即重连")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(CL.red)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 5)
                            .background(Capsule().fill(Color.white.opacity(0.92)))
                    }
                    .buttonStyle(.plain)

                    Button {
                        conn.disconnect()
                    } label: {
                        Text("断开连接")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 5)
                            .overlay(Capsule().stroke(Color.white.opacity(0.65), lineWidth: 1))
                    }
                    .buttonStyle(.plain)
                    Spacer(minLength: 0)
                }
                .padding(.top, 1)
            }
            .foregroundStyle(.white)
            .padding(.vertical, 5)
            .listRowBackground(CL.red)
            .listRowSeparator(.hidden)
        }
    }

    private var bannerDetail: String {
        var parts: [String] = ["正在自动重连"]
        if let since = conn.offlineSince {
            parts.append("已断开 \(max(0, Int(Date().timeIntervalSince(since)))) 秒")
        }
        if let seen = conn.lastSeenAt {
            parts.append("最后在线 \(Fmt.time(seen))")
        }
        if conn.reconnectAttempt > 0 {
            parts.append("第 \(conn.reconnectAttempt + 1) 次尝试")
        }
        return parts.joined(separator: " · ")
    }

    // 设备卡（设计图 3.1）：名称/地址/在线点 · 频段+信号+测速 · 存储环+余量+机型版本
    private var deviceCard: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(conn.deviceName)
                            .font(.system(size: 15, weight: .bold))
                        HStack(spacing: 4) {
                            Text("\(conn.client?.host ?? "-"):\(conn.client?.port ?? 8080)")
                                .font(.system(size: 11))
                                .foregroundStyle(CL.ink2)
                            Text("·")
                                .font(.system(size: 11))
                                .foregroundStyle(CL.ink2)
                            // 每秒刷新：掉线后「已断开 · 18 秒前在线」持续计时
                            TimelineView(.periodic(from: .now, by: 1)) { _ in
                                Text(conn.linkText)
                                    .font(.system(size: 11, weight: .semibold))
                                    .monospacedDigit()
                                    .foregroundStyle(linkColor)
                            }
                        }
                    }
                    Spacer()
                    LinkDot(health: conn.health)
                        .padding(.top, 1)
                }

                HStack(spacing: 6) {
                    if let wifi = conn.carInfo?.wifi {
                        Text(wifi.mode == "ap" ? "热点 \(wifi.band ?? "")" : (wifi.band ?? "WiFi"))
                            .font(.system(size: 10.5, weight: .bold))
                            .foregroundStyle(CL.blue)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 1.5)
                            .background(RoundedRectangle(cornerRadius: 6).fill(CL.blueBg))

                        SignalBars(rssi: wifi.rssi)
                        if let q = wifi.quality {
                            Text("信号\(q)")
                                .font(.system(size: 10.5, weight: .semibold))
                                .foregroundStyle(CL.green)
                        }
                        if let rssi = wifi.rssi {
                            Text("\(rssi) dBm")
                                .font(.system(size: 10.5))
                                .foregroundStyle(CL.ink2)
                        }
                    } else {
                        Text(conn.isOnline ? "WiFi 状态获取中…" : "WiFi 状态不可用")
                            .font(.system(size: 10.5))
                            .foregroundStyle(CL.ink2)
                    }
                    Spacer()
                    NavigationLink {
                        SpeedTestView()
                    } label: {
                        Text("测速 ›")
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(CL.blue)
                    }
                    .buttonStyle(.plain)
                }
                .opacity(dimmed ? 0.45 : 1)

                HStack(spacing: 12) {
                    StorageRing(volume: conn.internalVolume)
                    VStack(alignment: .leading, spacing: 2) {
                        storageLine("内置存储", conn.internalVolume)
                        storageLine("SD 卡", conn.externalVolume)
                        Text(modelVersionText)
                            .font(.system(size: 10.5))
                            .foregroundStyle(CL.ink2)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.top, 2)
                .opacity(dimmed ? 0.45 : 1)
            }
            .padding(.vertical, 4)
        }
    }

    private var linkColor: Color {
        switch conn.health {
        case .online: return CL.green
        case .unstable: return CL.orange
        case .offline: return CL.red
        }
    }

    private func storageLine(_ title: String, _ v: VolumeInfo?) -> some View {
        HStack(spacing: 3) {
            if let v = v, let free = v.freeBytes {
                Text("\(title) · 剩余 \(Fmt.bytes(free))")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.primary)
                let ratio = v.totalBytes.map { Double(free) / Double(max($0, 1)) } ?? 1
                if ratio < 0.05 {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(CL.orange)
                }
            } else {
                Text("\(title) · 未挂载")
                    .font(.system(size: 11.5))
                    .foregroundStyle(CL.ink2)
            }
        }
    }

    private var modelVersionText: String {
        var parts: [String] = []
        if let m = conn.carInfo?.modelText { parts.append(m) }
        if let v = conn.carInfo?.version { parts.append("v\(v)") }
        return parts.isEmpty ? "机型信息获取中" : parts.joined(separator: " · ")
    }

    // MARK: 实时状态卡：流量 / 客户端 / 计数（2s 刷新，掉线后保留快照并标红）

    private var statusCard: some View {
        Section {
            if let s = conn.status {
                LabeledRow(icon: "arrow.up.circle", title: "车机发送",
                           value: Fmt.rate(s.upRate ?? 0), dimmed: dimmed)
                LabeledRow(icon: "arrow.down.circle", title: "车机接收",
                           value: Fmt.rate(s.downRate ?? 0), dimmed: dimmed)
                LabeledRow(icon: "externaldrive.connected.to.line.below", title: "已连接设备",
                           value: "\(s.clientCount ?? 1) 台", dimmed: dimmed)
            } else if conn.isOnline {
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text("正在读取车机状态…")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } else {
                LabeledRow(icon: "wifi.slash", title: "状态不可用", value: "等待重连")
            }

            if let counts = conn.carInfo?.counts {
                LabeledRow(icon: "camera.viewfinder", title: "截图",
                           value: "\(counts.screenshot ?? 0) 张", dimmed: dimmed)
                LabeledRow(icon: "video.fill", title: "记录仪视频",
                           value: "\(counts.dashcam ?? 0) 段", dimmed: dimmed)
            }
        } header: {
            HStack(spacing: 6) {
                Text("车机状态")
                Spacer(minLength: 0)
                StatusChip(health: conn.health)
            }
            .font(.system(size: 13))
            .textCase(nil)
        } footer: {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                Text(statusFooter)
                    .font(.system(size: 11))
                    .foregroundStyle(conn.health == .offline ? CL.red : Color.secondary)
                    .monospacedDigit()
            }
        }
    }

    private var statusFooter: String {
        switch conn.health {
        case .online:
            guard let t = conn.lastUpdatedAt else { return "实时更新中…" }
            let sec = max(0, Int(Date().timeIntervalSince(t)))
            return sec <= 2 ? "实时更新 · 刚刚" : "实时更新 · \(sec) 秒前"
        case .unstable:
            return "网络不稳定，正在重试…"
        case .offline:
            guard let t = conn.lastUpdatedAt else { return "已断开 · 暂无数据" }
            return "已断开 · 数据停在 \(Fmt.time(t))"
        }
    }

    // 快捷入口
    private var quickLinks: some View {
        Section("快捷入口") {
            NavigationLink {
                MonitorView()
            } label: {
                HStack(spacing: 8) {
                    Label("车机监控", systemImage: "video.fill")
                    Spacer(minLength: 0)
                    Text(conn.isOnline ? "\(settings.monitorDefaultLayout) 路画面" : "离线")
                        .font(.system(size: 10.5))
                        .foregroundStyle(conn.isOnline ? CL.ink2 : CL.red)
                }
            }
            Button {
                nav.filesJump = FileSegmentJump(segment: .remote, category: .loop)
                nav.tab = .files
            } label: {
                Label("浏览记录仪视频", systemImage: "square.stack.3d.up.fill")
            }
            Button {
                nav.filesJump = FileSegmentJump(segment: .screenshots, category: nil)
                nav.tab = .files
            } label: {
                Label("浏览车机截图", systemImage: "photo.on.rectangle")
            }
            Button {
                nav.tab = .transfer
            } label: {
                Label("上传文件到车机", systemImage: "square.and.arrow.up")
            }
        }
    }
}

// MARK: - 链路状态圆点（在线绿 / 不稳定橙呼吸 / 掉线红脉冲）

struct LinkDot: View {
    let health: LinkHealth
    @State private var pulse = false

    private var color: Color {
        switch health {
        case .online: return CL.green
        case .unstable: return CL.orange
        case .offline: return CL.red
        }
    }

    var body: some View {
        ZStack {
            if health != .online {
                Circle()
                    .stroke(color.opacity(0.5), lineWidth: 1.4)
                    .frame(width: 9, height: 9)
                    .scaleEffect(pulse ? 2.3 : 1)
                    .opacity(pulse ? 0 : 1)
            }
            Circle()
                .fill(color)
                .frame(width: 9, height: 9)
                .shadow(color: color.opacity(health == .online ? 0.35 : 0.55),
                        radius: health == .online ? 2 : 4)
        }
        .frame(width: 22, height: 22)
        .onAppear {
            pulse = false
            withAnimation(.easeOut(duration: 1.1).repeatForever(autoreverses: false)) {
                pulse = true
            }
        }
    }
}

// MARK: - 状态卡右上角实时标签

struct StatusChip: View {
    let health: LinkHealth

    private var color: Color {
        switch health {
        case .online: return CL.green
        case .unstable: return CL.orange
        case .offline: return CL.red
        }
    }

    private var text: String {
        switch health {
        case .online: return "实时更新"
        case .unstable: return "连接不稳定"
        case .offline: return "已断开"
        }
    }

    var body: some View {
        HStack(spacing: 3) {
            Circle()
                .fill(color)
                .frame(width: 5, height: 5)
            Text(text)
                .font(.system(size: 10.5, weight: .semibold))
                .textCase(nil)
        }
        .foregroundStyle(color)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(color.opacity(0.14)))
    }
}

struct LabeledRow: View {
    let icon: String
    let title: String
    let value: String
    var dimmed: Bool = false

    var body: some View {
        HStack {
            Label(title, systemImage: icon)
                .foregroundStyle(.primary)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .font(.subheadline.monospacedDigit())
        }
        .opacity(dimmed ? 0.45 : 1)
    }
}

// MARK: - 存储容量环（设计图 .ring：蓝色已用弧 + 中间剩余量）

struct StorageRing: View {
    let volume: VolumeInfo?

    private var ratio: Double {
        guard let v = volume else { return 0 }
        return v.usedRatio
    }

    private var freeText: String {
        guard let f = volume?.freeBytes else { return "--" }
        if f >= 1_073_741_824 { return String(format: "%.1fG", Double(f) / 1_073_741_824) }
        if f >= 1_048_576 { return String(format: "%.0fM", Double(f) / 1_048_576) }
        return Fmt.bytes(f)
    }

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color(uiColor: .tertiarySystemFill), lineWidth: 9)
            Circle()
                .trim(from: 0, to: max(0.02, min(1, ratio)))
                .stroke(CL.blue, style: StrokeStyle(lineWidth: 9, lineCap: .round))
                .rotationEffect(.degrees(-90))
            VStack(spacing: 0) {
                Text(freeText)
                    .font(.system(size: 13, weight: .bold))
                    .minimumScaleFactor(0.6)
                    .lineLimit(1)
                Text("剩余")
                    .font(.system(size: 9))
                    .foregroundStyle(CL.ink2)
            }
            .padding(14)
        }
        .frame(width: 86, height: 86)
    }
}

// MARK: - 信号格（4 格，按 RSSI 点亮）

struct SignalBars: View {
    let rssi: Int?

    private var lit: Int {
        guard let r = rssi else { return 0 }
        switch r {
        case (-55)...: return 4
        case (-65)..<(-55): return 3
        case (-75)..<(-65): return 2
        default: return 1
        }
    }

    var body: some View {
        HStack(alignment: .bottom, spacing: 1.5) {
            ForEach(0..<4, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(i < lit ? CL.green : Color(uiColor: .quaternaryLabel))
                    .frame(width: 3, height: 5 + CGFloat(i) * 2.2)
            }
        }
        .frame(height: 12, alignment: .bottom)
    }
}
