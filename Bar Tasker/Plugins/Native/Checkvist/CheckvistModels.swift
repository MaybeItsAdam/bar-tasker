import Foundation

extension KeyedDecodingContainer {
  fileprivate func decodeLossyString(forKey key: Key) -> String? {
    if let value = try? decodeIfPresent(String.self, forKey: key) {
      return value
    }
    if let value = try? decodeIfPresent(Int.self, forKey: key) {
      return String(value)
    }
    if let value = try? decodeIfPresent(Double.self, forKey: key) {
      return String(value)
    }
    if let value = try? decodeIfPresent(Bool.self, forKey: key) {
      return value ? "true" : "false"
    }
    return nil
  }

  fileprivate func decodeLossyInt(forKey key: Key) -> Int? {
    if let value = try? decodeIfPresent(Int.self, forKey: key) {
      return value
    }
    if let value = try? decodeIfPresent(String.self, forKey: key) {
      return Int(value)
    }
    if let value = try? decodeIfPresent(Double.self, forKey: key) {
      return Int(value)
    }
    return nil
  }
}

struct CheckvistNote: Codable, Identifiable, Sendable, Equatable {
  let id: Int?
  let content: String
  let createdAt: String?
  let updatedAt: String?

  enum CodingKeys: String, CodingKey {
    case id, content
    case createdAt = "created_at"
    case updatedAt = "updated_at"
  }

  private enum DecodingKeys: String, CodingKey {
    case id, content
    case text
    case note
    case createdAt = "created_at"
    case updatedAt = "updated_at"
  }

  init(id: Int?, content: String, createdAt: String?, updatedAt: String?) {
    self.id = id
    self.content = content
    self.createdAt = createdAt
    self.updatedAt = updatedAt
  }

  init(from decoder: Decoder) throws {
    if let singleValue = try? decoder.singleValueContainer() {
      if let stringValue = try? singleValue.decode(String.self) {
        self.init(id: nil, content: stringValue, createdAt: nil, updatedAt: nil)
        return
      }
    }

    let container = try decoder.container(keyedBy: DecodingKeys.self)
    let id = container.decodeLossyInt(forKey: .id)
    let content =
      container.decodeLossyString(forKey: .content)
      ?? container.decodeLossyString(forKey: .text)
      ?? container.decodeLossyString(forKey: .note)
      ?? ""
    let createdAt = container.decodeLossyString(forKey: .createdAt)
    let updatedAt = container.decodeLossyString(forKey: .updatedAt)
    self.init(id: id, content: content, createdAt: createdAt, updatedAt: updatedAt)
  }
}

struct CheckvistTask: Codable, Identifiable, Sendable, Equatable {
  let id: Int
  let content: String
  let status: Int
  let due: String?
  let position: Int?
  let parentId: Int?
  let level: Int?
  let notes: [CheckvistNote]?
  let updatedAt: String?

  enum CodingKeys: String, CodingKey {
    case id, content, status, due, position
    case parentId = "parent_id"
    case level, notes
    case updatedAt = "updated_at"
  }

  private enum DecodingKeys: String, CodingKey {
    case id, content, status, due, position
    case parentId = "parent_id"
    case level, notes
    case text
    case updatedAt = "updated_at"
  }

  init(
    id: Int,
    content: String,
    status: Int,
    due: String?,
    position: Int?,
    parentId: Int?,
    level: Int?,
    notes: [CheckvistNote]? = nil,
    updatedAt: String? = nil
  ) {
    self.id = id
    self.content = content
    self.status = status
    self.due = due
    self.position = position
    self.parentId = parentId
    self.level = level
    self.notes = notes
    self.updatedAt = updatedAt
  }

