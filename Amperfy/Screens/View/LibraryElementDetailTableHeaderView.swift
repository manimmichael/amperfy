//
//  LibraryElementDetailTableHeaderView.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 09.03.19.
//  Copyright (c) 2019 Maximilian Bauer. All rights reserved.
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

typealias GetInfoCallback = () -> String

// MARK: - PlayShuffleInfoConfiguration

struct PlayShuffleInfoConfiguration {
  var infoCB: GetInfoCallback?
  var playContextCb: GetPlayContextCallback?
  var player: PlayerFacade
  let isInfoAlwaysHidden: Bool
  var customPlayName: String?
  var isShuffleHidden = false
  var isShuffleOnContextNeccessary: Bool = true
  var shuffleContextCb: GetPlayContextCallback?
  var isEmbeddedInOtherView: Bool = false
  /// cassette polish Part 4 / Polish 2 (D1): when true (set only by the Album /
  /// Artist / Playlist detail headers), the compact-width layout swaps the
  /// side-by-side bordered pair for a single action bar:
  /// `[heart]  [PLAY][shuffle]  [overflow]`. List headers leave this false.
  var usesProminentPlayButton: Bool = false
  /// cassette Polish 2 (D1): the entity the action-bar heart favorites and the
  /// overflow menu targets. Injected by GenericDetailTableHeader from its own
  /// DetailHeaderConfiguration so the shared header needs no VC-specific code.
  var favoriteEntity: (any PlayableContainable)?
  var rootViewController: UIViewController?
}

// MARK: - LibraryElementDetailTableHeaderView

class LibraryElementDetailTableHeaderView: UIView {
  @IBOutlet
  weak var playAllButton: UIButton!
  @IBOutlet
  weak var playShuffledButton: UIButton!
  @IBOutlet
  weak var infoContainerView: UIView!
  @IBOutlet
  weak var infoLabel: UILabel!

  static let frameHeight: CGFloat = 40.0 + margin.top + margin.bottom
  /// cassette Polish 2 (D1): the prominent layout is now a single 56pt-tall
  /// action bar (was a 120pt stacked Play + bordered Shuffle), so the detail
  /// header grows by only ~16pt over the bordered baseline.
  static let prominentPlayDiameter: CGFloat = 56.0
  static let prominentFrameHeight: CGFloat = prominentPlayDiameter + margin.top + margin.bottom
  static let margin = UIView.defaultMarginMiddleElement

  private var config: PlayShuffleInfoConfiguration?

  private var prominentContainer: UIView?
  private var cassettePlayButton: CassettePlayButton?
  private var prominentShuffleButton: UIButton?
  private var prominentHeartButton: UIButton?
  private var prominentOverflowButton: UIButton?

  required init?(coder aDecoder: NSCoder) {
    super.init(coder: aDecoder)
    self.layoutMargins = UIEdgeInsets(
      top: 0.0,
      left: UIView.defaultMarginX,
      bottom: 0.0,
      right: UIView.defaultMarginX
    )

    registerForTraitChanges(
      [UITraitUserInterfaceStyle.self, UITraitHorizontalSizeClass.self],
      handler: { (self: Self, previousTraitCollection: UITraitCollection) in
        self.refresh()
      }
    )
  }

  public static func createTableHeader(
    rootView: BasicTableViewController,
    configuration: PlayShuffleInfoConfiguration
  )
    -> LibraryElementDetailTableHeaderView? {
    rootView.tableView.tableHeaderView = UIView(frame: CGRect(
      x: 0,
      y: 0,
      width: rootView.view.bounds.size.width,
      height: Self.frameHeight
    ))
    let genericDetailTableHeaderView = ViewCreator<LibraryElementDetailTableHeaderView>
      .createFromNib(withinFixedFrame: CGRect(
        x: 0,
        y: 0,
        width: rootView.view.bounds.size.width,
        height: Self.frameHeight
      ))!
    genericDetailTableHeaderView.prepare(configuration: configuration)
    rootView.tableView.tableHeaderView?.addSubview(genericDetailTableHeaderView)
    return genericDetailTableHeaderView
  }

