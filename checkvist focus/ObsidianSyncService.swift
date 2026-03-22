import AppKit
import Foundation

enum ObsidianOpenMode {
  case standard
  case newWindow
}

final class ObsidianSyncService {
  private static let bookmarkDefaultsKey = "obsidianInboxBookmark"
  private static let linkedFolderBookmarksDefaultsKey = "obsidianLinkedFolderBookmarksByTaskId"
  private static let obsidianBundleIdentifier = "md.obsidian"
  private static let remoteTimestampParsers: [ISO8601DateFormatter] = {
    let internet = ISO8601DateFormatter()
    internet.formatOptions = [.withInternetDateTime, .withDashSeparatorInDate]

    let internetFractional = ISO8601DateFormatter()
    internetFractional.formatOptions = [
      .withInternetDateTime, .withFractionalSeconds, .withDashSeparatorInDate,
    ]

    return [internetFractional, internet]
  }()
  private static let remoteDateFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.dateFormat = "yyyy-MM-dd HH:mm:ss Z"
    return formatter
  }()

  private var inboxBookmark: Data?
  private var linkedFolderBookmarksByTaskId: [Int: String]

  init(defaults: UserDefaults = .standard) {
    self.inboxBookmark = defaults.data(forKey: Self.bookmarkDefaultsKey)
    let rawLinkedBookmarks =
      (defaults.dictionary(forKey: Self.linkedFolderBookmarksDefaultsKey) as? [String: String])
      ?? [:]
    self.linkedFolderBookmarksByTaskId = rawLinkedBookmarks.reduce(into: [:]) {
      partialResult, entry in
      guard let taskId = Int(entry.key) else { return }
      partialResult[taskId] = entry.value
    }
  }

  var inboxPath: String {
    Self.pathFromBookmarkData(inboxBookmark) ?? ""
  }

  @MainActor
  func chooseInboxFolder() throws -> String? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    panel.prompt = "Choose Inbox"
    panel.message = "Select your Obsidian Inbox folder."

    guard panel.runModal() == .OK, let selectedURL = panel.url else { return nil }

    let bookmark = try selectedURL.bookmarkData(
      options: [.withSecurityScope],
      includingResourceValuesForKeys: nil,
      relativeTo: nil
    )

    inboxBookmark = bookmark
    UserDefaults.standard.set(bookmark, forKey: Self.bookmarkDefaultsKey)
    return selectedURL.path
  }

  func clearInboxFolder() {
    inboxBookmark = nil
    UserDefaults.standard.removeObject(forKey: Self.bookmarkDefaultsKey)
  }

  @MainActor
  func chooseLinkedFolder(forTaskId taskId: Int, taskContent: String) throws -> String? {
    let panel = NSOpenPanel()
    panel.canChooseFiles = false
    panel.canChooseDirectories = true
    panel.allowsMultipleSelection = false
    panel.canCreateDirectories = true
    panel.prompt = "Link Folder"
    panel.message = "Select the Obsidian folder to use for \"\(taskContent)\" and its subtasks."

    guard panel.runModal() == .OK, let selectedURL = panel.url else { return nil }

    let bookmark = try selectedURL.bookmarkData(
      options: [.withSecurityScope],
      includingResourceValuesForKeys: nil,
      relativeTo: nil
    )

    linkedFolderBookmarksByTaskId[taskId] = bookmark.base64EncodedString()
    persistLinkedFolderBookmarks()
    return selectedURL.path
  }

  func clearLinkedFolder(forTaskId taskId: Int) {
    linkedFolderBookmarksByTaskId.removeValue(forKey: taskId)
    persistLinkedFolderBookmarks()
  }

  func linkedFolderPath(forTaskId taskId: Int) -> String? {
    guard let bookmark = bookmarkDataForLinkedTask(taskId) else { return nil }
    return Self.pathFromBookmarkData(bookmark)
  }

  func hasLinkedFolder(forTaskId taskId: Int) -> Bool {
    linkedFolderPath(forTaskId: taskId) != nil
  }

  func syncTask(
    _ task: CheckvistTask,
    listId: String,
    linkedFolderTaskId: Int? = nil,
    openMode: ObsidianOpenMode = .standard,
    syncDate: Date = Date()
  ) throws -> URL {
    let inboxURL = try resolvedDestinationFolderURL(linkedFolderTaskId: linkedFolderTaskId)
    let markdownURL = try writeTaskMarkdown(
      task: task,
      listId: listId,
      inboxURL: inboxURL,
      syncDate: syncDate
    )
    openInObsidian(markdownURL, mode: openMode)
    return markdownURL
  }

  private func persistLinkedFolderBookmarks() {
    let raw = Dictionary(
      uniqueKeysWithValues: linkedFolderBookmarksByTaskId.map { (String($0.key), $0.value) })
    UserDefaults.standard.set(raw, forKey: Self.linkedFolderBookmarksDefaultsKey)
  }

  private func bookmarkDataForLinkedTask(_ taskId: Int) -> Data? {
    guard
      let base64 = linkedFolderBookmarksByTaskId[taskId],
      let bookmark = Data(base64Encoded: base64)
    else { return nil }
    return bookmark
  }

  private func resolvedDestinationFolderURL(linkedFolderTaskId: Int?) throws -> URL {
    if let linkedFolderTaskId,
      let linkedURL = try resolvedLinkedFolderURL(forTaskId: linkedFolderTaskId)
    {
      return linkedURL
    }
    return try resolvedInboxURL()
  }

  private func resolvedInboxURL() throws -> URL {
    guard let bookmarkData = inboxBookmark else {
      throw ObsidianSyncError.inboxFolderNotConfigured
    }

    var isStale = false
    let resolvedURL = try URL(
      resolvingBookmarkData: bookmarkData,
      options: [.withSecurityScope],
      relativeTo: nil,
      bookmarkDataIsStale: &isStale
    )

    if isStale {
      let refreshedBookmark = try resolvedURL.bookmarkData(
        options: [.withSecurityScope],
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
      inboxBookmark = refreshedBookmark
      UserDefaults.standard.set(refreshedBookmark, forKey: Self.bookmarkDefaultsKey)
    }

    return resolvedURL
  }

  private func resolvedLinkedFolderURL(forTaskId taskId: Int) throws -> URL? {
    guard let bookmarkData = bookmarkDataForLinkedTask(taskId) else { return nil }

    var isStale = false
    let resolvedURL = try URL(
      resolvingBookmarkData: bookmarkData,
      options: [.withSecurityScope],
      relativeTo: nil,
      bookmarkDataIsStale: &isStale
    )

    if isStale {
      let refreshedBookmark = try resolvedURL.bookmarkData(
        options: [.withSecurityScope],
        includingResourceValuesForKeys: nil,
        relativeTo: nil
      )
      linkedFolderBookmarksByTaskId[taskId] = refreshedBookmark.base64EncodedString()
      persistLinkedFolderBookmarks()
    }

    return resolvedURL
  }

  private func writeTaskMarkdown(task: CheckvistTask, listId: String, inboxURL: URL, syncDate: Date)
    throws -> URL
  {
    let accessed = inboxURL.startAccessingSecurityScopedResource()
    defer {
      if accessed {
        inboxURL.stopAccessingSecurityScopedResource()
      }
    }

    try FileManager.default.createDirectory(at: inboxURL, withIntermediateDirectories: true)

    let safeName = sanitizeTaskFileName(task.content)
    let markdownURL = inboxURL.appendingPathComponent("\(safeName).md")
    let localCreationDate = try? fileCreationDate(at: markdownURL)
    let latestRemoteUpdate = latestRemoteUpdateDate(for: task)

    if let localCreationDate, let latestRemoteUpdate, latestRemoteUpdate < localCreationDate {
      return markdownURL
    }

    let markdown = markdownDocument(for: task, listId: listId, syncDate: syncDate)
    try markdown.write(to: markdownURL, atomically: true, encoding: .utf8)
    return markdownURL
  }

  private func openInObsidian(_ markdownURL: URL, mode: ObsidianOpenMode) {
    let obsidianURL = makeObsidianOpenURL(for: markdownURL, mode: mode)

    if let obsidianAppURL = NSWorkspace.shared.urlForApplication(
      withBundleIdentifier: Self.obsidianBundleIdentifier)
    {
      let fileOpenConfiguration = NSWorkspace.OpenConfiguration()
      fileOpenConfiguration.activates = mode == .standard
      NSWorkspace.shared.open(
        [markdownURL], withApplicationAt: obsidianAppURL, configuration: fileOpenConfiguration
      ) { _, _ in
        guard let obsidianURL else { return }
        let delay: TimeInterval = mode == .newWindow ? 0.8 : 0.4
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
          let uriOpenConfiguration = NSWorkspace.OpenConfiguration()
          uriOpenConfiguration.activates = mode == .standard
          NSWorkspace.shared.open(
            [obsidianURL], withApplicationAt: obsidianAppURL, configuration: uriOpenConfiguration
          ) { _, _ in }
        }
      }
      return
    }

    if let obsidianURL, NSWorkspace.shared.open(obsidianURL) {
      return
    }

    NSWorkspace.shared.open(markdownURL)
  }

  private func makeObsidianOpenURL(for markdownURL: URL, mode: ObsidianOpenMode) -> URL? {
    var components = URLComponents()
    components.scheme = "obsidian"
    components.host = "open"
    var queryItems = [URLQueryItem(name: "path", value: markdownURL.path)]
    if mode == .newWindow {
      queryItems.append(URLQueryItem(name: "paneType", value: "window"))
    }
    components.queryItems = queryItems
    return components.url
  }

  private func markdownDocument(for task: CheckvistTask, listId: String, syncDate: Date) -> String {
    let iso = ISO8601DateFormatter()
    var lines: [String] = []
    lines.append(task.content)
    lines.append("Checkvist Link: https://checkvist.com/checklists/\(listId)#t\(task.id)")
    lines.append("")
    lines.append("Sync Date: \(iso.string(from: syncDate))")
    lines.append("")
    lines.append("Notes")

    let noteContents = (task.notes ?? [])
      .map(\.content)
      .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }

    if noteContents.isEmpty {
      lines.append("_No notes_")
    } else {
      for noteContent in noteContents {
        lines.append(noteContent)
        lines.append("")
      }
      if lines.last?.isEmpty == true {
        lines.removeLast()
      }
    }

    return lines.joined(separator: "\n")
  }

  private func sanitizeTaskFileName(_ raw: String) -> String {
    let illegal = CharacterSet(charactersIn: "/\\?%*|\"<>:\n\r\t")
    let cleanedScalars = raw.unicodeScalars.map { illegal.contains($0) ? "-" : Character($0) }
    let cleaned = String(cleanedScalars)
      .trimmingCharacters(in: .whitespacesAndNewlines)
      .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
    return cleaned.isEmpty ? "Task" : cleaned
  }

  private func latestRemoteUpdateDate(for task: CheckvistTask) -> Date? {
    var candidates: [Date] = []
    if let taskUpdatedDate = parseRemoteTimestamp(task.updatedAt) {
      candidates.append(taskUpdatedDate)
    }
    for note in task.notes ?? [] {
      if let noteUpdatedDate = parseRemoteTimestamp(note.updatedAt) {
        candidates.append(noteUpdatedDate)
      }
    }
    return candidates.max()
  }

  private func parseRemoteTimestamp(_ raw: String?) -> Date? {
    guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
      return nil
    }
    for parser in Self.remoteTimestampParsers {
      if let parsed = parser.date(from: raw) {
        return parsed
      }
    }
    return Self.remoteDateFormatter.date(from: raw)
  }

  private func fileCreationDate(at url: URL) throws -> Date {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    if let date = attributes[.creationDate] as? Date {
      return date
    }
    if let date = attributes[.modificationDate] as? Date {
      return date
    }
    throw ObsidianSyncError.fileDateUnavailable
  }

  private static func pathFromBookmarkData(_ bookmarkData: Data?) -> String? {
    guard let bookmarkData else { return nil }

    var isStale = false
    guard
      let resolvedURL = try? URL(
        resolvingBookmarkData: bookmarkData,
        options: [.withSecurityScope],
        relativeTo: nil,
        bookmarkDataIsStale: &isStale
      )
    else { return nil }

    return resolvedURL.path
  }
}

enum ObsidianSyncError: LocalizedError {
  case inboxFolderNotConfigured
  case fileDateUnavailable

  var errorDescription: String? {
    switch self {
    case .inboxFolderNotConfigured:
      return "Choose an Obsidian Inbox folder in Settings first."
    case .fileDateUnavailable:
      return "Unable to determine the local file date."
    }
  }
}
