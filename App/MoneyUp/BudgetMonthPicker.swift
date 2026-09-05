import SwiftUI

struct BudgetMonthPicker: View {
    @Binding var selection: Date
    let calendar: Calendar
    @State private var isChoosingMonth = false

    var body: some View {
        HStack(spacing: 12) {
            Button { move(by: -1) } label: {
                Image(systemName: "chevron.left").frame(minWidth: 44, minHeight: 44)
            }.accessibilityLabel("budget.previous_month")
            Button { isChoosingMonth = true } label: {
                Text(selection, format: .dateTime.month(.wide).year())
                    .font(.headline).frame(maxWidth: .infinity, minHeight: 44)
            }
            .accessibilityHint("budget.choose_month")
            Button { move(by: 1) } label: {
                Image(systemName: "chevron.right").frame(minWidth: 44, minHeight: 44)
            }.accessibilityLabel("budget.next_month")
        }
        .buttonStyle(.plain)
        .environment(\.calendar, calendar)
        .environment(\.timeZone, calendar.timeZone)
        .sheet(isPresented: $isChoosingMonth) {
            BudgetMonthSelectionSheet(selection: $selection, calendar: calendar)
        }
    }

    private func move(by months: Int) {
        guard let start = calendar.dateInterval(of: .month, for: selection)?.start,
              let next = calendar.date(byAdding: .month, value: months, to: start),
              calendar.component(.era, from: next) == 1,
              (1...9999).contains(calendar.component(.year, from: next)) else { return }
        selection = next
    }
}

private struct BudgetMonthSelectionSheet: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Binding var selection: Date
    let calendar: Calendar
    @State private var year: String
    @State private var month: Int

    init(selection: Binding<Date>, calendar: Calendar) {
        _selection = selection
        self.calendar = calendar
        _year = State(initialValue: String(calendar.component(.year, from: selection.wrappedValue)))
        _month = State(initialValue: calendar.component(.month, from: selection.wrappedValue))
    }

    private var selectedDate: Date? {
        guard let year = Int(year), (1...9999).contains(year) else { return nil }
        return calendar.date(from: DateComponents(year: year, month: month, day: 1))
    }
    private var yearValidationMessage: String? {
        selectedDate == nil ? AppLocalization.string("budget.invalid_year") : nil
    }
    private var monthNames: [String] {
        var localized = calendar
        localized.locale = locale
        return localized.monthSymbols
    }

    var body: some View {
        NavigationStack {
            Form {
                TextField("budget.year", text: $year)
                    .keyboardType(.numberPad)
                    .moneyUpFieldValidation(yearValidationMessage)
                if let yearValidationMessage { MoneyUpFieldError(message: yearValidationMessage) }
                Picker("budget.month", selection: $month) {
                    ForEach(1...12, id: \.self) { value in
                        Text(monthNames[value - 1]).tag(value)
                    }
                }
            }
            .navigationTitle("budget.choose_month")
            .navigationBarTitleDisplayMode(.inline)
            .scrollDismissesKeyboard(.interactively)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("action.cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("action.apply") {
                        if let selectedDate { selection = selectedDate; dismiss() }
                    }.disabled(selectedDate == nil)
                }
                MoneyUpKeyboardDoneToolbar()
            }
        }
    }
}
