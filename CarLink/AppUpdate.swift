import Foundation

// MARK: - 在线更新（OTA 清单：https://smartdash-ota.w.zood.org:8888/carlink/ios-version.json）

struct AppUpdateInfo: Codable, Equatable {
    let version: String
    let build: String?
    let ipaUrl: String
    let size: Int64?
    let md5: String?
    let changelog: String?
    let date: String?

    /// 完整版本号显示："1.0.3 (5)"
    var displayVersion: String {
        version + (build.map { " (\($0))" } ?? "")
    }
}

@MainActor
final class UpdateChecker: ObservableObject {
    /// OTA 清单地址（与车机端同目录）
    static let manifestURL = URL(string: "https://smartdash-ota.w.zood.org:8888/carlink/ios-version.json")!

    @Published var available: AppUpdateInfo?
    @Published var checking = false
    @Published var lastResultText: String?

    /// 用户已忽略的版本（点击「稍后再说」后不再打扰）
    @AppStorage("dismissedUpdateVersion") private var dismissedVersion: String = ""

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    static var currentBuild: String {
        (Bundle.main.infoDictionary?["CFBundleVersion"] as? String) ?? "0"
    }

    static var currentDisplay: String {
        "\(currentVersion) (\(currentBuild))"
    }

    /// 语义化版本比较：a 是否比 b 新（"1.10.0" > "1.9.2"）
    static func isNewer(_ a: String, than b: String) -> Bool {
        let pa = a.split(separator: ".").compactMap { Int($0) }
        let pb = b.split(separator: ".").compactMap { Int($0) }
        let n = max(pa.count, pb.count)
        for i in 0..<n {
            let x = i < pa.count ? pa[i] : 0
            let y = i < pb.count ? pb[i] : 0
            if x != y { return x > y }
        }
        return false
    }

    /// 拉取清单并比较版本
    /// - Parameter silent: 静默模式（启动自动检查）：无更新/已忽略时不提示，失败不报错
    func check(silent: Bool) async {
        guard !checking else { return }
        checking = true
        defer { checking = false }
        do {
            let (data, resp) = try await URLSession.shared.data(from: Self.manifestURL)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw APIError("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
            }
            let info = try JSONDecoder().decode(AppUpdateInfo.self, from: data)
            if Self.isNewer(info.version, than: Self.currentVersion) {
                if silent && info.version == dismissedVersion { return }
                available = info
                lastResultText = nil
            } else {
                available = nil
                if !silent { lastResultText = "已是最新版本（\(Self.currentDisplay)）" }
            }
        } catch {
            if !silent {
                lastResultText = "检查更新失败：\(error.localizedDescription)"
            }
        }
    }

    /// 用户选择忽略本次更新
    func dismiss() {
        if let v = available?.version { dismissedVersion = v }
        available = nil
    }
}
