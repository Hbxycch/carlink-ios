import SwiftUI

// MARK: - 记录仪文件段（设计图 3.3：四子分类 + 筛选 chips + 日期分组 + 2 列大图/列表）

struct RemoteAlbumContent: View {
    @Binding var segment: FileSegment
    @Binding var category: MediaCategory

    @EnvironmentObject var conn: ConnectionStore
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var downloads: DownloadManager

    @State private var files: [CarFile] = []
    @State private var loading = false
    @State private var errorText: String?
    /// 分页状态：SD 卡上万条录像时只先拉 60 条，滚动到底再追加
    @State private var hasMore = false
    @State private var total = 0
    @State private var indexing = false
    @State private var scanned = 0
    @State private var loadingMore = false
    private let pageSize = 60
    @State private var showDownloads = false
    @State private var cameraFilter = "all"
    @State private var onlyUndownloaded = false
    @State private var filterDay: Date?
    @State private var showDatePicker = false
    @State private var selectMode = false
    @State private var selection = Set<String>()
    /// 区间选择的锚点（先点一个，再长按另一个 = 整段选中）
    @State private var anchorID: String?
    @State private var playerFile: CarFile?
    @State private var preview: CarFile?
    @AppStorage("remoteListMode") private var listMode = false

    private let gridColumns = [GridItem(.flexible(), spacing: 5), GridItem(.flexible(), spacing: 5)]

    var body: some View {
        VStack(spacing: 0) {
            AlbumTopBar(title: showDownloads ? "下载中" : category.title) {
                HStack(spacing: 8) {
                    if !showDownloads {
                        if selectMode {
                            Button {
                                toggleSelectAll()
                            } label: {
                                Text(selectedAll ? "全不选" : "全选")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(CL.blue)
                            }
                            .buttonStyle(.plain)
                            Button {
                                selectMode = false
                                selection.removeAll()
                                anchorID = nil
                            } label: {
                                Text("完成")
                                    .font(.system(size: 13, weight: .semibold))
                                    .foregroundStyle(CL.blue)
                            }
                            .buttonStyle(.plain)
                        } else {
                            Button {
                                downloadAllPending()
                            } label: {
                                CircleIcon(system: "arrow.down.circle")
                            }
                            .buttonStyle(.plain)
                            .disabled(pendingFiles.isEmpty)

                            Button {
                                listMode.toggle()
                            } label: {
                                CircleIcon(system: listMode ? "square.grid.2x2" : "list.bullet", hot: true)
                            }
                            .buttonStyle(.plain)

                            Button {
                                withAnimation(.easeInOut(duration: 0.15)) { selectMode = true }
                            } label: {
                                Text("选择")
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(CL.blue)
                            }
                            .buttonStyle(.plain)
                            .disabled(filtered.isEmpty)
                        }
                    }
                }
            }

            SegmentBar(selection: $segment)

            SubTabsBar(category: $category,
                       showDownloads: $showDownloads,
                       badge: downloads.activeCount)

            if !showDownloads {
                chipsRow
                dateFilterBar
            }

            content

            if !showDownloads && !selection.isEmpty {
                batchBar
            }
        }
        .task(id: reloadKey) { await load() }
        .sheet(isPresented: $showDatePicker) {
            DatePickerSheet(days: availableDays, selected: $filterDay)
                .presentationDetents([.medium, .large])
        }
        .fullScreenCover(item: $playerFile) { f in
            PlayerView(file: f, siblings: filtered)
        }
        .sheet(item: $preview) { f in
            ImagePreviewSheet(file: f)
        }
        .onChange(of: category) { _ in
            selection.removeAll()
            selectMode = false
            anchorID = nil
        }
        .onChange(of: filterDay) { _ in
            selection.removeAll()
            anchorID = nil
        }
    }

    private var reloadKey: String {
        "\(category.rawValue)-\(showDownloads ? "dl" : "files")"
    }

    // MARK: 数据

    private var filtered: [CarFile] {
        var out = files
        if cameraFilter != "all" {
            out = out.filter { ($0.camera ?? "unknown") == cameraFilter }
        }
        if onlyUndownloaded {
            out = out.filter { !library.isDownloaded($0) }
        }
        if let day = filterDay {
            let key = Fmt.day(day)
            out = out.filter { Fmt.day($0.date) == key }
        }
        return out
    }