  func refresh() {
    guard let config = config else { return }
    if config.isEmbeddedInOtherView {
      layoutMargins = UIEdgeInsets(top: 0.0, left: 0.0, bottom: 0.0, right: 0.0)
    } else {
      if traitCollection.horizontalSizeClass == .compact {
        layoutMargins = UIEdgeInsets(
          top: 0.0,
          left: UIView.defaultMarginCellX,
          bottom: 0.0,
          right: UIView.defaultMarginCellX
        )
      } else {
        layoutMargins = UIEdgeInsets(
          top: 0.0,
          left: UIView.defaultMarginX,
          bottom: 0.0,
          right: UIView.defaultMarginX
        )
      }
    }
    infoContainerView.isHidden = config
      .isInfoAlwaysHidden || (traitCollection.horizontalSizeClass == .compact)
    infoLabel.text = config.infoCB?() ?? ""

    // cassette polish Part 4 / Polish 2 (D1): the prominent action bar is
    // compact-width only; iPad/Mac (regular) and standalone list headers keep
    // the known-good bordered pair.
    let showProminent = config.usesProminentPlayButton &&
      traitCollection.horizontalSizeClass == .compact
    prominentContainer?.isHidden = !showProminent
    playAllButton.isHidden = showProminent
    playShuffledButton.isHidden = showProminent || config.isShuffleHidden

    if showProminent {
      prominentShuffleButton?.isHidden = config.isShuffleHidden
      // Heart only for favoritable containers (Album/Artist). Playlists,
      // genres and podcasts are not favoritable and hide it.
      prominentHeartButton?.isHidden = !(config.favoriteEntity?.isFavoritable ?? false)
      refreshProminentHeartIcon()
    }
  }

  private func refreshProminentHeartIcon() {
    guard let heart = prominentHeartButton else { return }
    let isFav = config?.favoriteEntity?.isFavorite ?? false
    var heartConfig = heart.configuration ?? UIButton.Configuration.plain()
    heartConfig.image = isFav ? UIImage(systemName: "heart.fill") : UIImage(systemName: "heart")
    heart.configuration = heartConfig
    heart.accessibilityLabel = isFav ? "Unmark favorite" : "Favorite"
  }

  @IBAction
  func playAllButtonPressed(_ sender: Any) {
    Haptics.success.vibrate(isHapticsEnabled: appDelegate.storage.settings.user.isHapticsEnabled)
    play(isShuffled: false)
  }

  @IBAction
  func addAllShuffledButtonPressed(_ sender: Any) {
    Haptics.success.vibrate(isHapticsEnabled: appDelegate.storage.settings.user.isHapticsEnabled)
    shuffle()
  }

  private func play(isShuffled: Bool) {
    guard let playContext = config?.playContextCb?(), let player = config?.player else { return }
    isShuffled ? player.playShuffled(context: playContext) : player.play(context: playContext)
  }

  private func shuffle() {
    guard let player = config?.player else { return }
    if let shuffleContext = config?.shuffleContextCb?() {
      if config?.isShuffleOnContextNeccessary ?? true {
        player.playShuffled(context: shuffleContext)
      } else {
        player.play(context: shuffleContext)
      }
    } else {
      play(isShuffled: true)
    }
  }

  /// isShuffleOnContextNeccessary: In AlbumsVC the albums are shuffled, keep the order when shuffle button is pressed
  func prepare(configuration: PlayShuffleInfoConfiguration) {
    config = configuration
    Self.applyCassetteStyle(
      to: playAllButton,
      title: config?.customPlayName ?? "Play",
      systemImage: "play.fill"
    )
    Self.applyCassetteStyle(
      to: playShuffledButton,
      title: configuration.isShuffleOnContextNeccessary ? "Shuffle" : "Random",
      systemImage: "shuffle",
      isHidden: configuration.isShuffleHidden
    )
    setupProminentLayoutIfNeeded()
    activate()
    registerForTraitChanges(
      [UITraitUserInterfaceStyle.self, UITraitHorizontalSizeClass.self],
      handler: { (self: Self, previousTraitCollection: UITraitCollection) in
        self.refresh()
      }
    )
  }

