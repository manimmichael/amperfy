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
}

// MARK: - GenericDetailTableHeader

class GenericDetailTableHeader: UIView {
  @IBOutlet
  weak var entityImage: EntityImageView!
  @IBOutlet
  weak var titleLabel: UILabel!
  @IBOutlet
  weak var nameTextField: UITextField!
  @IBOutlet
  weak var subtitleView: UIView!
  @IBOutlet
  weak var subtitleLabel: UILabel!
  @IBOutlet
  weak var infoLabel: UILabel!
  @IBOutlet
  weak var playShuffleInfoPlaceholderStack: UIStackView!
  @IBOutlet
  weak var descriptionLabel: UILabel!
  @IBOutlet
  weak var playShuffleInfoContainerView: UIView!

  @IBOutlet
  weak var titlePlayButtonContainerHeightConstraint: NSLayoutConstraint!

  var playShuffleInfoView: LibraryElementDetailTableHeaderView?
  var isEditing = false

  // cassette Patch 026: artist headers keep their bottom-edge gradient so
  // the circular photo gracefully fades into the title block. The orange
  // category eyebrow introduced in Patch 019/021 is gone — detail VCs now
  // set `metadataOverride` with a Spotify-style "Type · Year · Duration"
  // (or per-type equivalent) line, rendered in the existing infoLabel.
  private let artistGradient = CAGradientLayer()

  /// Optional one-line metadata that replaces the auto-generated info
  /// text (e.g. "Album · 2024 · 23m"). Detail VCs set this in their
  /// existing refresh path; nil falls back to the entity's default
  /// `info(for:details:)` output.
  var metadataOverride: String? {
    didSet { refresh() }
  }

  // cassette Patch 034 (3C): bump compact-width header by 24pt to absorb
  // the new top breathing room added in prepare() without compressing
  // the artwork. iPad/Mac (regular) keeps the existing rhythm.
  static let frameHeightCompact: CGFloat = 424.0
  static let frameHeightRegular: CGFloat = 240.0
  // cassette polish Part 4: the prominent skeuomorphic Play layout is taller
  // than the bordered pair. The detail header grows by this delta, but only at
  // compact width (where the prominent layout actually renders).
  static let prominentExtraHeight: CGFloat =
    LibraryElementDetailTableHeaderView.prominentFrameHeight
      - LibraryElementDetailTableHeaderView.frameHeight
  static func frameHeight(
    traitCollection: UITraitCollection,
    isProminentPlayButton: Bool = false
  ) -> CGFloat {
    if traitCollection.horizontalSizeClass == .compact {
      return GenericDetailTableHeader.frameHeightCompact +
        (isProminentPlayButton ? prominentExtraHeight : 0)
    } else {
      return GenericDetailTableHeader.frameHeightRegular
    }
  }

  static let frameHeightForDescription: CGFloat = 85.0
  private static let titlePlayButtonContainerHeightCompact: CGFloat = 155.0
  private static let titlePlayButtonContainerHeightWithoutButtons: CGFloat =
    titlePlayButtonContainerHeightCompact - LibraryElementDetailTableHeaderView.frameHeight

  private var config: DetailHeaderConfiguration?

  public static func createTableHeader(configuration: DetailHeaderConfiguration)
    -> GenericDetailTableHeader? {
    let isProminent = configuration.playShuffleInfoConfig?.usesProminentPlayButton ?? false
    configuration.tableView.tableHeaderView = UIView(frame: CGRect(
      x: 0,
      y: 0,
      width: configuration.rootView.view.bounds.size.width,
      height: GenericDetailTableHeader
        .frameHeight(
          traitCollection: configuration.rootView.traitCollection,
          isProminentPlayButton: isProminent
        )
    ))
    let genericDetailTableHeaderView = ViewCreator<GenericDetailTableHeader>
      .createFromNib(withinFixedFrame: CGRect(
        x: 0,
        y: 0,
        width: configuration.rootView.view.bounds.size.width,
        height: GenericDetailTableHeader
          .frameHeight(
            traitCollection: configuration.rootView.traitCollection,
            isProminentPlayButton: isProminent
          )
      ))!
    genericDetailTableHeaderView.prepare(configuration: configuration)
    configuration.tableView.tableHeaderView?.addSubview(genericDetailTableHeaderView)
    return genericDetailTableHeaderView
  }

