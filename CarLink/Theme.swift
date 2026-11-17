import SwiftUI

// MARK: - 设计规范色彩（对齐「手机端设计图_iOS_v1」：浅色 #F2F2F7/#FFF，深色 #000/#1C1C1E）
//
// 全部用 UIColor 动态色实现，系统深浅色切换时自动取对应值——
// 不在任何页面写死 .white / .black 背景，也不强制 preferredColorScheme。

enum CL {
    /// 主蓝 #007AFF（深色 0A84FF）
    static let blue = Color(uiColor: UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.04, green: 0.52, blue: 1.00, alpha: 1)
            : UIColor(red: 0.00, green: 0.478, blue: 1.00, alpha: 1)
    })

    /// 蓝底 chip 的文字色（浅色 #0C447C，深色 #9EC7F2）
    static let blueInk = Color(uiColor: UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.62, green: 0.78, blue: 0.95, alpha: 1)
            : UIColor(red: 0.047, green: 0.267, blue: 0.486, alpha: 1)
    })

    /// 蓝底 chip 的底色（浅色 #E6F1FB，深色 #1C3A5E）
    static let blueBg = Color(uiColor: UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.11, green: 0.23, blue: 0.37, alpha: 1)
            : UIColor(red: 0.902, green: 0.945, blue: 0.984, alpha: 1)
    })

    /// 成功绿 #34C759（深色 30D158）
    static let green = Color(uiColor: UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.188, green: 0.820, blue: 0.345, alpha: 1)
            : UIColor(red: 0.204, green: 0.780, blue: 0.349, alpha: 1)
    })

    /// 「已在本地」文字色：设计图 list 内联 #1D7A34（深色用亮绿保证对比度）
    static let okText = Color(uiColor: UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.188, green: 0.820, blue: 0.345, alpha: 1)
            : UIColor(red: 0.114, green: 0.478, blue: 0.204, alpha: 1)
    })

    /// 「已在本地」胶囊底（浅色 #E1F5EE，深色绿 16% 透明）
    static let okBg = Color(uiColor: UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.188, green: 0.820, blue: 0.345, alpha: 0.18)
            : UIColor(red: 0.882, green: 0.961, blue: 0.933, alpha: 1)
    })

    /// 缩略图右下角绿色 ✓ 圆点（#34C759）
    static let okDot = green

    /// 页面底色（浅 #F2F2F7，深 #000）
    static let page = Color(uiColor: UIColor { tc in
        tc.userInterfaceStyle == .dark ? .black : UIColor(red: 0.949, green: 0.949, blue: 0.969, alpha: 1)
    })

    /// 卡片/列表底色（浅 #FFF，深 #1C1C1E）
    static let card = Color(uiColor: UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 0.11, green: 0.11, blue: 0.118, alpha: 1)
            : .white
    })

    /// 分割线（跟随系统）
    static let line = Color(uiColor: UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(white: 1, alpha: 0.10)
            : UIColor(white: 0, alpha: 0.06)
    })

    /// 提示黄 #FF9500
    static let orange = Color(uiColor: UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 1.0, green: 0.62, blue: 0.13, alpha: 1)
            : UIColor(red: 1.0, green: 0.584, blue: 0.0, alpha: 1)
    })

    /// 告警红 #FF3B30
    static let red = Color(uiColor: UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(red: 1.0, green: 0.38, blue: 0.33, alpha: 1)
            : UIColor(red: 1.0, green: 0.231, blue: 0.188, alpha: 1)
    })

    /// 次要文字（#888780 系）
    static let ink2 = Color(uiColor: UIColor { tc in
        tc.userInterfaceStyle == .dark
            ? UIColor(white: 0.62, alpha: 1)
            : UIColor(red: 0.537, green: 0.529, blue: 0.502, alpha: 1)
    })
}

// MARK: - 「✓ 已在本地」胶囊（设计图 .acts .ok / .pacts）

struct LocalTag: View {
    var text: String = "已在本地"
    var compact: Bool = false

    var body: some View {
        HStack(spacing: 2.5) {
            Image(systemName: "checkmark")
                .font(.system(size: compact ? 8 : 9, weight: .bold))
            Text(text)
                .font(.system(size: compact ? 9.5 : 11, weight: .semibold))
        }
        .foregroundStyle(CL.okText)
        .padding(.horizontal, compact ? 5 : 7)
        .padding(.vertical, compact ? 1.5 : 3)
        .background(Capsule().fill(CL.okBg))
    }
}

// MARK: - 缩略图右下角绿色 ✓（设计图 .dlok）

struct LocalCheckDot: View {
    var body: some View {
        Image(systemName: "checkmark")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(.white)
            .frame(width: 14, height: 14)
            .background(Circle().fill(CL.okDot))
            .overlay(Circle().stroke(Color.black.opacity(0.08), lineWidth: 0.5))
            .shadow(color: Color.black.opacity(0.45), radius: 1.5, x: 0, y: 1)
    }
}

// MARK: - 封面下载进度角标（缩略图上的环形进度 + 百分比）

struct DownloadProgressBadge: View {
    let progress: Double
    var paused: Bool = false

    private var percent: Int { max(0, min(100, Int((progress * 100).rounded()))) }

    var body: some View {
        ZStack {
            Circle()
                .fill(Color.black.opacity(0.55))
            Circle()
                .trim(from: 0, to: max(0.02, min(1, progress)))
                .stroke(CL.blue, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                .rotationEffect(.degrees(-90))
            if paused {
                Image(systemName: "pause.fill")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(.white)
            } else {
                Text("\(percent)%")
                    .font(.system(size: 8, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
                    .monospacedDigit()
            }
        }
        .frame(width: 30, height: 30)
        .overlay(Circle().stroke(Color.white.opacity(0.85), lineWidth: 1))
    }
}

/// 下载态角标（缩略图右上角用的简化版：图标 + 半透明底）
struct DownloadingChip: View {
    let progress: Double
    var paused: Bool = false

    var body: some View {
        HStack(spacing: 2) {
            Image(systemName: paused ? "pause.fill" : "arrow.down")
                .font(.system(size: 7, weight: .bold))
            Text(paused ? "已暂停" : "\(Int((progress * 100).rounded()))%")
                .font(.system(size: 8, weight: .bold, design: .rounded))
                .monospacedDigit()
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 4)
        .padding(.vertical, 1.5)
        .background(Capsule().fill(Color.black.opacity(0.55)))
    }
}
