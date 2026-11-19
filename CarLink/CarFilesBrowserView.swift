import SwiftUI

// MARK: - 车机文件浏览器（传输 › 车机文件）
//
// 记录仪/截图之外的文件（音乐、安装包、文档、任何 SD 卡目录）在这里逐层浏览，
// 点一下直接下载到「文件」App › CarLink › 车机文件，复用下载队列（可暂停/续传）。

struct CarFilesBrowserView: View {
    @EnvironmentObject var conn: ConnectionStore
    @EnvironmentObject var downloads: DownloadManager
    @EnvironmentObject var uploads: UploadManager

    /// 打开时直接定位到的目录（如截图页跳转到 /sdcard/Pictures/CarCap）
    var initialPath: String = ""

    @State private var path: String = ""
    @State private var showUploadPicker = false
    @State private var entries: [BrowseEntry] = []
    @State private var parent: String?
    @State private var total = 0
    @State private var hasMore = false
    @State private var loading = false
    @State private var loadingMore = false
    @State private var errorText: String?
    @State private var offset = 0
    @State private var toast: String?

    private let pageSize = 300

    var body: some View {
        List {
            if !path.isEmpty {
                Section {
                    Button {
                        goParent()
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "arrow.up.left")
                            Text("返回上一级")
                            Spacer()
                        }
                        .font(.subheadline)
                    }
                } footer: {
                    Text(path)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
            }

            if let e = errorText {
                Section {
                    VStack(alignment: .leading, spacing: 8) {
                        Label(e, systemImage: "exclamationmark.triangle")
                            .font(.subheadline)
                            .foregroundStyle(.orange)
                        Button("重试") { Task { await load(reset: true) } }
                            .font(.subheadline)
                    }
                    .padding(.vertical, 2)
                }
            }

            if loading && entries.isEmpty {
                Section {
                    HStack {
                        ProgressView()
                        Text("正在读取目录…").font(.subheadline).foregroundStyle(.secondary)
                    }
                }
            } else if entries.isEmpty && errorText == nil && !loading {
                Section {
                    HStack {
                        Spacer()
                        VStack(spacing: 6) {
                            Image(systemName: "folder")
                                .font(.largeTitle)
                                .foregroundStyle(.tertiary)
                            Text(path.isEmpty ? "没有可浏览的存储卷" : "这个文件夹是空的")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                    }
                    .padding(.vertical, 18)
                }
            }

            if !entries.isEmpty {
                Section {
                    ForEach(entries) { e in
                        row(e)
                    }
                    if hasMore {
                        Button {
                            Task { await loadMore() }
                        } label: {
                            HStack {
                                Spacer()
                                if loadingMore {
                                    ProgressView()
                                } else {
                                    Text("加载更多（已显示 \(entries.count)/\(total)）")
                                        .font(.subheadline)
                                }
                                Spacer()
                            }
                        }
                    }
                } header: {
                    HStack {
                        Text(path.isEmpty ? "存储" : "共 \(total) 项")
                        Spacer()
                        if downloads.activeCount > 0 {
                            Text("下载中 \(downloads.runningCount)")
                                .font(.caption)
                                .foregroundStyle(.blue)
                        }
                    }
                } footer: {
                    Text("点文件名即可下载到「文件」App › CarLink › 车机文件；文件夹点进去继续浏览。")
                }
            }
            uploadSection
        }
        .listStyle(.insetGrouped)
        .navigationTitle(path.isEmpty ? "车机文件" : folderName(path))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if !path.isEmpty {
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showUploadPicker = true
                    } label: {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .disabled(!conn.isConnected)
                }
            }
        }
        .fileImporter(isPresented: $showUploadPicker,
                      allowedContentTypes: [.item],
                      allowsMultipleSelection: true) { result in
            if case .success(let urls) = result {
                let dir = path
                for u in urls { uploads.uploadFile(url: u, to: dir) }
                if !urls.isEmpty { showToast("已加入上传队列 · \(urls.count) 个文件") }
            }
        }
        .refreshable { await load(reset: true) }
        .task {
            if path.isEmpty, !initialPath.isEmpty { path = initialPath }
            if entries.isEmpty { await load(reset: true) }
        }
        .overlay(alignment: .bottom) {
            if let t = toast {
                Text(t)
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .background(Capsule().fill(Color.black.opacity(0.72)))
                    .padding(.bottom, 22)
                    .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.2), value: toast)
    }

    // MARK: 上传到当前目录

    private var uploadSection: some View {
        let items = uploads.items(in: path)
        return Group {
            if !items.isEmpty {
                Section {
                    ForEach(items) { item in
                        UploadRow(item: item) {
                            uploads.remove(item)
                        }
                    }
                } header: {
                    Text("上传到本文件夹")
                } footer: {
                    Text("上传完成后下拉刷新即可看到新文件。")
                }
            }
        }
    }

    // MARK: 行

    @ViewBuilder
    private func row(_ e: BrowseEntry) -> some View {
        Button {
            if e.dir {
                path = e.path
                entries = []
                total = 0
                hasMore = false
                offset = 0
                errorText = nil
                Task { await load(reset: true) }
            } else {
                download(e)
            }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: iconFor(e))
                    .font(.system(size: 17))
                    .foregroundStyle(e.dir ? CL.blue : Color.secondary)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 2) {
                    Text(e.name)
                        .font(.system(size: 14))
                        .lineLimit(1)
                        .foregroundStyle(.primary)

                    if e.dir {
                        if let free = e.freeBytes, e.root == true {
                            Text("剩余 \(Fmt.bytes(free))\(e.totalBytes.map { " / \(Fmt.bytes($0))" } ?? "")")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        } else {
                            Text("文件夹")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    } else {
                        Text(fileSubtitle(e))
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 4)

                if e.dir {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.tertiary)
                } else {
                    downloadBadge(e)
                }
            }
            .padding(.vertical, 1)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .swipeActions(edge: .trailing) {
            if !e.dir {
                Button {
                    download(e)
                } label: {
                    Label("下载", systemImage: "arrow.down.circle")
                }
                .tint(.blue)
            }
        }
    }

    @ViewBuilder
    private func downloadBadge(_ e: BrowseEntry) -> some View {
        if let b = downloads.badge(for: e.path) {
            DownloadingChip(progress: b.progress, paused: b.paused, speedBps: b.speedBps)
        } else if downloads.items.contains(where: { $0.id == e.path && $0.state == .done }) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(CL.green)
        } else {
            Image(systemName: "arrow.down.circle")
                .foregroundStyle(CL.blue)
        }
    }

    private func fileSubtitle(_ e: BrowseEntry) -> String {
        var parts: [String] = []
        if let s = e.size, s > 0 { parts.append(Fmt.bytes(s)) }
        if let m = e.modified, m > 0 {
            let d = Date(timeIntervalSince1970: m / 1000)
            let f = DateFormatter()
            f.dateFormat = "MM-dd HH:mm"
            parts.append(f.string(from: d))
        }
        if let ext = e.ext, !ext.isEmpty { parts.append(ext.uppercased()) }
        return parts.isEmpty ? "文件" : parts.joined(separator: " · ")
    }

    private func iconFor(_ e: BrowseEntry) -> String {
        if e.dir { return e.root == true ? "externaldrive.fill" : "folder.fill" }
        switch (e.ext ?? "").lowercased() {
        case "mp4", "mov", "ts", "mkv", "avi", "m4v", "mpg", "mpeg", "3gp":
            return "film"
        case "mp3", "wav", "flac", "aac", "m4a", "ogg", "ape":
            return "music.note"
        case "jpg", "jpeg", "png", "heic", "heif", "webp", "gif", "bmp":
            return "photo"
        case "apk":
            return "shippingbox"
        case "zip", "rar", "7z", "gz", "tar":
            return "archivebox"
        case "pdf":
            return "doc.richtext"
        case "txt", "log", "json", "xml", "csv", "md":
            return "doc.text"
        default:
            return "doc"
        }
    }

    private func folderName(_ p: String) -> String {
        let n = (p as NSString).lastPathComponent
        return n.isEmpty ? "车机文件" : n
    }

    // MARK: 动作

    private func goParent() {
        guard let p = parent else { return }
        path = p
        entries = []
        total = 0
        hasMore = false
        offset = 0
        errorText = nil
        Task { await load(reset: true) }
    }

    private func download(_ e: BrowseEntry) {
        if downloads.items.contains(where: { $0.id == e.path && ($0.state == .downloading || $0.state == .waiting) }) {
            showToast("已在下载队列中")
            return
        }
        let size = e.size ?? 0
        let file = CarFile(name: e.name,
                           path: e.path,
                           size: size,
                           modified: e.modified ?? 0,
                           format: (e.ext ?? "").uppercased(),
                           camera: "unknown",
                           locked: false,
                           thumb: nil)
        downloads.addOne(file, target: .carFile)
        showToast(size > 0 ? "已加入下载 · \(Fmt.bytes(size))" : "已加入下载")
    }

    private func showToast(_ text: String) {
        toast = text
        Task {
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            if toast == text { toast = nil }
        }
    }

    // MARK: 数据

    private func load(reset: Bool) async {
        guard let api = conn.client else {
            errorText = "未连接车机"
            return
        }
        if reset { offset = 0 }
        loading = true
        defer { loading = false }
        do {
            let r = try await api.browse(path: path, limit: pageSize, offset: offset)
            if let err = r.error, !err.isEmpty {
                errorText = err
            } else {
                errorText = nil
            }
            if reset {
                entries = r.entries
            } else {
                entries.append(contentsOf: r.entries)
            }
            parent = r.parent
            total = r.total ?? entries.count
            hasMore = r.hasMore ?? false
            offset = entries.count
            ConnLogStore.shared.log("BROWSE", "\(path.isEmpty ? "<根>" : path) → \(r.entries.count) 项")
        } catch {
            errorText = ConnectionStore.describe(error)
        }
    }

    private func loadMore() async {
        guard !loadingMore else { return }
        loadingMore = true
        defer { loadingMore = false }
        await load(reset: false)
    }
}
