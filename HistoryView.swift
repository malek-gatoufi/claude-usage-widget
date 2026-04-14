import SwiftUI
import Charts

struct HistoryView: View {
    @StateObject private var vm = HistoryViewModel()
    private let orange = Color(red: 0.81, green: 0.48, blue: 0.34)

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            Text("Historique d'utilisation")
                .font(.title2.bold())

            Picker("Période", selection: $vm.range) {
                Text("24h").tag(HistoryViewModel.Range.h24)
                Text("7 jours").tag(HistoryViewModel.Range.d7)
            }
            .pickerStyle(.segmented)
            .frame(maxWidth: 200)

            if vm.filtered.isEmpty {
                ContentUnavailableView(
                    "Pas encore de données",
                    systemImage: "chart.line.uptrend.xyaxis",
                    description: Text("L'historique se remplit au fil du temps.")
                )
                .frame(maxHeight: 260)
            } else {
                Chart {
                    ForEach(vm.filtered) { pt in
                        LineMark(
                            x: .value("Date", pt.date),
                            y: .value("Session", pt.session),
                            series: .value("Série", "Session")
                        )
                        .foregroundStyle(orange)
                        .interpolationMethod(.catmullRom)

                        LineMark(
                            x: .value("Date", pt.date),
                            y: .value("Weekly", pt.weekly),
                            series: .value("Série", "Weekly")
                        )
                        .foregroundStyle(.blue)
                        .interpolationMethod(.catmullRom)

                        if let s45 = pt.sonnet45 {
                            LineMark(
                                x: .value("Date", pt.date),
                                y: .value("Sonnet", s45),
                                series: .value("Série", "Sonnet 4.5")
                            )
                            .foregroundStyle(.purple)
                            .interpolationMethod(.catmullRom)
                        }
                    }
                }
                .chartYScale(domain: 0...100)
                .chartYAxis {
                    AxisMarks(values: [0, 25, 50, 75, 100]) { v in
                        AxisGridLine()
                        AxisValueLabel { Text("\(v.as(Int.self) ?? 0)%") }
                    }
                }
                .chartXAxis {
                    AxisMarks(preset: .automatic, values: .stride(by: vm.xStride)) { v in
                        AxisGridLine()
                        AxisValueLabel(format: vm.xFormat)
                    }
                }
                .frame(height: 260)

                // Legend
                HStack(spacing: 16) {
                    legendDot(color: orange, label: "Session")
                    legendDot(color: .blue,  label: "Weekly")
                    legendDot(color: .purple, label: "Sonnet 4.5")
                }
                .font(.caption)
            }

            Spacer()
        }
        .padding(24)
        .frame(minWidth: 520, minHeight: 380)
    }

    private func legendDot(color: Color, label: String) -> some View {
        HStack(spacing: 5) {
            Circle().fill(color).frame(width: 8, height: 8)
            Text(label).foregroundStyle(.secondary)
        }
    }
}

// MARK: - ViewModel

@MainActor
final class HistoryViewModel: ObservableObject {
    enum Range { case h24, d7 }

    @Published var range: Range = .h24

    var filtered: [HistoryPoint] {
        let cutoff: Date
        switch range {
        case .h24: cutoff = Date().addingTimeInterval(-86400)
        case .d7:  cutoff = Date().addingTimeInterval(-7 * 86400)
        }
        return HistoryStore.shared.points.filter { $0.date >= cutoff }
    }

    var xStride: Calendar.Component {
        range == .h24 ? .hour : .day
    }

    var xFormat: Date.FormatStyle {
        range == .h24
            ? .dateTime.hour(.twoDigits(amPM: .abbreviated))
            : .dateTime.weekday(.abbreviated)
    }
}
