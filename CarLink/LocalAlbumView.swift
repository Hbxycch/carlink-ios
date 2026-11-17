import SwiftUI
import AVKit
import Photos

// MARK: - 本地文件段（设计图 3.6：与记录仪文件同级，同名三子分类）
//
// 视频点开不再用系统播放器，而是复用「记录仪文件」里的 PlayerView：
// 倍速、三路互切、上一/下一条、全屏、上下滑切换全都一致。

/// 播放请求（把整段视频条目一起传进统一播放器）
struct LocalPlayRequest: Identifiable {
    let id = UUID()
    let items: [PlayItem]
    let startID: String
}

struct LocalAlbumContent: View {
    @Binding var segment: FileSegment

    @EnvironmentObject var library: LibraryStore

    @State private var category: MediaCategory = .loop
    @State private var filterDay: Date?
    @State private var showDatePicker = false
    @State private var viewer: LocalRecord?
    @State private var playRequest: LocalPlayRequest?
    @State private var selectMode = false
    @State private var selection = Set<String>()
    @State private var anchorID: String?
    @State private var confirmDelete = false
    @AppStorage("localListMode") private var listMode = true

    private let gridColumns = [GridItem(.flexible(), spacing: 5), GridItem(.flexible(), spacing: 5)]

    private var records: [LocalRecord] {
        library.records(category: category)
    }

    private var filtered: [LocalRecord] {
        guard let day = filterDay else { return records }
        let key = Fmt.day(day)
        return records.filter { Fmt.day($0.date) == key }
    }

    private var grouped: [(String, [LocalRecord])] {
        let groups = Dictionary(grouping: filtered) { Fmt.day($0.date) }
        return groups.keys.sorted(by: >).map { ($0, groups[$0]!) }
    }

    private var availableDays: Set<Date> {
        Set(records.map { Calendar.current.startOfDay(for: $0.date) })
    }

    private var occupiedBytes: Int64 {
        records.reduce(Int64(0)) { $0 + $1.sourceSize }
    }

    private var selectedRecords: [LocalRecord] {
        filtered.filter { selection.contains($0.id) }
    }

    var body: some View {
        VStack(spacing: 0) {
            AlbumTopBar(title: "本地文件") {
                HStack(spacing: 8) {
                    if selectMode && !selection.isEmpty {
                        Button {
                            confirmDelete = true
                        } label: {
                            CircleIcon(system: "trash")
                        }
                        .buttonStyle(.plain)
                    }
                    if selectMode {
                        Button {
                            if filtered.allSatisfy({ selection.contains($0.id) }) && !filtered.isEmpty {
                                selection.removeAll()
                            } else {
                                selection = Set(filtered.map(\.id))
                            }
                        } label: {
                            Text(filtered.allSatisfy { selection.contains($0.id) } && !filtered.isEmpty ? "全不选" : "全选")
                                .font(.system(size: 13, weight: .medium))
                                .foregroundStyle(CL.blue)
                        }
                        .buttonStyle(.plain)
                    } else {
                        Button {
                            listMode.toggle()
                        } label: {
                            CircleIcon(system: listMode ? "square.grid.2x2" : "list.bullet", hot: true)
                        }
                        .buttonStyle(.plain)
                    }
                    Button {
                        selectMode.toggle()
                        if !selectMode {
                            selection.removeAll()
                            anchorID = nil
                        }
                    } label: {
                        Text(selectMode ? "完成" : "选择")
                            .font(.system(size: 13, weight: selectMode ? .semibold : .medium))
                            .foregroundStyle(records.isEmpty ? Color.secondary : CL.blue)
                    }
                    .buttonStyle(.plain)
                    .disabled(records.isEmpty)
                }
            }

            SegmentBar(selection: $segment)

            LocalTabsBar(category: $category)

            dateHead

            content
        }
        .sheet(isPresented: $showDatePicker) {
            DatePickerSheet(days: availableDays, selected: $filterDay)
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $viewer) { r in
            LocalViewerSheet(record: r)
        }
        .fullScreenCover(item: $playRequest) { req in
            PlayerView(items: req.items, startID: req.startID)
        }
        .confirmationDialog("删除 \(selection.count) 个本地副本？车机上的原片不受影响。",
                            isPresented: $confirmDelete, titleVisibility: .visible) {
            Button("删除", role: .destructive) {
                for r in selectedRecords {
                    library.remove(r)
                }
                selection.removeAll()
                selectMode = false
            }
            Button("取消", role: .cancel) {}
        }
        .onChange(of: category) { _ in
            selection.removeAll()
            selectMode = false
        }
    }

