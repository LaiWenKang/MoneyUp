import Foundation

/// Passive widgets expose destinations, never an action or financial payload.
enum MoneyUpOverviewRoute: CaseIterable, Equatable, Sendable {
    case today
    case budget

    var url: URL? {
        switch self {
        case .today: URL(string: "moneyup://overview/today")
        case .budget: URL(string: "moneyup://overview/budget")
        }
    }

    init?(exactDeepLink url: URL) {
        guard url.baseURL == nil, url.relativeString == url.absoluteString,
              let route = Self.allCases.first(where: { $0.url?.absoluteString == url.absoluteString })
        else { return nil }
        self = route
    }
}