    private var grouped: [(String, [CarFile])] {
        let groups = Dictionary(grouping: filtered) { Fmt.day($0.date) }
        return groups.keys.sorted(by: >).map { ($0, groups[$0]!) }
    }

    private var availableDays: Set<Date> {
        Set(files.map { Calendar.current.startOfDay(for: $0.date) })
    }

    private var pendingFiles: [CarFile] {
        filtered.filter { !library.isDownloaded($0) }
    }

    private var selectedAll: Bool {
        !filtered.isEmpty && filtered.allSatisfy { selection.contains($0.id) }
    }

    // MARK: 多选工具（全选 / 区间 / 整组）

    private func toggleSelectAll() {
        if selectedAll {
            selection.removeAll()
            anchorID = nil
        } else {
            selection = Set(filtered.map(\.id))
        }
    }

    private func toggleSelection(_ f: CarFile) {
        if selection.contains(f.id) {
            selection.remove(f.id)
        } else {
            selection.insert(f.id)
        }
        anchorID = f.id
    }

    /// 长按 = 从锚点到当前项整段选中（连续几十段一次搞定）
    private func selectRange(to f: CarFile) {
        guard let anchor = anchorID,
              let i = filtered.firstIndex(where: { $0.id == anchor }),
              let j = filtered.firstIndex(where: { $0.id == f.id }) else {
            selection.insert(f.id)
            anchorID = f.id
            return
        }
        let range = i <= j ? i...j : j...i
        for k in range { selection.insert(filtered[k].id) }
        anchorID = f.id
    }

    private func selectGroup(_ items: [CarFile]) {
        for f in items { selection.insert(f.id) }
    }

    // MARK: 筛选 chips（全部 / 前摄 / 后摄 / 自由 / 未下载）

