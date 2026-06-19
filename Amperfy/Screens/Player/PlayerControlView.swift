//
//  PlayerControlView.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 07.02.24.
//  Copyright (c) 2024 Maximilian Bauer. All rights reserved.
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
import MarqueeLabel
import MediaPlayer
import UIKit

// MARK: - PlayerControlView

class PlayerControlView: UIView {
  // cassette Patch 104: +12pt so the added breathing room between the
  // transport row and the airplay/heart/queue row isn't squeezed out.
  static let frameHeight: CGFloat = 187
  static private let margin = UIEdgeInsets(
    top: 0,
    left: UIView.defaultMarginX,
    bottom: 20,
    right: UIView.defaultMarginX
  )

  private var player: PlayerFacade!
  private var rootView: PopupPlayerVC?
  private var playerHandler: PlayerUIHandler?
  #if targetEnvironment(macCatalyst) // ok
    var airplayVolume: MPVolumeView?
  #endif

  @IBOutlet
  weak var playButton: UIButton!
  @IBOutlet
  weak var previousButton: UIButton!
  @IBOutlet
  weak var nextButton: UIButton!
  @IBOutlet
  weak var skipBackwardButton: UIButton!
  @IBOutlet
  weak var skipForwardButton: UIButton!

  @IBOutlet
  weak var timeSlider: UISlider!
  @IBOutlet
  weak var elapsedTimeLabel: UILabel!
  @IBOutlet
  weak var remainingTimeLabel: UILabel!
  @IBOutlet
  weak var liveLabel: UILabel!
  @IBOutlet
  weak var audioInfoLabel: UILabel!
  @IBOutlet
  weak var playTypeIcon: UIImageView!

  @IBOutlet
  weak var optionsStackView: UIStackView!
  @IBOutlet
  weak var playerModeButton: UIButton!
  @IBOutlet
  weak var airplayButton: UIButton!
  @IBOutlet
  weak var displayPlaylistButton: UIButton!
  @IBOutlet
  weak var volumeButton: UIButton!
  @IBOutlet
  weak var optionsButton: UIButton!

  /// cassette polish Part 2: the heart moves into the bottom row (AirPlay -
  /// Heart - Queue). Created in code and inserted into `optionsStackView`.
  private var heartButton: UIButton?

  /// cassette transport polish: the previous/play/next buttons are re-pinned to
  /// the SAME equidistant quarter-point distribution the album action row uses
  /// (LibraryElementDetailTableHeaderView.setupProminentLayoutIfNeeded):
  /// centerX multipliers 0.5 / 1.0 / 1.5 against the full view width, so
  /// back/play/forward sit centered between the play disc and each screen edge
  /// — instead of the old fixed-width `fillEqually` cluster. Skip buttons (off
  /// by default in Cassette) flank at the eighth points (0.25 / 1.75). Set once.
  private var didSetupCassetteTransportLayout = false

  required init?(coder aDecoder: NSCoder) {
    #if targetEnvironment(macCatalyst) // ok
      self.airplayVolume = MPVolumeView(frame: .zero)
      airplayVolume!.showsVolumeSlider = false
      airplayVolume!.isHidden = true
    #endif

    super.init(coder: aDecoder)
    self.layoutMargins = Self.margin
    self.player = appDelegate.player
    player.addNotifier(notifier: self)

    #if targetEnvironment(macCatalyst) // ok
      addSubview(airplayVolume!)
    #endif
  }

