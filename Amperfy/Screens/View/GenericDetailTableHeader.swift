//
//  GenericDetailTableHeader.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 19.02.22.
//  Copyright (c) 2022 Maximilian Bauer. All rights reserved.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//
//  This program is distributed in the hope that it will be useful,
//  but WITHOUT ANY WARRANTY; without even the implied warranty of
//  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
//  GNU General Public License for more details.
//
//  You should have received a copy of the GNU General Public License
//  along with this program.  If not, see <http://www.gnu.org/licenses/>.
//

import AmperfyKit
import UIKit

// MARK: - DetailHeaderConfiguration

struct DetailHeaderConfiguration {
  var entityContainer: PlayableContainable
  var rootView: UIViewController
  var tableView: UITableView
  var playShuffleInfoConfig: PlayShuffleInfoConfiguration?
  var descriptionText: String?
  /// cassette Patch 104 (Root 2): album/artist detail extend the scroll
  /// under the navigation bar so the artwork is the first content and the
  /// nav (back/overflow) floats over it. The header pads its top by the
  /// root view's safe-area inset instead of relying on the bar pushing
  /// the content down. Other detail screens leave this false and keep
  /// the below-the-bar layout.
  var extendsUnderNavigationBar: Bool = false
}

// MARK: - GenericDetailTableHeader

/// cassette Patch 104 (Root 2): rebuilt programmatically. The old XIB was a
/// fixed-height block (424pt of hand-tuned constants) whose artwork lived in
/// a nested stack below the navigation bar — it could never be the top of
/// the scroll, and its IB-instantiated plain buttons + systemBackground
/// artwork backing leaked the iOS 26 default glass treatment (Root 1).
/// The header now self-sizes, owns no fixed frame constants, and the
/// artwork is the first content of the scroll view.
class GenericDetailTableHeader: UIView {
  // MARK: Subviews

  let entityImage = EntityImageView(
    frame: CGRect(
      x: 0,
      y: 0,
      width: GenericDetailTableHeader.artworkSide,
      height: GenericDetailTableHeader.artworkSide
    )
  )

  private let titleLabel: UILabel = {
    let label = UILabel()
    label.font = UIFont.cassette(.heroTitle)
    label.textColor = CassetteTheme.UIColors.ink
    label.numberOfLines = 2
    label.lineBreakMode = .byTruncatingTail
    label.setContentCompressionResistancePriority(.required, for: .vertical)
    return label
  }()

  private let nameTextField: UITextField = {
    let field = UITextField()
    field.font = UIFont.cassette(.heroTitle)
    field.textColor = CassetteTheme.UIColors.ink
    field.isHidden = true
    field.setContentCompressionResistancePriority(.required, for: .vertical)
    return field
  }()

  // Patch 104 (Root 1): the XIB's invisible full-width system button behind
  // the subtitle label picked up the iOS 26 glass capsule. The subtitle is
  // now a single bare-configured button (label + action in one view).
  private let subtitleButton: UIButton = {
    let button = UIButton(configuration: .cassetteBare())
    button.configuration?.contentInsets = .zero
    return button
  }()

  private let infoLabel: UILabel = {
    let label = UILabel()
    label.font = UIFont.cassette(.metadata)
    label.textColor = CassetteTheme.UIColors.ink2
    label.numberOfLines = 2
    label.setContentCompressionResistancePriority(.required, for: .vertical)
    return label
  }()

  private let descriptionLabel: UILabel = {
    let label = UILabel()
    label.font = UIFont.cassette(.body)
    label.textColor = CassetteTheme.UIColors.ink2
    label.numberOfLines = 0
    label.isHidden = true
    return label
  }()

  private let artworkWrap = UIView()
  private let playSlot: UIStackView = {
    let stack = UIStackView()
    stack.axis = .vertical
    return stack
  }()

  private let contentColumn: UIStackView = {
    let stack = UIStackView()
    stack.axis = .vertical
    stack.alignment = .fill
    stack.spacing = CassetteTheme.Spacing.xs
    return stack
  }()

  private let mainStack: UIStackView = {
    let stack = UIStackView()
    stack.axis = .vertical
    stack.alignment = .fill
    stack.spacing = CassetteTheme.Spacing.md
    return stack
  }()

  var playShuffleInfoView: LibraryElementDetailTableHeaderView?
  var isEditing = false

