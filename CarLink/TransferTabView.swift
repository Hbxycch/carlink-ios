import SwiftUI
import PhotosUI
import UniformTypeIdentifiers

// MARK: - 传输 Tab：上传 + 下载队列

struct TransferTabView: View {
    @EnvironmentObject var conn: ConnectionStore
    @EnvironmentObject var uploads: UploadManager
    @EnvironmentObject var downloads: DownloadManager

    @State private var photoSelection: [PhotosPickerItem] = []
    @State private var showFileImporter = false

    var body: some View {
        NavigationStack {
            List {
                carFilesSection
                uploadSection
                downloadSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("传输")
        }
    }

    // MARK: - 车机文件（浏览内部存储 / SD 卡）

    private var carFilesSection: some View {
        Section {
            NavigationLink {
                CarFilesBrowserView()
            } label: {
                Label("浏览车机文件", systemImage: "externaldrive")
            }
            .disabled(!conn.isConnected)
        } header: {
            Text("车机文件")
        } footer: {
            Text(conn.isConnected
                 ? "浏览车机内部存储 / SD 卡 / U 盘里的任意文件（音乐、安装包、文档…）并下载到「文件」App › CarLink › 车机文件。"
                 : "未连接车机，连接后即可浏览车机文件。")
        }
    }

    // MARK: - 上传

    private var uploadSection: some View {
        Section {
            if !conn.isConnected {
                Label("未连接车机，连接后即可上传", systemImage: "wifi.slash")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            }
            PhotosPicker(selection: $photoSelection,
                         matching: .any(of: [.images, .videos]),
                         photoLibrary: .shared()) {
                Label("从相册选择上传", systemImage: "photo.stack")
            }
            .disabled(!conn.isConnected)
            .onChange(of: photoSelection) { items in
                for item in items {
                    guard let id = item.itemIdentifier else { continue }
                    uploads.uploadAsset(id, name: "照片/视频")
                }
                photoSelection.removeAll()
            }

            Button {
                showFileImporter = true
            } label: {
                Label("从「文件」App 选择上传", systemImage: "folder")
            }
            .disabled(!conn.isConnected)
            .fileImporter(isPresented: $showFileImporter,
                          allowedContentTypes: [.item],
                          allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    uploads.uploadFile(url: url)
                }
            }

            if !uploads.items.isEmpty {
                ForEach(uploads.items) { item in
                    UploadRow(item: item) {
                        uploads.remove(item)
                    }
                }
                if uploads.items.contains(where: { $0.state == .done || $0.state == .failed }) {
                    Button("清除已完成/失败") { uploads.clearFinished() }
                        .font(.subheadline)
                }
            }
        } header: {
            Text("上传到车机")
        } footer: {
            if let maxBytes = conn.carInfo?.switches?.receive, maxBytes == false {
                Text("车机端已关闭「文件接收」，上传会被拒绝。").foregroundStyle(.orange)
            } else {
                Text("上传分片进行（2 MB/片），中断后可重新发起。")
            }
        }
    }

    // MARK: - 下载队列

    private var downloadSection: some View {
        Section {
            if downloads.items.isEmpty {
                Text("暂无下载任务")
                    .foregroundStyle(.secondary)
            }
            if !downloads.items.isEmpty {
                HStack {
                    Button("全部暂停") { downloads.pauseAll() }
                        .font(.subheadline)
                    Spacer()
                    Button("全部取消") { downloads.cancelAll() }
                        .font(.subheadline)
                        .foregroundStyle(.red)
                    Spacer()
                    if downloads.items.contains(where: { $0.state == .done }) {
                        Button("清除已完成") { downloads.clearFinished() }
                            .font(.subheadline)
                    }
                }
            }
            ForEach(downloads.items) { item in
                DownloadRow(item: item,
                            onPause: { downloads.pause(item) },
                            onResume: { downloads.resume(item) },
                            onRetry: { downloads.retry(item) },
                            onCancel: { downloads.cancel(item) })
            }
        } header: {
            HStack {
                Text("下载队列")
                Spacer()
                if downloads.activeCount > 0 {
                    Text("进行中 \(downloads.activeCount)")
                        .font(.caption)
                        .foregroundStyle(.blue)
                }
            }
        } footer: {
            Text("视频下载后在本机转存 .mp4（画质不变）；转存失败的坏文件自动保存原始 .ts 到「文件」App › CarLink。播放视频时下载会自动挂起，退出播放后续跑。")
        }
    }
}

