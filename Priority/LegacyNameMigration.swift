import Foundation
import OSLog

/// Carries forward the state left behind when the app was renamed.
///
/// Renaming the app changed its bundle identifier, and on macOS that identifier
/// *is* the key to two stores the user's data lives in: `UserDefaults` resolves
/// to `~/Library/Preferences/<bundle id>.plist`, and the Application Support
/// container is named after the app. A rename therefore moves nothing — it
/// silently points the app at empty locations, and the first save writes that
/// emptiness back. Priorities, recurrence rules, the Checkvist list id, every
/// daily and the whole day log would appear to have been deleted by an update.
///
/// This runs before anything reads either store. It is deliberately:
///
/// - **idempotent** — it stops the moment the new location has data, so it is
///   safe on every launch rather than needing a "have I migrated yet?" flag,
///   which is itself state that can be lost or wrong;
/// - **non-destructive** — the old preferences domain and the old directory are
///   left exactly where they are. If anything about the new name turns out to
///   be wrong, the previous state is still on disk. They are safe to delete by
///   hand once a rename has clearly settled.
///
/// The keychain is handled separately, by `CheckvistCredentialStore`'s legacy
/// service list, because credentials need reading through the Security
/// framework rather than copying between files.
enum LegacyNameMigration {
  private static let logger = Logger(
    subsystem: "uk.co.maybeitsadam.priority", category: "migration")

  /// Every identifier this app has shipped under, newest legacy name first.
  /// Append rather than replace: someone updating from two names ago has to
  /// land on their data too.
  private static let legacyBundleIdentifiers = [
    "uk.co.maybeitsadam.bar-tasker"
  ]

  /// Application Support directory names matching those identifiers.
  private static let legacyDirectoryNames = ["Bar Tasker"]

  private static let currentDirectoryName = "Priority"

  static func runIfNeeded() {
    migratePreferences()
    migrateApplicationSupport()
  }

  // MARK: - Preferences

  /// Copies keys the current domain does not already have.
  ///
  /// Key-by-key rather than wholesale so a re-run can never clobber a newer
  /// value with a stale one — which matters because this runs on every launch,
  /// and the old domain is never cleared.
  private static func migratePreferences() {
    let defaults = UserDefaults.standard

    for identifier in legacyBundleIdentifiers {
      guard let legacy = defaults.persistentDomain(forName: identifier), !legacy.isEmpty else {
        continue
      }

      var copied = 0
      for (key, value) in legacy where defaults.object(forKey: key) == nil {
        defaults.set(value, forKey: key)
        copied += 1
      }

      if copied > 0 {
        logger.notice(
          "Carried \(copied, privacy: .public) preference(s) forward from \(identifier, privacy: .public)"
        )
      }
    }
  }

  // MARK: - Application Support

  /// Copies each entry the destination does not already have.
  ///
  /// Entry-by-entry rather than copying the directory wholesale, because the
  /// destination usually *already exists* by the time this runs: `AppDelegate`
  /// builds its object graph in stored-property initialisers, which Swift runs
  /// before `applicationDidFinishLaunching`, and `UserPluginManager` creates
  /// its `Plugins` subdirectory on the way up. A "does the destination exist?"
  /// guard therefore sees a directory containing nothing but `Plugins` and
  /// skips the copy — silently leaving every daily and the whole day log
  /// behind. Asking per entry makes the ordering irrelevant.
  ///
  /// Copied rather than moved: this holds the day log, which is append-only
  /// history that cannot be reconstructed, so leaving the original in place
  /// costs a few kilobytes and buys a way back.
  private static func migrateApplicationSupport() {
    let manager = FileManager.default
    guard
      let base = manager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    else { return }

    let destination = base.appendingPathComponent(currentDirectoryName, isDirectory: true)

    for name in legacyDirectoryNames {
      let source = base.appendingPathComponent(name, isDirectory: true)
      guard
        let entries = try? manager.contentsOfDirectory(
          at: source, includingPropertiesForKeys: nil)
      else { continue }

      var copied: [String] = []
      for entry in entries {
        let target = destination.appendingPathComponent(entry.lastPathComponent)
        // Never overwrite: anything already at the new name is newer than the
        // old copy by definition, and clobbering it would be the data loss
        // this exists to prevent, in the other direction.
        guard !manager.fileExists(atPath: target.path) else { continue }
        do {
          try manager.createDirectory(at: destination, withIntermediateDirectories: true)
          try manager.copyItem(at: entry, to: target)
          copied.append(entry.lastPathComponent)
        } catch {
          // Not fatal: the app comes up on an empty store, which is the same
          // state as a fresh install rather than a crash. Logged loudly
          // because it is the one failure that looks to a user like data loss.
          logger.error(
            "Could not carry \(entry.lastPathComponent, privacy: .public) forward from \(name, privacy: .public): \(error.localizedDescription, privacy: .public)"
          )
        }
      }

      if !copied.isEmpty {
        logger.notice(
          "Carried \(copied.count, privacy: .public) item(s) forward from \(name, privacy: .public): \(copied.joined(separator: ", "), privacy: .public)"
        )
      }
    }
  }
}
