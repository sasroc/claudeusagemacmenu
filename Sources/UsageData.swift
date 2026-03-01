import Foundation

struct UsageData {
    var sessionPercent: Double?        // e.g. 2.0
    var sessionResetText: String?      // e.g. "3 hr 59 min"
    var weeklyPercent: Double?         // e.g. 28.0
    var weeklyResetText: String?       // e.g. "Thu 10:00 PM"
    var extraPercent: Double?          // e.g. 100.0
    var extraAmountSpent: Double?      // e.g. 50.25
    var extraResetText: String?        // e.g. "Mar 1"
    var monthlyLimit: Double?          // e.g. 50.0
    var currentBalance: Double?        // e.g. -0.01
    var lastUpdatedText: String?       // e.g. "less than a minute ago"
}
