import Cocoa
import Defaults
import LaunchAtLogin
import SafariServices
import Settings

class GeneralPreferencesController: NSViewController, SettingsPane {
  var paneIdentifier = Settings.PaneIdentifier.general
  var paneTitle: String = "General"

  override var nibName: NSNib.Name? { "General" }

  @IBOutlet var statusLight: NSButton!
  @IBOutlet var certificateLight: NSButton!
  @IBOutlet var trustCertificateButton: NSButton!
  @IBOutlet var directoryPathControl: NSPathControl!
  @IBOutlet var pickLocationButton: NSButton!
  @IBOutlet var revealButton: NSButton!
  @IBOutlet var launchAtLoginCheckbox: NSButton!
  @IBOutlet var diagnosticsCheckbox: NSButton!
  @IBOutlet var safariButton: NSButton!
  @IBOutlet var firefoxButton: NSButton!
  @IBOutlet var chromeButton: NSButton!

  var unsubscribe: UnsubscribeFn?
  var dockTimer: Timer?

  deinit {
    unsubscribe?()
  }

  override func viewDidLoad() {
    super.viewDidLoad()

    self.preferredContentSize = NSSize(width: 480, height: 325)

    unsubscribe = store.subscribe { state in
      self.directoryPathControl.url = state.directory
      self.revealButton.isEnabled = state.directory != nil

      switch state.serverState {
      case .booting:
        self.statusLight.image = NSImage(named: NSImage.statusPartiallyAvailableName)
        self.statusLight.title = "Booting…"
      case .stopped:
        self.statusLight.image = NSImage(named: NSImage.statusUnavailableName)
        self.statusLight.title = "Stopped"
      case .running:
        self.statusLight.image = NSImage(named: NSImage.statusAvailableName)
        self.statusLight.title = "Running on localhost:3133"
      }
    }

    launchAtLoginCheckbox.state = LaunchAtLogin.isEnabled ? .on : .off

    refreshCertificateStatus()
  }

  override func viewWillAppear() {
    super.viewWillAppear()

    // Re-checked every time the pane is shown rather than once at load: the trust setting lives in
    // the keychain, not beside the certificate files, so it can disappear while Sprinkles runs.
    refreshCertificateStatus()
  }

  private func refreshCertificateStatus() {
    let trusted = SprinklesCertificate.isTrusted

    certificateLight.image = NSImage(
      named: trusted ? NSImage.statusAvailableName : NSImage.statusUnavailableName)
    certificateLight.title = trusted ? "Trusted" : "Not trusted — browsers will refuse to connect"

    // The whole grid row is hidden, not just the button: hiding the button on its own would leave
    // the row holding an empty gap open under the status line.
    if let grid = trustCertificateButton.superview as? NSGridView,
      let row = grid.cell(for: trustCertificateButton)?.row
    {
      row.isHidden = trusted
      resize(around: grid)
    } else {
      trustCertificateButton.isHidden = trusted
    }
  }

  /// The pane is two rows tall in one state and three in the other, so its height is measured
  /// rather than pinned to a number that can only be right for one of them. 15 above the grid and
  /// 20 below it are the paddings the layout already asks for.
  private func resize(around grid: NSGridView) {
    view.layoutSubtreeIfNeeded()

    preferredContentSize = NSSize(width: 480, height: ceil(grid.fittingSize.height) + 35)
  }

  @IBAction func chooseLocationPressed(_ sender: Any?) {
    OpenPanel.pick { result in
      guard let url = result else { return }

      Bookmark.url = url
      store.dispatch(.setDirectory(url))
    }
  }

  @IBAction func revealButtonPressed(_ sender: Any?) {
    guard let dir = store.state.directory else { return }
    NSWorkspace.shared.open(dir)
  }

  @IBAction func launchAtStartupPressed(_ sender: Any?) {
    LaunchAtLogin.isEnabled = launchAtLoginCheckbox.state == .on
  }

  @IBAction func supportPressed(_ sender: Any?) {
    NSWorkspace.shared.open(URL(string: "https://getsprinkles.app/")!)
  }

  @IBAction func safariPressed(_ sender: Any?) {
    ExtensionLinks.safari()
  }

  @IBAction func firefoxPressed(_ sender: Any?) {
    ExtensionLinks.firefox()
  }

  @IBAction func chromePressed(_ sender: Any?) {
    ExtensionLinks.chrome()
  }

  @IBAction func trustCertificatePressed(_ sender: Any?) {
    let trusted = SprinklesCertificate.trust()
    refreshCertificateStatus()

    guard !trusted else { return }

    // Only reached when macOS asked to authorise the change and did not get it, so say what is
    // still broken instead of leaving the light red with no explanation.
    let alert = NSAlert()
    alert.messageText = "Sprinkles could not trust its certificate"
    alert.informativeText = """
      macOS has to authorise the change and that was declined, so browsers will keep refusing \
      https://localhost:3133 and no styles or scripts will load.

      You can also trust it yourself by opening the certificate in Keychain Access.
      """
    alert.addButton(withTitle: "OK")
    alert.addButton(withTitle: "Show Certificate")

    if alert.runModal() == .alertSecondButtonReturn {
      NSWorkspace.shared.activateFileViewerSelecting([
        URL(fileURLWithPath: SprinklesCertificate.caPath)
      ])
    }
  }
}
