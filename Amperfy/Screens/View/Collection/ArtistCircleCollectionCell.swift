//
//  ArtistCircleCollectionCell.swift
//  Amperfy
//
//  Created by Cassette Patch 038.
//  Copyright (c) 2026 Cassette. All rights reserved.
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

/// cassette Patch 038: Home tab "Artists" shelf cell. Circular
/// artwork sized to the carousel item, with the artist name in
/// the project metadata font centered below. Built programmatically
/// (no XIB) — the layout is simple enough that an additional XIB +
/// pbxproj resource entry would only add maintenance cost.
final class ArtistCircleCollectionCell: BasicCollectionCell {
  static let imageDiameter: CGFloat = 96.0
  static let nameTopSpacing: CGFloat = 8.0
  // cassette Patch 043: smaller overlay than the Album cell so the
  // capsule sits comfortably inside the 96pt circle without cropping
  // against the bottom-right edge.
  static let playOverlayDiameter: CGFloat = 32.0

  private let entityImage: LibraryEntityImage = {
    let imageView = LibraryEntityImage(frame: .zero)
    imageView.translatesAutoresizingMaskIntoConstraints = false
    imageView.contentMode = .scaleAspectFill
    imageView.clipsToBounds = true
    return imageView
  }()

  private let nameLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = UIFont.cassette(.metadata)
    label.textColor = CassetteTheme.UIColors.ink
    label.textAlignment = .center
    label.numberOfLines = 2
    label.lineBreakMode = .byTruncatingTail
    return label
  }()

  // cassette Patch 043: tap split for Home cards. Body tap still
  // navigates via the collection view's didSelectItemAt; this
  // overlay fires `onPlayTapped` so HomeVC can start playback.
  private lazy var playOverlay: UIButton = {
    // cassette Patch 051 (Phase F): see AlbumCollectionCell for rationale.
    // Bg3 disc + ink glyph; orange retired from home overlays.
    var config = UIButton.Configuration.filled()
    config.baseBackgroundColor = CassetteTheme.UIColors.bg3
    config.baseForegroundColor = CassetteTheme.UIColors.ink
    config.cornerStyle = .capsule
    config.image = UIImage(systemName: "play.fill")?
      .withConfiguration(UIImage.SymbolConfiguration(pointSize: 13, weight: .bold))
    config.contentInsets = NSDirectionalEdgeInsets(
      top: 0, leading: 0, bottom: 0, trailing: 0
    )
    let button = UIButton(configuration: config)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.accessibilityLabel = "Play"
    button.layer.shadowColor = UIColor.black.cgColor
    button.layer.shadowOpacity = 0.25
    button.layer.shadowRadius = 3
    button.layer.shadowOffset = CGSize(width: 0, height: 1)
    button.addAction(UIAction { [weak self] _ in self?.onPlayTapped?() }, for: .touchUpInside)
    return button
  }()

  /// cassette Patch 043: HomeVC sets this in its cellProvider so
  /// tapping the overlay starts playback for the artist. Cleared
  /// in `prepareForReuse` so the closure doesn't outlive the
  /// bound container.
  var onPlayTapped: (() -> Void)?

  override init(frame: CGRect) {
    super.init(frame: frame)
    setupSubviews()
  }

  required init?(coder: NSCoder) {
    super.init(coder: coder)
    setupSubviews()
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    onPlayTapped = nil
  }

  private func setupSubviews() {
    contentView.backgroundColor = CassetteTheme.UIColors.bg
    contentView.addSubview(entityImage)
    contentView.addSubview(nameLabel)
    contentView.addSubview(playOverlay)
    NSLayoutConstraint.activate([
      entityImage.topAnchor.constraint(equalTo: contentView.topAnchor),
      entityImage.centerXAnchor.constraint(equalTo: contentView.centerXAnchor),
      entityImage.widthAnchor.constraint(equalToConstant: Self.imageDiameter),
      entityImage.heightAnchor.constraint(equalToConstant: Self.imageDiameter),
      nameLabel.topAnchor.constraint(
        equalTo: entityImage.bottomAnchor,
        constant: Self.nameTopSpacing
      ),
      nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      nameLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      nameLabel.bottomAnchor.constraint(
        lessThanOrEqualTo: contentView.bottomAnchor
      ),
      // cassette Patch 043: anchor the overlay to the visible
      // bottom-right of the 96pt circle. A small inset (~3pt)
      // keeps the capsule from poking outside the circular mask
      // while staying touch-target friendly.
      playOverlay.widthAnchor.constraint(equalToConstant: Self.playOverlayDiameter),
      playOverlay.heightAnchor.constraint(equalToConstant: Self.playOverlayDiameter),
      playOverlay.trailingAnchor.constraint(equalTo: entityImage.trailingAnchor, constant: -3),
      playOverlay.bottomAnchor.constraint(equalTo: entityImage.bottomAnchor, constant: -3),
    ])
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    // RoundedImage hard-codes a 5pt corner radius in its initializer;
    // override here so the artwork renders as a true circle no
    // matter the imageDiameter we end up settling on.
    entityImage.layer.cornerRadius = entityImage.bounds.width / 2.0
  }

  func display(artist: Artist) {
    nameLabel.text = artist.name
    entityImage.displayAndUpdate(entity: artist)
  }
}
