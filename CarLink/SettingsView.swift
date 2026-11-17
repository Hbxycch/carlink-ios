import SwiftUI

// MARK: - 设置页

struct SettingsView: View {
    @EnvironmentObject var conn: ConnectionStore
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var updateChecker: UpdateChecker
    @Environment(\.openURL) private var openURL

    @State private var showUpdateDetail = false

    var body: some View {
        NavigationStack {
            List {
                connectionSection
                downloadSection
                playbackSection
                aboutSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("设置")
            .alert("发现新版本", isPresented: $showUpdateDetail, presenting: updateChecker.available) { info in
                Button("前往下载") {
                    if let url = URL(string: info.ipaUrl) { openURL(url) }
                    updateChecker.dismiss()
                }
                Button("稍后再说", role: .cancel) { updateChecker.dismiss() }
            } message: { info in
                Text("v\(info.displayVersion) 已发布\(info.date.map { "（\($0)）" } ?? "")\n\(info.changelog ?? "")\n\n下载 ipa 后通过 Sideloadly 重装即可，数据不受影响。")
            }
        }
    }

    private var connectionSection: some View {
        Section {
            if conn.isConnected {
                LabeledRow(icon: "car.fill", title: "当前车机", value: conn.deviceName)
                LabeledRow(icon: "link", title: "地址",
                           value: "\(conn.client?.host ?? ""):\(conn.client?.port ?? 8080)")
                Button(role: .destructive) {
                    conn.disconnect()
                } label: {
                    Label("断开连接", systemImage: "xmark.circle")
                }
            } else {
                LabeledRow(icon: "car.2", title: "当前车机", value: "未连接")
            }

            Toggle("自动连接上次车机", isOn: $settings.autoConnect)

            if !conn.savedDevices.isEmpty {
                ForEach(conn.savedDevices) { d in
                    HStack {
                        Text(d.name)
                        Spacer()
                        Text("\(d.host):\(d.port)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .swipeActions {
                        Button(role: .destructive) { conn.forget(d) } label: {
                            Label("忘记", systemImage: "trash")
                        }
                    }
                }
            }
        } header: {
            Text("连接")
        } footer: {
            Text("开启后，每次进入 App 或回到前台时自动连接最近一次使用的车机（约 20 秒内不重复尝试）。")
        }
    }

    private var playbackSection: some View {
        Section {
            Toggle("播完自动连播下一段", isOn: $settings.autoPlayNext)
        } header: {
            Text("播放")
        } footer: {
            Text("循环文件按时间顺序播完自动切到下一段；倍速按分类记忆，三路互切保持播放进度。")
        }
    }

    private var downloadSection: some View {
        Section {
            Toggle("下载后保存到系统相册", isOn: $settings.saveToPhotos)
            Toggle("仅 WiFi 下下载", isOn: $settings.wifiOnlyDownload)

            if settings.wifiOnlyDownload && !settings.isWiFi {
                Label("当前不在 WiFi 网络，下载任务将等待", systemImage: "exclamationmark.triangle")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }

            LabeledRow(icon: "internaldrive", title: "本地已占用",
                       value: Fmt.bytes(library.totalBytes))
            LabeledRow(icon: "photo.on.rectangle", title: "本地文件数",
                       value: "\(library.records.count) 个")
        } header: {
            Text("下载与保存")
        } footer: {
            Text("相册保存位置：系统相册 ›「CarLink 车机互传」相簿；转存失败的 .ts 回退文件位于「文件」App › CarLink › CarLink 目录。关闭相册保存后，所有下载文件均存入「文件」App。")
        }
    }

    private var aboutSection: some View {
        Section {
            LabeledRow(icon: "app.badge", title: "App", value: "CarLink 车机互传")
            LabeledRow(icon: "number", title: "版本", value: UpdateChecker.currentDisplay)
            if let info = conn.carInfo {
                LabeledRow(icon: "car.2.fill", title: "车机端版本", value: "v\(info.version)")
            }
            LabeledRow(icon: "checkmark.seal", title: "播放内核",
                       value: "VLC（流式）+ AVPlayer（本地）")

            Button {
                Task {
                    await updateChecker.check(silent: false)
                    if updateChecker.available != nil { showUpdateDetail = true }
                }
            } label: {
                HStack {
                    Label("检查更新", systemImage: "arrow.triangle.2.circlepath")
                    Spacer()
                    if updateChecker.checking {
                        ProgressView()
                    } else if let text = updateChecker.lastResultText {
                        Text(text)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    } else if updateChecker.available != nil {
                        Text("有新版本")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
            .disabled(updateChecker.checking)
        } header: {
            Text("关于")
        } footer: {
            Text("配套车机端 App：com.zood.carlink（建议 v1.1.10 及以上，mp4 转存已隔离崩溃进程）。更新包托管于 smartdash-ota.w.zood.org，下载 ipa 后用 Sideloadly 重装。")
        }
    }
}
