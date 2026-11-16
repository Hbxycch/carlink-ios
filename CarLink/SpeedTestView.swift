import SwiftUI

// MARK: - 测速：延迟 + 吞吐（AP 模式下以此评估链路质量）

struct SpeedTestView: View {
    @EnvironmentObject var conn: ConnectionStore

    @State private var phase: Phase = .idle
    @State private var pingResults: [Double] = []
    @State private var throughput: Double = 0
    @State private var testedBytes: Int64 = 0
    @State private var errorMessage: String?

    enum Phase: Equatable {
        case idle, pinging, downloading, done, failed
    }

    var body: some View {
        List {
            Section("延迟（PING /api/info × 10）") {
                if pingResults.isEmpty {
                    Text(phase == .pinging ? "测试中…" : "未测试")
                        .foregroundStyle(.secondary)
                } else {
                    LabeledRow(icon: "bolt.horizontal", title: "平均", value: String(format: "%.0f ms", pingResults.reduce(0, +) / Double(pingResults.count)))
                    LabeledRow(icon: "bolt.horizontal.circle", title: "最小", value: String(format: "%.0f ms", pingResults.min() ?? 0))
                    LabeledRow(icon: "hourglass", title: "最大", value: String(format: "%.0f ms", pingResults.max() ?? 0))
                }
            }

            Section("下载吞吐（最多取 8 MB）") {
                if throughput > 0 {
                    LabeledRow(icon: "arrow.down.circle.fill", title: "速度",
                               value: Fmt.rate(throughput))
                    LabeledRow(icon: "internaldrive", title: "测试数据量", value: Fmt.bytes(testedBytes))
                    LabeledRow(icon: "chart.bar", title: "链路评价", value: grade)
                } else {
                    Text(phase == .downloading ? "测试中…" : "未测试")
                        .foregroundStyle(.secondary)
                }
            }

            Section {
                Button {
                    Task { await run() }
                } label: {
                    HStack {
                        Spacer()
                        if phase == .pinging || phase == .downloading {
                            ProgressView().padding(.trailing, 8)
                        }
                        Text(phase == .idle || phase == .done || phase == .failed ? "开始测速" : "测试中…")
                        Spacer()
                    }
                }
                .disabled(phase == .pinging || phase == .downloading)

                if let errorMessage {
                    Label(errorMessage, systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                        .font(.subheadline)
                }
            } footer: {
                Text("车机自开热点时手机端无法读取信号强度（RSSI），以吞吐评估：≥8 MB/s 优 · ≥3 MB/s 良 · ≥1 MB/s 一般 · 其余 弱。")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("测速")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var grade: String {
        switch throughput {
        case 8_000_000...: return "优 🟢"
        case 3_000_000..<8_000_000: return "良 🟡"
        case 1_000_000..<3_000_000: return "一般 🟠"
        default: return "弱 🔴"
        }
    }

    private func run() async {
        guard let api = conn.client else { return }
        errorMessage = nil
        pingResults = []
        throughput = 0
        phase = .pinging

        // 1. 延迟
        for _ in 0..<10 {
            let t0 = Date()
            do {
                _ = try await api.info()
                pingResults.append(Date().timeIntervalSince(t0) * 1000)
            } catch {
                errorMessage = ConnectionStore.describe(error)
                phase = .failed
                return
            }
        }

        // 2. 吞吐：找一个文件下载（Range 最多 8MB）
        phase = .downloading
        do {
            var file: CarFile?
            let dashcamFiles = try await api.dashcam(category: .loop)
            if let f = dashcamFiles.first(where: { $0.size > 1_000_000 }) {
                file = f
            } else if let s = try await api.screenshots().first(where: { $0.size > 500_000 }) {
                file = s
            }
            guard let f = file else {
                errorMessage = "车机上没有可用于测速的文件"
                phase = .failed
                return
            }
            var req = URLRequest(url: api.downloadURL(path: f.path))
            let limit: Int64 = 8 * 1024 * 1024
            if f.size > limit {
                req.setValue("bytes=0-\(limit - 1)", forHTTPHeaderField: "Range")
            }
            req.timeoutInterval = 60
            let t0 = Date()
            let (data, _) = try await URLSession.shared.data(for: req)
            let dt = Date().timeIntervalSince(t0)
            testedBytes = Int64(data.count)
            if dt > 0 { throughput = Double(data.count) / dt }
            phase = .done
        } catch {
            errorMessage = ConnectionStore.describe(error)
            phase = .failed
        }
    }
}
