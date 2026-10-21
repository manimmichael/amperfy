//
//  CurrentlyPlayingTableCell.swift
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

class CurrentlyPlayingTableCell: BasicTableCell {
  static let rowHeight: CGFloat = 94.0

  private var rootView: PopupPlayerVC?

  @IBOutlet
  weak var artworkImage: LibraryEntityImage!
  @IBOutlet
  weak var titleLabel: MarqueeLabel!
  @IBOutlet
  weak var artistLabel: MarqueeLabel!
  @IBOutlet
  weak var favoriteButton: UIButton!
  @IBOutlet
  weak var optionsButton: UIButton!

  required init?(coder aDecoder: NSCoder) {
    super.init(coder: aDecoder)
  }

  func prepare(toWorkOnRootView: PopupPlayerVC?) {
    rootView = toWorkOnRootView
    // cassette: favorites removed. The favorite button is kept in the nib (its
    // outlet + constraints anchor the options button) but permanently hidden and
    // no longer wired to any action.
    favoriteButton.isHidden = true
    titleLabel.applyAmperfyStyle()
    artistLabel.applyAmperfyStyle()
    applyCassetteType()
    refresh()
  }

  /// cassette (BUG-418): the compact now-playing header at the top of the queue
  /// rendered in the XIB's bold-system 17/19 and system 16/17. Re-stamped on trait change.
  /// phone-taste (queue-now-row): the same voice as Now Playing, a step smaller: the song in
  /// Barlow ExtraBold 24 capitals (refresh() sets the capitals), the artist in the answer
  /// voice (New York italic 20) in the record's colour.
  private func applyCassetteType() {
    titleLabel.font = UIFont.cassetteDisplay(size: 24, weight: .extraBold)
    titleLabel.textColor = UIColor.cassette(.textPrimary)
    artistLabel.font = UIFont.cassette(.answerCompact)
    applyCoverTint(rootView?.coverTint ?? .neutral)
  }

  /// phone-taste: the artist line speaks in the record's colour (`.neutral` until one is
  /// read, never orange).
  func applyCoverTint(_ tint: CoverTint) {
    artistLabel.textColor = tint.text
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    applyCassetteType()
  }

  /// The shared refresh writes the song title here in mixed case, and only its capitals
  /// reach the marquee, which then restarts its scroll only when the song changes.
  private lazy var mixedCaseTitle = UILabel()

  func refresh() {
    rootView?.playerHandler?.refreshCurrentlyPlayingInfo(
      artworkImage: artworkImage,
      titleLabel: mixedCaseTitle,
      artistLabel: artistLabel
    )
    // phone-taste: capitals here only; the mini player and the lock screen keep mixed
    // case, and VoiceOver reads the title as written.
    titleLabel.text = mixedCaseTitle.text?.uppercased()
    titleLabel.accessibilityLabel = mixedCaseTitle.text
    rootView?.refreshOptionButton(button: optionsButton, rootView: rootView)
  }

  func refreshArtwork() {
    rootView?.playerHandler?.refreshArtwork(artworkImage: artworkImage)
  }

  @IBAction
  func artworkPressed(_ sender: Any) {
    rootView?.controlView?.displayPlaylistPressed()
  }

  @IBAction
  func titlePressed(_ sender: Any) {
    rootView?.displayAlbumDetail()
    rootView?.displayPodcastDetail()
  }

  @IBAction
  func artistNamePressed(_ sender: Any) {
    rootView?.displayArtistDetail()
    rootView?.displayPodcastDetail()
  }
}
