import Cocoa
import Defaults
import Settings

/// Lists every `@domain` section found in `sprinkles.css` and `sprinkles.js` and lets the user
/// switch one off without deleting it.
final class SitesPreferencesController: NSViewController, SettingsPane {
  let paneIdentifier = Settings.PaneIdentifier.sites
  let paneTitle = "Sites"

  var toolbarItemIcon: NSImage {
    NSImage(systemSymbolName: "checklist", accessibilityDescription: paneTitle) ?? NSImage()
  }

  private static let explanation = """
    Sprinkles keeps everything in sprinkles.css and sprinkles.js. Start a section with a marker \
    comment — /* @domain example.com */ or // @domain example.com — and it shows up here.
    """

  private let tableView = NSTableView()
  private let emptyLabel = NSTextField(wrappingLabelWithString: "")
  private let revealStyleButton = NSButton(title: "Reveal sprinkles.css", target: nil, action: nil)
  private let revealScriptButton = NSButton(title: "Reveal sprinkles.js", target: nil, action: nil)

  /// One row of the table. Comparing `[Row]` is what decides whether a redraw is needed, so
  /// everything the row draws has to live here - and nothing else has to.
  private struct Row: Equatable {
    var domain: String
    var kinds: Set<ScriptSection.Kind>
    var isEnabled: Bool

    var displayName: String {
      domain == ScriptParser.globalIdentifier ? "All sites" : domain
    }

    var kindsLabel: String {
      ScriptSection.Kind.allCases
        .filter(kinds.contains)
        .map { $0.rawValue.uppercased() }
        .joined(separator: " · ")
    }
  }

  private var rows: [Row] = []
  private var refreshTimer: Timer?

  override func loadView() {
    let view = NSView(frame: NSRect(x: 0, y: 0, width: 480, height: 403))

    let explanationLabel = NSTextField(wrappingLabelWithString: Self.explanation)
    explanationLabel.font = .preferredFont(forTextStyle: .subheadline)
    explanationLabel.textColor = .secondaryLabelColor

    let column = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("domain"))
    column.title = "Site"
    column.resizingMask = .autoresizingMask

