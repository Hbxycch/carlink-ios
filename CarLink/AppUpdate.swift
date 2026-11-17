import Foundation
import SwiftUI

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

    /// 忽略版本的去重键（同版本不同 build 也算新版本）
    var key: String { "\(version)#\(build ?? "0")" }
}

@MainActor
final class UpdateChecker: ObservableObject {
    /// OTA 清单地址（与车机端同目录）
    static let manifestURL = URL(string: "https://smartdash-ota.w.zood.org:8888/carlink/ios-version.json")!

    @Published var available: AppUpdateInfo?
    @Published var checking = false
    @Published var lastResultText: String?

    /// 用户已忽略的版本（点击「稍后再说」后不再打扰）
    @AppStorage("dismissedUpdateKey") private var dismissedKey: String = ""

    /// 清单用 nginx 托管且带 Cache-Control: max-age=3600，
    /// 用共享 URLSession 会拿到一小时内的旧清单（表现为「刚发布却不提示新版本」）。
    /// 这里用 ephemeral + 强制忽略缓存，并附加时间戳参数双保险。
    private static let session: URLSession = {
        let cfg = URLSessionConfiguration.ephemeral
        cfg.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        cfg.timeoutIntervalForRequest = 20
        cfg.timeoutIntervalForResource = 30
        return URLSession(configuration: cfg)
    }()

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
            var comps = URLComponents(url: Self.manifestURL, resolvingAgainstBaseURL: false)
            comps?.queryItems = [URLQueryItem(name: "t", value: String(Int(Date().timeIntervalSince1970)))]
            guard let url = comps?.url else { throw APIError("清单地址无效") }
            var req = URLRequest(url: url)
            req.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData

            let (data, resp) = try await Self.session.data(for: req)
            guard let http = resp as? HTTPURLResponse, (200..<300).contains(http.statusCode) else {
                throw APIError("HTTP \((resp as? HTTPURLResponse)?.statusCode ?? -1)")
            }
            let info = try JSONDecoder().decode(AppUpdateInfo.self, from: data)

            // 版本号更大，或同版本号但 build 更高，都算有更新
            let newerVersion = Self.isNewer(info.version, than: Self.currentVersion)
            let newerBuild = info.version == Self.currentVersion
                && Self.isNewer(info.build ?? "0", than: Self.currentBuild)

            if newerVersion || newerBuild {
                if silent && info.key == dismissedKey { return }
                available = info
                lastResultText = nil
            } else {
                available = nil
                if !silent { lastResultText = "已是最新（\(Self.currentDisplay)）" }
            }
        } catch {
            if !silent {
                lastResultText = "检查失败：\(error.localizedDescription)"
            }
        }
    }

    /// 用户选择忽略本次更新
    func dismiss() {
        if let v = available { dismissedKey = v.key }
        available = nil
    }
}