  /// Optional one-line metadata that replaces the auto-generated info
  /// text (e.g. "2024 · 23m"). Detail VCs set this in their existing
  /// refresh path; nil falls back to the entity's default
  /// `info(for:details:)` output.
  ///
  /// cassette: an EMPTY string is meaningful and distinct from nil — it
  /// means "this screen has nothing worth putting on the line, show no
  /// line." Previously empty was treated like nil and fell through to the
  /// verbose default, so a record with no year and no duration couldn't
  /// end up with a clean header.
  var metadataOverride: String? {
    didSet { refresh() }
  }

  // MARK: Layout constants

  /// Square artwork side (album / playlist / genre / podcast).
  private static let artworkSide: CGFloat = 240.0
  /// Artist photos render as a slightly smaller circle so the tightened
  /// picture/title/subtitle block reads as one unit.
  private static let artistCircleDiameter: CGFloat = 200.0

  private var config: DetailHeaderConfiguration?

  private var artworkWidthConstraint: NSLayoutConstraint!
  private var playSlotHeightConstraint: NSLayoutConstraint!
  private var compactConstraints: [NSLayoutConstraint] = []
  private var regularConstraints: [NSLayoutConstraint] = []
  private var lastLayoutWidth: CGFloat = 0

  // MARK: Creation

  public static func createTableHeader(configuration: DetailHeaderConfiguration)
    -> GenericDetailTableHeader? {
    let header = GenericDetailTableHeader(frame: CGRect(
      x: 0,
      y: 0,
      width: configuration.rootView.view.bounds.size.width,
      height: 1000 // corrected in viewDidLayoutSubviews once nav bar geometry is available
    ))
    header.prepare(configuration: configuration)
    configuration.tableView.tableHeaderView = header
    header.resizeToFit()
    return header
  }

  func prepare(configuration: DetailHeaderConfiguration) {
    config = configuration
    config?.playShuffleInfoConfig?.isEmbeddedInOtherView = true
    // cassette Polish 2 (D1): hand the embedded action bar the entity + root VC
    // so its heart can favorite the container and its overflow can open the
    // entity context menu — no per-VC wiring needed.
    config?.playShuffleInfoConfig?.favoriteEntity = configuration.entityContainer
    config?.playShuffleInfoConfig?.rootViewController = configuration.rootView

    buildHierarchyIfNeeded()

    if let playShuffleInfoConfig = config?.playShuffleInfoConfig {
      playShuffleInfoView = ViewCreator<LibraryElementDetailTableHeaderView>.createFromNib()
      playSlot.addArrangedSubview(playShuffleInfoView!)
      playShuffleInfoView?.prepare(configuration: playShuffleInfoConfig)
      playSlot.isHidden = false
    } else {
      playSlot.isHidden = true
    }

    if let descriptionText = configuration.descriptionText {
      descriptionLabel.text = descriptionText
      descriptionLabel.isHidden = false
    } else {
      descriptionLabel.isHidden = true
    }

    configureArtworkPresentation()
    applyLayout()
    refresh()
    registerForTraitChanges(
      [UITraitUserInterfaceStyle.self, UITraitHorizontalSizeClass.self],
      handler: { (self: Self, _: UITraitCollection) in
        self.applyLayout()
        self.refresh()
        self.resizeToFit()
      }
    )
  }

  private var didBuildHierarchy = false