  func prepare(toWorkOnRootView: PopupPlayerVC?) {
    rootView = toWorkOnRootView

    playerHandler = PlayerUIHandler(player: player, style: .popupPlayer)

    // cassette redesign (Surface 5): no container box behind play/pause —
    // the bg3 capsule (Patch 047) is retired and the play/pause glyph
    // carries the state on its own, matching the prev/next treatment.
    // Patch 104: transport glyphs were oversized — play/pause drops
    // 40 -> 32 (prev/next/skip drop to 20 in the XIB) and the config
    // routes through cassetteBare() (Root 1) so no glass capsule leaks.
    var playConfig = UIButton.Configuration.cassetteBare()
    playConfig.baseForegroundColor = CassetteTheme.UIColors.ink
    playConfig.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
      pointSize: 32, weight: .bold
    )
    playButton.configuration = playConfig
    playButton.tintColor = CassetteTheme.UIColors.ink
    previousButton.tintColor = CassetteTheme.UIColors.ink
    nextButton.tintColor = CassetteTheme.UIColors.ink
    skipBackwardButton.tintColor = CassetteTheme.UIColors.ink
    skipForwardButton.tintColor = CassetteTheme.UIColors.ink
    // cassette Polish 2 (G2): AirPlay + player-mode buttons were ink2 while
    // every other bottom-row glyph is ink — uniform ink reads as one row.
    airplayButton.tintColor = CassetteTheme.UIColors.ink
    playerModeButton.tintColor = CassetteTheme.UIColors.ink
    elapsedTimeLabel.font = UIFont.cassette(.metadata)
    elapsedTimeLabel.textColor = CassetteTheme.UIColors.ink2
    remainingTimeLabel.font = UIFont.cassette(.metadata)
    remainingTimeLabel.textColor = CassetteTheme.UIColors.ink2
    timeSlider.minimumTrackTintColor = CassetteTheme.UIColors.orange
    timeSlider.maximumTrackTintColor = CassetteTheme.UIColors.ink4
    timeSlider.thumbTintColor = CassetteTheme.UIColors.orange
    // cassette polish Part 1: drop the "MP3 2658 kbps" bitrate strip beneath the
    // scrubber. Removed from the hierarchy so the time row reads clean; the
    // refresh path keeps these as optionals and no longer un-hides them.
    audioInfoLabel?.removeFromSuperview()
    playTypeIcon?.removeFromSuperview()
    // cassette polish Part 2: kill the on-screen volume control (physical
    // buttons handle volume) and the player-level overflow menu. The heart
    // joins the bottom row between AirPlay and the queue button. The heart's
    // data path (rootView.favoritePressed -> remoteToggleFavorite) is
    // untouched; only its placement changes.
    volumeButton?.removeFromSuperview()
    optionsButton?.removeFromSuperview()
    setupBottomRowHeart()
    setupCassetteTransportLayout()
    refreshPlayer()

