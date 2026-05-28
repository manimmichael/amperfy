//
//  GenericTableCell.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 20.02.22.
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

class GenericTableCell: BasicTableCell {
  @IBOutlet
  weak var titleLabel: UILabel!
  @IBOutlet
  weak var subtitleLabel: UILabel!
  @IBOutlet
  weak var entityImage: EntityImageView!
  @IBOutlet
  weak var infoLabel: UILabel!
  @IBOutlet
  weak var favoriteIconImage: UIImageView!

  @IBOutlet
  weak var infoLabelWidthConstraint: NSLayoutConstraint!

  static let rowHeight: CGFloat = 48.0 + margin.bottom + margin.top
  static let rowHeightWithoutImage: CGFloat = 28.0 + margin.bottom + margin.top

  private var container: PlayableContainable?
  private var rootView: UITableViewController?
  // cassette Polish 2 (A3/C1): artist artwork is circular app-wide. Albums and
  // everything else keep the squared 5pt rounded crop. Applied in
  // layoutSubviews because the imageView's bounds aren't final in display().
  private var isArtworkCircular = false

  override func layoutSubviews() {
    super.layoutSubviews()
    guard let entityImage else { return }
    entityImage.layer.masksToBounds = true
    entityImage.layer.cornerRadius = isArtworkCircular
      ? entityImage.bounds.width / 2.0
      : CornerRadius.small.asCGFloat
  }

  func display(container: PlayableContainable, rootView: UITableViewController) {
    self.container = container
    self.rootView = rootView
    isArtworkCircular = container is Artist
    setNeedsLayout()
    selectionStyle = .none
    titleLabel.text = container.name
    subtitleLabel.isHidden = container.subtitle == nil
    subtitleLabel.text = container.subtitle
    entityImage.display(
      theme: appDelegate.storage.settings.accounts.getSetting(container.account?.info).read
        .themePreference,
      container: container
    )
    let infoText = container.info(
      for: container.account?.apiType.asServerApiType,
      details: DetailInfoType(type: .short, settings: appDelegate.storage.settings)
    )
    infoLabel.isHidden = infoText.isEmpty
    infoLabel.text = infoText
    infoLabel.textAlignment = (traitCollection.horizontalSizeClass == .regular) ? .right : .left
    favoriteIconImage.isHidden = !container.isFavorite
    // cassette Patch 049 (Phase D): favorite icon drops from amber to ink.
    // See PlayableTableCell for shared rationale.
    favoriteIconImage.tintColor = CassetteTheme.UIColors.ink

    if container is Album {
      infoLabelWidthConstraint.constant = 75
    } else if container is Artist {
      infoLabelWidthConstraint.constant = 230
    } else if container is Genre {
      infoLabelWidthConstraint.constant = 260
    } else if container is Podcast {
      infoLabelWidthConstraint.constant = 140
    }
    accessoryType = .disclosureIndicator
    // cassette Patch 032: route through the canonical scale. Title drops
    // 17pt -> 16pt rowTitle to match track and other library rows.
    // Subtitle is metadata (12pt medium mono); the trailing info column
    // is caption (12pt regular mono) — same size, lighter weight.
    backgroundColor = CassetteTheme.UIColors.bg
    contentView.backgroundColor = CassetteTheme.UIColors.bg
    titleLabel.font = UIFont.cassette(.rowTitle)
    titleLabel.textColor = CassetteTheme.UIColors.ink
    subtitleLabel.font = UIFont.cassette(.metadata)
    subtitleLabel.textColor = CassetteTheme.UIColors.ink2
    infoLabel.font = UIFont.cassette(.caption)
    infoLabel.textColor = CassetteTheme.UIColors.ink3
  }
}
