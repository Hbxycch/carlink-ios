import SwiftUI

// MARK: - 日期选择器（蓝点 = 当天有文件）

struct DatePickerSheet: View {
    let days: Set<Date>                 // 有文件的日期（startOfDay）
    @Binding var selected: Date?
    @Environment(\.dismiss) private var dismiss

    @State private var monthAnchor: Date = Calendar.current.startOfDay(for: Date())

    private var cal: Calendar { Calendar.current }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                quickBar
                monthHeader
                weekdayRow
                dayGrid
                Spacer(minLength: 0)
            }
            .navigationTitle("选择日期")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("清除") {
                        selected = nil
                        dismiss()
                    }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("完成") { dismiss() }
                        .fontWeight(.semibold)
                }
            }
        }
    }

    // 快捷按钮：全部 / 今天 / 最早 / 最近
    private var quickBar: some View {
        HStack(spacing: 10) {
            quickChip("全部") { selected = nil; dismiss() }
            quickChip("今天") { selected = cal.startOfDay(for: Date()); dismiss() }
            if let earliest = days.min() {
                quickChip(Fmt.day(earliest)) { selected = earliest; dismiss() }
            }
            if let latest = days.max() {
                quickChip(Fmt.day(latest)) { selected = latest; dismiss() }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }

    private func quickChip(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Capsule().fill(Color.blue.opacity(0.12)))
        }
        .buttonStyle(.borderless)
    }

    private var monthHeader: some View {
        HStack {
            Button {
                shiftMonth(-1)
            } label: {
                Image(systemName: "chevron.left")
            }
            Spacer()
            Text(monthTitle)
                .font(.headline)
            Spacer()
            Button {
                shiftMonth(1)
            } label: {
                Image(systemName: "chevron.right")
            }
            .disabled(isCurrentMonth)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 8)
    }

    private var monthTitle: String {
        let comps = cal.dateComponents([.year, .month], from: monthAnchor)
        return "\(comps.year ?? 0) 年 \(comps.month ?? 0) 月"
    }

    private var isCurrentMonth: Bool {
        let now = cal.dateComponents([.year, .month], from: Date())
        let cur = cal.dateComponents([.year, .month], from: monthAnchor)
        return now == cur
    }

    private func shiftMonth(_ delta: Int) {
        if let next = cal.date(byAdding: .month, value: delta, to: monthAnchor) {
            monthAnchor = next
        }
    }

    private var weekdayRow: some View {
        HStack {
            ForEach(["日", "一", "二", "三", "四", "五", "六"], id: \.self) { d in
                Text(d)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity)
            }
        }
        .padding(.horizontal, 16)
    }

    private var dayGrid: some View {
        let daysOfMonth = daysInMonth()
        let firstWeekday = cal.component(.weekday, from: daysOfMonth.first ?? monthAnchor)
        let leadingCount = firstWeekday - 1

        return LazyVGrid(columns: Array(repeating: GridItem(.flexible()), count: 7), spacing: 6) {
            ForEach(0..<leadingCount, id: \.self) { _ in
                Color.clear.frame(height: 44)
            }
            ForEach(daysOfMonth, id: \.self) { day in
                dayCell(day)
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 8)
    }

    private func daysInMonth() -> [Date] {
        guard let interval = cal.dateInterval(of: .month, for: monthAnchor) else { return [] }
        var d = interval.start
        var out: [Date] = []
        while d < interval.end {
            out.append(cal.startOfDay(for: d))
            d = cal.date(byAdding: .day, value: 1, to: d) ?? interval.end
        }
        return out
    }

    private func dayCell(_ day: Date) -> some View {
        let hasFile = days.contains(day)
        let isSelected = selected.map { cal.isDate($0, inSameDayAs: day) } ?? false
        let isToday = cal.isDateInToday(day)

        return Button {
            selected = day
            dismiss()
        } label: {
            VStack(spacing: 3) {
                Text("\(cal.component(.day, from: day))")
                    .font(.body)
                    .fontWeight(isSelected ? .bold : .regular)
                    .foregroundStyle(
                        isSelected ? Color.white :
                        (isToday ? Color.blue : (hasFile ? Color.primary : Color.secondary.opacity(0.4)))
                    )
                Circle()
                    .fill(isSelected ? Color.white : Color.blue)
                    .frame(width: 5, height: 5)
                    .opacity(hasFile ? 1 : 0)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.blue : Color.clear)
            )
        }
        .buttonStyle(.plain)
    }
}