    private var dateHead: some View {
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
                .foregroundStyle(Color.blue)
            }
            .buttonStyle(.plain)
            Spacer()
            Text(records.isEmpty ? "已占用 0 B" : "已占用 \(Fmt.bytes(occupiedBytes))")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.top, 6)
        .padding(.bottom, 4)
    }

    @ViewBuilder
    private var content: some View {
        if records.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "tray")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                Text("暂无本地文件")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Text("到「记录仪文件」下载，完成后自动出现在这里\n视频存系统相册「CarLink 车机互传」相簿")
                    .font(.caption)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.tertiary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if filtered.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "tray")
                    .font(.largeTitle)
                    .foregroundStyle(.tertiary)
                Text("该日期暂无文件")
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

    private var listBody: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(grouped, id: \.0) { day, items in
                    groupHead(day, items)
                    ForEach(items) { r in
                        row(r)
                    }
                }
            }
            .padding(.bottom, 12)
        }
    }

    private var gridBody: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(grouped, id: \.0) { day, items in
                    groupHead(day, items)
                    LazyVGrid(columns: gridColumns, spacing: 5) {
                        ForEach(items) { r in
                            cell(r)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.bottom, 8)
                }
            }
            .padding(.bottom, 12)
        }
    }

    private func groupHead(_ day: String, _ items: [LocalRecord]) -> some View {
        HStack(spacing: 6) {
            Text(day)
                .font(.system(size: 11.5, weight: .bold))
            Spacer()
            Text("\(items.count) 个")
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            if selectMode {
                let allIn = items.allSatisfy { selection.contains($0.id) }
                Button {
                    if allIn {
                        for r in items { selection.remove(r.id) }
                    } else {
                        for r in items { selection.insert(r.id) }
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
        .padding(.top, 7)
        .padding(.bottom, 3)
    }

    private func row(_ r: LocalRecord) -> some View {
        Button {
            handleTap(r)
        } label: {
            HStack(spacing: 8) {
                ZStack {
                    RoundedRectangle(cornerRadius: 5)
                        .fill(r.camera.color.opacity(0.22))
                    LocalThumb(record: r)
                        .clipShape(RoundedRectangle(cornerRadius: 5))
                }
                .frame(width: 56, height: 34)
                .clipShape(RoundedRectangle(cornerRadius: 5))

                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 3) {
                        CameraBadge(camera: r.camera)
                        Text(Fmt.dateTime(r.date))
                            .font(.system(size: 11, weight: .semibold))
                    }
                    Text(subtitle(r))
                        .font(.system(size: 9.5))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 4)

                if selectMode {
                    Image(systemName: selection.contains(r.id) ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 17))
                        .foregroundStyle(selection.contains(r.id) ? CL.blue : Color.secondary)
                } else {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11))
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.35).onEnded { _ in
                if selectMode {
                    selectRange(to: r)
                } else {
                    selectMode = true
                    selection.insert(r.id)
                    anchorID = r.id
                }
            }
        )
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(CL.line)
                .frame(height: 0.5)
                .padding(.leading, 76)
        }
    }

    private func cell(_ r: LocalRecord) -> some View {
        Button {
            handleTap(r)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                ZStack {
                    LocalThumb(record: r)
                    if r.kind == .fileTS || !isPhoto(r) {
                        Image(systemName: "play.fill")
                            .font(.system(size: 9, weight: .bold))
                            .foregroundStyle(.white)
                            .frame(width: 24, height: 24)
                            .background(Circle().fill(Color.black.opacity(0.28)))
                            .overlay(Circle().stroke(Color.white.opacity(0.95), lineWidth: 1.2))
                    }
                    if selectMode {
                        Image(systemName: selection.contains(r.id) ? "checkmark.circle.fill" : "circle")
                            .font(.system(size: 17))
                            .foregroundStyle(selection.contains(r.id) ? CL.blue : .white)
                            .shadow(radius: 2)
                            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                            .padding(4)
                    }
                }
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 6))
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(selection.contains(r.id) ? CL.blue : Color.clear, lineWidth: 2)
                )

                HStack(spacing: 3) {
                    CameraBadge(camera: r.camera)
                    Text(Fmt.dateTime(r.date))
                        .font(.system(size: 10.5, weight: .semibold))
                        .lineLimit(1)
                }
                Text(subtitle(r))
                    .font(.system(size: 9.5))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
        .buttonStyle(.plain)
        .simultaneousGesture(
            LongPressGesture(minimumDuration: 0.35).onEnded { _ in
                if selectMode {
                    selectRange(to: r)
                } else {
                    selectMode = true
                    selection.insert(r.id)
                    anchorID = r.id
                }
            }
        )
    }

    private func subtitle(_ r: LocalRecord) -> String {
        var parts = [Fmt.bytes(r.sourceSize)]
        if let d = r.duration {
            parts.append(Fmt.duration(d))
        } else if r.kind == .fileTS {
            parts.append("TS 回退")
        }
        parts.append(downloadedText(r.downloadedAt))
        return parts.joined(separator: " · ")
    }

    private func downloadedText(_ d: Date) -> String {
        let c = Calendar.current.dateComponents([.month, .day], from: d)
        return "\(c.month ?? 0)-\(c.day ?? 0) 下载"
    }

    private func isPhoto(_ r: LocalRecord) -> Bool {
        let exts: Set<String> = ["png", "jpg", "jpeg", "webp", "heic", "heif", "bmp", "gif"]
        return exts.contains((r.name as NSString).pathExtension.lowercased())
    }

    private func handleTap(_ r: LocalRecord) {
        if selectMode {
            if selection.contains(r.id) { selection.remove(r.id) }
            else { selection.insert(r.id) }
            anchorID = r.id
        } else if isPhoto(r) {
            viewer = r
        } else {
            // 视频：进统一播放器（倍速 / 三路 / 上下滑切换都与在线播放一致）
            let items = filtered.filter { !isPhoto($0) }.map { PlayItem(record: $0) }
            if !items.isEmpty {
                playRequest = LocalPlayRequest(items: items,
                                               startID: PlayItem(record: r).id)
            }
        }
    }

    /// 长按 = 从锚点整段选中（一次删掉一整天几十个回退文件）
    private func selectRange(to r: LocalRecord) {
        guard let anchor = anchorID,
              let i = filtered.firstIndex(where: { $0.id == anchor }),
              let j = filtered.firstIndex(where: { $0.id == r.id }) else {
            selection.insert(r.id)
            anchorID = r.id
            return
        }
        let range = i <= j ? i...j : j...i
        for k in range { selection.insert(filtered[k].id) }
        anchorID = r.id
    }
}

