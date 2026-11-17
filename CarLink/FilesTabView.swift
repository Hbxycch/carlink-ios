import SwiftUI

// MARK: - 文件 Tab 三段（对齐设计图：单页 + 记录仪文件 / 截图 / 本地文件）

enum FileSegment: String, CaseIterable, Identifiable {
    case remote = "记录仪文件"
    case screenshots = "截图"
    case local = "本地文件"

    var id: String { rawValue }
}

/// 跨 Tab 跳转请求（车机页快捷入口用）
struct FileSegmentJump: Equatable {
    var segment: FileSegment
    var category: MediaCategory?
}

// MARK: - 文件 Tab（单页三段式）

struct FilesTabView: View {
    @EnvironmentObject var conn: ConnectionStore
    @EnvironmentObject var nav: AppNav

    @State private var segment: FileSegment = .remote
    @State private var remoteCategory: MediaCategory = .loop
    @State private var didAppear = false

    var body: some View {
        NavigationStack {
            Group {
                switch segment {
                case .screenshots:
                    ScreenshotAlbumContent(segment: $segment)
                case .local:
                    LocalAlbumContent(segment: $segment)
                case .remote:
                    RemoteAlbumContent(segment: $segment, category: $remoteCategory)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(CL.page)
            .toolbar(.hidden, for: .navigationBar)
        }
        .onAppear {
            guard !didAppear else { return }
            didAppear = true
            // 设计规范：默认进入「记录仪文件 · 循环文件」，未连接车机则落在「本地文件」
            segment = conn.isConnected ? .remote : .local
        }
        .onChange(of: nav.filesJump) { jump in
            guard let jump = jump else { return }
            segment = jump.segment
            if let c = jump.category { remoteCategory = c }
            nav.filesJump = nil
        }
    }
}

// MARK: - 三段控件（对齐设计图 .seg：灰底 + 白色浮起选中块）

struct SegmentBar: View {
    @Binding var selection: FileSegment

    var body: some View {
        HStack(spacing: 0) {
            ForEach(FileSegment.allCases) { s in
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { selection = s }
                } label: {
                    Text(s.rawValue)
                        .font(.system(size: 12, weight: selection == s ? .semibold : .regular))
                        .foregroundStyle(selection == s ? Color.primary : Color.secondary)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                        .background(
                            Group {
                                if selection == s {
                                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                                        .fill(CL.card)
                                        .shadow(color: Color.black.opacity(0.12), radius: 1.5, x: 0, y: 1)
                                }
                            }
                        )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(
            RoundedRectangle(cornerRadius: 9, style: .continuous)
                .fill(Color(.tertiarySystemFill))
        )
        .padding(.horizontal, 12)
        .padding(.bottom, 6)
    }
}

// MARK: - 顶部标题行（对齐设计图 .album-top）

struct AlbumTopBar<Trailing: View>: View {
    let title: String
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 20, weight: .bold))
                .lineLimit(1)
            Spacer()
            trailing()
        }
        .padding(.horizontal, 12)
        .padding(.top, 4)
        .padding(.bottom, 6)
    }
}

/// 圆形图标按钮（对齐设计图 .acts span：26pt 灰底圆，hot 为蓝底白字）
struct CircleIcon: View {
    let system: String
    var hot: Bool = false

    var body: some View {
        Image(systemName: system)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(hot ? Color.white : Color.primary)
            .frame(width: 28, height: 28)
            .background(Circle().fill(hot ? Color.blue : Color(.tertiarySystemFill)))
    }
}

// MARK: - 截图段（设计图 3.2：3 列网格 + 底部下载条）

struct ScreenshotAlbumContent: View {
    @Binding var segment: FileSegment

    @EnvironmentObject var conn: ConnectionStore
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var downloads: DownloadManager

