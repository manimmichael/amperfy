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

  // cassette Patch 019: editorial polish layer for hero detail headers.
  // Eyebrow label sits above the title and reads "ALBUM" / "ARTIST" /
  // "PLAYLIST" / "GENRE" / "PODCAST" in mono orange — Cassette's
  // signature category cue. Gradient layer fades the artist artwork's
  // bottom edge so the title stays legible against any photo.
  private let eyebrowLabel = UILabel()
  private let artistGradient = CAGradientLayer()
  private var didInstallEyebrow = false

  /// Pass an uppercase tag like "ALBUM" or "ARTIST" before calling
  /// `prepare(configuration:)` (or right after) to surface the eyebrow.
  /// Set to nil to hide it. The label installs lazily so callers don't
  /// have to coordinate timing with awakeFromNib.
  var kind: String? {
    didSet {
      installEyebrowIfNeeded()
      if let raw = kind, !raw.isEmpty {
        let attrs: [NSAttributedString.Key: Any] = [
          .kern: 0.08 * 10, // letter spacing 0.08 of point size
        ]
        eyebrowLabel.attributedText = NSAttributedString(
          string: raw.uppercased(),
          attributes: attrs
        )
        eyebrowLabel.isHidden = false
      } else {
        eyebrowLabel.attributedText = nil
        eyebrowLabel.isHidden = true
      }
    }
  }

  static let frameHeightCompact: CGFloat = 400.0
  static let frameHeightRegular: CGFloat = 240.0
  static func frameHeight(traitCollection: UITraitCollection) -> CGFloat {
    if traitCollection.horizontalSizeClass == .compact {
      return GenericDetailTableHeader.frameHeightCompact
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
    configuration.tableView.tableHeaderView = UIView(frame: CGRect(
      x: 0,
      y: 0,
      width: configuration.rootView.view.bounds.size.width,
      height: GenericDetailTableHeader
        .frameHeight(traitCollection: configuration.rootView.traitCollection)
    ))
    let genericDetailTableHeaderView = ViewCreator<GenericDetailTableHeader>
      .createFromNib(withinFixedFrame: CGRect(
        x: 0,
        y: 0,
        width: configuration.rootView.view.bounds.size.width,
        height: GenericDetailTableHeader
          .frameHeight(traitCollection: configuration.rootView.traitCollection)
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
    // cassette Patch 015f: hero header typography. Title in big
    // display, subtitle (artist link) in display, info (year, count)
    // in mono. Subtitle keeps tint colour for the tappable feel.
    titleLabel.font = UIFont.cassetteDisplay(size: 28, weight: .bold)
    titleLabel.textColor = CassetteTheme.UIColors.ink
    nameTextField.font = UIFont.cassetteDisplay(size: 28, weight: .bold)
    nameTextField.textColor = CassetteTheme.UIColors.ink
    subtitleLabel.font = UIFont.cassetteDisplay(size: 17, weight: .semibold)
    subtitleLabel.textColor = .tintColor
    infoLabel.font = UIFont.cassetteMono(size: 12)
    infoLabel.textColor = CassetteTheme.UIColors.ink2
    descriptionLabel.font = UIFont.preferredFont(forTextStyle: .body)
    descriptionLabel.textColor = CassetteTheme.UIColors.ink2
    infoLabel.setContentCompressionResistancePriority(.required, for: .vertical)
    layoutMargins = UIView.defaultMarginTopElement
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
    installEyebrowIfNeeded()
    configureArtworkPresentation()
    refresh()
    registerForTraitChanges(
      [UITraitUserInterfaceStyle.self, UITraitHorizontalSizeClass.self],
      handler: { (self: Self, previousTraitCollection: UITraitCollection) in
        self.applyTraitCollectionChange()
      }
    )
  }

  private func installEyebrowIfNeeded() {
    guard !didInstallEyebrow, titleLabel != nil else { return }
    didInstallEyebrow = true
    eyebrowLabel.translatesAutoresizingMaskIntoConstraints = false
    eyebrowLabel.font = UIFont.cassetteMono(size: 10, weight: .medium)
    eyebrowLabel.textColor = CassetteTheme.UIColors.orange
    eyebrowLabel.numberOfLines = 1
    // 0.08 letter spacing applied via attributedText on each set so the
    // tracking persists when the title text changes.
    eyebrowLabel.isHidden = true

    guard let titleSuperview = titleLabel.superview else { return }
    titleSuperview.addSubview(eyebrowLabel)
    // cassette Patch 021: anchor eyebrow's last baseline relative to the
    // title's first baseline so the visual gap is independent of the
    // title font's ascender slack. cassetteDisplay 28 .bold has ~22pt
    // cap height, so a -22 offset yields ~5pt of clear space between
    // the eyebrow letters and the top of the title cap-line.
    NSLayoutConstraint.activate([
      eyebrowLabel.leadingAnchor.constraint(equalTo: titleLabel.leadingAnchor),
      eyebrowLabel.trailingAnchor.constraint(lessThanOrEqualTo: titleLabel.trailingAnchor),
      eyebrowLabel.lastBaselineAnchor.constraint(
        equalTo: titleLabel.firstBaselineAnchor,
        constant: -22
      ),
    ])
  }

  private func configureArtworkPresentation() {
    guard let entityContainer = config?.entityContainer else { return }
    if entityContainer is Artist {
      // Circular artist photo + bottom gradient for legibility.
      entityImage.layer.masksToBounds = true
      if artistGradient.superlayer == nil {
        artistGradient.colors = [
          UIColor.clear.cgColor,
          UIColor.black.withAlphaComponent(0.35).cgColor,
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

    var isCountInfoHidden = false
    if let playShuffleInfoConfig = config.playShuffleInfoConfig {
      isCountInfoHidden = !playShuffleInfoConfig.isInfoAlwaysHidden && playShuffleInfoConfig
        .isShuffleHidden && (traitCollection.horizontalSizeClass == .regular)
    }
    let detailLevel = isCountInfoHidden ? DetailType.noCountInfo : DetailType.long

    let infoText = entityContainer.info(
      for: entityContainer.account?.apiType.asServerApiType,
      details: DetailInfoType(type: detailLevel, settings: appDelegate.storage.settings)
    )
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
        titlePlayButtonContainerHeightConstraint.constant = Self
          .titlePlayButtonContainerHeightCompact
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