// MARK: - 本地三子分类 Tab（无「下载中」）

struct LocalTabsBar: View {
    @Binding var category: MediaCategory

    var body: some View {
        HStack(spacing: 0) {
            ForEach(MediaCategory.allCases) { c in
                Button {
                    category = c
                } label: {
                    VStack(spacing: 4) {
                        Text(c.title)
                            .font(.system(size: 11, weight: category == c ? .bold : .regular))
                            .foregroundStyle(category == c ? Color.blue : Color.secondary)
                        Rectangle()
                            .fill(category == c ? Color.blue : Color.clear)
                            .frame(width: 34, height: 2)
                    }
                    .frame(maxWidth: .infinity)
                    .padding(.top, 7)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(Color(.separator).opacity(0.6))
                .frame(height: 0.5)
        }
    }
}

// MARK: - 本地缩略图（相册资产 / 回退文件用图标）

struct LocalThumb: View {
    let record: LocalRecord
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(record.camera.color.opacity(0.25))
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if record.kind == .fileTS {
                Image(systemName: "film")
                    .font(.system(size: 13))
                    .foregroundStyle(record.camera.color)
            } else {
                ProgressView()
                    .scaleEffect(0.6)
            }
        }
        .task(id: record.id) {
            switch record.kind {
            case .photoAlbum:
                PhotoSaver.loadAssetImage(localId: record.localRef, size: CGSize(width: 480, height: 270)) { img in
                    DispatchQueue.main.async { self.image = img }
                }
            case .fileTS:
                // 本地封面：车机缩略图缓存 / 图片直读 / mp4 首帧
                if let img = await LocalThumbStore.load(record: record) {
                    self.image = img
                }
            }
        }
    }
}

