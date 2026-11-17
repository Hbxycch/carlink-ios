import SwiftUI
import UIKit

/// 连接诊断页：查看 / 复制连接日志（配合车机端 /api/connlog 双向排查）
struct ConnDiagnosticsView: View {
    @EnvironmentObject private var conn: ConnectionStore
    @ObservedObject private var store = ConnLogStore.shared
    @State private var copied = false
    @State private var probing = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    hintCard
                    probeCard

                    ForEach(Array(store.snapshot().enumerated()), id: \.offset) { idx, line in
                        Text(line)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(isError(line) ? Color.red : Color.primary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .id(idx)
                    }
                    if store.snapshot().isEmpty {
                        Text("暂无日志。回到首页尝试连接一次车机，再回到本页查看。")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .padding(12)
                    }
                    Color.clear.frame(height: 8).id("bottom")
                }
                .padding(.top, 8)
            }
            .onChange(of: store.count) { _ in
                withAnimation { proxy.scrollTo("bottom") }
            }
            .onAppear {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    proxy.scrollTo("bottom")
                }
            }
        }
        .navigationTitle("连接诊断")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Button {
                    UIPasteboard.general.string = store.fullText()
                    copied = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
            }
            ToolbarItem(placement: .topBarLeading) {
                Button("清空") { store.clear() }
                    .foregroundStyle(.red)
            }
        }
    }

    /// 自检卡片：一键探测 /api/info、/api/volumes、/web，不需要另开 Safari
    private var probeCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let target = probeTarget {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("自检当前车机")
                            .font(.system(size: 12, weight: .bold))
                        Text("http://\(target.host):\(target.port)")
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button {
                        probe(target.host, target.port)
                    } label: {
                        if probing {
                            ProgressView()
                        } else {
                            Text("开始自检")
                                .font(.system(size: 12, weight: .semibold))
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(probing)
                }
            } else {
                Text("自检：先连接或保存一个车机地址")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(.secondarySystemFill)))
        .padding(.horizontal, 12)
    }

    private var probeTarget: (host: String, port: Int)? {
        if let api = conn.client { return (api.host, api.port) }
        if let d = conn.savedDevices.first { return (d.host, d.port) }
        return nil
    }

    /// 自检：串行跑三个请求，结果写进日志（App 内即可判断"请求有没有到服务端 / 服务端回了什么"）
    @MainActor
    private func probe(_ host: String, _ port: Int) {
        probing = true
        ConnLogStore.shared.log("TEST", "=== 自检开始 \(host):\(port) ===")
        Task {
            let api = APIClient(host: host, port: port)
            func ms(_ t: Date) -> Int { Int(Date().timeIntervalSince(t) * 1000) }

            var t = Date()
            do {
                let info = try await api.info()
                ConnLogStore.shared.log("TEST", "① /api/info 通：\(info.deviceName) v\(info.version)（\(ms(t))ms）")
            } catch {
                ConnLogStore.shared.log("ERR", "① /api/info 失败：\(ConnLogStore.describe(error))（\(ms(t))ms）")
            }

            t = Date()
            do {
                let (code, body) = try await api.raw(path: "/api/volumes")
                ConnLogStore.shared.log("TEST", "② /api/volumes HTTP \(code)（\(ms(t))ms）\(body.prefix(160))")
            } catch {
                ConnLogStore.shared.log("ERR", "② /api/volumes 失败：\(ConnLogStore.describe(error))（\(ms(t))ms）")
            }

            t = Date()
            do {
                let (code, body) = try await api.raw(path: "/web")
                ConnLogStore.shared.log("TEST", "③ /web HTTP \(code)（\(ms(t))ms）\(body.prefix(120))")
            } catch {
                ConnLogStore.shared.log("ERR", "③ /web 失败：\(ConnLogStore.describe(error))（\(ms(t))ms）")
            }

            ConnLogStore.shared.log("TEST", "=== 自检结束 ===")
            probing = false
        }
    }

    private var hintCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("排查指引")
                .font(.system(size: 12, weight: .bold))
            Text("先点上方「开始自检」，会依次请求 /api/info、/api/volumes、/web 并写进日志。\n① 若 Safari 能开 http://车机IP:8080/web 但自检① /api/info 失败 → 多为 iOS「本地网络」权限被拒（设置 → 隐私与安全性 → 本地网络 → CarLink）。\n② 若自检①失败但日志里是 HTTP 错误并带原始响应 → 车机端版本旧/字段缺失，把日志发开发者。\n③ ERR 行的 domain/code 是定位关键：-1004 端口未开、-1002 IP 错、超时=网络不通或权限被拒。")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color(.tertiarySystemFill)))
        .padding(.horizontal, 12)
    }

    private func isError(_ line: String) -> Bool {
        line.contains("[ERR]") || line.contains("失败")
    }
}
