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
  /// rendered in the XIB's bold-system 17/19 and system 16/17. Title on the
  /// display face, artist in mono, both re-stamped on trait change.
  private func applyCassetteType() {
    titleLabel.font = UIFont.cassetteDisplay(size: 20, weight: .semibold)
    titleLabel.textColor = CassetteTheme.UIColors.ink
    artistLabel.font = UIFont.cassette(.cardSubtitle)
    artistLabel.textColor = CassetteTheme.UIColors.ink2
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    applyCassetteType()
  }

  func refresh() {
    rootView?.playerHandler?.refreshCurrentlyPlayingInfo(
      artworkImage: artworkImage,
      titleLabel: titleLabel,
      artistLabel: artistLabel
    )
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