    registerForTraitChanges(
      [UITraitUserInterfaceStyle.self, UITraitHorizontalSizeClass.self],
      handler: { (self: Self, previousTraitCollection: UITraitCollection) in
        self.playerHandler?.refreshTimeInfo(
          timeSlider: self.timeSlider,
          elapsedTimeLabel: self.elapsedTimeLabel,
          remainingTimeLabel: self.remainingTimeLabel,
          audioInfoLabel: self.audioInfoLabel,
          playTypeIcon: self.playTypeIcon,
          liveLabel: self.liveLabel
        )
      }
    )
  }

  @IBAction
  func swipeHandler(_ gestureRecognizer: UISwipeGestureRecognizer) {
    if gestureRecognizer.state == .ended {
      rootView?.closePopupPlayer()
    }
  }

  @IBAction
  func playButtonPushed(_ sender: Any) {
    playerHandler?.playButtonPushed()
    playerHandler?.refreshPlayButton(playButton)
  }

  @IBAction
  func previousButtonPushed(_ sender: Any) {
    playerHandler?.previousButtonPushed()
    // Patch 113: optimistic now-playing update — refresh the hero
    // (title/artist/cover) from the just-advanced queue item now, not on the
    // trailing didStartPlaying callback. (This control bar refreshes its own
    // transport buttons; the hero lives on the popup VC.)
    rootView?.optimisticallyRefreshNowPlaying()
  }

  @IBAction
  func nextButtonPushed(_ sender: Any) {
    playerHandler?.nextButtonPushed()
    // Patch 113: optimistic now-playing update (see previousButtonPushed).
    rootView?.optimisticallyRefreshNowPlaying()
  }

  @IBAction
  func skipBackwardButtonPushed(_ sender: Any) {
    playerHandler?.skipBackwardButtonPushed()
  }

  @IBAction
  func skipForwardButtonPushed(_ sender: Any) {
    playerHandler?.skipForwardButtonPushed()
  }

  @IBAction
  func timeSliderChanged(_ sender: Any) {
    playerHandler?.timeSliderChanged(timeSlider: timeSlider)
  }

  @IBAction
  func timeSliderIsChanging(_ sender: Any) {
    playerHandler?.timeSliderIsChanging(
      timeSlider: timeSlider,
      elapsedTimeLabel: elapsedTimeLabel,
      remainingTimeLabel: remainingTimeLabel
    )
  }

  @IBAction
  func airplayButtonPushed(_ sender: UIButton) {
    #if targetEnvironment(macCatalyst) // ok
      playerHandler?.airplayButtonPushed(
        rootView: self,
        airplayButton: airplayButton,
        airplayVolume: airplayVolume
      )
    #else
      playerHandler?.airplayButtonPushed(rootView: self, airplayButton: airplayButton)
    #endif
  }

  // cassette polish Part 2: the on-screen volume control is removed (physical
  // buttons own volume). The button is dropped from the bottom row; this stub
  // preserves the XIB action connection and does nothing.
  @IBAction
  func volumeButtonPressed(_ sender: Any) {}

  /// cassette transport polish: re-pin back/play/forward to the album action
  /// row's equidistant distribution (centerX multipliers 0.5 / 1.0 / 1.5 of the
  /// full view width). The transport buttons ship inside a fixed-width
  /// `fillEqually` stack (`SoI-ny-Hw0`); that clusters them more tightly than
  /// the album row's heart/play/shuffle and isn't a true equidistant-around-
  /// center layout once the skip buttons toggle. We lift the 5 buttons out of
  /// that stack into `self` and pin each by centerX multiplier, keeping the now-
  /// empty stack as the (unchanged) vertical anchor so the time row above and
  /// the AirPlay/heart/queue row below keep their existing spacing.
  private func setupCassetteTransportLayout() {
    guard !didSetupCassetteTransportLayout else { return }
    guard let transportStack = playButton.superview else { return }
    didSetupCassetteTransportLayout = true

    // The stack stays in the hierarchy (its top/centerX/width/height constraints
    // anchor the row vertically) but no longer lays out the buttons.
    let rowCenterY = transportStack.centerYAnchor

    func pin(_ button: UIButton?, centerXMultiplier: CGFloat) {
      guard let button else { return }
      button.removeFromSuperview()
      button.translatesAutoresizingMaskIntoConstraints = false
      addSubview(button)
      NSLayoutConstraint.activate([
        NSLayoutConstraint(
          item: button,
          attribute: .centerX,
          relatedBy: .equal,
          toItem: self,
          attribute: .centerX,
          multiplier: centerXMultiplier,
          constant: 0
        ),
        button.centerYAnchor.constraint(equalTo: rowCenterY),
      ])
    }

    // Primary three — identical multipliers to the album action row.
    pin(previousButton, centerXMultiplier: 0.5)
    pin(playButton, centerXMultiplier: 1.0)
    pin(nextButton, centerXMultiplier: 1.5)
    // Skip buttons (default-hidden in Cassette) flank symmetrically further out.
    pin(skipBackwardButton, centerXMultiplier: 0.25)
    pin(skipForwardButton, centerXMultiplier: 1.75)
  }

  private func setupBottomRowHeart() {
    let heart = UIButton(type: .system)
    heart.translatesAutoresizingMaskIntoConstraints = false
    heart.addTarget(self, action: #selector(heartButtonPushed), for: .touchUpInside)
    // cassette Polish 2 (G1): keep the heart from clipping inside the 28pt row.
    heart.clipsToBounds = false
    NSLayoutConstraint.activate([
      heart.widthAnchor.constraint(equalToConstant: 28),
      heart.heightAnchor.constraint(equalToConstant: 28),
    ])
    optionsStackView.clipsToBounds = false
    // AirPlay (index 0) - Heart - Queue ...
    optionsStackView.insertArrangedSubview(heart, at: 1)
    heartButton = heart
  }

  // cassette Polish 2 (G1): the shared `refreshFavoriteButton` applies an 11pt
  // content inset for a standalone 44pt hit target. Inside the 28pt bottom row
  // that left only ~6pt for the 22pt glyph, clipping it. Re-fit to the row
  // after refreshing the favorite state.
  private func refreshBottomRowHeart() {
    guard let heartButton else { return }
    rootView?.refreshFavoriteButton(button: heartButton)
    if var config = heartButton.configuration {
      config.contentInsets = .zero
      heartButton.configuration = config
    }
  }

  @objc
  func heartButtonPushed() {
    rootView?.favoritePressed()
    refreshBottomRowHeart()
  }

  @IBAction
  func displayPlaylistPressed() {
    rootView?.switchDisplayStyleOptionPersistent()
    playerHandler?.refreshDisplayPlaylistButton(displayPlaylistButton: displayPlaylistButton)
  }

  @IBAction
  func playerModeChangePressed(_ sender: Any) {
    switch player.playerMode {
    case .music:
      appDelegate.player.setPlayerMode(.podcast)
    case .podcast:
      appDelegate.player.setPlayerMode(.music)
    }
    refreshPlayerModeChangeButton()
  }

  func refreshView() {
    refreshPlayer()
  }

  func refreshPlayer() {
    playerHandler?.refreshSkipButtons(
      skipBackwardButton: skipBackwardButton,
      skipForwardButton: skipForwardButton
    )
    playerHandler?.refreshPlayButton(playButton)
    playerHandler?.refreshTimeInfo(
      timeSlider: timeSlider,
      elapsedTimeLabel: elapsedTimeLabel,
      remainingTimeLabel: remainingTimeLabel,
      audioInfoLabel: audioInfoLabel,
      playTypeIcon: playTypeIcon,
      liveLabel: liveLabel
    )
    playerHandler?.refreshPrevNextButtons(previousButton: previousButton, nextButton: nextButton)
    playerHandler?.refreshDisplayPlaylistButton(displayPlaylistButton: displayPlaylistButton)
    refreshBottomRowHeart()
    refreshPlayerModeChangeButton()
  }

  func refreshPlayerModeChangeButton() {
    playerModeButton.isHidden = appDelegate.player.podcastItemCount == 0 && appDelegate.player
      .playerMode != .podcast
    switch player.playerMode {
    case .music:
      playerModeButton.setImage(UIImage.musicalNotes, for: .normal)
    case .podcast:
      playerModeButton.setImage(UIImage.podcast, for: .normal)
    }
    optionsStackView.layoutIfNeeded()
  }
}

// MARK: MusicPlayable

extension PlayerControlView: MusicPlayable {
  func didStartPlayingFromBeginning() {}

  func didStartPlaying() {
    refreshPlayer()
  }

  func didPause() {
    refreshPlayer()
  }

  func didStopPlaying() {
    refreshPlayer()
    playerHandler?.refreshSkipButtons(
      skipBackwardButton: skipBackwardButton,
      skipForwardButton: skipForwardButton
    )
  }

  func didElapsedTimeChange() {
    playerHandler?.refreshTimeInfo(
      timeSlider: timeSlider,
      elapsedTimeLabel: elapsedTimeLabel,
      remainingTimeLabel: remainingTimeLabel,
      audioInfoLabel: audioInfoLabel,
      playTypeIcon: playTypeIcon,
      liveLabel: liveLabel
    )
  }

  func didPlaylistChange() {
    refreshPlayer()
  }

  func didArtworkChange() {}

  func didShuffleChange() {}

  func didRepeatChange() {}

  func didPlaybackRateChange() {}
}