  func prepare(configuration: DetailHeaderConfiguration) {
    config = configuration
    config?.playShuffleInfoConfig?.isEmbeddedInOtherView = true
    titleLabel.setContentCompressionResistancePriority(.required, for: .vertical)
    nameTextField.setContentCompressionResistancePriority(.required, for: .vertical)
    subtitleLabel.setContentCompressionResistancePriority(.required, for: .vertical)
    // cassette Patch 032: route hero header through the canonical scale.
    // Title and editable name use heroTitle (28pt bold display); subtitle
    // (artist link) drops 17pt -> 16pt rowTitle for consistency with row
    // titles elsewhere; info line is 12pt medium mono (.metadata).
    titleLabel.font = UIFont.cassette(.heroTitle)
    titleLabel.textColor = CassetteTheme.UIColors.ink
    nameTextField.font = UIFont.cassette(.heroTitle)
    nameTextField.textColor = CassetteTheme.UIColors.ink
    subtitleLabel.font = UIFont.cassette(.rowTitle)
    // cassette Patch 048 (Phase C): detail subtitle (artist name) was painted
    // with `.tintColor` (orange) to suggest "tappable link" affordance.
    // Inspection shows the label is not actually tappable
    // (`userInteractionEnabled=NO` in XIB, no gesture recognizer), so the
    // color was decorative only. Drop to ink2 for quiet secondary metadata.
    subtitleLabel.textColor = CassetteTheme.UIColors.ink2
    infoLabel.font = UIFont.cassette(.metadata)
    infoLabel.textColor = CassetteTheme.UIColors.ink2
    descriptionLabel.font = UIFont.preferredFont(forTextStyle: .body)
    descriptionLabel.textColor = CassetteTheme.UIColors.ink2
    infoLabel.setContentCompressionResistancePriority(.required, for: .vertical)
    // cassette Patch 034 (3C): the outer wrapper anchors via topMargin in
    // the XIB, so a 24pt top margin here gives the artwork breathing room
    // below the navigation bar (Apple Music's album-detail rhythm). The
    // legacy defaultMarginTopElement set top=0 which packed the artwork
    // hard against the nav bar.
    layoutMargins = UIEdgeInsets(
      top: 24.0,
      left: UIView.defaultMarginX,
      bottom: 0.0,
      right: UIView.defaultMarginX
    )
    if let playShuffleInfoConfig = config?.playShuffleInfoConfig {
      playShuffleInfoView = ViewCreator<LibraryElementDetailTableHeaderView>.createFromNib()
      playShuffleInfoPlaceholderStack.addArrangedSubview(playShuffleInfoView!)
      playShuffleInfoView?.prepare(configuration: playShuffleInfoConfig)
      playShuffleInfoContainerView.isHidden = false
    } else {
      playShuffleInfoContainerView.isHidden = true
    }
    if let descriptionText = configuration.descriptionText {
      descriptionLabel.text = descriptionText
      descriptionLabel.isHidden = false
    } else {
      descriptionLabel.isHidden = true
    }
    configureArtworkPresentation()
    refresh()
    registerForTraitChanges(
      [UITraitUserInterfaceStyle.self, UITraitHorizontalSizeClass.self],
      handler: { (self: Self, previousTraitCollection: UITraitCollection) in
        self.applyTraitCollectionChange()
      }
    )
  }