    let kindColumn = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("kind"))
    kindColumn.title = "Applies to"
    kindColumn.width = 90
    kindColumn.resizingMask = []

    tableView.addTableColumn(column)
    tableView.addTableColumn(kindColumn)
    tableView.headerView = nil
    tableView.usesAlternatingRowBackgroundColors = true
    tableView.style = .inset
    tableView.rowHeight = 22
    tableView.allowsEmptySelection = true
    tableView.dataSource = self
    tableView.delegate = self

    let scrollView = NSScrollView()
    scrollView.documentView = tableView
    scrollView.hasVerticalScroller = true
    scrollView.borderType = .bezelBorder
    scrollView.autohidesScrollers = true

    emptyLabel.alignment = .center
    emptyLabel.textColor = .secondaryLabelColor
    emptyLabel.isHidden = true

    revealStyleButton.target = self
    revealStyleButton.action = #selector(revealStylesPressed)
    revealScriptButton.target = self
    revealScriptButton.action = #selector(revealScriptsPressed)

    let buttons = NSStackView(views: [revealStyleButton, revealScriptButton])
    buttons.orientation = .horizontal
    buttons.spacing = 8

    let stack = NSStackView(views: [explanationLabel, scrollView, buttons])
    stack.orientation = .vertical
    stack.alignment = .leading
    stack.spacing = 12
    stack.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(stack)

    emptyLabel.translatesAutoresizingMaskIntoConstraints = false
    scrollView.addSubview(emptyLabel)

    NSLayoutConstraint.activate([
      stack.leadingAnchor.constraint(equalTo: view.leadingAnchor, constant: 20),
      stack.trailingAnchor.constraint(equalTo: view.trailingAnchor, constant: -20),
      stack.topAnchor.constraint(equalTo: view.topAnchor, constant: 20),
      stack.bottomAnchor.constraint(equalTo: view.bottomAnchor, constant: -20),
      explanationLabel.widthAnchor.constraint(equalTo: stack.widthAnchor),
      scrollView.widthAnchor.constraint(equalTo: stack.widthAnchor),
      emptyLabel.centerXAnchor.constraint(equalTo: scrollView.centerXAnchor),
      emptyLabel.centerYAnchor.constraint(equalTo: scrollView.centerYAnchor),
      emptyLabel.widthAnchor.constraint(equalTo: scrollView.widthAnchor, constant: -40),
    ])

    self.view = view
    preferredContentSize = NSSize(width: 480, height: 403)
  }

  override func viewWillAppear() {
    super.viewWillAppear()
    reload()

    // The files are edited outside Sprinkles, so poll for changes while the pane is on screen.
    refreshTimer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
      self?.reload()
    }
  }

  override func viewDidDisappear() {
    super.viewDidDisappear()
    refreshTimer?.invalidate()
    refreshTimer = nil
  }

  private func reload() {
    let catalog = ScriptCatalog.load(from: store.state.directory)
    // `kinds(for:)` filters every section, so it is computed once per domain here rather than
    // again per row in the table delegate.
    let rows = catalog.domains.map {
      Row(domain: $0, kinds: catalog.kinds(for: $0), isEnabled: catalog.isEnabled($0))
    }

    let hasDirectory = store.state.directory != nil
    revealStyleButton.isEnabled = hasDirectory
    revealScriptButton.isEnabled = hasDirectory

    emptyLabel.stringValue =
      hasDirectory
      ? "No sections yet. Add rules to sprinkles.css or sprinkles.js to see them here."
      : "Pick a scripts directory in General first."
    emptyLabel.isHidden = !rows.isEmpty

    // `[]` is a correct starting value: an empty catalog really does mean an empty table, and
    // redrawing an already-empty table costs nothing. A toggle changes `isEnabled`, so it is
    // caught here without any need to poison the comparison first.
    guard rows != self.rows else { return }

    self.rows = rows
    tableView.reloadData()
  }

  @objc private func toggleDomain(_ sender: NSButton) {
    guard rows.indices.contains(sender.tag) else { return }
    let domain = rows[sender.tag].domain

    var disabled = Defaults[.disabledDomains]
    if sender.state == .on {
      disabled.remove(domain)
    } else {
      disabled.insert(domain)
    }
    Defaults[.disabledDomains] = disabled

    reload()
  }

  @objc private func revealStylesPressed() { reveal(.css) }
  @objc private func revealScriptsPressed() { reveal(.js) }

  /// Selects the file in Finder rather than handing it to whichever app claims .css and .js -
  /// which is as likely to be a browser as an editor.
  private func reveal(_ kind: ScriptSection.Kind) {
    guard let directory = store.state.directory else { return }

    ExampleFiles.copyTo(directory)
    NSWorkspace.shared.activateFileViewerSelecting([
      directory.appendingPathComponent(kind.filename)
    ])
  }
}

extension SitesPreferencesController: NSTableViewDataSource, NSTableViewDelegate {
  func numberOfRows(in tableView: NSTableView) -> Int { rows.count }

  func tableView(
    _ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int
  ) -> NSView? {
    guard rows.indices.contains(row) else { return nil }
    let entry = rows[row]

    if tableColumn?.identifier.rawValue == "kind" {
      let label = NSTextField(labelWithString: entry.kindsLabel)
      label.font = .preferredFont(forTextStyle: .caption1)
      label.textColor = .secondaryLabelColor
      label.alignment = .right
      label.translatesAutoresizingMaskIntoConstraints = false

      // A text field handed straight to the table is stretched to the full height of the row and
      // draws its text from the top of that, which left these sitting a few points above the
      // domain names beside them - the more so because the caption font is shorter than the
      // checkbox titles it lines up against. Centring it in a cell view puts the two on the same
      // line at any row height.
      let cell = NSTableCellView()
      cell.addSubview(label)
      cell.textField = label

      NSLayoutConstraint.activate([
        label.leadingAnchor.constraint(equalTo: cell.leadingAnchor),
        label.trailingAnchor.constraint(equalTo: cell.trailingAnchor),
        label.centerYAnchor.constraint(equalTo: cell.centerYAnchor),
      ])

      return cell
    }

    let checkbox = NSButton(
      checkboxWithTitle: entry.displayName, target: self, action: #selector(toggleDomain))
    checkbox.tag = row
    checkbox.state = entry.isEnabled ? .on : .off
    return checkbox
  }
}
