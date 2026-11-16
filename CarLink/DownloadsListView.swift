import SwiftUI

// MARK: - 下载中页面（文件 Tab → 记录仪文件 → 下载中）

struct DownloadsListView: View {
    @EnvironmentObject var downloads: DownloadManager

    var body: some View {
        List {
            if downloads.items.isEmpty {
                Text("暂无下载任务")
                    .foregroundStyle(.secondary)
            }
            if !downloads.items.isEmpty {
                Section {
                    HStack {
                        Button("全部暂停") { downloads.pauseAll() }
                        Spacer()
                        Button("全部取消") { downloads.cancelAll() }
                            .foregroundStyle(.red)
                        Spacer()
                        if downloads.items.contains(where: { $0.state == .done }) {
                            Button("清除已完成") { downloads.clearFinished() }
                        }
                    }
                    .font(.subheadline)
                }
            }
            Section {
                ForEach(downloads.items) { item in
                    DownloadRow(item: item,
                                onPause: { downloads.pause(item) },
                                onResume: { downloads.resume(item) },
                                onRetry: { downloads.retry(item) },
                                onCancel: { downloads.cancel(item) })
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("下载中")
        .navigationBarTitleDisplayMode(.inline)
    }
}
