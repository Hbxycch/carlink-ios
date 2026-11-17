import SwiftUI

// MARK: - 连接页：发现 / 记忆设备 / 手动 IP / 扫码

struct ConnectView: View {
    @EnvironmentObject var conn: ConnectionStore
    @ObservedObject private var browser = BonjourBrowser()

    @State private var ipText = ""
    @State private var portText = "8080"
    @State private var showScanner = false

    var body: some View {
        List {
            errorSection
            savedSection
            discoveredSection
            manualSection
            scanSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle("连接车机")
        .onAppear { browser.start() }
        .onDisappear { browser.stop() }
        .sheet(isPresented: $showScanner) {
            QRScannerView { code in
                showScanner = false
                _ = conn.connectQR(code)
            }
        }
    }

    @ViewBuilder
    private var errorSection: some View {
        if let err = conn.lastError {
            Section {
                Label(err, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .font(.subheadline)
                NavigationLink {
                    ConnDiagnosticsView()
                } label: {
                    Label("查看连接诊断日志", systemImage: "stethoscope")
                        .font(.subheadline)
                }
            }
        }
    }

    private var savedSection: some View {
        Section("最近连接") {
            if conn.savedDevices.isEmpty {
                Text("暂无记录").foregroundStyle(.secondary)
            }
            ForEach(conn.savedDevices) { d in
                Button {
                    conn.connect(device: d)
                } label: {
                    HStack {
                        Image(systemName: "car.fill").foregroundStyle(.blue)
                        VStack(alignment: .leading) {
                            Text(d.name).foregroundStyle(.primary)
                            Text("\(d.host):\(d.port)")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .swipeActions {
                    Button(role: .destructive) { conn.forget(d) } label: { Label("删除", systemImage: "trash") }
                }
            }
        }
    }

    private var discoveredSection: some View {
        Section {
            if browser.devices.isEmpty {
                HStack {
                    if browser.browsing { ProgressView().padding(.trailing, 8) }
                    Text("正在搜索局域网内的车机…")
                        .foregroundStyle(.secondary)
                }
            }
            ForEach(browser.devices) { d in
                Button {
                    guard let h = d.host, let p = d.port else { return }
                    conn.connect(host: h, port: p)
                } label: {
                    HStack {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                            .foregroundStyle(.green)
                        VStack(alignment: .leading) {
                            Text(d.name).foregroundStyle(.primary)
                            Text(d.resolved ? "\(d.host ?? ""):\(d.port ?? 8080)" : "解析中…")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
                    }
                }
                .disabled(!d.resolved)
            }
        } header: {
            HStack {
                Text("自动发现")
                Spacer()
                Button("重新搜索") { browser.start() }
                    .font(.caption)
            }
        } footer: {
            Text("需手机与车机处于同一网络（连同一 WiFi，或手机连车机热点）。首次使用会请求本地网络权限。")
        }
    }

    private var manualSection: some View {
        Section {
            HStack {
                TextField("车机 IP，如 192.168.43.1", text: $ipText)
                    .keyboardType(.decimalPad)
                    .autocorrectionDisabled()
                TextField("端口", text: $portText)
                    .keyboardType(.numberPad)
                    .frame(width: 70)
                Button("连接") {
                    guard let p = Int(portText), !ipText.isEmpty else { return }
                    conn.connect(host: ipText.trimmingCharacters(in: .whitespaces), port: p)
                }
                .buttonStyle(.borderedProminent)
                .disabled(ipText.isEmpty || conn.state == .connecting)
            }
        } header: {
            Text("手动输入")
        } footer: {
            Text("在车机 App 主页查看 IP 与端口，也可扫车机上的二维码自动填入。")
        }
    }

    private var scanSection: some View {
        Section {
            Button {
                showScanner = true
            } label: {
                Label("扫描车机二维码", systemImage: "qrcode.viewfinder")
            }
        }
    }
}
