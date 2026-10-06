import Foundation
import MoneyUpCore

/// The wording of each reminder, resolved through the app's language choice.
@MainActor
enum ReminderText {
    static func title(for message: ReminderMessage) -> String {
        switch message {
        case let .due(kind, leadDays):
            return dueTitle(income: kind == .income, leadDays: leadDays)
        case let .dueDetail(_, leadDays, name, _):
            return detailTitle(name: name, leadDays: leadDays)
        case .dailyLog:
            return AppLocalization.string("reminder.daily_title")
        case .weeklyReview:
            return AppLocalization.string("reminder.weekly_title")
        case .test:
            return AppLocalization.string("reminder.test_title")
        }
    }

    static func body(for message: ReminderMessage) -> String {
        switch message {
        case .due:
            return AppLocalization.string("reminder.due_body")
        case let .dueDetail(kind, _, _, amount):
            return String(
                format: AppLocalization.string(kind == .income ? "reminder.income_detail_format" : "reminder.payment_detail_format"),
                formattedMoneyForNotification(amount)
            )
        case .dailyLog:
            return AppLocalization.string("reminder.daily_body")
        case .weeklyReview:
            return AppLocalization.string("reminder.weekly_body")
        case .test:
            return AppLocalization.string("reminder.test_body")
        }
    }

    /// Notifications of one thread stack together on the Lock Screen.
    static func thread(for message: ReminderMessage) -> String {
        switch message {
        case .due, .dueDetail: "moneyup.reminder.due"
        case .dailyLog: "moneyup.reminder.daily"
        case .weeklyReview: "moneyup.reminder.weekly"
        case .test: "moneyup.reminder.test"
        }
    }

    private static func dueTitle(income: Bool, leadDays: Int) -> String {
        switch leadDays {
        case ..<1:
            return AppLocalization.string(income ? "reminder.income_due" : "reminder.payment_due")
        case 1:
            return AppLocalization.string(income ? "reminder.income_due_tomorrow" : "reminder.payment_due_tomorrow")
        default:
            return String(
                format: AppLocalization.string(income ? "reminder.income_due_days_format" : "reminder.payment_due_days_format"),
                leadDays
            )
        }
    }

    private static func detailTitle(name: String, leadDays: Int) -> String {
        switch leadDays {
        case ..<1:
            return String(format: AppLocalization.string("reminder.due_detail_title_format"), name)
        case 1:
            return String(format: AppLocalization.string("reminder.due_detail_tomorrow_format"), name)
        default:
            return String(format: AppLocalization.string("reminder.due_detail_days_format"), name, leadDays)
        }
    }
}
