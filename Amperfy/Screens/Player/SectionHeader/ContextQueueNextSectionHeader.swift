//
//  ContextQueueSectionHeader.swift
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
import UIKit

// MARK: - ContextQueueNextSectionHeader

class ContextQueueNextSectionHeader: UIView {
  static let frameHeight: CGFloat = 40.0 + margin.top + margin.bottom
  static let margin = UIEdgeInsets(
    top: 8,
    left: UIView.defaultMarginX,
    bottom: 8,
    right: UIView.defaultMarginX
  )

  private var player: PlayerFacade!
  private var rootView: PopupPlayerVC?
  private var playerHandler: PlayerUIHandler?

  @IBOutlet
  weak var queueNameLabel: UILabel!
  @IBOutlet
  weak var contextNameLabel: MarqueeLabel!

  @IBOutlet
  weak var shuffleButton: UIButton!
  @IBOutlet
  weak var repeatButton: UIButton!

  required init?(coder aDecoder: NSCoder) {
    super.init(coder: aDecoder)
    self.layoutMargins = Self.margin
    self.player = appDelegate.player
    player.addNotifier(notifier: self)
    self.playerHandler = PlayerUIHandler(player: player, style: .popupPlayer)
  }

  /// phone-taste: the record's colour for the heading's answer. The player sheet pushes it;
  /// the Mac queue, which has no record colour, keeps `.neutral`.
  private var coverTint: CoverTint = .neutral

  override func awakeFromNib() {
    super.awakeFromNib()
    // phone-taste (queue-head-two-voice): the head is one line, "UP NEXT" and then what
    // the queue was started from, so the second label goes. Done here rather than in
    // prepare() so the Mac queue, which never calls prepare(), reads the same.
    MainActor.assumeIsolated {
      contextNameLabel.isHidden = true
      queueNameLabel.numberOfLines = 1
      queueNameLabel.lineBreakMode = .byTruncatingTail
      queueNameLabel.adjustsFontSizeToFitWidth = false
      queueNameLabel.accessibilityTraits = .header
      // Centre the line on the shuffle and repeat glyphs. The nib's top pin stays: the
      // label has no height of its own, so it grows down to this centre line and UILabel
      // centres its text in the space.
      queueNameLabel.centerYAnchor.constraint(equalTo: shuffleButton.centerYAnchor)
        .isActive = true
      refreshHeading()
    }
  }

  func prepare(toWorkOnRootView: PopupPlayerVC?) {
    rootView = toWorkOnRootView
    contextNameLabel.applyAmperfyStyle()
    applyCassetteType()
    refresh()
  }

  /// cassette (BUG-418): the XIB carries system fonts. Re-stamped on trait change because
  /// the nib's variations put SF back. phone-taste: the head is the two-voice heading (the
  /// shout in Barlow ExtraBold 26, the answer in the New York italic 25 in the record's
  /// colour), rebuilt here, in refresh() and when a new colour arrives.
  private func applyCassetteType() {
    if let rootView {
      coverTint = rootView.coverTint
    }
    refreshHeading()
  }

  /// phone-taste: a newly read record colour for the heading's answer.
  func applyCoverTint(_ tint: CoverTint) {
    coverTint = tint
    refreshHeading()
  }

  /// What the queue was started from, or nil when there is no honest name for it: an empty
  /// context, or the player's internal "Mixed Context" and "Siri Intent" labels. Then the
  /// head reads just "UP NEXT". Display only; the stored context name is untouched.
  static func queueAnswer(contextName: String) -> String? {
    let name = contextName.trimmingCharacters(in: .whitespacesAndNewlines)
    switch name {
    case "", "Mixed Context", "Siri Intent":
      return nil
    default:
      return name
    }
  }

  private func refreshHeading() {
    let answer = Self.queueAnswer(contextName: player.contextName)
    queueNameLabel.attributedText = CassetteHeading.attributed(
      shout: "UP NEXT",
      answer: answer,
      answerColor: coverTint.text
    )
    queueNameLabel.accessibilityLabel = CassetteHeading.accessibilityLabel(
      shout: "Up next",
      answer: answer
    )
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    applyCassetteType()
  }

  func refresh() {
    refreshHeading()
    refreshCurrentlyPlayingInfo()
    playerHandler?.refreshRepeatButton(repeatButton: repeatButton)
    playerHandler?.refreshShuffleButton(shuffleButton: shuffleButton)
  }

  func refreshCurrentlyPlayingInfo() {
    switch player.playerMode {
    case .music:
      repeatButton.isHidden = false
      shuffleButton.isHidden = false
    case .podcast:
      repeatButton.isHidden = true
      shuffleButton.isHidden = true
    }
  }

  @IBAction
  func pressedShuffle(_ sender: Any) {
    playerHandler?.shuffleButtonPushed()
    playerHandler?.refreshShuffleButton(shuffleButton: shuffleButton)
    rootView?.scrollToCurrentlyPlayingRow()
  }

  @IBAction
  func pressedRepeat(_ sender: Any) {
    playerHandler?.repeatButtonPushed()
    playerHandler?.refreshRepeatButton(repeatButton: repeatButton)
  }
}

// MARK: MusicPlayable

extension ContextQueueNextSectionHeader: MusicPlayable {
  func didStartPlayingFromBeginning() {}

  func didStartPlaying() {}

  func didPause() {}

  func didStopPlaying() {
    refreshCurrentlyPlayingInfo()
  }

  func didElapsedTimeChange() {}

  func didPlaylistChange() {
    refresh()
  }

  func didArtworkChange() {}

  func didShuffleChange() {
    playerHandler?.refreshShuffleButton(shuffleButton: shuffleButton)
  }

  func didRepeatChange() {
    playerHandler?.refreshRepeatButton(repeatButton: repeatButton)
  }

  func didPlaybackRateChange() {}
}
