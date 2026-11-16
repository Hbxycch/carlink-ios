import SwiftUI

enum AppTab: Hashable {
    case car, files, transfer, settings
}

/// 全局导航（跨 Tab 跳转）
@MainActor
final class AppNav: ObservableObject {
    @Published var tab: AppTab = .car
    /// 文件 Tab 跳转请求（车机页快捷入口 → 指定段/分类）
    @Published var filesJump: FileSegmentJump?
}

@main
struct CarLinkApp: App {
    @StateObject private var conn = ConnectionStore()
    @StateObject private var library = LibraryStore()
    @StateObject private var settings = SettingsStore()
    @StateObject private var downloads: DownloadManager
    @StateObject private var uploads = UploadManager()
    @StateObject private var nav = AppNav()

    init() {
        let connection = ConnectionStore()
        _conn = StateObject(wrappedValue: connection)
        let lib = LibraryStore()
        _library = StateObject(wrappedValue: lib)
        let st = SettingsStore()
        _settings = StateObject(wrappedValue: st)
        let dl = DownloadManager()
        dl.setup(connection: connection, library: lib, settings: st)
        _downloads = StateObject(wrappedValue: dl)
        let up = UploadManager()
        up.connection = connection
        _uploads = StateObject(wrappedValue: up)
    }

    var body: some Scene {
        WindowGroup {
            RootTabView()
                .environmentObject(conn)
                .environmentObject(library)
                .environmentObject(settings)
                .environmentObject(downloads)
                .environmentObject(uploads)
                .environmentObject(nav)
                .tint(Color(red: 0.18, green: 0.49, blue: 0.88))
                .task {
                    settings.startMonitoring()
                }
        }
    }
}

struct RootTabView: View {
    @EnvironmentObject var nav: AppNav
    @EnvironmentObject var downloads: DownloadManager

    var body: some View {
        TabView(selection: $nav.tab) {
            CarTabView()
                .tabItem { Label("车机", systemImage: "car.fill") }
                .tag(AppTab.car)

            FilesTabView()
                .tabItem { Label("文件", systemImage: "folder.fill") }
                .tag(AppTab.files)

            TransferTabView()
                .tabItem { Label("传输", systemImage: "arrow.left.arrow.right") }
                .tag(AppTab.transfer)
                .badge(downloads.activeCount > 0 ? downloads.activeCount : 0)

            SettingsView()
                .tabItem { Label("设置", systemImage: "gearshape.fill") }
                .tag(AppTab.settings)
        }
    }
}
