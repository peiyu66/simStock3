import SwiftUI

/// The setting stores a Date instant but selects a Taiwan calendar day.
/// Both limit dates use the same captured clock value.
struct TaiwanSimulationDatePicker: View {
    @Binding var selection: Date
    var asOf: Date = twDateTime.now()

    var body: some View {
        DatePicker("起始日期", selection: $selection,
                   in: twDateTime.simulationStartRange(asOf: asOf), displayedComponents: .date)
            .environment(\.locale, twDateTime.locale)
            .environment(\.calendar, twDateTime.calendar)
            .environment(\.timeZone, twDateTime.timeZone)
    }
}
