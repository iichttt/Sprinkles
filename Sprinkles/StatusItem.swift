import Cocoa

class StatusItem: NSObject {
  var statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

  /// SF Symbol used for the menu bar. Template rendering keeps it correct in light, dark and
  /// tinted menu bars, and matches the rest of the system's items.
  private static let symbolName = "paintbrush.pointed.fill"

  private var unsubscribe: UnsubscribeFn?

  deinit {
    unsubscribe?()
  }

  override func awakeFromNib() {
    let button = statusItem.button
    button?.image = Self.icon()
    button?.setAccessibilityLabel("Sprinkles")

    statusItem.menu = buildMenu()

    unsubscribe = store.subscribe { state in
      // Dimmed while the local server is down, so a broken setup is visible at a glance.
      button?.appearsDisabled = state.serverState != .running
      button?.toolTip = state.serverState == .running ? "Sprinkles" : "Sprinkles — server stopped"
    }
  }

  private static func icon() -> NSImage? {
    guard
      let image = NSImage(
        systemSymbolName: symbolName, accessibilityDescription: "Sprinkles")
    else {
      return NSImage(named: NSImage.Name("ToolbarItemIcon"))
    }

    let configuration = NSImage.SymbolConfiguration(pointSize: 15, weight: .regular)
    let configured = image.withSymbolConfiguration(configuration) ?? image
    configured.isTemplate = true

    return configured
  }

  private func buildMenu() -> NSMenu {
    let menu = NSMenu()

    let preferencesItem = NSMenuItem(
      title: "Preferences…", action: #selector(showPreferences), keyEquivalent: ",")
    preferencesItem.target = self
    menu.addItem(preferencesItem)

    let onboardingItem = NSMenuItem(
      title: "Onboarding…", action: #selector(showOnboarding), keyEquivalent: ",")
    onboardingItem.target = self
    onboardingItem.isAlternate = true
    onboardingItem.keyEquivalentModifierMask = .option
    menu.addItem(onboardingItem)

    let directoryItem = NSMenuItem(
      title: "Open directory…", action: #selector(openDirectory), keyEquivalent: "o")
    directoryItem.target = self
    menu.addItem(directoryItem)

    menu.addItem(NSMenuItem.separator())
    menu.addItem(
      NSMenuItem(
        title: "Quit Sprinkles", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    )

    return menu
  }

  @objc func openDirectory() {
    if let directory = store.state.directory {
      NSWorkspace.shared.open(directory)
    } else {
      showPreferences()
    }
  }

  @objc func showPreferences() {
    guard let delegate = NSApplication.shared.delegate as? AppDelegate else { return }
    delegate.showPreferences()
  }

  @objc func showOnboarding() {
    guard let delegate = NSApplication.shared.delegate as? AppDelegate else { return }
    delegate.showOnboarding()
  }
}
