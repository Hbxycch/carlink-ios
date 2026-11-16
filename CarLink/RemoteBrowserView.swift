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
    @State private var showDownloads = false
    @State private var cameraFilter = "all"
    @State private var onlyUndownloaded = false
    @State private var filterDay: Date?
    @State private var showDatePicker = false
    @State private var selectMode = false
    @State private var selection = Set<String>()
    @State private var playerFile: CarFile?
    @State private var preview: CarFile?
    @AppStorage("remoteListMode") private var listMode = false

    private let gridColumns = [GridItem(.flexible(), spacing: 5), GridItem(.flexible(), spacing: 5)]

    var body: some View {
        VStack(spacing: 0) {
            AlbumTopBar(title: showDownloads ? "下载中" : category.title) {
                HStack(spacing: 8) {
                    if !showDownloads {
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
                    }
                }
            }

            SegmentBar(selection: $segment)

            SubTabsBar(category: $category,
                       showDownloads: $showDownloads,
                       badge: downloads.activeCount)

            if !showDownloads {
                chipsRow
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

    private func chip(_ title: String, active: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.system(size: 10.5, weight: active ? .semibold : .regular))
                .foregroundStyle(active ? Color(red: 0.05, green: 0.27, blue: 0.49) : Color.secondary)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(
                    Capsule().fill(active ? Color.blue.opacity(0.14) : Color(.tertiarySystemFill))
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
            }
            .padding(.bottom, 56)
        }
        .refreshable { await load() }
    }

    private func dateHeader(_ day: String, _ items: [CarFile]) -> some View {
        HStack {
            Button {
                showDatePicker = true
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "calendar")
                        .font(.system(size: 10))
                    Text(day)
                        .font(.system(size: 11.5, weight: .bold))
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold))
                }
                .foregroundStyle(Color.blue)
            }
            .buttonStyle(.plain)
            Spacer()
            Text("\(items.count) \(category == .snapshot ? "张" : "段") · 已下载 \(library.downloadedCount(in: items))")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    // MARK: 2 列大图（缩略图下方两行说明）

    private func gridCell(_ f: CarFile) -> some View {
        Button {
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
                        Image(systemName: "play.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(Color.black.opacity(0.28)))
                            .overlay(Circle().stroke(Color.white.opacity(0.95), lineWidth: 1.2))
                    } else {
                        Image(systemName: "photo.fill")
                            .font(.system(size: 16))
                            .foregroundStyle(f.cameraEnum.color.opacity(0.9))
                    }
                    if f.locked == true {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.system(size: 11))
                            .foregroundStyle(.red)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
                            .padding(.top, 2)
                    }
                    if library.isDownloaded(f) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 8, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 14, height: 14)
                            .background(Circle().fill(Color.green))
                            .padding(3)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    }
                    if selectMode {
                        Image(systemName: selection.contains(f.id) ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 17))
                            .foregroundStyle(.white)
                            .shadow(radius: 2)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .padding(4)
                    }
                }
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(selection.contains(f.id) ? Color.blue : Color.clear, lineWidth: 2)
                )

                HStack(spacing: 3) {
                    CameraBadge(camera: f.cameraEnum)
                    Text(Fmt.dateTime(f.date))
                        .font(.system(size: 10.5, weight: .semibold))
                        .lineLimit(1)
                }
                Text(subtitle(f))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.4).onEnded { _ in
                if !selectMode {
                    selectMode = true
                    selection.insert(f.id)
                }
            }
        )
    }

    // MARK: 列表行（56×34 缩略图 + 两行文字 + 右侧状态）

    private func listRow(_ f: CarFile) -> some View {
        HStack(spacing: 8) {
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
                Image(systemName: f.isVideo ? "play.fill" : "photo.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.white)
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
                            .foregroundStyle(.orange)
                    }
                }
                Text(subtitle(f))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 4)

            if selectMode {
                Image(systemName: selection.contains(f.id) ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 17))
                    .foregroundStyle(selection.contains(f.id) ? Color.blue : Color.secondary)
            } else if library.isDownloaded(f) {
                Image(systemName: "checkmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(.green)
            } else {
                // 行内下载按钮独立成 Button，其余区域走整行手势
                Button {
                    downloads.addOne(f, target: .dashcam(category))
                } label: {
                    Image(systemName: "arrow.down.circle")
                        .font(.system(size: 15))
                        .foregroundStyle(.blue)
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
        .onLongPressGesture(minimumDuration: 0.4) {
            if !selectMode {
                selectMode = true
                selection.insert(f.id)
            }
        }
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color.black.opacity(0.05))
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

        return Button {
            _ = downloads.add(pending, target: .dashcam(category))
            selection.removeAll()
            selectMode = false
        } label: {
            Text("下载所选（\(pending.count) 新）· \(Fmt.bytes(bytes))" + (skipped > 0 ? " · 自动跳过 \(skipped) 段已下载" : ""))
                .font(.system(size: 11.5, weight: .semibold))
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 9)
                .background(RoundedRectangle(cornerRadius: 10).fill(Color.blue))
                .shadow(color: Color.blue.opacity(0.35), radius: 6, x: 0, y: 3)
        }
        .buttonStyle(.plain)
        .disabled(pending.isEmpty)
        .padding(.horizontal, 10)
        .padding(.bottom, 8)
    }

    // MARK: 工具

    private func subtitle(_ f: CarFile) -> String {
        var parts = [Fmt.bytes(f.size)]
        if let d = DurationCache.duration(for: f.path) {
            parts.append(Fmt.duration(d))
        }
        if library.isDownloaded(f) {
            parts.append("已在本地")
        }
        return parts.joined(separator: " · ")
    }

    private func handleTap(_ f: CarFile) {
        if selectMode {
            if selection.contains(f.id) { selection.remove(f.id) }
            else { selection.insert(f.id) }
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
            files = try await api.dashcam(category: category)
        } catch {
            errorText = ConnectionStore.describe(error)
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
                        .foregroundStyle(active ? Color.blue : Color.secondary)
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
                    .fill(active ? Color.blue : Color.clear)
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
