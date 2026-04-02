import Foundation

@MainActor
final class BarTaskerPluginRegistry {
  private(set) var checkvistSyncPluginsByIdentifier: [String: any CheckvistSyncPlugin] = [:]
  private(set) var obsidianPluginsByIdentifier: [String: any ObsidianIntegrationPlugin] = [:]
  private(set) var googleCalendarPluginsByIdentifier:
    [String: any GoogleCalendarIntegrationPlugin] =
      [:]
  private(set) var mcpIntegrationPluginsByIdentifier: [String: any MCPIntegrationPlugin] = [:]

  private(set) var activeCheckvistSyncPluginIdentifier: String?
  private(set) var activeObsidianPluginIdentifier: String?
  private(set) var activeGoogleCalendarPluginIdentifier: String?
  private(set) var activeMCPIntegrationPluginIdentifier: String?

  var activeCheckvistSyncPlugin: (any CheckvistSyncPlugin)? {
    guard let activeCheckvistSyncPluginIdentifier else { return nil }
    return checkvistSyncPluginsByIdentifier[activeCheckvistSyncPluginIdentifier]
  }

  var activeObsidianPlugin: (any ObsidianIntegrationPlugin)? {
    guard let activeObsidianPluginIdentifier else { return nil }
    return obsidianPluginsByIdentifier[activeObsidianPluginIdentifier]
  }

  var activeGoogleCalendarPlugin: (any GoogleCalendarIntegrationPlugin)? {
    guard let activeGoogleCalendarPluginIdentifier else { return nil }
    return googleCalendarPluginsByIdentifier[activeGoogleCalendarPluginIdentifier]
  }

  var activeMCPIntegrationPlugin: (any MCPIntegrationPlugin)? {
    guard let activeMCPIntegrationPluginIdentifier else { return nil }
    return mcpIntegrationPluginsByIdentifier[activeMCPIntegrationPluginIdentifier]
  }

  func register(_ plugin: any CheckvistSyncPlugin, activate: Bool = false) {
    checkvistSyncPluginsByIdentifier[plugin.pluginIdentifier] = plugin
    if activate || activeCheckvistSyncPluginIdentifier == nil {
      activeCheckvistSyncPluginIdentifier = plugin.pluginIdentifier
    }
  }

  func register(_ plugin: any ObsidianIntegrationPlugin, activate: Bool = false) {
    obsidianPluginsByIdentifier[plugin.pluginIdentifier] = plugin
    if activate || activeObsidianPluginIdentifier == nil {
      activeObsidianPluginIdentifier = plugin.pluginIdentifier
    }
  }

  func register(_ plugin: any GoogleCalendarIntegrationPlugin, activate: Bool = false) {
    googleCalendarPluginsByIdentifier[plugin.pluginIdentifier] = plugin
    if activate || activeGoogleCalendarPluginIdentifier == nil {
      activeGoogleCalendarPluginIdentifier = plugin.pluginIdentifier
    }
  }

  func register(_ plugin: any MCPIntegrationPlugin, activate: Bool = false) {
    mcpIntegrationPluginsByIdentifier[plugin.pluginIdentifier] = plugin
    if activate || activeMCPIntegrationPluginIdentifier == nil {
      activeMCPIntegrationPluginIdentifier = plugin.pluginIdentifier
    }
  }

  @discardableResult
  func activateCheckvistSyncPlugin(identifier: String) -> Bool {
    guard checkvistSyncPluginsByIdentifier[identifier] != nil else { return false }
    activeCheckvistSyncPluginIdentifier = identifier
    return true
  }

  @discardableResult
  func activateObsidianPlugin(identifier: String) -> Bool {
    guard obsidianPluginsByIdentifier[identifier] != nil else { return false }
    activeObsidianPluginIdentifier = identifier
    return true
  }

  @discardableResult
  func activateGoogleCalendarPlugin(identifier: String) -> Bool {
    guard googleCalendarPluginsByIdentifier[identifier] != nil else { return false }
    activeGoogleCalendarPluginIdentifier = identifier
    return true
  }

  @discardableResult
  func activateMCPIntegrationPlugin(identifier: String) -> Bool {
    guard mcpIntegrationPluginsByIdentifier[identifier] != nil else { return false }
    activeMCPIntegrationPluginIdentifier = identifier
    return true
  }

  static func nativeFirst() -> BarTaskerPluginRegistry {
    let registry = BarTaskerPluginRegistry()
    registry.register(NativeCheckvistSyncPlugin(), activate: true)
    registry.register(NativeObsidianIntegrationPlugin(), activate: true)
    registry.register(NativeGoogleCalendarIntegrationPlugin(), activate: true)
    registry.register(NativeMCPIntegrationPlugin(), activate: true)
    return registry
  }
}
