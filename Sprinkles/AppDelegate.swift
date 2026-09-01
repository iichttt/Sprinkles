import Cocoa
import Defaults
import Settings

extension Settings.PaneIdentifier {
  static let general = Self("general")
  static let sites = Self("sites")
}

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate {
  @IBOutlet var onboarding: OnboardingController!

  lazy var preferences = SettingsWindowController(
    panes: [GeneralPreferencesController(), SitesPreferencesController()],
    style: .segmentedControl)

  private var hasOfferedMigration = false
  private var trustTimer: Timer?

  func applicationDidFinishLaunching(_ aNotification: Notification) {
    if Defaults[.userId] == nil {
      Defaults[.userId] = UUID().uuidString
    }

    // Start when the server's inputs appear or change - never in response to the server's own
    // state. `start()` reports failure by returning to .stopped, and reacting to that here would
    // schedule another attempt, which fails the same way: an endless boot loop whenever the certs
    // are unreadable or port 3133 is already taken by another copy of Sprinkles.
    var lastInputs: (hasCert: Bool, directory: URL?)?

    _ = store.subscribe { state in
      if lastInputs?.hasCert != state.hasCert || lastInputs?.directory != state.directory {
        lastInputs = (state.hasCert, state.directory)

        if state.hasCert && state.directory != nil {
          Server.instance.start(3133)
        }
      }

      self.offerMigrationIfNeeded(state)
    }

    startWatchingCertificateTrust()

    if !Defaults[.hasOnboarded] {
      showOnboarding()
    }
  }

  /// Nothing tells an app when a certificate stops being trusted - the setting lives in the
  /// keychain, and Keychain Access can revoke it at any moment - so it is re-checked periodically
  /// to keep the menu bar icon honest. A generous tolerance lets the system fold the wake-up into
  /// whatever else it was already doing.
  private func startWatchingCertificateTrust() {
    trustTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
      SprinklesCertificate.refreshTrust()
    }
    trustTimer?.tolerance = 30
  }

  func applicationWillTerminate(_ aNotification: Notification) {
    trustTimer?.invalidate()
    Server.instance.stop()
  }

  func showPreferences() {
    preferences.show()
    styleSettingsToolbar()
    bringToFront(preferences.window)
  }

  /// The Settings package puts the pane titles on the toolbar item *and* draws them as segment
  /// labels, so every pane's name appeared twice - once in the segmented control, once again
  /// underneath it. It also brackets the control with flexible spaces, which centres it in the
  /// space left of the traffic lights rather than in the window.
  private func styleSettingsToolbar() {
    guard let toolbar = preferences.window?.toolbar else { return }

    toolbar.displayMode = .iconOnly
    toolbar.centeredItemIdentifier = NSToolbarItem.Identifier("toolbarSegmentedControlItem")
  }

  func showOnboarding() {
    Defaults[.hasOnboarded] = false
    onboarding.showWindow(nil)
    bringToFront(onboarding.window)
  }

  /// Sprinkles is an `LSUIElement` app, so it is never the active application when one of its
  /// menu bar items is picked. Activation alone is not enough — the system may decline it, and
  /// the window then opens behind whatever the user was looking at. `orderFrontRegardless()`
  /// puts it in front either way, and deferring by one turn of the run loop lets the status
  /// menu finish tracking first, so dismissing the menu doesn't push the window back down.
  private func bringToFront(_ window: NSWindow?) {
    DispatchQueue.main.async {
      guard let window = window else { return }

      window.collectionBehavior.insert(.moveToActiveSpace)

      if #available(macOS 14.0, *) {
        NSApp.activate()
      } else {
        NSApp.activate(ignoringOtherApps: true)
      }

      window.orderFrontRegardless()
      window.makeKey()
    }
  }

  private func offerMigrationIfNeeded(_ state: State) {
    guard !hasOfferedMigration, Defaults[.hasOnboarded], let directory = state.directory else {
      return
    }
    hasOfferedMigration = true

    DispatchQueue.main.async {
      ScriptsMigration.offerIfNeeded(in: directory)
    }
  }
}

extension NSApplication {
  func relaunch(afterDelay seconds: TimeInterval = 0.5) -> Never {
    let task = Process()
    task.launchPath = "/bin/sh"
    task.arguments = ["-c", "sleep \(seconds); open \"\(Bundle.main.bundlePath)\""]
    task.launch()

    self.terminate(nil)
    exit(0)
  }
}