  /// cassette Patch 034 (3B, Option A): switch from .tinted() to
  /// .borderedTinted(). Borderedtinted gives a slightly more defined
  /// edge that reads more like Apple Music's primary action buttons
  /// while staying native. Keep contentInsets / imagePadding / SF
  /// Symbol point size unchanged from Patch 027 — only the surface
  /// treatment changes. Drop the explicit baseBackgroundColor so iOS
  /// can paint the bordered-tinted default (a subtle tint of the
  /// foreground color) rather than the prior bg2 grey.
  private static func applyCassetteStyle(
    to button: UIButton,
    title: String,
    systemImage: String,
    isHidden: Bool = false
  ) {
    var config = UIButton.Configuration.borderedTinted()
    config.image = UIImage(systemName: systemImage)
    config.imagePadding = 6
    config.imagePlacement = .leading
    config.cornerStyle = .medium
    config.baseForegroundColor = CassetteTheme.UIColors.ink
    config.contentInsets = NSDirectionalEdgeInsets(
      top: 8,
      leading: 16,
      bottom: 8,
      trailing: 16
    )
    config.title = title
    config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
      pointSize: 15,
      weight: .semibold
    )
    button.configuration = config
    button.isHidden = isHidden
  }

  // cassette Polish 2 (D1): build the action bar once. A single horizontal row,
  // pinned to the header bounds and toggled visible only for compact width in
  // refresh():  [heart]  ...  [PLAY 56][shuffle]  ...  [overflow].
  // - PLAY is the skeuomorphic CassettePlayButton (56pt), the visual anchor.
  // - Shuffle is a small ink icon (no label) to the immediate right of Play.
  // - Heart (leading) and overflow (trailing) are plain ink icons matching the
  //   player treatment; heart favorites the container, overflow opens the
  //   entity context menu.
  private func setupProminentLayoutIfNeeded() {
    guard config?.usesProminentPlayButton == true, prominentContainer == nil else { return }

    let container = UIView()
    container.translatesAutoresizingMaskIntoConstraints = false
    addSubview(container)

    let play = CassettePlayButton(diameter: Self.prominentPlayDiameter)
    play.translatesAutoresizingMaskIntoConstraints = false
    play.onTap = { [weak self] in self?.play(isShuffled: false) }

    let shuffle = UIButton(type: .system)
    var shuffleConfig = UIButton.Configuration.plain()
    shuffleConfig.image = UIImage(systemName: "shuffle")
    shuffleConfig.baseForegroundColor = CassetteTheme.UIColors.ink
    shuffleConfig.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
      pointSize: 18,
      weight: .semibold
    )
    shuffleConfig.contentInsets = NSDirectionalEdgeInsets(
      top: 5,
      leading: 5,
      bottom: 5,
      trailing: 5
    )
    shuffle.configuration = shuffleConfig
    shuffle.tintColor = CassetteTheme.UIColors.ink
    shuffle.accessibilityLabel = "Shuffle"
    shuffle.translatesAutoresizingMaskIntoConstraints = false
    shuffle.addTarget(self, action: #selector(prominentShufflePressed), for: .touchUpInside)

    let heart = Self.makePlainActionButton(systemImage: "heart")
    heart.addTarget(self, action: #selector(prominentHeartPressed), for: .touchUpInside)

    let overflow = Self.makePlainActionButton(systemImage: "ellipsis")
    overflow.accessibilityLabel = "More"
    overflow.showsMenuAsPrimaryAction = true
    overflow.menu = UIMenu.lazyMenu { [weak self] in
      guard let self,
            let entity = config?.favoriteEntity,
            let rootVC = config?.rootViewController
      else { return [] }
      return EntityPreviewActionBuilder(container: entity, on: rootVC).createMenuActions()
    }

    container.addSubview(heart)
    container.addSubview(play)
    container.addSubview(shuffle)
    container.addSubview(overflow)
    NSLayoutConstraint.activate([
      container.topAnchor.constraint(equalTo: topAnchor),
      container.bottomAnchor.constraint(equalTo: bottomAnchor),
      container.leadingAnchor.constraint(equalTo: leadingAnchor),
      container.trailingAnchor.constraint(equalTo: trailingAnchor),

      heart.leadingAnchor.constraint(equalTo: container.leadingAnchor),
      heart.centerYAnchor.constraint(equalTo: container.centerYAnchor),

      play.centerXAnchor.constraint(equalTo: container.centerXAnchor),
      play.centerYAnchor.constraint(equalTo: container.centerYAnchor),
      play.widthAnchor.constraint(equalToConstant: Self.prominentPlayDiameter),
      play.heightAnchor.constraint(equalToConstant: Self.prominentPlayDiameter),

      shuffle.leadingAnchor.constraint(equalTo: play.trailingAnchor, constant: 12),
      shuffle.centerYAnchor.constraint(equalTo: container.centerYAnchor),

      overflow.trailingAnchor.constraint(equalTo: container.trailingAnchor),
      overflow.centerYAnchor.constraint(equalTo: container.centerYAnchor),
    ])

    prominentContainer = container
    cassettePlayButton = play
    prominentShuffleButton = shuffle
    prominentHeartButton = heart
    prominentOverflowButton = overflow
  }

  // cassette Polish 2 (D1): plain ink icon button, 22pt symbol, 44pt hit
  // target via symmetric insets — matches the popup player heart/overflow.
  private static func makePlainActionButton(systemImage: String) -> UIButton {
    let button = UIButton(type: .system)
    var config = UIButton.Configuration.plain()
    config.image = UIImage(systemName: systemImage)
    config.baseForegroundColor = CassetteTheme.UIColors.ink
    config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
      pointSize: 22,
      weight: .regular
    )
    config.contentInsets = NSDirectionalEdgeInsets(top: 11, leading: 11, bottom: 11, trailing: 11)
    button.configuration = config
    button.tintColor = CassetteTheme.UIColors.ink
    button.translatesAutoresizingMaskIntoConstraints = false
    return button
  }

  @objc
  private func prominentShufflePressed() {
    Haptics.light.vibrate(isHapticsEnabled: appDelegate.storage.settings.user.isHapticsEnabled)
    shuffle()
  }

  @objc
  private func prominentHeartPressed() {
    guard let entity = config?.favoriteEntity, entity.isFavoritable,
          let accountInfo = entity.account?.info else { return }
    guard appDelegate.storage.settings.user.isOnlineMode else { return }
    Haptics.light.vibrate(isHapticsEnabled: appDelegate.storage.settings.user.isHapticsEnabled)
    Task { @MainActor in
      do {
        try await entity.remoteToggleFavorite(
          syncer: self.appDelegate.getMeta(accountInfo).librarySyncer
        )
      } catch {
        self.appDelegate.eventLogger.report(
          topic: "Toggle Favorite",
          error: error,
          isBackground: true
        )
      }
      self.refreshProminentHeartIcon()
    }
  }

  func activate() {
    playAllButton.isEnabled = true
    playShuffledButton.isEnabled = !(config?.isShuffleOnContextNeccessary ?? true) || appDelegate
      .storage.settings.user.isPlayerShuffleButtonEnabled
    cassettePlayButton?.isEnabled = true
    prominentShuffleButton?.isEnabled = playShuffledButton.isEnabled
  }

  func deactivate() {
    playAllButton.isEnabled = false
    playShuffledButton.isEnabled = false
    cassettePlayButton?.isEnabled = false
    prominentShuffleButton?.isEnabled = false
  }
}
