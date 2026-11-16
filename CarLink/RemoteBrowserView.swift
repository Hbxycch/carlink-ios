import SwiftUI

// MARK: - 远端文件浏览页（截图 + 记录仪三分类共用）

enum RemoteSource: Hashable {
    case screenshots
    case dashcam(MediaCategory)

    var title: String {
        switch self {
        case .screenshots: return "截图"
        case .dashcam(let c): return c.title
        }
    }

    var downloadTarget: DownloadTarget {
        switch self {
        case .screenshots: return .screenshot
        case .dashcam(let c): return .dashcam(c)
        }
    }
}

struct RemoteBrowserView: View {
    let source: RemoteSource

    @EnvironmentObject var conn: ConnectionStore
    @EnvironmentObject var downloads: DownloadManager
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var settings: SettingsStore

    @State private var files: [CarFile] = []
    @State private var loading = false
    @State private var errorText: String?
    @State private var selectMode = false
    @State private var selection = Set<String>()
    @State private var filterDay: Date?
    @State private var showDatePicker = false
    @State private var playerFile: CarFile?
    @State private var previewFile: CarFile?
    @AppStorage("remoteListMode") private var listMode = false

    var body: some View {
        content
            .navigationTitle(source.title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { toolbarContent }
            .task { await load() }
            .refreshable { await load() }
            .sheet(isPresented: $showDatePicker) {
                DatePickerSheet(days: availableDays, selected: $filterDay)
                    .presentationDetents([.medium, .large])
            }
            .fullScreenCover(item: $playerFile) { f in
                PlayerView(file: f, siblings: files)
            }
            .sheet(item: $previewFile) { f in
                ImagePreviewSheet(file: f)
            }
            .onChange(of: library.records.count) { _ in }   // 触发已下载✓刷新
    }

    // MARK: - 数据

    private func load() async {
        guard let api = conn.client else {
            errorText = "未连接车机"
            return
        }
        loading = true
        errorText = nil
        defer { loading = false }
        do {
            switch source {
            case .screenshots:
                files = try await api.screenshots()
            case .dashcam(let c):
                files = try await api.dashcam(category: c)
            }
        } catch {
            errorText = ConnectionStore.describe(error)
        }
    }

    private var filtered: [CarFile] {
        guard let day = filterDay else { return files }
        let key = Fmt.day(day)
        return files.filter { Fmt.day($0.date) == key }
    }

    private var availableDays: Set<Date> {
        Set(files.map { Calendar.current.startOfDay(for: $0.date) })
    }

    private var availableDayKeys: Set<String> {
        Set(files.map { Fmt.day($0.date) })
    }

    // MARK: - 列表

    @ViewBuilder
    private var content: some View {
        if loading && files.isEmpty {
            ProgressView("加载中…")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let errorText {
            VStack(spacing: 12) {
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
                Text(filterDay == nil ? "暂无文件" : "该日期暂无文件")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if listMode {
            fileList(filtered)
        } else {
            gridList(filtered)
        }
    }

    private func fileList(_ items: [CarFile]) -> some View {
        List {
            ForEach(groupedByDay(items), id: \.0) { day, dayFiles in
                Section {
                    ForEach(dayFiles) { f in
                        FileListRow(file: f,
                                    downloaded: library.isDownloaded(f),
                                    selected: selection.contains(f.id),
                                    selectMode: selectMode) {
                            handleTap(f)
                        } onLongPress: {
                            if !selectMode { enterSelect(f) }
                        }
                    }
                } header: {
                    Text("\(day) · \(dayFiles.count) 个 · 已下载 \(library.downloadedCount(in: dayFiles))")
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func gridList(_ items: [CarFile]) -> some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
                ForEach(groupedByDay(items), id: \.0) { day, dayFiles in
                    Section {
                        ForEach(dayFiles) { f in
                            FileGridCell(file: f,
                                         downloaded: library.isDownloaded(f),
                                         selected: selection.contains(f.id),
                                         selectMode: selectMode,
                                         thumbURL: conn.client?.thumbURL(f)) {
                                handleTap(f)
                            } onLongPress: {
                                if !selectMode { enterSelect(f) }
                            }
                        }
                    } header: {
                        HStack {
                            Text("\(day) · \(dayFiles.count) 个 · 已下载 \(library.downloadedCount(in: dayFiles))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        .padding(.top, 6)
                    }
                }
            }
            .padding(.horizontal, 12)
        }
    }

    private func groupedByDay(_ items: [CarFile]) -> [(String, [CarFile])] {
        let groups = Dictionary(grouping: items) { Fmt.day($0.date) }
        return groups.keys.sorted(by: >).map { ($0, groups[$0]!) }
    }

    // MARK: - 工具栏

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .topBarTrailing) {
            Button {
                showDatePicker = true
            } label: {
                Image(systemName: filterDay == nil ? "calendar" : "calendar.badge.checkmark")
            }

            Button {
                listMode.toggle()
            } label: {
                Image(systemName: listMode ? "square.grid.2x2" : "list.bullet")
            }

            if selectMode {
                Button(selectAllLabel) { toggleSelectAll() }
                Button("下载") { batchDownload() }
                    .disabled(selection.isEmpty)
                Button("取消") {
                    selectMode = false
                    selection.removeAll()
                }
            } else {
                Button {
                    // 未进入选择模式时：一键下载全部未下载项
                    let pending = files.filter { !library.isDownloaded($0) }
                    if !pending.isEmpty {
                        _ = downloads.add(pending, target: source.downloadTarget)
                    }
                } label: {
                    Image(systemName: "arrow.down.circle")
                }
                .disabled(files.isEmpty)
            }
        }
    }

    private var selectAllLabel: String {
        if selection.count == filtered.count { "取消全选" }
        else { "全选" }
    }

    // MARK: - 交互

    private func handleTap(_ f: CarFile) {
        if selectMode {
            if selection.contains(f.id) { selection.remove(f.id) }
            else { selection.insert(f.id) }
        } else if f.isVideo {
            playerFile = f
        } else {
            previewFile = f
        }
    }

    private func enterSelect(_ f: CarFile) {
        selectMode = true
        selection.insert(f.id)
    }

    private func toggleSelectAll() {
        if selection.count == filtered.count { selection.removeAll() }
        else { selection = Set(filtered.map(\.id)) }
    }

    private func batchDownload() {
        let picked = filtered.filter { selection.contains($0.id) }
        let n = downloads.add(picked, target: source.downloadTarget)
        if n < picked.count {
            // 已跳过已下载项
        }
        selection.removeAll()
        selectMode = false
    }
}

// MARK: - 列表行

struct FileListRow: View {
    let file: CarFile
    let downloaded: Bool
    let selected: Bool
    let selectMode: Bool
    let onTap: () -> Void
    let onLongPress: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 10) {
                if selectMode {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(selected ? .blue : .secondary)
                }
                CameraBadge(camera: file.cameraEnum)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 6) {
                        Text(Fmt.dateTime(file.date))
                            .font(.subheadline)
                            .foregroundStyle(.primary)
                        if file.locked == true {
                            Image(systemName: "lock.fill")
                                .font(.caption2)
                                .foregroundStyle(.orange)
                        }
                    }
                    Text("\(Fmt.bytes(file.size))\(durationText)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if downloaded {
                    Label("已在本地", systemImage: "checkmark.circle.fill")
                        .font(.caption)
                        .foregroundStyle(.green)
                        .labelStyle(.iconOnly)
                }
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
        .onLongPressGesture(perform: onLongPress)
    }

    private var durationText: String {
        if let d = DurationCache.duration(for: file.path) {
            return " · \(Fmt.duration(d))"
        }
        return ""
    }
}

// MARK: - 缩略图格子（2 列）

struct FileGridCell: View {
    let file: CarFile
    let downloaded: Bool
    let selected: Bool
    let selectMode: Bool
    let thumbURL: URL?
    let onTap: () -> Void
    let onLongPress: () -> Void

    var body: some View {
        Button(action: onTap) {
            ZStack(alignment: .bottomLeading) {
                thumb
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))

                // 底部信息条
                HStack(spacing: 5) {
                    CameraBadge(camera: file.cameraEnum)
                    Text(Fmt.time(file.date))
                        .font(.caption2)
                        .fontWeight(.medium)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Spacer(minLength: 0)
                    Text(Fmt.bytes(file.size))
                        .font(.caption2)
                        .lineLimit(1)
                }
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .bottomLeading)
                .background(
                    LinearGradient(colors: [.clear, .black.opacity(0.55)],
                                   startPoint: .top, endPoint: .bottom)
                )
                .clipShape(RoundedRectangle(cornerRadius: 10))

                // 锁影标记
                if file.locked == true {
                    Image(systemName: "lock.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                }

                // 已下载 ✓
                if downloaded {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.green)
                        .shadow(radius: 2)
                        .padding(6)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                }

                // 选择圈
                if selectMode {
                    Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                        .font(.title3)
                        .foregroundStyle(.white)
                        .shadow(radius: 2)
                        .padding(8)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }
            }
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(selected ? Color.blue : .clear, lineWidth: 3)
            )
        }
        .buttonStyle(.plain)
        .onLongPressGesture(perform: onLongPress)
    }

    @ViewBuilder
    private var thumb: some View {
        if let url = thumbURL {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    AnyView(img.resizable().scaledToFill())
                case .failure:
                    AnyView(placeholder)
                default:
                    AnyView(ZStack {
                        Rectangle().fill(Color.secondary.opacity(0.15))
                        ProgressView()
                    })
                }
            }
        } else {
            placeholder
        }
    }

    private var placeholder: some View {
        ZStack {
            Rectangle().fill(file.cameraEnum.color.opacity(0.25))
            Image(systemName: "video.fill")
                .font(.title)
                .foregroundStyle(file.cameraEnum.color)
        }
    }
}

// MARK: - 截图预览

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
