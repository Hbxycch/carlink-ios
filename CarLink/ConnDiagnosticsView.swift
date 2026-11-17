import SwiftUI
import UIKit

/// 连接诊断页：查看 / 复制连接日志（配合车机端 /api/connlog 双向排查）
struct ConnDiagnosticsView: View {
    @ObservedObject private var store = ConnLogStore.shared
    @State private var copied = false

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 4) {
                    hintCard

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

    private var hintCard: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("排查指引")
                .font(.system(size: 12, weight: .bold))
            Text("① 用 Safari 打开 http://车机IP:8080/web 能访问但 App 连不上 → 多为 iOS「本地网络」权限被拒（设置 → 隐私与安全性 → 本地网络 → CarLink）。\n② ERR 行里的 domain/code 是定位关键：NSURLErrorDomain -1004=端口未开、-1002=IP 错、超时=网络不通或权限被拒。\n③ 点右上角复制，把日志发给开发者即可。")
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
