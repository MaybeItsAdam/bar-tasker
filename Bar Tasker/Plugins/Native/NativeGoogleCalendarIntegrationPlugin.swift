import Foundation

@MainActor
final class NativeGoogleCalendarIntegrationPlugin: GoogleCalendarIntegrationPlugin {
  let pluginIdentifier = "native.google.calendar.integration"
  let displayName = "Native Google Calendar Integration"

  private let defaultEventDurationMinutes: Int
  private let calendar: Calendar

  init(defaultEventDurationMinutes: Int = 30, calendar: Calendar = .current) {
    self.defaultEventDurationMinutes = max(defaultEventDurationMinutes, 1)
    self.calendar = calendar
  }

  func makeCreateEventURL(task: CheckvistTask, listId: String, now: Date) -> URL? {
    var components = URLComponents(string: "https://calendar.google.com/calendar/render")

    let title =
      task.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
      ? "Checkvist Task #\(task.id)" : task.content

    let details = """
      Created from Bar Tasker
      List ID: \(listId)
      Task ID: \(task.id)
      """

    var queryItems: [URLQueryItem] = [
      .init(name: "action", value: "TEMPLATE"),
      .init(name: "text", value: title),
      .init(name: "details", value: details),
      .init(name: "ctz", value: calendar.timeZone.identifier),
    ]

    if let datesValue = eventDatesValue(task: task, now: now) {
      queryItems.append(.init(name: "dates", value: datesValue))
    }

    components?.queryItems = queryItems
    return components?.url
  }

  private func eventDatesValue(task: CheckvistTask, now: Date) -> String? {
    if let dueDate = task.dueDate {
      if hasExplicitDueTime(rawDue: task.due) {
        let end = dueDate.addingTimeInterval(Double(defaultEventDurationMinutes * 60))
        return "\(formatDateTimeUTC(dueDate))/\(formatDateTimeUTC(end))"
      }

      let startOfDay = calendar.startOfDay(for: dueDate)
      guard let endOfDay = calendar.date(byAdding: .day, value: 1, to: startOfDay) else {
        return nil
      }
      return "\(formatDateOnly(startOfDay))/\(formatDateOnly(endOfDay))"
    }

    let start = now
    let end = start.addingTimeInterval(Double(defaultEventDurationMinutes * 60))
    return "\(formatDateTimeUTC(start))/\(formatDateTimeUTC(end))"
  }

  private func hasExplicitDueTime(rawDue: String?) -> Bool {
    guard let rawDue else { return false }
    let normalized = rawDue.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    guard !normalized.isEmpty, normalized != "asap" else { return false }

    if normalized.range(of: #"^\d{4}-\d{1,2}-\d{1,2}$"#, options: .regularExpression) != nil {
      return false
    }

    return normalized.contains(":")
      || normalized.contains("t")
      || normalized.contains("am")
      || normalized.contains("pm")
  }

  private func formatDateTimeUTC(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyyMMdd'T'HHmmss'Z'"
    return formatter.string(from: date)
  }

  private func formatDateOnly(_ date: Date) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = calendar.timeZone
    formatter.dateFormat = "yyyyMMdd"
    return formatter.string(from: date)
  }
}
