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

    // 设备卡：名称 / 版本 / IP / WiFi 频段与信号 / 测速
    private var deviceCard: some View {
        Section {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Image(systemName: "car.circle.fill")
                        .font(.system(size: 40))
                        .foregroundStyle(.blue)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(conn.deviceName).font(.headline)
                        Text("v\(conn.carInfo?.version ?? "-") · \(conn.carInfo?.ip ?? conn.client?.host ?? "")")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    HStack(spacing: 4) {
                        Circle().fill(.green).frame(width: 8, height: 8)
                        Text("已连接").font(.caption).foregroundStyle(.green)
                    }
                }

                if let wifi = conn.carInfo?.wifi {
                    HStack(spacing: 10) {
                        // 频段 chip
                        Text(wifi.mode == "ap" ? "热点 \(wifi.band ?? "-")" : (wifi.band ?? "WiFi"))
                            .font(.caption)
                            .fontWeight(.semibold)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.blue.opacity(0.15)))
                            .foregroundStyle(.blue)

                        if let q = wifi.quality {
                            Text("信号\(q)")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let rssi = wifi.rssi {
                            Text("\(rssi) dBm")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let ls = wifi.linkSpeed, ls > 0 {
                            Text("\(ls) Mbps")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        NavigationLink {
                            SpeedTestView()
                        } label: {
                            Label("测速", systemImage: "speedometer")
                                .font(.caption)
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
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
