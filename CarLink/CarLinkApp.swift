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
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var conn = ConnectionStore()
    @StateObject private var library = LibraryStore()
    @StateObject private var settings = SettingsStore()
    @StateObject private var downloads: DownloadManager
    @StateObject private var uploads = UploadManager()
    @StateObject private var nav = AppNav()
    @StateObject private var updateChecker = UpdateChecker()
    @Environment(\.scenePhase) private var scenePhase

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
        // 清理旧版本自动截图在 tmp 里遗留的大量临时 PNG（后台执行，不阻塞启动）
        ScreenShotTempStore.cleanupOnLaunch()
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
                .environmentObject(updateChecker)
                .tint(CL.blue)
                .preferredColorScheme(settings.appearance.scheme)
                .task {
                    settings.startMonitoring()
                    // 启动自动连接上次使用的车机
                    if settings.autoConnect { conn.autoConnectIfPossible() }
                    // 启动后静默检查更新（无更新/已忽略不提示）
                    await updateChecker.check(silent: true)
                }
                .onChange(of: scenePhase) { phase in
                    // 回到前台：先立刻探测一次真实链路（不等 2s 轮询），再按需自动重连
                    if phase == .active {
                        if settings.autoConnect {
                            conn.autoConnectIfPossible()
                        }
                        Task { await conn.probeNow() }
                    }
                }
        }
    }
}

struct RootTabView: View {
    @EnvironmentObject var nav: AppNav
    @EnvironmentObject var downloads: DownloadManager
    @EnvironmentObject var updateChecker: UpdateChecker
    @Environment(\.openURL) private var openURL

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
        // 启动自动检查发现的更新：全局弹窗（手动检查的结果在设置页内展示）
        .alert("发现新版本", isPresented: Binding(
            get: { updateChecker.available != nil },
            set: { if !$0 { updateChecker.dismiss() } }
        )) {
            Button("前往下载") {
                if let url = URL(string: updateChecker.available?.ipaUrl ?? "") {
                    openURL(url)
                }
                updateChecker.dismiss()
            }
            Button("稍后再说", role: .cancel) {
                updateChecker.dismiss()
            }
        } message: {
            if let info = updateChecker.available {
                Text("v\(info.displayVersion) 已发布\(info.date.map { "（\($0)）" } ?? "")\n\(info.changelog ?? "")\n\n下载 ipa 后通过 Sideloadly 重装即可，数据不受影响。")
            }
        }
    }
}
