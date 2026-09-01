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
      // Dimmed whenever the browser extensions cannot reach Sprinkles - a stopped server and an
      // untrusted certificate look identical from a page's point of view, and both leave every
      // site unstyled, so both dim the icon and the tooltip says which one it is.
      button?.appearsDisabled = !(state.serverState == .running && state.isCertTrusted)
      button?.toolTip = Self.tooltip(for: state)
    }
  }

  private static func tooltip(for state: State) -> String {
    if state.serverState != .running { return "Sprinkles — server stopped" }
    if !state.isCertTrusted { return "Sprinkles — certificate not trusted" }

    return "Sprinkles"
  }

  private static func icon() -> NSImage? {
    guard
      let image = NSImage(
        systemSymbolName: symbolName, accessibilityDescription: "Sprinkles")
    else {
      return nil
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
