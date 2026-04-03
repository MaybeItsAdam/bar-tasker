import Foundation

/// A recurring task rule stored as a raw string in UserDefaults.
/// Supported patterns:
///   "daily"                  – every day
///   "weekdays"               – Mon–Fri
///   "weekly"                 – same weekday each week
///   "every 3 days"           – every N days
///   "every 2 weeks"          – every N weeks
///   "every monday"           – every specific weekday
struct BarTaskerRecurrenceRule: Equatable {
  let raw: String

  // MARK: - Parsing

  static func from(_ raw: String) -> BarTaskerRecurrenceRule? {
    let normalized = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalized.isEmpty else { return nil }
    let rule = BarTaskerRecurrenceRule(raw: normalized)
    // Validate by attempting to compute next due date from a sample date
    let sample = Date()
    guard rule.nextDueDate(from: sample) != nil else { return nil }
    return rule
  }

  // MARK: - Display

  var displayLabel: String {
    switch raw {
    case "daily": return "Daily"
    case "weekdays": return "Weekdays"
    case "weekly": return "Weekly"
    default: break
    }

    if let (n, unit) = everyNComponents() {
      let unitStr = unit == "day" ? (n == 1 ? "day" : "days") : (n == 1 ? "week" : "weeks")
      return "Every \(n) \(unitStr)"
    }

    if let weekday = weekdayNumber(from: raw.replacingOccurrences(of: "every ", with: "")) {
      return "Every \(weekdayName(weekday))"
    }

    return raw.capitalized
  }

  // MARK: - Next Due Date

  func nextDueDate(from current: Date, calendar: Calendar = .current) -> Date? {
    switch raw {
    case "daily":
      return calendar.date(byAdding: .day, value: 1, to: current)

    case "weekdays":
      var next = calendar.date(byAdding: .day, value: 1, to: current)!
      for _ in 0..<7 {
        let weekday = calendar.component(.weekday, from: next)
        // weekday 1 = Sunday, 7 = Saturday
        if weekday != 1 && weekday != 7 { return next }
        next = calendar.date(byAdding: .day, value: 1, to: next)!
      }
      return nil

    case "weekly":
      return calendar.date(byAdding: .weekOfYear, value: 1, to: current)

    default:
      break
    }

    if let (n, unit) = everyNComponents() {
      let component: Calendar.Component = unit == "week" ? .weekOfYear : .day
      return calendar.date(byAdding: component, value: n, to: current)
    }

    // "every <weekday>"
    let weekdayPart = raw.replacingOccurrences(of: "every ", with: "")
    if let targetWeekday = weekdayNumber(from: weekdayPart) {
      var next = calendar.date(byAdding: .day, value: 1, to: current)!
      for _ in 0..<8 {
        if calendar.component(.weekday, from: next) == targetWeekday { return next }
        next = calendar.date(byAdding: .day, value: 1, to: next)!
      }
      return nil
    }

    return nil
  }

  // MARK: - Private helpers

  private func everyNComponents() -> (Int, String)? {
    // Matches "every N day(s)" or "every N week(s)"
    let pattern = #"^every\s+(\d+)\s+(day|days|week|weeks|wk|wks)$"#
    guard
      let regex = try? NSRegularExpression(pattern: pattern),
      let match = regex.firstMatch(
        in: raw, range: NSRange(raw.startIndex..., in: raw))
    else { return nil }

    guard
      let nRange = Range(match.range(at: 1), in: raw),
      let unitRange = Range(match.range(at: 2), in: raw),
      let n = Int(raw[nRange])
    else { return nil }

    let unitRaw = String(raw[unitRange])
    let unit = unitRaw.hasPrefix("week") || unitRaw.hasPrefix("wk") ? "week" : "day"
    return (n, unit)
  }

  private func weekdayNumber(from name: String) -> Int? {
    // Returns Calendar weekday number: 1=Sun, 2=Mon, ..., 7=Sat
    switch name.lowercased() {
    case "sunday", "sun": return 1
    case "monday", "mon": return 2
    case "tuesday", "tue": return 3
    case "wednesday", "wed": return 4
    case "thursday", "thu": return 5
    case "friday", "fri": return 6
    case "saturday", "sat": return 7
    default: return nil
    }
  }

  private func weekdayName(_ weekday: Int) -> String {
    switch weekday {
    case 1: return "Sunday"
    case 2: return "Monday"
    case 3: return "Tuesday"
    case 4: return "Wednesday"
    case 5: return "Thursday"
    case 6: return "Friday"
    case 7: return "Saturday"
    default: return "Day \(weekday)"
    }
  }
}