    @State private var files: [CarFile] = []
    @State private var loading = false
    @State private var errorText: String?
    @State private var selectMode = false
    @State private var selection = Set<String>()
    @State private var preview: CarFile?
    /// 分页：截图也可能上千张，一次只拉一页
    @State private var hasMore = false
    @State private var total = 0
    @State private var indexing = false
    @State private var scanned = 0
    @State private var loadingMore = false
    private let pageSize = 90

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 3), count: 3)

    var body: some View {
        VStack(spacing: 0) {
            AlbumTopBar(title: "截图") {
                HStack(spacing: 10) {
                    if selectMode {
                        Button {
                            if files.allSatisfy({ selection.contains($0.id) }) {
                                selection.removeAll()
                            } else {
                                selection = Set(files.map(\.id))
                            }
                        } label: {
                            Text(files.allSatisfy { selection.contains($0.id) } && !files.isEmpty ? "全不选" : "全选")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(CL.blue)
                        }
                        .buttonStyle(.plain)
                    }
                    Button {
                        selectMode.toggle()
                        if !selectMode { selection.removeAll() }
                    } label: {
                        Text(selectMode ? "完成" : "选择")
                            .font(.system(size: 13, weight: selectMode ? .semibold : .medium))
                            .foregroundStyle(files.isEmpty ? Color.secondary : CL.blue)
                    }
                    .buttonStyle(.plain)
                    .disabled(files.isEmpty)
                }
            }

            SegmentBar(selection: $segment)

            Text(subtitleText)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.bottom, 2)

            content

            if selectMode && !selection.isEmpty {
                downloadBar
            }
        }
        .task { await load() }
        .sheet(item: $preview) { f in
            ImagePreviewSheet(file: f)
        }
    }

    private var subtitleText: String {
        "Pictures/CarCap · \(total > 0 ? total : files.count) 张 · 由新到旧"
    }

    @ViewBuilder
    private var content: some View {
        if loading && files.isEmpty {
            ProgressView("加载中…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorText = errorText {
            VStack(spacing: 10) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.largeTitle)
                    .foregroundStyle(.orange)
                Text(errorText).font(.subheadline)
                Button("重试") { Task { await load() } }
                    .buttonStyle(.borderedProminent)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if files.isEmpty {
            emptyState(indexing ? "车机正在建立索引… 已扫描 \(scanned) 项" : "暂无截图")
        } else {
            ScrollView {
                VStack(spacing: 0) {
                    LazyVGrid(columns: columns, spacing: 3) {
                        ForEach(files) { f in
                            cell(f)
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    if hasMore {
                        ProgressView()
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 14)
                            .onAppear { Task { await loadMore() } }
                    }
                }
            }
            .refreshable { await load() }
        }
    }

    private func emptyState(_ text: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func cell(_ f: CarFile) -> some View {
        let badge = downloads.badge(for: f.path)
        let downloaded = library.isDownloaded(f)
        return Button {
            if selectMode {
                if selection.contains(f.id) { selection.remove(f.id) }
                else { selection.insert(f.id) }
            } else {
                preview = f
            }
        } label: {
            ZStack(alignment: .bottomLeading) {
                Rectangle()
                    .fill(Color(.secondarySystemFill))
                if let url = conn.client?.downloadURL(path: f.path) {
                    AsyncImage(url: url) { phase in
                        if case .success(let img) = phase {
                            img.resizable().scaledToFill()
                        } else {
                            Color.clear
                        }
                    }
                }
                LinearGradient(colors: [.clear, .black.opacity(0.35)],
                               startPoint: .center, endPoint: .bottom)
                Text(Fmt.time(f.date))
                    .font(.system(size: 8))
                    .foregroundStyle(.white)
                    .padding(4)

                if let b = badge, b.active {
                    DownloadProgressBadge(progress: b.progress, paused: b.paused)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if downloaded {
                    LocalCheckDot()
                        .padding(3)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                }

                if selectMode {
                    Image(systemName: selection.contains(f.id) ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 16))
                        .foregroundStyle(selection.contains(f.id) ? CL.blue : .white)
                        .shadow(radius: 2)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                        .padding(3)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .clipShape(RoundedRectangle(cornerRadius: 4))
            .overlay(
                RoundedRectangle(cornerRadius: 4)
                    .stroke(selection.contains(f.id) ? CL.blue : Color.clear, lineWidth: 2)
            )
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.35).onEnded { _ in
                if !selectMode {
                    selectMode = true
                    selection.insert(f.id)
                }
            }
        )
    }

    private var downloadBar: some View {
        Button {
            let picked = files.filter { selection.contains($0.id) }
            _ = downloads.add(picked, target: .screenshot)
            selection.removeAll()
            selectMode = false
        } label: {
            Text("下载所选（\(selection.count)）到相册")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 10)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.blue))
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 12)
        .padding(.bottom, 8)
    }

    private func load() async {
        guard let api = conn.client else {
            errorText = "未连接车机"
            files = []
            return
        }
        loading = true
        errorText = nil
        defer { loading = false }
        do {
            let page = try await api.filesPage(type: "screenshot", limit: pageSize, offset: 0)
            apply(page, replace: true)
            if indexing {
                loading = false
                var tries = 0
                while indexing, tries < 30, !Task.isCancelled {
                    tries += 1
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    guard let api2 = conn.client,
                          let p = try? await api2.filesPage(type: "screenshot",
                                                            limit: pageSize, offset: 0) else { return }
                    apply(p, replace: true)
                }
            }
        } catch {
            errorText = ConnectionStore.describe(error)
        }
    }

    private func loadMore() async {
        guard hasMore, !loadingMore, !indexing, let api = conn.client else { return }
        loadingMore = true
        defer { loadingMore = false }
        guard let page = try? await api.filesPage(type: "screenshot",
                                                  limit: pageSize, offset: files.count) else { return }
        apply(page, replace: false)
    }

    private func apply(_ page: FilePage, replace: Bool) {
        total = page.total
        hasMore = page.hasMore
        indexing = page.indexing
        scanned = page.scanned
        if replace {
            files = page.files
        } else {
            let exist = Set(files.map(\.id))
            files.append(contentsOf: page.files.filter { !exist.contains($0.id) })
        }
    }
}