  private func configureArtworkPresentation() {
    guard let entityContainer = config?.entityContainer else { return }
    if entityContainer is Artist {
      // Circular artist photo + bottom gradient for legibility.
      entityImage.layer.masksToBounds = true
      if artistGradient.superlayer == nil {
        // cassette Patch 033: replace pure black at 35% (cool grey wash)
        // with bg4 at 50% so the artist photo's bottom edge fades into
        // the same neutral grey family as the rest of the chrome.
        artistGradient.colors = [
          UIColor.clear.cgColor,
          CassetteTheme.UIColors.bg4.withAlphaComponent(0.5).cgColor,
        ]
        artistGradient.locations = [0.6, 1.0]
        artistGradient.startPoint = CGPoint(x: 0.5, y: 0.0)
        artistGradient.endPoint = CGPoint(x: 0.5, y: 1.0)
        entityImage.layer.addSublayer(artistGradient)
      }
      artistGradient.isHidden = false
    } else {
      // Album / playlist / genre / podcast keep the existing square crop.
      entityImage.layer.cornerRadius = CornerRadius.small.asCGFloat
      artistGradient.isHidden = true
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
    subtitleView.isHidden = entityContainer.subtitle == nil
    subtitleLabel.text = entityContainer.subtitle

    let infoText: String
    if let metadataOverride, !metadataOverride.isEmpty {
      // Patch 026: detail VCs supply a curated metadata line (e.g.
      // "Album · 2024 · 23m") so we skip the verbose default info text.
      infoText = metadataOverride
    } else {
      var isCountInfoHidden = false
      if let playShuffleInfoConfig = config.playShuffleInfoConfig {
        isCountInfoHidden = !playShuffleInfoConfig.isInfoAlwaysHidden && playShuffleInfoConfig
          .isShuffleHidden && (traitCollection.horizontalSizeClass == .regular)
      }
      let detailLevel = isCountInfoHidden ? DetailType.noCountInfo : DetailType.long
      infoText = entityContainer.info(
        for: entityContainer.account?.apiType.asServerApiType,
        details: DetailInfoType(type: detailLevel, settings: appDelegate.storage.settings)
      )
    }
    infoLabel.isHidden = infoText.isEmpty
    infoLabel.text = infoText

    titleLabel.textAlignment = (traitCollection.horizontalSizeClass == .compact) ? .center : .left
    nameTextField
      .textAlignment = (traitCollection.horizontalSizeClass == .compact) ? .center : .left
    subtitleLabel
      .textAlignment = (traitCollection.horizontalSizeClass == .compact) ? .center : .left
    infoLabel.textAlignment = (traitCollection.horizontalSizeClass == .compact) ? .center : .left

    if isEditing {
      titleLabel.isHidden = true
      nameTextField.isHidden = false
      nameTextField.text = entityContainer.name
    } else {
      titleLabel.isHidden = false
      nameTextField.isHidden = true
    }

    playShuffleInfoView?.refresh()
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    // Circular crop and gradient frame have to track the artwork's bounds.
    if config?.entityContainer is Artist {
      entityImage.layer.cornerRadius = entityImage.bounds.width / 2
      CATransaction.begin()
      CATransaction.setDisableActions(true)
      artistGradient.frame = entityImage.bounds
      CATransaction.commit()
    }
  }

  func applyTraitCollectionChange() {
    guard let config = config else { return }
    let rootView = config.rootView

    let isProminent = config.playShuffleInfoConfig?.usesProminentPlayButton ?? false
    var height = (traitCollection.horizontalSizeClass == .compact) ?
      GenericDetailTableHeader.frameHeightCompact :
      GenericDetailTableHeader.frameHeightRegular
    if traitCollection.horizontalSizeClass == .compact {
      if config.playShuffleInfoConfig == nil {
        titlePlayButtonContainerHeightConstraint.constant = Self
          .titlePlayButtonContainerHeightWithoutButtons
        height -=
          (
            Self.titlePlayButtonContainerHeightCompact - Self
              .titlePlayButtonContainerHeightWithoutButtons
          )
      } else {
        // cassette polish Part 4: grow the title/play column + total header by
        // the prominent delta when the skeuomorphic Play layout is active.
        titlePlayButtonContainerHeightConstraint.constant = Self
          .titlePlayButtonContainerHeightCompact + (isProminent ? Self.prominentExtraHeight : 0)
        height += isProminent ? Self.prominentExtraHeight : 0
      }
    }
    if config.descriptionText != nil {
      height += GenericDetailTableHeader.frameHeightForDescription
    }
    config.tableView.tableHeaderView?.frame = CGRect(
      x: 0,
      y: 0,
      width: rootView.view.bounds.size.width,
      height: height
    )
    frame = CGRect(x: 0, y: 0, width: rootView.view.bounds.size.width, height: height)
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

  @IBAction
  func subtitleButtonPressed(_ sender: Any) {
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
