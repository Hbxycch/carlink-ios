import SwiftUI

// MARK: - 下载中（文件 Tab → 记录仪文件 → 下载中，内嵌内容）

struct DownloadsListView: View {
    @EnvironmentObject var downloads: DownloadManager

    var body: some View {
        List {
            if downloads.items.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "arrow.down.circle")
                        .font(.largeTitle)
                        .foregroundStyle(.tertiary)
                    Text("暂无下载任务")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text("在「记录仪文件」点缩略图右侧的下载按钮")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 30)
                .listRowBackground(Color.clear)
            } else {
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
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }
}
