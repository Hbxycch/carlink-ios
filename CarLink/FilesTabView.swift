import SwiftUI

// MARK: - 文件 Tab 顶层：截图 / 本地文件 / 记录仪文件

struct FilesTabView: View {
    @EnvironmentObject var conn: ConnectionStore
    @EnvironmentObject var library: LibraryStore
    @EnvironmentObject var downloads: DownloadManager
    @EnvironmentObject var nav: AppNav

    var body: some View {
        NavigationStack(path: $nav.filesPath) {
            List {
                screenshotSection
                localSection
                remoteSection
            }
            .listStyle(.insetGrouped)
            .navigationTitle("文件")
            .navigationDestination(for: FilesRoute.self) { route in
                switch route {
                case .screenshots:
                    RemoteBrowserView(source: .screenshots)
                case .remoteAlbum(let c):
                    RemoteBrowserView(source: .dashcam(c))
                case .localAlbum(let c):
                    LocalAlbumView(category: c)
                case .downloads:
                    DownloadsListView()
                }
            }
        }
    }

    private var screenshotSection: some View {
        Section {
            NavigationLink(value: FilesRoute.screenshots) {
                Label("截图", systemImage: "camera.viewfinder")
            }
        } header: {
            Text("车机截图")
        } footer: {
            Text("车机端 Pictures/CarCap 目录下的截图。")
        }
    }

    private var localSection: some View {
        Section("本地文件（已下载到手机）") {
            ForEach(MediaCategory.allCases) { c in
                NavigationLink(value: FilesRoute.localAlbum(c)) {
                    HStack {
                        Label(c.title, systemImage: iconName(c))
                        Spacer()
                        Text("\(library.records(category: c).count)")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var remoteSection: some View {
        Section("记录仪文件（车机上）") {
            if !conn.isConnected {
                Label("未连接车机，请先在「车机」页连接", systemImage: "wifi.slash")
                    .foregroundStyle(.secondary)
                    .font(.subheadline)
            }
            ForEach(MediaCategory.allCases) { c in
                NavigationLink(value: FilesRoute.remoteAlbum(c)) {
                    Label(c.title, systemImage: iconName(c))
                }
                .disabled(!conn.isConnected)
            }
            NavigationLink(value: FilesRoute.downloads) {
                HStack {
                    Label("下载中", systemImage: "arrow.down.circle")
                    Spacer()
                    if downloads.activeCount > 0 {
                        Text("\(downloads.activeCount)")
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                            .background(Capsule().fill(Color.blue.opacity(0.15)))
                            .foregroundStyle(.blue)
                    }
                }
            }
            .disabled(!conn.isConnected)
        }
    }

    private func iconName(_ c: MediaCategory) -> String {
        switch c {
        case .loop: return "arrow.triangle.2.circlepath"
        case .snapshot: return "camera.fill"
        case .locked: return "lock.fill"
        }
    }
}
