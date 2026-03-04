# Checkvist Focus

A macOS Menu Bar application that seamlessly integrates with your [Checkvist](https://checkvist.com/) account to help you focus on your top priorities.

## Features

- **Menu Bar Integration:** Sits quietly in your macOS menu bar. The icon displays the top-most actionable task from a specified list.
- **Quick Add:** Quickly add new tasks to your Checkvist list right from the popover.
- **Top Task Display:** Focus on one thing at a time. The app displays your top open task from the selected list.
- **SwiftUI Native Settings:** Configure your Checkvist credentials and List ID directly in the macOS native Settings window.

## Configuration

To use the app, you will need your Checkvist OpenAPI credentials:

1. **Username:** Your Checkvist account email.
2. **OpenAPI Key:** You can generate a remote key from your Checkvist profile pages. (Account > OpenAPI key).
3. **List ID:** The ID of the list you want to sync. You can find this in the URL when viewing a list on the Checkvist website (e.g., `https://checkvist.com/checklists/123456`, the List ID is `123456`).

Enter these in the app's Settings preferences.

## Architecture & Tech Stack

- **Swift** & **SwiftUI** for the UI and layout.
- **AppKit** (`NSStatusItem`, `NSPopover`) for the menu bar lifecycle.
- **Combine** & `@Published` along with `UserDefaults` for persistent configuration and state management (`ObservableObject`).
- **Checkvist OpenAPI** via `URLSession` async/await requests for API synchronization.

## Build Requirements

- macOS 13.0+
- Xcode 14.0+

## License

MIT License.