// MARK: - 上传行

struct UploadRow: View {
    @ObservedObject var item: UploadItem
    var onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Image(systemName: icon)
                    .foregroundStyle(iconColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.displayName)
                        .font(.subheadline)
                        .lineLimit(1)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if item.state == .done {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                }
                Button {
                    onRemove()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
            }
            if item.state == .preparing || item.state == .running {
                ProgressView(value: item.progress)
                Text("\(Fmt.bytes(item.sent)) / \(item.size > 0 ? Fmt.bytes(item.size) : "…")"
                     + (item.state == .running && item.speedBps > 0 ? " · \(Fmt.rate(item.speedBps))" : ""))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if let msg = item.message {
                Text(msg).font(.caption2).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }

    private var icon: String {
        switch item.state {
        case .preparing: return "hourglass"
        case .running: return "arrow.up.circle"
        case .done: return "checkmark.circle"
        case .failed: return "exclamationmark.circle"
        }
    }

    private var iconColor: Color {
        switch item.state {
        case .preparing: return .secondary
        case .running: return .blue
        case .done: return .green
        case .failed: return .orange
        }
    }

    private var statusText: String {
        switch item.state {
        case .preparing: return "准备中…"
        case .running: return item.speedBps > 0
            ? "上传中 \(Int(item.progress * 100))% · \(Fmt.rate(item.speedBps))"
            : "上传中 \(Int(item.progress * 100))%"
        case .done: return "已保存到车机 \(item.savedPath.map { "· \($0)" } ?? "")"
        case .failed: return item.message ?? "上传失败"
        }
    }
}

// MARK: - 下载行

struct DownloadRow: View {
    @ObservedObject var item: DownloadItem
    var onPause: () -> Void
    var onResume: () -> Void
    var onRetry: () -> Void
    var onCancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                CameraBadge(camera: item.file.cameraEnum)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.file.name)
                        .font(.subheadline)
                        .lineLimit(1)
                    Text(statusText)
                        .font(.caption)
                        .foregroundStyle(statusColor)
                }
                Spacer()
                controls
            }
            if item.state == .downloading || (item.state == .paused && item.received > 0) {
                ProgressView(value: item.progress)
                Text("\(Fmt.bytes(item.received)) / \(item.total > 0 ? Fmt.bytes(item.total) : Fmt.bytes(item.file.size))"
                     + (item.state == .downloading && item.speedBps > 0 ? " · \(Fmt.rate(item.speedBps))" : ""))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if let msg = item.message, item.state == .failed || item.state == .done {
                Text(msg).font(.caption2).foregroundStyle(item.state == .failed ? .orange : .secondary)
            }
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var controls: some View {
        HStack(spacing: 14) {
            switch item.state {
            case .downloading, .waiting:
                Button(action: onPause) { Image(systemName: "pause.circle") }
            case .paused, .failed:
                Button(action: onResume) { Image(systemName: "play.circle") }
            default:
                EmptyView()
            }
            Button(action: onCancel) {
                Image(systemName: "xmark.circle")
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.title3)
    }

    private var statusText: String {
        switch item.state {
        case .waiting: return "排队中"
        case .downloading: return item.speedBps > 0
            ? "下载中 \(Int(item.progress * 100))% · \(Fmt.rate(item.speedBps))"
            : "下载中 \(Int(item.progress * 100))%"
        case .paused: return "已暂停 \(Int(item.progress * 100))%"
        case .failed: return item.message ?? "下载失败"
        case .done: return item.savedAs ?? "已完成"
        }
    }

    private var statusColor: Color {
        switch item.state {
        case .failed: return .orange
        case .done: return .green
        default: return .secondary
        }
    }
}
