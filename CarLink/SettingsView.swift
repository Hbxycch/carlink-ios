import SwiftUI

// MARK: - 设置页

struct SettingsView: View {
    @EnvironmentObject var conn: ConnectionStore
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var library: LibraryStore

    var body: some View {
        NavigationStack {
            List {
                connectionSection
                downloadSection
                aboutSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("设置")
        }
    }

    private var connectionSection: some View {
        Section("连接") {
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
            LabeledRow(icon: "number", title: "版本", value: "1.0.0 (1)")
            if let info = conn.carInfo {
                LabeledRow(icon: "car.2.fill", title: "车机端版本", value: "v\(info.version)")
            }
            LabeledRow(icon: "checkmark.seal", title: "播放内核",
                       value: "VLC（流式）+ AVPlayer（本地）")
        } header: {
            Text("关于")
        } footer: {
            Text("配套车机端 App：com.zood.carlink（建议 v1.1.9 及以上，支持分类与 mp4 转存）。")
        }
    }
}