// MARK: - 本地查看（图片 / AVPlayer 播放 + 分享 + 删除本地副本）

struct LocalViewerSheet: View {
    @EnvironmentObject var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let record: LocalRecord

    @State private var shareURL: URL?
    @State private var showShare = false
    @State private var confirmDelete = false

    var body: some View {
        NavigationStack {
            Group {
                if record.kind == .fileTS {
                    tsViewer
                } else {
                    albumViewer
                }
            }
            .navigationTitle(Fmt.dateTime(record.date))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("关闭") { dismiss() }
                }
                ToolbarItemGroup(placement: .topBarTrailing) {
                    Button {
                        prepareShare()
                    } label: {
                        Label("分享", systemImage: "square.and.arrow.up")
                    }
                    Button(role: .destructive) {
                        confirmDelete = true
                    } label: {
                        Label("删除本地副本", systemImage: "trash")
                    }
                }
            }
            .sheet(isPresented: $showShare) {
                if let url = shareURL {
                    ShareSheet(items: [url])
                }
            }
            .confirmationDialog("删除本地副本？车机上的原片不受影响。", isPresented: $confirmDelete, titleVisibility: .visible) {
                Button("删除", role: .destructive) {
                    library.remove(record)
                    dismiss()
                }
                Button("取消", role: .cancel) {}
            }
        }
    }

    // 已下载视频：相册资产走 AVPlayerItem（兼容 AVComposition），
    // 「文件」App 的 .ts 回退文件走 VLC 内核——两者都不再出现「黑屏 + 静音图标」
    @ViewBuilder
    private var tsViewer: some View {
        if isPhotoRecord {
            fileImageView
        } else {
            LocalVideoView(fileURL: LibraryStore.tsDirectory.appending(path: record.localRef))
        }
    }

    /// 「文件」App 里的图片（关闭相册保存时截图会落成文件）
    @ViewBuilder
    private var fileImageView: some View {
        let url = LibraryStore.tsDirectory.appending(path: record.localRef)
        if let img = UIImage(contentsOfFile: url.path) {
            Image(uiImage: img)
                .resizable()
                .scaledToFit()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            Text("图片已丢失或无法读取")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    // 相册资产：图片直接显示，视频走 AVPlayerItem
    @ViewBuilder
    private var albumViewer: some View {
        if isPhotoRecord {
            PhotoAssetImageView(localId: record.localRef)
        } else {
            LocalVideoView(localId: record.localRef)
        }
    }

    private var isPhotoRecord: Bool {
        // 抓拍/截图记录都是图片；循环/锁影是视频。以扩展名判断更稳妥
        let imgExts: Set<String> = ["png", "jpg", "jpeg", "webp", "heic"]
        return imgExts.contains((record.name as NSString).pathExtension.lowercased())
    }

    private func prepareShare() {
        if record.kind == .fileTS {
            shareURL = LibraryStore.tsDirectory.appending(path: record.localRef)
            showShare = true
        } else if isPhotoRecord {
            PhotoSaver.loadAssetImage(localId: record.localRef, size: CGSize(width: 4096, height: 4096)) { img in
                guard let img = img, let data = img.jpegData(compressionQuality: 0.95) else { return }
                let url = FileManager.default.temporaryDirectory.appending(path: record.name)
                try? data.write(to: url)
                DispatchQueue.main.async {
                    self.shareURL = url
                    self.showShare = true
                }
            }
        } else {
            Task {
                if let u = await LocalVideoResolver.exportURL(localId: record.localRef) {
                    self.shareURL = u
                    self.showShare = true
                }
            }
        }
    }
}

struct PhotoAssetImageView: View {
    let localId: String
    @State private var image: UIImage?

    var body: some View {
        Group {
            if let image = image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFit()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProgressView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            PhotoSaver.loadAssetImage(localId: localId) { img in
                DispatchQueue.main.async { self.image = img }
            }
        }
    }
}

struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ vc: UIActivityViewController, context: Context) {}
}