  private func buildHierarchyIfNeeded() {
    guard !didBuildHierarchy else { return }
    didBuildHierarchy = true

    backgroundColor = .clear
    // The header sits under the status/navigation bars at rest, so UIKit
    // propagates that covered region into its safeAreaInsets; with the
    // default insetsLayoutMarginsFromSafeArea the layoutMarginsGuide would
    // add it ON TOP of the manual bar clearance from resizeToFit, doubling
    // the gap above the artwork (and re-measuring it during scroll).
    insetsLayoutMarginsFromSafeArea = false
    directionalLayoutMargins = NSDirectionalEdgeInsets(
      top: CassetteTheme.Spacing.md,
      leading: UIView.defaultMarginX,
      bottom: CassetteTheme.Spacing.lg,
      trailing: UIView.defaultMarginX
    )

    subtitleButton.addTarget(self, action: #selector(subtitleButtonPressed), for: .touchUpInside)

    entityImage.translatesAutoresizingMaskIntoConstraints = false
    artworkWrap.translatesAutoresizingMaskIntoConstraints = false
    mainStack.translatesAutoresizingMaskIntoConstraints = false

    artworkWrap.addSubview(entityImage)

    contentColumn.addArrangedSubview(titleLabel)
    contentColumn.addArrangedSubview(nameTextField)
    contentColumn.addArrangedSubview(subtitleButton)
    contentColumn.addArrangedSubview(infoLabel)
    contentColumn.addArrangedSubview(playSlot)
    contentColumn.addArrangedSubview(descriptionLabel)
    // Breathing room: tight type block, then air before the action bar and
    // the optional description.
    contentColumn.setCustomSpacing(CassetteTheme.Spacing.lg, after: infoLabel)
    contentColumn.setCustomSpacing(CassetteTheme.Spacing.lg, after: playSlot)

    mainStack.addArrangedSubview(artworkWrap)
    mainStack.addArrangedSubview(contentColumn)
    addSubview(mainStack)

    artworkWidthConstraint = entityImage.widthAnchor
      .constraint(equalToConstant: Self.artworkSide)
    playSlotHeightConstraint = playSlot.heightAnchor.constraint(
      equalToConstant: LibraryElementDetailTableHeaderView.prominentPlayDiameter
    )

    // The horizontal stack-to-margins pins are dropped just below required so
    // the transient UITableView layout pass that sizes the header at width 0
    // ('UIView-Encapsulated-Layout-Width == 0', before it knows the real
    // width) can't force an unsatisfiable conflict against the 25pt side
    // margins + the 240pt artwork. At the real width nothing competes with
    // them, so they resolve exactly and layout is unchanged. The vertical
    // pins stay required — they drive the self-sizing height and never
    // conflict with a width-0 pass.
    let leadingPin = mainStack.leadingAnchor.constraint(equalTo: layoutMarginsGuide.leadingAnchor)
    let trailingPin = mainStack.trailingAnchor
      .constraint(equalTo: layoutMarginsGuide.trailingAnchor)
    leadingPin.priority = UILayoutPriority(999)
    trailingPin.priority = UILayoutPriority(999)

    NSLayoutConstraint.activate([
      mainStack.topAnchor.constraint(equalTo: layoutMarginsGuide.topAnchor),
      mainStack.bottomAnchor.constraint(equalTo: layoutMarginsGuide.bottomAnchor),
      leadingPin,
      trailingPin,

      entityImage.widthAnchor.constraint(equalTo: entityImage.heightAnchor),
      entityImage.topAnchor.constraint(equalTo: artworkWrap.topAnchor),
      artworkWidthConstraint,
      playSlotHeightConstraint,
    ])

    compactConstraints = [
      entityImage.centerXAnchor.constraint(equalTo: artworkWrap.centerXAnchor),
      entityImage.bottomAnchor.constraint(equalTo: artworkWrap.bottomAnchor),
    ]
    regularConstraints = [
      entityImage.leadingAnchor.constraint(equalTo: artworkWrap.leadingAnchor),
      entityImage.bottomAnchor.constraint(lessThanOrEqualTo: artworkWrap.bottomAnchor),
      artworkWrap.widthAnchor.constraint(equalToConstant: Self.artworkSide),
    ]
  }

  // cassette redesign (Surface 1) + Patch 104 (Root 3): the artist photo is
  // a clean circular crop owned by EntityImageView's shape — correct on
  // layout and after async image loads. Everything else keeps the squared
  // rounded crop.
  private func configureArtworkPresentation() {
    guard let entityContainer = config?.entityContainer else { return }
    // cassette: the artist photo is a circular crop. Album covers use a much
    // smaller corner radius (.verySmall = 3pt, vs the .small = 5pt everything
    // else uses) so a bordered / framed cover keeps crisp corners instead of
    // having its border shaved off by the rounding. Other non-artist entities
    // (playlists, podcasts, genres) keep the standard .small.
    if entityContainer is Artist {
      entityImage.shape = .circle
    } else if entityContainer is Album {
      entityImage.shape = .rounded(.verySmall)
    } else {
      entityImage.shape = .rounded(.small)
    }
  }

  private var isCompactWidth: Bool {
    traitCollection.horizontalSizeClass == .compact
  }

  private func applyLayout() {
    let compact = isCompactWidth
    NSLayoutConstraint.deactivate(compact ? regularConstraints : compactConstraints)
    NSLayoutConstraint.activate(compact ? compactConstraints : regularConstraints)
    mainStack.axis = compact ? .vertical : .horizontal
    mainStack.alignment = compact ? .fill : .top
    mainStack.spacing = compact ? CassetteTheme.Spacing.md : CassetteTheme.Spacing.xl
    artworkWidthConstraint.constant = (compact && config?.entityContainer is Artist)
      ? Self.artistCircleDiameter
      : Self.artworkSide
    let isProminent = config?.playShuffleInfoConfig?.usesProminentPlayButton ?? false
    playSlotHeightConstraint.constant = (compact && isProminent)
      ? LibraryElementDetailTableHeaderView.prominentPlayDiameter
      : 40.0
  }

  /// Self-sizing replacement for the old fixed-height constant zoo. Sizes the
  /// header as topInset + mainStackHeight + bottomInset so the margin and the
  /// frame always land together — no transient constraint break, no
  /// "Unable to simultaneously satisfy constraints" from Auto Layout.
  func resizeToFit() {
    guard let config else { return }
    // cassette (header-pop fix, round 3): hard freeze for the whole pop. While
    // the host VC is mid-transition out of the stack, ANY re-measure here would
    // reset the table's content layout and snap the scrolled-collapsed hero back
    // to expanded ("pops in"). The reassignment guard below (round 2) covered
    // only one trigger; this covers all of them for the transition's duration.
    if (config.rootView as? BasicTableViewController)?.isHeaderTransitionFrozen == true {
      return
    }
    let tableWidth = config.tableView.bounds.width > 0
      ? config.tableView.bounds.width
      : config.rootView.view.bounds.width
    guard tableWidth > 0 else { return }

    // Determine the desired top clearance.
    // For screens that extend under the nav bar the inset is the STATUS-BAR
    // height (= nav bar's minY in window space) so art starts at the button
    // line, not below it. Guard: if neither value is available yet (early
    // viewDidLoad call before the window hierarchy is settled) return — the
    // VC's viewDidLayoutSubviews will call us back with correct geometry.
    let topInset: CGFloat
    if config.extendsUnderNavigationBar {
      let navBarMinY = config.rootView.navigationController?.navigationBar.frame.minY ?? 0
      let safeTop = config.rootView.view.safeAreaInsets.top
      guard navBarMinY > 0 || safeTop > 0 else { return }
      let statusBarH = navBarMinY > 0 ? navBarMinY : safeTop
      topInset = statusBarH + CassetteTheme.Spacing.sm
    } else {
      topInset = directionalLayoutMargins.top
    }
    let bottomInset = directionalLayoutMargins.bottom

    // Measure the main content stack independently of the header's current
    // frame and margins so topInset + stackHeight + bottomInset are computed
    // together. Setting margins.top on a small frame first, then calling
    // systemLayoutSizeFitting on the whole view, creates a window where the
    // layout engine sees e.g. margins.top=70 inside a frame.height=100 — the
    // artwork's 240×240 + labels are crushed to ~14pt and a constraint breaks.
    let hInset = directionalLayoutMargins.leading + directionalLayoutMargins.trailing
    let innerWidth = max(0, tableWidth - hInset)
    let stackH = mainStack.systemLayoutSizeFitting(
      CGSize(width: innerWidth, height: UIView.layoutFittingCompressedSize.height),
      withHorizontalFittingPriority: .required,
      verticalFittingPriority: .fittingSizeLevel
    ).height
    let newHeight = ceil(topInset + stackH + bottomInset)

    // Apply margin and frame together — they're always in sync from here on.
    if directionalLayoutMargins.top != topInset {
      directionalLayoutMargins.top = topInset
    }

    guard newHeight != frame.height || tableWidth != lastLayoutWidth else { return }
    // Defer mid-scroll re-measures: re-assigning tableHeaderView while dragging
    // mutates frame.maxY mid-flight, giving updateAlpha a spurious progress
    // spike → title flashes in then drops. The scroll-end hooks in both detail
    // VCs land the deferred size once the scroll settles.
    if config.tableView.isDragging || config.tableView.isDecelerating { return }

    // cassette: do NOT re-measure while the host VC is leaving the stack (a pop,
    // including the interactive edge-swipe). For the screens that extend under
    // the nav bar, `topInset` is derived from the nav bar's minY / the view's
    // top safe-area inset (see above) — both of which SHIFT mid-pop as UIKit
    // transitions the bar toward the destination's large-title layout. That
    // makes `newHeight` differ, and re-assigning `tableHeaderView` here resets
    // the table's content layout, snapping the scrolled-collapsed hero back to
    // expanded ("pops in") for the duration of the swipe. The VC is leaving, so
    // its header never needs a new size; skip. (Push-in sizing is unaffected —
    // the pushed VC is moving TO, not FROM, its parent. A cancelled pop
    // self-heals: viewIsAppearing recomputes the sticky-title alpha from the
    // preserved offset, and the next settled layout re-measures if needed.)
    if config.rootView.isMovingFromParent || config.rootView.isBeingDismissed { return }

    lastLayoutWidth = tableWidth
    UIView.performWithoutAnimation {
      frame = CGRect(x: 0, y: 0, width: tableWidth, height: newHeight)
      // Re-assigning makes the table view pick up the new frame.
      config.tableView.tableHeaderView = self
    }
  }

  func refresh() {
    guard let config = config else { return }
    let entityContainer = config.entityContainer
    entityImage.display(
      theme: appDelegate.storage.settings.accounts.getSetting(entityContainer.account?.info).read
        .themePreference,
      container: entityContainer
    )
    titleLabel.text = entityContainer.name

    // cassette Patch 048 (Phase C): subtitle is quiet secondary metadata in
    // ink2; it acts as a link (album -> artist) only where the action exists.
    var subtitleAttributes = AttributeContainer()
    subtitleAttributes.font = UIFont.cassette(.rowTitle)
    subtitleAttributes.foregroundColor = CassetteTheme.UIColors.ink2
    if let subtitle = entityContainer.subtitle {
      subtitleButton.configuration?.attributedTitle = AttributedString(
        subtitle,
        attributes: subtitleAttributes
      )
      subtitleButton.isHidden = false
      subtitleButton.isUserInteractionEnabled = entityContainer is Album
    } else {
      subtitleButton.isHidden = true
    }

    let infoText: String
    if let metadataOverride {
      // Patch 026: detail VCs supply a curated metadata line (e.g.
      // "2024 · 23m") so we skip the verbose default info text. Empty is a
      // deliberate "no line" (see the property doc), not a fall-through.
      infoText = metadataOverride
    } else {
      var isCountInfoHidden = false
      if let playShuffleInfoConfig = config.playShuffleInfoConfig {
        isCountInfoHidden = !playShuffleInfoConfig.isInfoAlwaysHidden && playShuffleInfoConfig
          .isShuffleHidden && !isCompactWidth
      }
      let detailLevel = isCountInfoHidden ? DetailType.noCountInfo : DetailType.long
      infoText = entityContainer.info(
        for: entityContainer.account?.apiType.asServerApiType,
        details: DetailInfoType(type: detailLevel, settings: appDelegate.storage.settings)
      )
    }
    infoLabel.isHidden = infoText.isEmpty
    infoLabel.text = infoText

    let textAlignment: NSTextAlignment = isCompactWidth ? .center : .left
    titleLabel.textAlignment = textAlignment
    nameTextField.textAlignment = textAlignment
    infoLabel.textAlignment = textAlignment
    descriptionLabel.textAlignment = isCompactWidth ? .center : .natural
    subtitleButton.contentHorizontalAlignment = isCompactWidth ? .center : .leading

    if isEditing {
      titleLabel.isHidden = true
      nameTextField.isHidden = false
      nameTextField.text = entityContainer.name
    } else {
      titleLabel.isHidden = false
      nameTextField.isHidden = true
    }

    playShuffleInfoView?.refresh()
    resizeToFit()
  }

  func startEditing() {
    isEditing = true
    refresh()
  }

  func endEditing() {
    isEditing = false
    defer { refresh() }
    guard let nameText = nameTextField.text, let playlist = config?.entityContainer as? Playlist,
          nameText != playlist.name, let account = playlist.account else { return }
    playlist.name = nameText
    titleLabel.text = nameText
    guard appDelegate.storage.settings.user.isOnlineMode else { return }

    Task { @MainActor in do {
      try await self.appDelegate.getMeta(account.info).librarySyncer
        .syncUpload(playlistToUpdateName: playlist)
    } catch {
      self.appDelegate.eventLogger.report(topic: "Playlist Update Name", error: error)
    }}
  }

  @objc
  private func subtitleButtonPressed() {
    guard let album = config?.entityContainer as? Album,
          let artist = album.artist,
          let account = album.account,
          let navController = config?.rootView.navigationController
    else { return }
    appDelegate.userStatistics.usedAction(.alertGoToAlbum)
    navController.pushViewController(
      AppStoryboard.Main.segueToArtistDetail(account: account, artist: artist),
      animated: true
    )
  }
}
