import SwiftUI

// MARK: - 车机状态页（设置 › 车机状态）
//
// 数据来自 /api/device/info（每 5 秒自动刷新：CPU/内存/网络速率会动）、
// /api/device/apps（一次）与 /api/device/peripherals（一次）。

struct DeviceStatusView: View {
    @EnvironmentObject var conn: ConnectionStore

    @State private var info: [String: Any]?
    @State private var apps: [String: Any]?
    @State private var periph: [String: Any]?
    @State private var errorText: String?
    @State private var lastUpdated: Date?
    @State private var autoRefresh = true

    private let refreshInterval: TimeInterval = 5

    var body: some View {
        List {
            if let e = errorText {
                Section {
                    Label(e, systemImage: "exclamationmark.triangle")
                        .font(.subheadline)
                        .foregroundStyle(.orange)
                    Button("重试") { Task { await loadAll(force: true) } }
                        .font(.subheadline)
                }
            } else if info == nil {
                Section {
                    HStack(spacing: 10) {
                        ProgressView()
                        Text("正在读取车机状态…")
                            .font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            } else {
                overviewSection
                cpuSection
                memorySection
                storageSection
                networkSection
                screenSection
                trafficSection
                appsSection
                peripheralSection
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("车机状态")
        .navigationBarTitleDisplayMode(.inline)
        .refreshable { await loadAll(force: true) }
        .task {
            await loadAll(force: true)
            // 轮询：CPU 占用 / 内存 / 网络速率 5 秒一跳；页面退出自动停
            while autoRefresh, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: UInt64(refreshInterval * 1_000_000_000))
                guard autoRefresh, !Task.isCancelled else { break }
                await loadCore()
            }
        }
        .onDisappear { autoRefresh = false }
    }

    // MARK: 概览

    private var overviewSection: some View {
        Section {
            LabeledRow(icon: "car.fill", title: "设备名称", value: conn.deviceName)
            row("iphone.gen3", "机型", modelText)
            row("cpu", "处理器", hardwareText)
            row("gearshape", "Android", androidText)
            row("app.badge", "CarLink", appVersionText)
            row("number", "服务端口", portText)
            row("person.2", "连接客户端", clientText)
            row("clock", "已运行", uptimeText)
        } header: {
            HStack {
                Text("概览")
                Spacer()
                if let t = lastUpdated {
                    Text("更新于 \(t.formatted(date: .omitted, time: .standard))")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    // MARK: CPU

    private var cpuSection: some View {
        Section {
            HStack(spacing: 14) {
                Gauge(value: min(1, max(0, cpuUsageValue / 100))) {
                    Text("CPU")
                } currentValueLabel: {
                    Text(cpuUsageValue >= 0 ? "\(Int(cpuUsageValue))%" : "—")
                        .font(.system(.body, design: .rounded).weight(.semibold))
                }
                .gaugeStyle(.accessoryCircular)
                .tint(cpuUsageValue > 85 ? Color.orange : CL.blue)

                VStack(alignment: .leading, spacing: 4) {
                    Text(cpuUsageText).font(.subheadline)
                    Text("负载 \(loadAvgText)").font(.caption).foregroundStyle(.secondary)
                }
            }
            row("cpu", "核心数", coreText)
            row("speedometer", "当前频率", freqText)
            row("bolt", "最大频率", maxFreqText)
            row("thermometer.medium", "温度", tempText)
        } header: {
            Text("CPU")
        }
    }

    // MARK: 内存

    private var memorySection: some View {
        Section {
            LabeledRow(icon: "memorychip", title: "运行内存",
                       value: "\(memUsedText) / \(memTotalText)")
            if let low = boolVal(hw, "memLowMemory"), low {
                Label("系统内存吃紧（lowMemory）", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text("内存")
        }
    }

    // MARK: 存储

    private var storageSection: some View {
        Section {
            LabeledRow(icon: "internaldrive", title: "内置存储", value: internalStorageText)
            ForEach(volumeIndices, id: \.self) { idx in
                volumeRow(idx)
            }
        } header: {
            Text("存储")
        }
    }

    // MARK: 网络

    private var networkSection: some View {
        Section {
            row("wifi", "连接方式", networkTypeText)
            row("wifi.router", "SSID", ssidText)
            row("number", "IP 地址", ipText)
            row("dot.radiowaves.left.and.right", "频段", bandText)
            row("waveform.path.ecg.rectangle", "信道 / 频率", channelText)
            row("speedometer", "协商速率", linkSpeedText)
            row("antenna.radiowaves.left.and.right", "信号强度", rssiText)
        } header: {
            Text("网络")
        } footer: {
            Text("车机开热点时显示 AP 模式；连路由时显示 station 模式与信号质量。")
        }
    }

    // MARK: 屏幕

    private var screenSection: some View {
        Section {
            row("rectangle.on.rectangle", "分辨率", resolutionText)
            row("aspectratio", "刷新率", refreshText)
            row("circle.grid.cross", "密度", densityText)
            row("ruler", "物理尺寸", physicalSizeText)
        } header: {
            Text("屏幕")
        }
    }

    // MARK: 流量

    private var trafficSection: some View {
        Section {
            LabeledRow(icon: "arrow.up.circle", title: "发送速率", value: upRateText)
            LabeledRow(icon: "arrow.down.circle", title: "接收速率", value: downRateText)
            LabeledRow(icon: "arrow.uturn.up", title: "累计发送", value: upTotalText)
            LabeledRow(icon: "arrow.uturn.down", title: "累计接收", value: downTotalText)
        } header: {
            Text("传输流量")
        }
    }

    // MARK: 安装应用

    private var appsSection: some View {
        Section {
            NavigationLink {
                DeviceAppsView(apps: apps)
            } label: {
                HStack {
                    Label("已安装应用", systemImage: "square.grid.3x3")
                    Spacer()
                    Text(appsSummaryText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("应用")
        }
    }

    // MARK: 外设

    private var peripheralSection: some View {
        Section {
            row("camera.fill", "摄像头", cameraText)
            row("sensor.tag.radiowaves.forward", "传感器", sensorText)
            row("usb", "USB 设备", usbText)
            row("location", "GPS", gpsText)
        } header: {
            Text("外设与传感器")
        }
    }

    // MARK: 子视图

    @ViewBuilder
    private func volumeRow(_ idx: Int) -> some View {
        let v = volumeDicts[idx]
        let name = str(v, "uuid") ?? str(v, "path") ?? "卷"
        let total = intVal(v, "total") ?? 0
        let free = intVal(v, "free") ?? 0
        let mounted = boolVal(v, "mounted") ?? false
        VStack(alignment: .leading, spacing: 3) {
            HStack {
                Image(systemName: v["type"] as? String == "sdcard" ? "sdcard" : "externaldrive")
                    .foregroundStyle(CL.blue)
                Text(name)
                    .font(.subheadline)
                Spacer()
                Text(mounted ? "" : "未挂载")
                    .font(.caption).foregroundStyle(.orange)
            }
            if total > 0 {
                VStack(alignment: .leading, spacing: 2) {
                    ProgressView(value: Double(total - free) / Double(total))
                        .tint((total - free) * 10 > total * 9 ? Color.orange : CL.blue)
                    Text("已用 \(Fmt.bytes(total - free)) · 剩余 \(Fmt.bytes(free)) · 共 \(Fmt.bytes(total))")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .padding(.vertical, 2)
    }

    private func row(_ icon: String, _ title: String, _ value: String) -> some View {
        LabeledRow(icon: icon, title: title, value: value.isEmpty ? "—" : value)
    }

    // MARK: 数据加载

    private func loadAll(force: Bool) async {
        guard conn.isConnected, let api = conn.client else {
            errorText = "未连接车机"
            return
        }
        await loadCore()
        if apps == nil || periph == nil {
            async let a = try? api.deviceAppsDict()
            async let p = try? api.devicePeripheralsDict()
            let (appsRes, pRes) = await (a, p)
            if let appsRes = appsRes { apps = appsRes }
            if let pRes = pRes { periph = pRes }
        }
    }

    private func loadCore() async {
        guard let api = conn.client else { return }
        do {
            info = try await api.deviceInfoDict()
            errorText = nil
            lastUpdated = Date()
        } catch {
            if info == nil { errorText = ConnectionStore.describe(error) }
        }
    }

    // MARK: 取值辅助（JSONSerialization 字典）

    private var dev: [String: Any]? { info?["device"] as? [String: Any] }
    private var hw: [String: Any]? { info?["hardware"] as? [String: Any] }
    private var scr: [String: Any]? { info?["screen"] as? [String: Any] }
    private var net: [String: Any]? { info?["network"] as? [String: Any] }
    private var wifi: [String: Any]? { net?["wifi"] as? [String: Any] }
    private var app: [String: Any]? { info?["app"] as? [String: Any] }
    private var traffic: [String: Any]? { app?["traffic"] as? [String: Any] }
    private var storage: [String: Any]? { info?["storage"] as? [String: Any] }
    private var volumeDicts: [[String: Any]] {
        (storage?["volumes"] as? [[String: Any]]) ?? []
    }
    private var volumeIndices: [Int] { volumeDicts.indices.map { $0 } }
    private var gpsDict: [String: Any]? { periph?["gps"] as? [String: Any] }

    private func str(_ d: [String: Any]?, _ k: String) -> String? {
        guard let v = d?[k] else { return nil }
        return String(describing: v)
    }
    private func intVal(_ d: [String: Any]?, _ k: String) -> Int? {
        (d?[k] as? NSNumber)?.intValue
    }
    private func dblVal(_ d: [String: Any]?, _ k: String) -> Double? {
        (d?[k] as? NSNumber)?.doubleValue
    }
    private func boolVal(_ d: [String: Any]?, _ k: String) -> Bool? {
        (d?[k] as? NSNumber)?.boolValue
    }

    // MARK: 文案

    private var modelText: String {
        let m = str(dev, "model") ?? ""
        let b = str(dev, "brand") ?? ""
        return b.isEmpty ? m : "\(b) \(m)"
    }
    private var hardwareText: String {
        let board = str(dev, "board") ?? ""
        let hwName = str(dev, "hardware") ?? ""
        return [board, hwName].filter { !$0.isEmpty }.joined(separator: " · ")
    }
    private var androidText: String {
        let ver = str(dev, "androidVersion") ?? ""
        let sdk = intVal(dev, "sdk").map { "API \($0)" } ?? ""
        let patch = str(dev, "securityPatch").map { " · \($0)" } ?? ""
        return [ver, sdk].filter { !$0.isEmpty }.joined(separator: " ") + patch
    }
    private var appVersionText: String {
        let v = str(app, "versionName") ?? ""
        let code = intVal(app, "versionCode").map { "(\($0))" } ?? ""
        return [v, code].filter { !$0.isEmpty }.joined(separator: " ")
    }
    private var portText: String { str(app, "servicePort") ?? "" }
    private var clientText: String { intVal(app, "clients").map { "\($0) 台" } ?? "" }
    private var uptimeText: String {
        let ms = intVal(hw, "uptimeMs") ?? 0
        guard ms > 0 else { return "" }
        let s = ms / 1000
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d) 天 \(h) 小时" }
        if h > 0 { return "\(h) 小时 \(m) 分" }
        return "\(m) 分钟"
    }
    private var cpuUsageValue: Double {
        if let v = dblVal(hw, "cpuUsage"), v >= 0 { return v }
        if let v = intVal(hw, "cpuUsage"), v >= 0 { return Double(v) }
        return -1
    }
    private var cpuUsageText: String {
        cpuUsageValue >= 0 ? "整体占用 \(Int(cpuUsageValue))%" : "占用率不可用"
    }
    private var loadAvgText: String { str(hw, "loadAvg") ?? "—" }
    private var coreText: String { intVal(hw, "cpuCores").map { "\($0) 核" } ?? "" }
    private var freqText: String {
        guard let k = str(hw, "cpuFreqKHz"), let v = Double(k), v > 0 else { return "" }
        return v >= 1_000_000 ? String(format: "%.2f GHz", v / 1_000_000)
                              : String(format: "%.0f MHz", v / 1_000)
    }
    private var maxFreqText: String {
        guard let k = str(hw, "cpuMaxFreqKHz"), let v = Double(k), v > 0 else { return "" }
        return String(format: "%.2f GHz", v / 1_000_000)
    }
    private var tempText: String {
        guard let t = dblVal(hw, "cpuTemp"), t > 0 else { return "" }
        return String(format: "%.1f ℃", t)
    }
    private var memTotalText: String {
        guard let s = str(hw, "memTotal"), let v = Int64(s), v > 0 else { return "" }
        return Fmt.bytes(v)
    }
    private var memAvailText: String {
        guard let s = str(hw, "memAvailable"), let v = Int64(s), v > 0 else { return "" }
        return Fmt.bytes(v)
    }
    private var memUsedText: String {
        guard let t = str(hw, "memTotal"), let a = str(hw, "memAvailable"),
              let tv = Int64(t), let av = Int64(a) else { return "—" }
        return Fmt.bytes(max(0, tv - av))
    }
    private var internalStorageText: String {
        guard let t = intVal(storage, "internalTotal"), let f = intVal(storage, "internalFree"),
              t > 0 else { return "" }
        return "剩余 \(Fmt.bytes(f)) / \(Fmt.bytes(t))"
    }
    private var networkTypeText: String { str(net, "type") ?? "" }
    private var ssidText: String { str(net, "ssid") ?? "" }
    private var ipText: String { str(net, "ip") ?? "" }
    private var bandText: String {
        let b = str(wifi, "band") ?? ""
        let m = str(wifi, "mode") ?? ""
        return [b, m].filter { !$0.isEmpty }.joined(separator: " · ")
    }
    private var channelText: String {
        let ch = intVal(wifi, "channel").map(String.init) ?? ""
        let f = intVal(wifi, "freqMhz").map { "\($0) MHz" } ?? ""
        return [ch, f].filter { !$0.isEmpty }.joined(separator: " · ")
    }
    private var linkSpeedText: String {
        guard let l = intVal(wifi, "linkSpeed"), l > 0 else { return "" }
        return "\(l) Mbps"
    }
    private var rssiText: String {
        let r = intVal(wifi, "rssi").map { "\($0) dBm" } ?? ""
        let q = str(wifi, "quality") ?? ""
        return [r, q].filter { !$0.isEmpty }.joined(separator: " · ")
    }
    private var resolutionText: String {
        let w = intVal(scr, "width") ?? 0, h = intVal(scr, "height") ?? 0
        return w > 0 ? "\(w) × \(h)" : ""
    }
    private var refreshText: String {
        guard let r = dblVal(scr, "refreshRate"), r > 0 else { return "" }
        return String(format: "%.0f Hz", r)
    }
    private var densityText: String {
        guard let d = dblVal(scr, "densityDpi"), d > 0 else { return "" }
        return String(format: "%.0f dpi", d)
    }
    private var physicalSizeText: String { str(scr, "physicalSize") ?? "" }
    private var upRateText: String {
        guard let v = intVal(traffic, "upRate"), v >= 0 else { return "" }
        return Fmt.rate(Double(v))
    }
    private var downRateText: String {
        guard let v = intVal(traffic, "downRate"), v >= 0 else { return "" }
        return Fmt.rate(Double(v))
    }
    private var upTotalText: String {
        guard let v = intVal(traffic, "upTotal"), v >= 0 else { return "" }
        return Fmt.bytes(Int64(v))
    }
    private var downTotalText: String {
        guard let v = intVal(traffic, "downTotal"), v >= 0 else { return "" }
        return Fmt.bytes(Int64(v))
    }
    private var appsSummaryText: String {
        guard let a = apps else { return "读取中…" }
        let u = intVal(a, "userCount") ?? 0
        let s = intVal(a, "systemCount") ?? 0
        return "用户 \(u) · 系统 \(s)"
    }
    private var cameraText: String {
        let cams = (periph?["cameras"] as? [[String: Any]])?.count
        return cams.map { "\($0) 路" } ?? ""
    }
    private var sensorText: String {
        let s = (periph?["sensors"] as? [[String: Any]])?.count
        return s.map { "\($0) 个" } ?? ""
    }
    private var usbText: String {
        let u = (periph?["usbDevices"] as? [[String: Any]])?.count
        return u.map { $0 == 0 ? "无" : "\($0) 个" } ?? ""
    }
    private var gpsText: String {
        guard let g = gpsDict else { return "" }
        if let enabled = boolVal(g, "gpsEnabled") { return enabled ? "已开启" : "未开启" }
        return ""
    }
}

// MARK: - 已安装应用列表

private struct AppTarget {
    let packageName: String
    let name: String
}

struct DeviceAppsView: View {
    /// 原始 /api/device/apps 字典
    let apps: [String: Any]?

    @EnvironmentObject var conn: ConnectionStore

    @State private var query = ""
    /// 正在执行操作的包名（同一时刻只允许一个，防止连点把 adbd 打满）
    @State private var busyPackage: String?
    @State private var toast: String?
    @State private var showStopConfirm = false
    @State private var stopTarget = AppTarget(packageName: "", name: "")

    /// 车机端 v1.1.31+ 才有 /api/device/app/control
    private var supported: Bool { conn.carInfo?.appControl == true }
    private let selfPackage = "com.zood.carlink"

    private var allApps: [[String: Any]] {
        (apps?["apps"] as? [[String: Any]]) ?? []
    }
    private var filtered: [[String: Any]] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return allApps }
        return allApps.filter {
            ($0["name"] as? String)?.localizedCaseInsensitiveContains(q) == true
                || ($0["package"] as? String)?.localizedCaseInsensitiveContains(q) == true
        }
    }

    var body: some View {
        List {
            Section {
                ForEach(filtered.indices, id: \.self) { i in
                    appRow(filtered[i])
                }
                if filtered.isEmpty {
                    Text("没有匹配的应用")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            } header: {
                Text("用户应用 \(allApps.count) 个 · 系统应用 \(sysCount) 个")
            } footer: {
                Text(supported
                     ? "启动通过车机本地 ADB 回环拉起应用主界面；关闭为强制停止（force-stop），会中断该应用正在运行的任务。CarLink 自身不允许关闭，以免中断连接。系统应用只统计不列明细。"
                     : "需要车机端 v1.1.31 及以上版本才支持启动 / 关闭应用，请先升级车机端。系统应用只统计不列明细。")
            }
        }
        .listStyle(.insetGrouped)
        .searchable(text: $query, prompt: "搜索名称或包名")
        .navigationTitle("已安装应用")
        .navigationBarTitleDisplayMode(.inline)
        .overlay(alignment: .bottom) {
            if let t = toast {
                Text(t)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .background(Capsule().fill(Color.black.opacity(0.78)))
                    .padding(.horizontal, 24)
                    .padding(.bottom, 22)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: toast)
        .alert("关闭应用？", isPresented: $showStopConfirm) {
            Button("取消", role: .cancel) {}
            Button("关闭", role: .destructive) {
                perform("stop", target: stopTarget)
            }
        } message: {
            Text("将强制停止「\(stopTarget.name)」，它正在运行的任务会被中断。")
        }
    }

    private var sysCount: Int {
        (apps?["systemCount"] as? NSNumber)?.intValue ?? 0
    }

    @ViewBuilder
    private func appRow(_ a: [String: Any]) -> some View {
        let pkg = (a["package"] as? String) ?? ""
        let name = (a["name"] as? String) ?? pkg
        let isSelf = pkg == selfPackage
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 8) {
                Image(systemName: "app")
                    .foregroundStyle(CL.blue)
                Text(name)
                    .font(.subheadline.weight(.medium))
                if isSelf {
                    Text("当前服务")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.green.opacity(0.14)))
                }
                Spacer()
                Text((a["versionName"] as? String) ?? "")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(pkg)
                .font(.caption2)
                .foregroundStyle(.tertiary)
            HStack(spacing: 10) {
                if let sz = (a["apkSize"] as? NSNumber)?.int64Value, sz > 0 {
                    Text(Fmt.bytes(sz))
                }
                if let t = (a["firstInstallTime"] as? NSNumber)?.doubleValue, t > 0 {
                    Text("装于 ") + Text(Date(timeIntervalSince1970: t / 1000),
                                          format: .dateTime.year().month().day())
                }
                if let lu = (a["lastUpdateTime"] as? NSNumber)?.doubleValue,
                   lu > 0, lu != (a["firstInstallTime"] as? NSNumber)?.doubleValue {
                    Text("更新于 ") + Text(Date(timeIntervalSince1970: lu / 1000),
                                          format: .dateTime.year().month().day())
                }
            }
            .font(.caption2)
            .foregroundStyle(.secondary)

            if supported {
                HStack(spacing: 16) {
                    Button {
                        perform("start", target: AppTarget(packageName: pkg, name: name))
                    } label: {
                        Label("启动", systemImage: "play.fill")
                    }
                    Button(role: .destructive) {
                        stopTarget = AppTarget(packageName: pkg, name: name)
                        showStopConfirm = true
                    } label: {
                        Label("关闭", systemImage: "stop.fill")
                    }
                    .disabled(isSelf)
                    if busyPackage == pkg {
                        ProgressView().scaleEffect(0.75)
                    }
                    Spacer(minLength: 0)
                }
                .font(.caption.weight(.medium))
                .buttonStyle(.borderless)
                .disabled(busyPackage != nil)
                .padding(.top, 3)
            }
        }
        .padding(.vertical, 2)
    }

    private func perform(_ action: String, target: AppTarget) {
        guard let api = conn.client else {
            flash("未连接车机")
            return
        }
        guard busyPackage == nil else { return }
        busyPackage = target.packageName
        Task {
            defer { busyPackage = nil }
            do {
                let r = try await api.controlApp(packageName: target.packageName, action: action)
                if let ok = r["ok"] as? Bool, ok {
                    flash((r["message"] as? String)
                          ?? (action == "start" ? "已启动 \(target.name)" : "已关闭 \(target.name)"))
                } else {
                    flash((r["error"] as? String) ?? (r["message"] as? String) ?? "操作失败")
                }
            } catch {
                flash((error as? APIError)?.message ?? error.localizedDescription)
            }
        }
    }

    private func flash(_ text: String) {
        toast = text
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.4) {
            if toast == text { toast = nil }
        }
    }
}
