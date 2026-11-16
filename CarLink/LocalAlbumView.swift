import SwiftUI
import AVKit
import Photos

// MARK: - 本地文件页（相册相簿 + 回退文件）

struct LocalAlbumView: View {
    let category: MediaCategory

    @EnvironmentObject var library: LibraryStore
    @State private var filterDay: Date?
    @State private var showDatePicker = false
    @State private var viewer: LocalRecord?
    @AppStorage("localListMode") private var listMode = false

    private var records: [LocalRecord] {
        library.records(category: category)
    }

    private var filtered: [LocalRecord] {
        guard let day = filterDay else { return records }
        let key = Fmt.day(day)
        return records.filter { Fmt.day($0.date) == key }
    }

    var body: some View {
        Group {
            if records.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "tray")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text("暂无本地文件")
                        .foregroundStyle(.secondary)
                    Text("到「记录仪文件」下载，完成后自动出现在这里")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if listMode {
                listBody
            } else {
                gridBody
            }
        }
        .navigationTitle(category.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
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
            }
        }
        .sheet(isPresented: $showDatePicker) {
            DatePickerSheet(days: availableDays, selected: $filterDay)
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $viewer) { r in
            LocalViewerSheet(record: r)
        }
    }

    private var availableDays: Set<Date> {
        Set(records.map { Calendar.current.startOfDay(for: $0.date) })
    }

    private var grouped: [(String, [LocalRecord])] {
        let groups = Dictionary(grouping: filtered) { Fmt.day($0.date) }
        return groups.keys.sorted(by: >).map { ($0, groups[$0]!) }
    }

    private var listBody: some View {
        List {
            ForEach(grouped, id: \.0) { day, dayRecords in
                Section("\(day) · \(dayRecords.count) 个") {
                    ForEach(dayRecords) { r in
                        row(r)
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private var gridBody: some View {
        ScrollView {
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
                ForEach(grouped, id: \.0) { day, dayRecords in
                    Section {
                        ForEach(dayRecords) { r in
                            cell(r)
                        }
                    } header: {
                        Text("\(day) · \(dayRecords.count) 个")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.top, 6)
                    }
                }
            }
            .padding(.horizontal, 12)
        }
    }

    private func row(_ r: LocalRecord) -> some View {
        Button {
            viewer = r
        } label: {
            HStack(spacing: 10) {
                CameraBadge(camera: r.camera)
                VStack(alignment: .leading, spacing: 3) {
                    Text(Fmt.dateTime(r.date))
                        .font(.subheadline)
                        .foregroundStyle(.primary)
                    HStack(spacing: 6) {
                        Text(r.name).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                        if r.kind == .fileTS {
                            Text("TS")
                                .font(.caption2)
                                .padding(.horizontal, 4)
                                .background(RoundedRectangle(cornerRadius: 3).fill(Color.orange.opacity(0.2)))
                                .foregroundStyle(.orange)
                        }
                    }
                }
                Spacer()
                Text(Fmt.bytes(r.sourceSize))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
        }
    }

    private func cell(_ r: LocalRecord) -> some View {
        Button {
            viewer = r
        } label: {
            ZStack(alignment: .bottomLeading) {
                LocalThumb(record: r)
                    .aspectRatio(16 / 9, contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                HStack(spacing: 5) {
                    CameraBadge(camera: r.camera)
                    Text(Fmt.time(r.date)).font(.caption2).lineLimit(1)
                    Spacer(minLength: 0)
                    if let d = r.duration {
                        Text(Fmt.duration(d)).font(.caption2)
                    } else if r.kind == .fileTS {
                        Text("TS").font(.caption2)
                    }
                }
                .padding(6)
                .background(
                    LinearGradient(colors: [.clear, .black.opacity(0.55)], startPoint: .top, endPoint: .bottom)
                )
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .buttonStyle(.plain)
    }
}

// MARK: - 本地缩略图（相册资产 / 回退文件用图标）

struct LocalThumb: View {
    let record: LocalRecord
    @State private var image: UIImage?

    var body: some View {
        ZStack {
            Rectangle().fill(record.camera.color.opacity(0.25))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else if record.kind == .fileTS {
                Image(systemName: "film")
                    .font(.title)
                    .foregroundStyle(record.camera.color)
            } else {
                ProgressView()
            }
        }
        .task(id: record.id) {
            switch record.kind {
            case .photoAlbum:
                PhotoSaver.loadAssetImage(localId: record.localRef, size: CGSize(width: 480, height: 270)) { img in
                    DispatchQueue.main.async { self.image = img }
                }
            case .fileTS:
                break
            }
        }
    }
}

// MARK: - 本地查看（图片 / AVPlayer 播放 + 分享 + 删除本地副本）

struct LocalViewerSheet: View {
    @EnvironmentObject var library: LibraryStore
    @Environment(\.dismiss) private var dismiss
    let record: LocalRecord

    @State private var player: AVPlayer?
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

    // 回退 .ts 文件：AVPlayer 直接播 Documents/CarLink 下的文件
    private var tsViewer: some View {
        VStack {
            VideoPlayer(player: player)
                .onAppear {
                    let url = LibraryStore.tsDirectory.appending(path: record.localRef)
                    player = AVPlayer(url: url)
                    player?.play()
                }
                .onDisappear { player?.pause() }
        }
    }

    // 相册资产：图片直接显示，视频经 PHImageManager 拿 AVAsset
    @ViewBuilder
    private var albumViewer: some View {
        if isPhotoRecord {
            PhotoAssetImageView(localId: record.localRef)
        } else {
            VideoPlayer(player: player)
                .onAppear {
                    PhotoSaver.loadAssetVideoURL(localId: record.localRef) { url in
                        if let u = url {
                            let p = AVPlayer(url: u)
                            p.play()
                            DispatchQueue.main.async { self.player = p }
                        }
                    }
                }
                .onDisappear { player?.pause() }
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
            PhotoSaver.loadAssetVideoURL(localId: record.localRef) { url in
                guard let u = url else { return }
                DispatchQueue.main.async {
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
            if let image {
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
