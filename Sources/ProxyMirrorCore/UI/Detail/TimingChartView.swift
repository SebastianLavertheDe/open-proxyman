import SwiftUI

/// 耗时瀑布图（对齐 Proxyman TimingChart：请求/等待响应/内容下载 三段瀑布）
struct TimingChartView: View {
    let tx: Transaction

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                Text(Strings.Detail.timingChart)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 14)
                    .padding(.top, 8)

                if let start = Optional(tx.startedAt), total > 0 {
                    waterfall
                    legend
                    phaseRows
                } else {
                    Text(Strings.Detail.waitingForRequestToComplete)
                        .font(.system(size: 12))
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 14)
                }
            }
            .padding(.bottom, 14)
        }
    }

    // MARK: 阶段计算

    private var start: Date { tx.startedAt }
    private var connected: Date? { tx.tConnected }
    private var headerAt: Date? { tx.tHeaderAt }
    private var end: Date { Self.endDate(for: tx) }

    static func endDate(for tx: Transaction) -> Date {
        let terminal = tx.state == .completed || tx.state == .failed
        return max(tx.tHeaderAt ?? tx.startedAt,
                   terminal ? tx.startedAt.addingTimeInterval(tx.duration) : tx.startedAt)
    }
    private var total: TimeInterval {
        let e = end.timeIntervalSince(start)
        return e > 0 ? e : (tx.duration > 0 ? tx.duration : 0)
    }

    private var connectDur: TimeInterval { (connected ?? headerAt ?? end).timeIntervalSince(start) }
    private var waitDur: TimeInterval {
        guard let c = connected, let h = headerAt else { return 0 }
        return max(h.timeIntervalSince(c), 0)
    }
    private var downloadDur: TimeInterval {
        guard let h = headerAt else { return 0 }
        return max(end.timeIntervalSince(h), 0)
    }

    // MARK: 瀑布图

    private var waterfall: some View {
        let t = max(total, 0.001)
        let wConnect = min(connectDur / t, 1)
        let wWait = min(waitDur / t, 1 - wConnect)
        let wDownload = max(1 - wConnect - wWait, 0)

        return GeometryReader { geo in
            VStack(alignment: .leading, spacing: 0) {
                HStack(spacing: 0) {
                    if wConnect > 0.001 {
                        segment(width: geo.size.width * wConnect, color: .blue,
                                label: Strings.Detail.connect, ms: connectDur)
                    }
                    if wWait > 0.001 {
                        segment(width: geo.size.width * wWait, color: .orange,
                                label: Strings.Detail.wait, ms: waitDur)
                    }
                    if wDownload > 0.001 {
                        segment(width: geo.size.width * wDownload, color: .green,
                                label: Strings.Detail.download, ms: downloadDur)
                    }
                }
                .frame(height: 26)
                .clipShape(RoundedRectangle(cornerRadius: 5))
            }
        }
        .frame(height: 26)
        .padding(.horizontal, 14)
    }

    private func segment(width: CGFloat, color: Color, label: String, ms: TimeInterval) -> some View {
        ZStack {
            Rectangle().fill(color.opacity(0.75))
            if width > 46 {
                Text("\(label) \(String(format: "%.0f", ms * 1000))ms")
                    .font(.system(size: 10))
                    .foregroundColor(.white)
            }
        }
    }

    private var legend: some View {
        VStack(alignment: .leading, spacing: 6) {
            legendRow(Strings.Detail.connectSendRequest, connectDur, .blue)
            legendRow(Strings.Detail.waitForResponseTtfb, waitDur, .orange)
            legendRow(Strings.Detail.contentDownload, downloadDur, .green)
            HStack {
                Text(Strings.Detail.totalDuration)
                    .font(.system(size: 12, weight: .semibold))
                Text(String(format: "%.0f ms", total * 1000))
                    .font(.system(size: 12, weight: .semibold).monospacedDigit())
            }
        }
        .padding(.horizontal, 14)
    }

    private func legendRow(_ label: String, _ dur: TimeInterval, _ color: Color) -> some View {
        HStack(spacing: 6) {
            Circle().fill(color.opacity(0.75)).frame(width: 8, height: 8)
            Text(label).font(.system(size: 12)).foregroundColor(.secondary)
            Spacer(minLength: 0)
            Text(String(format: "%.0f ms", dur * 1000))
                .font(.system(size: 12).monospacedDigit())
                .foregroundColor(.primary)
        }
        .frame(maxWidth: 320)
    }

    private var phaseRows: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(Strings.Detail.phase).font(.system(size: 12, weight: .semibold)).foregroundColor(.secondary)
            kv(Strings.Detail.startTime, tx.timeText)
            if let c = connected { kv(Strings.Detail.upstreamConnected, DateFormatter.localizedString(from: c, dateStyle: .none, timeStyle: .medium)) }
            if let h = headerAt { kv(Strings.Detail.responseHeadersArrived, DateFormatter.localizedString(from: h, dateStyle: .none, timeStyle: .medium)) }
            kv(Strings.Detail.done, tx.state == .completed ? Strings.Detail.downloaded : (tx.state == .failed ? Strings.Detail.failed : Strings.Detail.inProgress))
        }
        .padding(.horizontal, 14)
    }

    private func kv(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.system(size: 12)).foregroundColor(.secondary)
            Spacer(minLength: 0)
            Text(v).font(.system(size: 12).monospacedDigit())
        }
        .frame(maxWidth: 320)
    }
}
