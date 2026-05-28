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
  /// cassette polish Part 4: when true (set only by the Album / Artist /
  /// Playlist detail headers), the compact-width layout swaps the side-by-side
  /// bordered pair for a prominent skeuomorphic CassettePlayButton with a
  /// quiet secondary Shuffle beneath it. List headers leave this false.
  var usesProminentPlayButton: Bool = false
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
  /// Height of the prominent (skeuomorphic) layout: 68pt Play + 16pt gap +
  /// ~36pt Shuffle = 120pt of content.
  static let prominentFrameHeight: CGFloat = 120.0 + margin.top + margin.bottom
  static let margin = UIView.defaultMarginMiddleElement

  private var config: PlayShuffleInfoConfiguration?

  private var prominentContainer: UIView?
  private var cassettePlayButton: CassettePlayButton?
  private var secondaryShuffleButton: UIButton?

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

    // cassette polish Part 4: the prominent skeuomorphic layout is compact-
    // width only; iPad/Mac (regular) and standalone list headers keep the
    // known-good bordered pair.
    let showProminent = config.usesProminentPlayButton &&
      traitCollection.horizontalSizeClass == .compact
    prominentContainer?.isHidden = !showProminent
    playAllButton.isHidden = showProminent
    playShuffledButton.isHidden = showProminent || config.isShuffleHidden
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

  // cassette polish Part 4: build the prominent skeuomorphic Play + secondary
  // Shuffle layout once. It overlays the header's full bounds and is toggled
  // visible only for compact width in refresh(). The Shuffle button is a quiet
  // bordered control (1pt ink4 border, ink glyph + label, light haptic).
  private func setupProminentLayoutIfNeeded() {
    guard config?.usesProminentPlayButton == true, prominentContainer == nil else { return }

    let container = UIView()
    container.translatesAutoresizingMaskIntoConstraints = false
    addSubview(container)

    let play = CassettePlayButton()
    play.translatesAutoresizingMaskIntoConstraints = false
    play.onTap = { [weak self] in self?.play(isShuffled: false) }

    let shuffle = UIButton(type: .system)
    var shuffleConfig = UIButton.Configuration.bordered()
    shuffleConfig.image = UIImage(systemName: "shuffle")
    shuffleConfig.imagePadding = 6
    shuffleConfig.imagePlacement = .leading
    shuffleConfig.cornerStyle = .medium
    shuffleConfig.baseForegroundColor = CassetteTheme.UIColors.ink
    shuffleConfig.baseBackgroundColor = .clear
    shuffleConfig.background.strokeColor = CassetteTheme.UIColors.ink4
    shuffleConfig.background.strokeWidth = 1
    shuffleConfig.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
      pointSize: 13,
      weight: .semibold
    )
    var titleAttributes = AttributeContainer()
    titleAttributes.font = UIFont.cassette(.miniTitle)
    shuffleConfig.attributedTitle = AttributedString("Shuffle", attributes: titleAttributes)
    shuffle.configuration = shuffleConfig
    shuffle.translatesAutoresizingMaskIntoConstraints = false
    shuffle.addTarget(self, action: #selector(prominentShufflePressed), for: .touchUpInside)

    container.addSubview(play)
    container.addSubview(shuffle)
    NSLayoutConstraint.activate([
      container.topAnchor.constraint(equalTo: topAnchor),
      container.bottomAnchor.constraint(equalTo: bottomAnchor),
      container.leadingAnchor.constraint(equalTo: leadingAnchor),
      container.trailingAnchor.constraint(equalTo: trailingAnchor),

      play.topAnchor.constraint(equalTo: container.topAnchor),
      play.centerXAnchor.constraint(equalTo: container.centerXAnchor),
      play.widthAnchor.constraint(equalToConstant: CassettePlayButton.diameter),
      play.heightAnchor.constraint(equalToConstant: CassettePlayButton.diameter),

      shuffle.topAnchor.constraint(equalTo: play.bottomAnchor, constant: 16),
      shuffle.centerXAnchor.constraint(equalTo: container.centerXAnchor),
      shuffle.widthAnchor.constraint(equalToConstant: 140),
      shuffle.bottomAnchor.constraint(equalTo: container.bottomAnchor),
    ])

    prominentContainer = container
    cassettePlayButton = play
    secondaryShuffleButton = shuffle
  }

  @objc
  private func prominentShufflePressed() {
    Haptics.light.vibrate(isHapticsEnabled: appDelegate.storage.settings.user.isHapticsEnabled)
    shuffle()
  }

  func activate() {
    playAllButton.isEnabled = true
    playShuffledButton.isEnabled = !(config?.isShuffleOnContextNeccessary ?? true) || appDelegate
      .storage.settings.user.isPlayerShuffleButtonEnabled
    cassettePlayButton?.isEnabled = true
    secondaryShuffleButton?.isEnabled = playShuffledButton.isEnabled
  }

  func deactivate() {
    playAllButton.isEnabled = false
    playShuffledButton.isEnabled = false
    cassettePlayButton?.isEnabled = false
    secondaryShuffleButton?.isEnabled = false
  }
}