    private var chipsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 5) {
                chip("全部", active: cameraFilter == "all" && !onlyUndownloaded) {
                    cameraFilter = "all"
                    onlyUndownloaded = false
                }
                chip("前摄", active: cameraFilter == "front") { cameraFilter = "front" }
                chip("后摄", active: cameraFilter == "rear") { cameraFilter = "rear" }
                chip("自由", active: cameraFilter == "free") { cameraFilter = "free" }
                chip("未下载", active: onlyUndownloaded) { onlyUndownloaded.toggle() }
            }
            .padding(.horizontal, 12)
        }
        .padding(.vertical, 5)
    }

    // MARK: 常驻日期筛选栏（设计图 3.3：📅 日期 ⌄ · N 段 · 已下载 M）

    private var dateFilterBar: some View {
        HStack {
            Button {
                showDatePicker = true
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "calendar")
                        .font(.system(size: 10))
                    Text(filterDay == nil ? "全部日期" : Fmt.day(filterDay!))
                        .font(.system(size: 11.5, weight: .bold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(CL.blue)
            }
            .buttonStyle(.plain)

            Spacer()

            Text("\(filtered.count) \(category == .snapshot ? "张" : "段") · 已下载 \(library.downloadedCount(in: filtered))")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(CL.page)
    }

    private func chip(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? CL.blueInk : Color.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(active ? CL.blueBg : Color(.tertiarySystemFill))
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if showDownloads {
            DownloadsListView()
        } else if !conn.isConnected {
            VStack(spacing: 10) {
                Image(systemName: "wifi.slash")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                Text("未连接车机")
                    .foregroundStyle(.secondary)
                Text("到「车机」页连接后可浏览记录仪文件\n下载过的内容在「本地文件」中查看")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if loading && files.isEmpty {
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
        } else if filtered.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "tray")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                Text(emptyText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if listMode {
            listBody
        } else {
            gridBody
        }
    }

    private var emptyText: String {
        if filterDay != nil { return "该日期暂无文件" }
        if onlyUndownloaded { return "已全部下载" }
        return "暂无文件"
    }

    private var gridBody: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(grouped, id: \.0) { day, items in
                    dateHeader(day, items)
                    LazyVGrid(columns: gridColumns, spacing: 5) {
                        ForEach(items) { f in
                            gridCell(f)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                }
                moreFooter
            }
            .padding(.bottom, 56)
        }
        .refreshable { await load() }
    }

    private var listBody: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(grouped, id: \.0) { day, items in
                    dateHeader(day, items)
                    ForEach(items) { f in
                        listRow(f)
                    }
                }
                moreFooter
            }
            .padding(.bottom, 56)
        }
        .refreshable { await load() }
    }

    /// 列表底部：索引进度 / 自动加载下一页 / 已到底提示
    @ViewBuilder
    private var moreFooter: some View {
        if indexing {
            HStack(spacing: 8) {
                ProgressView().scaleEffect(0.8)
                Text("车机正在建立索引… 已扫描 \(scanned) 项")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        } else if hasMore {
            ProgressView()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
                .onAppear { Task { await loadMore() } }
        } else if total > pageSize {
            Text("已全部加载 · 共 \(total) \(category == .snapshot ? "张" : "段")")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
        }
    }

    private func dateHeader(_ day: String, _ items: [CarFile]) -> some View {
        HStack(spacing: 6) {
            Text(day)
                .font(.system(size: 11.5, weight: .bold))
            Spacer()
            Text("\(items.count) \(category == .snapshot ? "张" : "段")")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            if selectMode {
                let allIn = items.allSatisfy { selection.contains($0.id) }
                Button {
                    if allIn {
                        for f in items { selection.remove(f.id) }
                    } else {
                        selectGroup(items)
                    }
                } label: {
                    Text(allIn ? "取消本组" : "选本组")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(CL.blue)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Capsule().fill(CL.blueBg))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    // MARK: 2 列大图（缩略图下方两行说明）

    private func gridCell(_ f: CarFile) -> some View {
        let badge = downloads.badge(for: f.path)
        let downloaded = library.isDownloaded(f)
        return Button {
            handleTap(f)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                ZStack {
                    RoundedRectangle(cornerRadius: 6)
                        .fill(
                            LinearGradient(colors: [f.cameraEnum.color.opacity(0.32), f.cameraEnum.color.opacity(0.16)],
                                           startPoint: .topLeading, endPoint: .bottomTrailing)
                        )
                    if let url = conn.client?.thumbURL(f) {
                        AsyncImage(url: url) { phase in
                            if case .success(let img) = phase {
                                img.resizable().scaledToFill()
                            } else {
                                Color.clear
                            }
                        }
                    }
                    if f.isVideo {
                        // 下载中时让位给进度环，避免图标叠在一起
                        if !(badge?.active ?? false) {
                            Image(systemName: "play.fill")
                                .font(.system(size: 9, weight: .bold))
                                .foregroundStyle(.white)
                                .frame(width: 24, height: 24)
                                .background(Circle().fill(Color.black.opacity(0.28)))
                                .overlay(Circle().stroke(Color.white.opacity(0.95), lineWidth: 1.2))
                        }
                    } else {
                        Image(systemName: "photo.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(f.cameraEnum.color.opacity(0.9))
                    }
                    if f.locked == true {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(CL.red)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            .padding(.top, 2)
                    }
                    // 下载中：封面上直接给进度（环形 + 百分比），不用翻到「下载中」才看得到
                    if let b = badge, b.active {
                        VStack(spacing: 2) {
                            DownloadProgressBadge(progress: b.progress, paused: b.paused)
                            if b.state == .waiting {
                                Text("排队")
                                    .font(.system(size: 8, weight: .bold))
                                    .foregroundStyle(.white)
                                    .padding(.horizontal, 4)
                                    .background(Capsule().fill(Color.black.opacity(0.55)))
                            }
                        }
                    } else if downloaded {
                        LocalCheckDot()
                            .padding(3)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    }
                    if selectMode {
                        Image(systemName: selection.contains(f.id) ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 17))
                            .foregroundStyle(selection.contains(f.id) ? CL.blue : .white)
                            .background(Circle().fill(Color.black.opacity(selection.contains(f.id) ? 0 : 0.18)))
                            .shadow(radius: 2)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .padding(4)
                    }
                }
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(selection.contains(f.id) ? CL.blue : Color.clear, lineWidth: 2)
                )

                HStack(spacing: 3) {
                    CameraBadge(camera: f.cameraEnum)
                    Text(Fmt.dateTime(f.date))
                        .font(.system(size: 10.5, weight: .semibold))
                        .lineLimit(1)
                }
                caption(f)
            }
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.35).onEnded { _ in
                if selectMode {
                    selectRange(to: f)
                } else {
                    selectMode = true
                    selection.insert(f.id)
                    anchorID = f.id
                }
            }
        )
    }

    // MARK: 列表行（56×34 缩略图 + 两行文字 + 右侧状态）

    private func listRow(_ f: CarFile) -> some View {
        let badge = downloads.badge(for: f.path)
        let downloaded = library.isDownloaded(f)
        return HStack(spacing: 8) {
            ZStack {
                RoundedRectangle(cornerRadius: 5)
                    .fill(f.cameraEnum.color.opacity(0.22))
                if let url = conn.client?.thumbURL(f) {
                    AsyncImage(url: url) { phase in
                        if case .success(let img) = phase {
                            img.resizable().scaledToFill()
                        } else {
                            Color.clear
                        }
                    }
                }
                if let b = badge, b.active {
                    DownloadProgressBadge(progress: b.progress, paused: b.paused)
                } else {
                    Image(systemName: f.isVideo ? "play.fill" : "photo.fill")
                        .font(.system(size: 9))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: 56, height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 5))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 3) {
                    CameraBadge(camera: f.cameraEnum)
                    Text(Fmt.dateTime(f.date))
                        .font(.system(size: 11, weight: .semibold))
                    if f.locked == true {
                        Image(systemName: "lock.fill")
                            .font(.system(size: 8))
                            .foregroundStyle(CL.orange)
                    }
                }
                caption(f)
            }
            Spacer(minLength: 4)

            if selectMode {
                Image(systemName: selection.contains(f.id) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17))
                    .foregroundStyle(selection.contains(f.id) ? CL.blue : Color.secondary)
            } else if let b = badge, b.active {
                DownloadingChip(progress: b.progress, paused: b.paused)
            } else if downloaded {
                LocalTag(compact: true)
            } else {
                // 行内下载按钮独立成 Button，其余区域走整行手势
                Button {
                    downloads.addOne(f, target: .dashcam(category))
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 15))
                        .foregroundStyle(CL.blue)
                        .frame(width: 30, height: 30)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
        .contentShape(Rectangle())
        .onTapGesture { handleTap(f) }
        .onLongPressGesture(minimumDuration: 0.35) {
            if selectMode {
                selectRange(to: f)
            } else {
                selectMode = true
                selection.insert(f.id)
                anchorID = f.id
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(CL.line)
                .frame(height: 0.5)
                .padding(.leading, 76)
        }
    }

    // MARK: 底部批量下载条（对齐设计图 .alb-foot）

    private var batchBar: some View {
        let picked = filtered.filter { selection.contains($0.id) }
        let pending = picked.filter { !library.isDownloaded($0) }
        let bytes = pending.reduce(Int64(0)) { $0 + $1.size }
        let skipped = picked.count - pending.count

        return VStack(spacing: 6) {
            HStack(spacing: 10) {
                Text("已选 \(picked.count) / \(filtered.count)")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.secondary)
                Button {
                    selection = Set(filtered.map(\.id).filter { !selection.contains($0) })
                } label: {
                    Text("反选")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(CL.blue)
                }
                .buttonStyle(.plain)
                Button {
                    selection.removeAll()
                    anchorID = nil
                } label: {
                    Text("清空")
                        .font(.system(size: 10.5, weight: .medium))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                Spacer()
                Text(skipped > 0 ? "自动跳过 \(skipped) 段已下载" : "")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 4)

            Button {
                _ = downloads.add(pending, target: .dashcam(category))
                selection.removeAll()
                selectMode = false
                anchorID = nil
            } label: {
                Text("下载所选（\(pending.count) 新）· \(Fmt.bytes(bytes))")
                    .font(.system(size: 11.5, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 9)
                    .background(RoundedRectangle(cornerRadius: 10).fill(CL.blue))
                    .shadow(color: CL.blue.opacity(0.35), radius: 6, x: 0, y: 3)
            }
            .buttonStyle(.plain)
            .disabled(pending.isEmpty)
        }
        .padding(.horizontal, 10)
        .padding(.top, 4)
        .padding(.bottom, 8)
        .background(.ultraThinMaterial)
    }

    // MARK: 工具

    private func subtitle(_ f: CarFile) -> String {
        var parts = [Fmt.bytes(f.size)]
        if let d = DurationCache.duration(for: f.path) {
            parts.append(Fmt.duration(d))
        }
        return parts.joined(separator: " · ")
    }

    /// 副标题（大小 · 时长 · 已在本地），「已在本地」用设计图的 #1D7A34 绿
    private func caption(_ f: CarFile) -> some View {
        HStack(spacing: 0) {
            Text(subtitle(f))
                .foregroundStyle(.secondary)
            if library.isDownloaded(f) {
                Text(" · ")
                    .foregroundStyle(.secondary)
                Text("已在本地")
                    .foregroundStyle(CL.okText)
                    .fontWeight(.semibold)
            }
        }
        .font(.system(size: 9.5))
        .lineLimit(1)
    }

    private func handleTap(_ f: CarFile) {
        if selectMode {
            toggleSelection(f)
        } else if f.isVideo {
            playerFile = f
        } else {
            preview = f
        }
    }

    private func downloadAllPending() {
        let pending = pendingFiles
        guard !pending.isEmpty else { return }
        _ = downloads.add(pending, target: .dashcam(category))
    }

    private func load() async {
        guard !showDownloads else { return }
        guard let api = conn.client else {
            files = []
            errorText = nil
            return
        }
        loading = true
        errorText = nil
        defer { loading = false }
        do {
            let page = try await api.filesPage(type: "dashcam", category: category.apiValue,
                                               limit: pageSize, offset: 0)
            apply(page, replace: true)
            if indexing {
                // 车机在后台建索引（上万条录像首次访问）：先结束 loading 显示进度，再自动重试
                loading = false
                await retryWhileIndexing()
            }
        } catch {
            errorText = ConnectionStore.describe(error)
        }
    }

    /// 车机建索引期间轮询，最多 45 秒
    private func retryWhileIndexing() async {
        var tries = 0
        while indexing, tries < 30, !Task.isCancelled {
            tries += 1
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            guard let api = conn.client else { return }
            guard let p = try? await api.filesPage(type: "dashcam", category: category.apiValue,
                                                   limit: pageSize, offset: 0) else { return }
            apply(p, replace: true)
        }
    }

    /// 滚动到底追加下一页
    private func loadMore() async {
        guard hasMore, !loadingMore, !indexing, let api = conn.client else { return }
        loadingMore = true
        defer { loadingMore = false }
        guard let page = try? await api.filesPage(type: "dashcam", category: category.apiValue,
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

// MARK: - 四子分类 Tab（循环 / 抓拍 / 锁影 / 下载中）

struct SubTabsBar: View {
    @Binding var category: MediaCategory
    @Binding var showDownloads: Bool
    let badge: Int

    var body: some View {
        HStack(spacing: 0) {
            tab(MediaCategory.loop.title, active: !showDownloads && category == .loop) {
                showDownloads = false
                category = .loop
            }
            tab(MediaCategory.snapshot.title, active: !showDownloads && category == .snapshot) {
                showDownloads = false
                category = .snapshot
            }
            tab(MediaCategory.locked.title, active: !showDownloads && category == .locked) {
                showDownloads = false
                category = .locked
            }
            tab("下载中", active: showDownloads, badge: badge) {
                showDownloads = true
            }
        }
        .padding(.horizontal, 8)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(.separator).opacity(0.6))
                .frame(height: 0.5)
        }
    }

    private func tab(_ title: String, active: Bool, badge: Int = 0, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 4) {
                HStack(spacing: 3) {
                    Text(title)
                        .font(.system(size: 11, weight: active ? .bold : .regular))
                        .foregroundStyle(active ? CL.blue : Color.secondary)
                        .lineLimit(1)
                    if badge > 0 {
                        Text("\(badge)")
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.white)
                            .padding(.horizontal, 4)
                            .padding(.vertical, 0.5)
                            .background(Capsule().fill(Color.red))
                    }
                }
                Rectangle()
                    .fill(active ? CL.blue : Color.clear)
                    .frame(width: 34, height: 2)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 7)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 截图预览（弹窗）

struct ImagePreviewSheet: View {
    @EnvironmentObject var conn: ConnectionStore
    @EnvironmentObject var downloads: DownloadManager
    let file: CarFile
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            VStack {
                if let url = conn.client?.downloadURL(path: file.path) {
                    AsyncImage(url: url) { img in
                        img.resizable().scaledToFit()
                    } placeholder: {
                        ProgressView()
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
            .navigationTitle(Fmt.dateTime(file.date))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        downloads.addOne(file, target: .screenshot)
                    } label: {
                        Label("存相册", systemImage: "square.and.arrow.down")
                    }
                }
            }
        }
    }
}
