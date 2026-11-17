import Foundation
import SwiftUI

/// 连接诊断日志（环形缓冲，线程安全；任意线程可写，UI 读取快照）
final class ConnLogStore: ObservableObject {
    static let shared = ConnLogStore()

    private var lines: [String] = []
    private let lock = NSLock()
    private let max = 300
    private let fmt: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "MM-dd HH:mm:ss.SSS"
        return f
    }()

    /// 记录一条事件；tag 例：CONN / AUTO / ERR / MON
    func log(_ tag: String, _ text: String) {
        let line = "\(fmt.string(from: Date())) [\(tag)] \(text)"
        lock.lock()
        lines.append(line)
        if lines.count > max { lines.removeFirst(lines.count - max) }
        lock.unlock()
        print("[ConnLog]", line)
        DispatchQueue.main.async { self.objectWillChange.send() }
    }

    /// 把错误展开成可读形式（含 domain/code，是定位本地网络权限等系统级拦截的关键）
    static func describe(_ error: Error) -> String {
        if let e = error as? APIError { return "APIError: \(e.message)" }
        let ns = error as NSError
        return "\(ns.domain) code=\(ns.code) \(ns.localizedDescription)"
    }

    var count: Int {
        lock.lock(); defer { lock.unlock() }
        return lines.count
    }

    func snapshot() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return lines
    }

    /// 复制用全文：头部带 app / 系统版本、保存的设备列表，便于发给别人排查
    func fullText() -> String {
        var head: [String] = []
        let appVersion = (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?")
        let build = (Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?")
        head.append("=== CarLink 连接诊断 ===")
        head.append("app: v\(appVersion) (\(build))  iOS: \(ProcessInfo.processInfo.operatingSystemVersionString)")
        head.append("导出时间: \(Date().formatted())")
        if let data = UserDefaults.standard.data(forKey: "carlink.savedDevices"),
           let list = try? JSONDecoder().decode([SavedDevice].self, from: data), !list.isEmpty {
            head.append("历史设备: " + list.map { "\($0.name) \($0.host):\($0.port)" }.joined(separator: " | "))
        } else {
            head.append("历史设备: 无")
        }
        head.append("---")
        return (head + snapshot()).joined(separator: "\n")
    }

    func clear() {
        lock.lock(); lines.removeAll(); lock.unlock()
        objectWillChange.send()
    }
}
