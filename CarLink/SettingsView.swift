import SwiftUI

// MARK: - 设置页

struct SettingsView: View {
    @EnvironmentObject var conn: ConnectionStore
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var downloads: DownloadManager
    @EnvironmentObject var updateChecker: UpdateChecker
    @Environment(\.openURL) private var openURL

    var body: some View {
        NavigationStack {
            List {
                connectionSection
                monitorSection
                downloadSection
                playbackSection
                appearanceSection
                aboutSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("设置")
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

            NavigationLink {
                ConnDiagnosticsView()
            } label: {
                HStack {
                    Label("连接诊断", systemImage: "stethoscope")
                    Spacer()
                    Text("\(ConnLogStore.shared.count) 条")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            NavigationLink {
                DeviceStatusView()
            } label: {
                Label("车机状态", systemImage: "gauge.with.dots.needle.bottom.50percent")
            }
            .disabled(!conn.isConnected)
            .foregroundStyle(conn.isConnected ? .primary : .secondary)

            NavigationLink {
                CameraStreamView()
            } label: {
                Label("摄像头推流", systemImage: "dot.radiowaves.left.and.right")
            }
            .disabled(!conn.isConnected)
            .foregroundStyle(conn.isConnected ? .primary : .secondary)

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

    // MARK: 车机监控（画面来源二选一）

    private var monitorSection: some View {
        Section {
            NavigationLink {
                MonitorView()
            } label: {
                Label("打开车机监控", systemImage: "video.fill")
            }
            .disabled(!conn.isConnected)
            .foregroundStyle(conn.isConnected ? .primary : .secondary)

            Picker("画面来源", selection: $settings.monitorSource) {
                ForEach(MonitorSource.allCases) { s in
                    Text(s.title).tag(s)
                }
            }
            .pickerStyle(.segmented)

            if settings.monitorSource != .snapshot {
                TextField("easyNVR 服务地址（http://ip:端口）", text: $settings.monitorNvrBase)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("HLS 地址模板", text: $settings.monitorHlsTemplate)
                    .keyboardType(.URL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
            }

            Picker("快照刷新", selection: $settings.monitorSnapshotFps) {
                Text("1 帧/秒").tag(1)
                Text("2 帧/秒").tag(2)
            }
        } header: {
            Text("车机监控")
        } footer: {
            Text("\(settings.monitorSource.detail)。HLS 走 easyNVR（连续视频、画质好，但手机必须能访问它）；快照流由车机每秒解一帧 640×360 JPEG，只要连上车机就能看，需车机端 v1.1.28+。模板占位符：{base} 服务地址、{key} 推流流名、{host} 车机推流主机。")
        }
    }

    private var appearanceSection: some View {
        Section {
            Picker("主题", selection: $settings.appearance) {
                ForEach(AppAppearance.allCases) { a in
                    Text(a.title).tag(a)
                }
            }
            .pickerStyle(.segmented)
        } header: {
            Text("外观")
        } footer: {
            Text("默认「跟随系统」，随 iOS 浅色/深色自动切换全部页面；也可强制保持浅色或深色。")
        }
    }

    private var playbackSection: some View {
        Section {
            Toggle("播完自动连播下一段", isOn: $settings.autoPlayNext)
        } header: {
            Text("播放")
        } footer: {
            Text("播放页支持上划看上一条、下滑看下一条，倍速按分类记忆，三路互切保持播放进度；在线与本地文件使用同一套播放界面。")
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

            Picker("同时下载", selection: $settings.maxConcurrentDownloads) {
                Text("1 个").tag(1)
                Text("2 个").tag(2)
                Text("3 个").tag(3)
                Text("4 个").tag(4)
            }
            .onChange(of: settings.maxConcurrentDownloads) { _ in
                downloads.reschedule()
            }

            Toggle("播放时暂停下载", isOn: $settings.pauseDownloadDuringPlayback)
                .onChange(of: settings.pauseDownloadDuringPlayback) { _ in
                    downloads.reschedule()
                }

            LabeledRow(icon: "internaldrive", title: "本地已占用",
                       value: Fmt.bytes(library.totalBytes))
            LabeledRow(icon: "photo.on.rectangle", title: "本地文件数",
                       value: "\(library.records.count) 个")
        } header: {
            Text("下载与保存")
        } footer: {
            Text("车机 CPU 与 WiFi 带宽都有限：播放视频时会自动挂起下载任务（退出播放后按断点续传继续），并发数调小也能让播放和下载都更稳。相册保存位置：系统相册 ›「CarLink 车机互传」相簿；转存失败的 .ts 回退文件位于「文件」App › CarLink。")
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
                Task { await updateChecker.check(silent: false) }
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
                            .foregroundStyle(CL.orange)
                    } else {
                        Text(UpdateChecker.currentDisplay)
                            .font(.caption)
                            .foregroundStyle(.secondary)
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