  init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: DecodingKeys.self)

    guard let id = container.decodeLossyInt(forKey: .id) else {
      throw DecodingError.keyNotFound(
        DecodingKeys.id,
        .init(codingPath: decoder.codingPath, debugDescription: "Task id is missing")
      )
    }

    let content =
      container.decodeLossyString(forKey: .content)
      ?? container.decodeLossyString(forKey: .text)
      ?? ""
    let status = container.decodeLossyInt(forKey: .status) ?? 0
    let due = container.decodeLossyString(forKey: .due)
    let position = container.decodeLossyInt(forKey: .position)
    let parentId = container.decodeLossyInt(forKey: .parentId)
    let level = container.decodeLossyInt(forKey: .level)
    let updatedAt = container.decodeLossyString(forKey: .updatedAt)

    let notes: [CheckvistNote]?
    if let decodedNotes = try? container.decodeIfPresent([CheckvistNote].self, forKey: .notes) {
      notes = decodedNotes
    } else if let singleNote = try? container.decode(CheckvistNote.self, forKey: .notes) {
      notes = [singleNote]
    } else if let noteStrings = try? container.decodeIfPresent([String].self, forKey: .notes) {
      notes = noteStrings.map {
        CheckvistNote(id: nil, content: $0, createdAt: nil, updatedAt: nil)
      }
    } else if let noteString = try? container.decodeIfPresent(String.self, forKey: .notes) {
      notes = [CheckvistNote(id: nil, content: noteString, createdAt: nil, updatedAt: nil)]
    } else {
      notes = nil
    }

    self.init(
      id: id,
      content: content,
      status: status,
      due: due,
      position: position,
      parentId: parentId,
      level: level,
      notes: notes,
      updatedAt: updatedAt
    )
  }

  private static let dueDateFormatters: [DateFormatter] = {
    let locale = Locale(identifier: "en_US_POSIX")

    let dateOnly = DateFormatter()
    dateOnly.locale = locale
    dateOnly.dateFormat = "yyyy-MM-dd"

    let dateOnlyNoPadding = DateFormatter()
    dateOnlyNoPadding.locale = locale
    dateOnlyNoPadding.dateFormat = "yyyy-M-d"

    let dateTime = DateFormatter()
    dateTime.locale = locale
    dateTime.dateFormat = "yyyy-MM-dd HH:mm:ss Z"

    return [dateOnly, dateOnlyNoPadding, dateTime]
  }()

  private static let iso8601Parsers: [ISO8601DateFormatter] = {
    let internet = ISO8601DateFormatter()
    internet.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate]

    let internetFractional = ISO8601DateFormatter()
    internetFractional.formatOptions = [
      .withInternetDateTime, .withFractionalSeconds, .withDashSeparatorInDate,
    ]

    let fullDate = ISO8601DateFormatter()
    fullDate.formatOptions = [.withFullDate, .withDashSeparatorInDate]

    return [internet, internetFractional, fullDate]
  }()

  var dueDate: Date? {
    guard let dueRaw = due?.trimmingCharacters(in: .whitespacesAndNewlines), !dueRaw.isEmpty else {
      return nil
    }

    for parser in Self.iso8601Parsers {
      if let parsed = parser.date(from: dueRaw) {
        return parsed
      }
    }

    for formatter in Self.dueDateFormatters {
      if let parsed = formatter.date(from: dueRaw) {
        return parsed
      }
    }

    // Common fallback for strings like "yyyy-MM-ddTHH:mm:ssZ"
    if dueRaw.count >= 10 {
      let dayPrefix = String(dueRaw.prefix(10))
      for formatter in Self.dueDateFormatters {
        if let parsed = formatter.date(from: dayPrefix) {
          return parsed
        }
      }
    }

    return nil
  }

  var isOverdue: Bool {
    guard let resolvedDueDate = dueDate else { return false }
    return resolvedDueDate < Calendar.current.startOfDay(for: Date())
  }

  var isDueToday: Bool {
    guard let resolvedDueDate = dueDate else { return false }
    return Calendar.current.isDateInToday(resolvedDueDate)
  }

  var hasNotes: Bool {
    guard let notes else { return false }
    return notes.contains { !$0.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
  }
}

struct CheckvistList: Codable, Identifiable, Sendable, Equatable {
  let id: Int
  let name: String
  let archived: Bool?
  let readOnly: Bool?

  enum CodingKeys: String, CodingKey {
    case id, name, archived
    case readOnly = "read_only"
  }
}
