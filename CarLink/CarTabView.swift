import SwiftUI

// MARK: - 车机 Tab：已连接显示主页，未连接显示连接页

struct CarTabView: View {
    @EnvironmentObject var conn: ConnectionStore

    var body: some View {
        NavigationStack {
            if conn.isConnected {
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

// MARK: - 主页（已连接）

struct CarHomeView: View {
    @EnvironmentObject var conn: ConnectionStore
    @EnvironmentObject var nav: AppNav

    var body: some View {
        List {
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

    // 设备卡（设计图 3.1）：名称/地址/在线点 · 频段+信号+测速 · 存储环+余量+机型版本
    private var deviceCard: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(conn.deviceName)
                            .font(.system(size: 15, weight: .bold))
                        Text("\(conn.client?.host ?? "-"):\(conn.client?.port ?? 8080) · 已连接")
                            .font(.system(size: 11))
                            .foregroundStyle(CL.ink2)
                    }
                    Spacer()
                    Circle()
                        .fill(CL.green)
                        .frame(width: 9, height: 9)
                        .padding(.top, 4)
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
                        Text("WiFi 状态获取中…")
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
            }
            .padding(.vertical, 4)
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

    // 实时状态卡：流量 / 客户端
    private var statusCard: some View {
        Section("车机状态") {
            if let s = conn.status {
                LabeledRow(icon: "arrow.up.circle", title: "车机发送", value: Fmt.rate(s.upRate ?? 0))
                LabeledRow(icon: "arrow.down.circle", title: "车机接收", value: Fmt.rate(s.downRate ?? 0))
                LabeledRow(icon: "externaldrive.connected.to.line.below", title: "已连接设备",
                           value: "\(s.clientCount ?? 1) 台")
            } else {
                LabeledRow(icon: "hourglass", title: "状态获取中", value: "…")
            }
            if let counts = conn.carInfo?.counts {
                LabeledRow(icon: "camera.viewfinder", title: "截图",
                           value: "\(counts.screenshot ?? 0) 张")
                LabeledRow(icon: "video.fill", title: "记录仪视频",
                           value: "\(counts.dashcam ?? 0) 段")
            }
        }
    }

    // 快捷入口
    private var quickLinks: some View {
        Section("快捷入口") {
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

struct LabeledRow: View {
    let icon: String
    let title: String
    let value: String

    var body: some View {
        HStack {
            Label(title, systemImage: icon)
                .foregroundStyle(.primary)
            Spacer()
            Text(value)
                .foregroundStyle(.secondary)
                .font(.subheadline.monospacedDigit())
        }
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
