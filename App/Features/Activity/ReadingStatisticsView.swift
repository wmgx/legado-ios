import SwiftUI

struct ReadingStatisticsView: View {
    @EnvironmentObject private var activity: ReadingActivityModel
    @ScaledMetric(relativeTo: .largeTitle) private var durationFontSize = 36
    @ScaledMetric(relativeTo: .caption2) private var chartHeight = 138

    private var statistics: ReadingStatistics { activity.statistics }

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                ReadingPageHeader(title: "阅读统计") { EmptyView() }
                VStack(spacing: 16) {
                    todayCard
                    overviewGrid
                    weeklyCard
                    historyLink
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
        }
        .background(ReadingTheme.canvas)
        .navigationBarHidden(true)
    }

    private var todayCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                Text("今日阅读")
                    .font(.subheadline)
                Spacer()
                Text(Date.now.formatted(.dateTime.locale(Locale(identifier: "zh_CN")).month().day()))
                    .font(.caption)
            }
            .foregroundStyle(ReadingTheme.onAccent.opacity(0.7))
            Text(duration(statistics.todayReadTime, compact: false))
                .font(.system(size: durationFontSize, weight: .medium))
                .foregroundStyle(ReadingTheme.onAccent)
                .readingNumericTransition()
                .minimumScaleFactor(0.7)
                .lineLimit(1)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(20)
        .background(ReadingTheme.emphasisSurface, in: RoundedRectangle(cornerRadius: 20))
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("statistics.todayCard")
    }

    private var overviewGrid: some View {
        ReadingCard {
            VStack(spacing: 18) {
                HStack(alignment: .top, spacing: 20) {
                    statisticTile(title: "累计阅读", value: duration(statistics.totalReadTime, compact: true))
                    statisticTile(title: "阅读书籍", value: "\(statistics.bookCount) 本")
                }
                Rectangle().fill(ReadingTheme.separator).frame(height: 0.5)
                HStack(alignment: .top, spacing: 20) {
                    statisticTile(
                        title: "近 7 天",
                        value: duration(statistics.recentDays.reduce(0) { $0 + $1.readTime }, compact: true)
                    )
                    statisticTile(title: "连续阅读", value: "\(statistics.currentStreak) 天")
                }
            }
        }
    }

    private func statisticTile(title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.title3.weight(.semibold))
                .readingNumericTransition()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title)，\(value)")
    }

    private var weeklyCard: some View {
        ReadingCard {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("最近 7 天")
                        .font(.headline)
                    Spacer()
                    Text("每日阅读时长")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                HStack(alignment: .bottom, spacing: 10) {
                    ForEach(statistics.recentDays, id: \.date) { day in
                        VStack(spacing: 7) {
                            Text(barLabel(day.readTime))
                                .font(.caption2.monospacedDigit())
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .minimumScaleFactor(0.7)
                            RoundedRectangle(cornerRadius: 3)
                                .fill(day.readTime > 0 ? ReadingTheme.accent.opacity(Calendar.current.isDateInToday(day.date) ? 1 : 0.22) : ReadingTheme.separator)
                                .frame(width: 22, height: barHeight(day.readTime))
                            Text(weekday(day.date))
                                .font(.caption2)
                                .foregroundStyle(Calendar.current.isDateInToday(day.date) ? ReadingTheme.accent : .secondary)
                        }
                        .frame(maxWidth: .infinity)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel("\(weekday(day.date))，阅读 \(duration(day.readTime, compact: false))")
                    }
                }
                .frame(height: chartHeight, alignment: .bottom)
            }
        }
    }

    private var historyLink: some View {
        NavigationLink {
            ReadingHistoryView()
        } label: {
            ReadingCard {
                HStack(spacing: 12) {
                    Image(systemName: "clock.arrow.circlepath").font(.title3)
                    Text("阅读记录").font(.subheadline.weight(.medium))
                    Spacer()
                    Image(systemName: "arrow.up.right").font(.subheadline)
                }
                .foregroundStyle(ReadingTheme.accent)
                .frame(minHeight: 24)
                .contentShape(Rectangle())
            }
        }
        .buttonStyle(.plain)
    }

    private func barHeight(_ milliseconds: Int64) -> CGFloat {
        let maximum = max(statistics.recentDays.map(\.readTime).max() ?? 0, 1)
        guard milliseconds > 0 else { return 2 }
        return 12 + 70 * CGFloat(milliseconds) / CGFloat(maximum)
    }

    private func barLabel(_ milliseconds: Int64) -> String {
        guard milliseconds >= 60_000 else { return milliseconds > 0 ? "<1分" : "0" }
        if milliseconds < 3_600_000 { return "\(milliseconds / 60_000)分" }
        let hours = Double(milliseconds) / 3_600_000
        return String(format: "%.1f时", hours)
    }

    private func weekday(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "EEE"
        return formatter.string(from: date)
    }

    private func duration(_ milliseconds: Int64, compact: Bool) -> String {
        let value = max(milliseconds, 0)
        let hours = value / 3_600_000
        let minutes = value % 3_600_000 / 60_000
        if compact {
            if hours > 0 { return minutes > 0 ? "\(hours)时\(minutes)分" : "\(hours)小时" }
            return "\(minutes)分钟"
        }
        let seconds = value % 60_000 / 1_000
        if hours > 0 { return minutes > 0 ? "\(hours)小时 \(minutes)分钟" : "\(hours)小时" }
        if minutes > 0 { return "\(minutes)分钟" }
        return "\(seconds)秒"
    }
}
