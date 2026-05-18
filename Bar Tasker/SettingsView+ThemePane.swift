import AppKit
import SwiftUI

/// Theme pane for `SettingsView`. Pulled out of the main file as part of the
/// Phase-4 settings split; the body is unchanged. State backing the JSON draft
/// editor (`themeJSONDraft`, `themeJSONStatusMessage`, `themeJSONStatusIsError`)
/// still lives on `SettingsView` itself — `@State` properties have to be
/// declared on the original struct.
extension SettingsView {
  var themePane: some View {
    Section(header: Text("Theme")) {
      VStack(alignment: .leading, spacing: 6) {
        Text("Appearance")
        Picker("", selection: preferenceBinding(\.appTheme)) {
          Text("System").tag(AppTheme.system)
          Text("Light").tag(AppTheme.light)
          Text("Dark").tag(AppTheme.dark)
        }
        .labelsHidden()
        .pickerStyle(.segmented)
      }
      .padding(.top, 4)

      Text("Applies immediately to the app and preferences window.")
        .font(.caption)
        .foregroundColor(themeColor(.textSecondary))

      Divider()
        .padding(.vertical, 6)

      VStack(alignment: .leading, spacing: 8) {
        Text("Accent color")
        Picker("", selection: preferenceBinding(\.themeAccentPreset)) {
          ForEach(ThemeAccentPreset.allCases) { preset in
            Text(preset.title).tag(preset)
          }
        }
        .labelsHidden()
        .pickerStyle(.menu)

        HStack(spacing: 8) {
          ForEach(ThemeAccentPreset.allCases.filter { $0 != .custom }) { preset in
            Button {
              preferences.themeAccentPreset = preset
            } label: {
              Circle()
                .fill(AppThemeColorCodec.color(from: preset.hex) ?? .accentColor)
                .frame(width: 18, height: 18)
                .overlay(
                  Circle().stroke(
                    preferences.themeAccentPreset == preset
                      ? themeColor(.textPrimary).opacity(0.55) : Color.clear,
                    lineWidth: 1.5
                  )
                )
            }
            .buttonStyle(.plain)
          }
          Spacer(minLength: 0)
          Button("Reset") {
            preferences.resetThemeCustomization()
          }
          .disabled(
            preferences.themeAccentPreset == .blue
              && preferences.themeCustomAccentHex
                == ThemeAccentPreset.blue.hex
          )
        }

        ColorPicker(
          "Custom Accent",
          selection: Binding(
            get: { preferences.themeAccentColor },
            set: { preferences.setCustomThemeAccentColor($0) }
          ),
          supportsOpacity: false
        )

        if preferences.themeAccentPreset == .custom {
          TextField("#RRGGBB", text: preferenceBinding(\.themeCustomAccentHex))
            .textFieldStyle(.roundedBorder)
            .font(.system(size: 12, design: .monospaced))
        } else {
          Text("Using \(preferences.themeAccentPreset.title) accent")
            .font(.caption)
            .foregroundColor(themeColor(.textSecondary))
        }
      }

      Divider()
        .padding(.vertical, 6)

      VStack(alignment: .leading, spacing: 8) {
        Text("Semantic colors")
        Text("These tokens drive popover, focus, selection, text, and status colors.")
          .font(.caption)
          .foregroundColor(themeColor(.textSecondary))

        ForEach(preferences.configurableThemeColorTokens) { token in
          HStack(spacing: 10) {
            Text(token.title)
              .frame(maxWidth: .infinity, alignment: .leading)
            Text(preferences.themeColorHex(for: token))
              .font(.system(size: 11, weight: .medium, design: .monospaced))
              .foregroundColor(themeColor(.textSecondary))
              .frame(width: 88, alignment: .trailing)
            ColorPicker(
              "",
              selection: Binding(
                get: { preferences.themeColor(for: token) },
                set: { preferences.setThemeColor(token, color: $0) }
              ),
              supportsOpacity: false
            )
            .labelsHidden()
            .frame(width: 72)
            Button("Reset") {
              preferences.resetThemeColorOverride(token)
            }
            .disabled(preferences.themeColorTokenHexOverrides[token.rawValue] == nil)
          }
        }

        HStack {
          Button("Reset all semantic overrides") {
            preferences.resetAllThemeColorOverrides()
          }
          .disabled(!preferences.hasThemeColorOverrides)
          Spacer(minLength: 0)
        }
      }

      Divider()
        .padding(.vertical, 6)

      VStack(alignment: .leading, spacing: 8) {
        Text("Theme JSON")
        Text(
          "Import/export full theme state (appearance, accent, and semantic color overrides)."
        )
        .font(.caption)
        .foregroundColor(themeColor(.textSecondary))

        TextEditor(text: $themeJSONDraft)
          .font(.system(size: 12, design: .monospaced))
          .frame(minHeight: 140, maxHeight: 180)
          .overlay(
            RoundedRectangle(cornerRadius: 6)
              .stroke(themeColor(.panelDivider), lineWidth: 1)
          )

        HStack(spacing: 8) {
          Button("Load current") {
            themeJSONDraft = preferences.exportThemeJSON(prettyPrinted: true)
            themeJSONStatusMessage = ""
            themeJSONStatusIsError = false
          }
          Button("Import JSON") {
            do {
              try preferences.importThemeJSON(themeJSONDraft)
              themeJSONDraft = preferences.exportThemeJSON(prettyPrinted: true)
              themeJSONStatusMessage = "Theme imported."
              themeJSONStatusIsError = false
            } catch {
              themeJSONStatusMessage =
                error.localizedDescription.isEmpty
                ? "Theme import failed." : error.localizedDescription
              themeJSONStatusIsError = true
            }
          }
          Button("Copy current JSON") {
            let payload = preferences.exportThemeJSON(prettyPrinted: true)
            let pasteboard = NSPasteboard.general
            pasteboard.clearContents()
            pasteboard.setString(payload, forType: .string)
            themeJSONStatusMessage = "Current theme JSON copied to clipboard."
            themeJSONStatusIsError = false
          }
        }

        if !themeJSONStatusMessage.isEmpty {
          Text(themeJSONStatusMessage)
            .font(.caption)
            .foregroundColor(themeJSONStatusIsError ? themeColor(.danger) : themeColor(.success))
        }
      }
    }
  }
}
