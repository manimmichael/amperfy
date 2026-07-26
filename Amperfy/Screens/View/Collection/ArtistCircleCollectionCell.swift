//
//  ArtistCircleCollectionCell.swift
//  Amperfy
//
//  Created by Cassette Patch 038.
//  Copyright (c) 2026 Cassette. All rights reserved.
//
//  cassette Patch 070: album-sized card with circular photo.
//  The redundant "Artist" caption under the name is retired - the circle
//  already says what it is; album cards don't label themselves "Album".
//

import AmperfyKit
import UIKit

final class ArtistCircleCollectionCell: BasicCollectionCell {
  static let artworkRegionHeight: CGFloat = 160
  // The circle nearly fills its 160pt cell (a hair of inset each side), matching
  // the album cards beside it and the Android artist grid, which fills its column
  // edge to edge. Was 120 in a 160 cell - a 20pt-per-side margin that left the
  // artist a small token in a sea of negative space.
  static let circleDiameter: CGFloat = 152
  static let playOverlayDiameter: CGFloat = 40

  private let artworkContainer: UIView = {
    let view = UIView()
    view.translatesAutoresizingMaskIntoConstraints = false
    // cassette Polish 2 (A3): clear container. Previously a bg2 rounded-rect
    // tile sat behind the 120pt circle, so the square corners showed around
    // the photo and made the card read "uneven / broken". The circular photo
    // now floats directly on the cell background.
    view.backgroundColor = .clear
    return view
  }()

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
    label.font = UIFont.cassette(.rowTitle)
    label.textColor = CassetteTheme.UIColors.ink
    label.numberOfLines = 2
    label.lineBreakMode = .byTruncatingTail
    return label
  }()

  private var playOverlay: UIButton?
  var showsPlayOverlay = false
  var onPlayTapped: (() -> ())?

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
    showsPlayOverlay = false
    playOverlay?.isHidden = true
  }

  private func setupSubviews() {
    // cassette Patch 104 (Root 3): the circle is deterministic - the photo
    // is constrained to a fixed square (Self.circleDiameter), so the mask is set
    // once from the constant instead of racing layout passes in layoutSubviews.
    entityImage.layer.cornerRadius = Self.circleDiameter / 2.0
    contentView.backgroundColor = CassetteTheme.UIColors.bg
    contentView.addSubview(artworkContainer)
    artworkContainer.addSubview(entityImage)
    contentView.addSubview(nameLabel)

    // Dropped just below required so the compositional layout's first
    // `.estimated`-height pass (which sizes the cell before it self-sizes to
    // content) can't force an unsatisfiable conflict - the artwork region
    // momentarily compresses instead of the required 160pt fighting a smaller
    // estimate. At the self-sized steady state nothing competes, so it resolves
    // at 160 exactly and the layout is unchanged.
    let artworkHeight = artworkContainer.heightAnchor
      .constraint(equalToConstant: Self.artworkRegionHeight)
    artworkHeight.priority = UILayoutPriority(999)

    NSLayoutConstraint.activate([
      artworkContainer.topAnchor.constraint(equalTo: contentView.topAnchor),
      artworkContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      artworkContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      artworkHeight,

      entityImage.centerXAnchor.constraint(equalTo: artworkContainer.centerXAnchor),
      entityImage.centerYAnchor.constraint(equalTo: artworkContainer.centerYAnchor),
      entityImage.widthAnchor.constraint(equalToConstant: Self.circleDiameter),
      entityImage.heightAnchor.constraint(equalToConstant: Self.circleDiameter),

      nameLabel.topAnchor.constraint(equalTo: artworkContainer.bottomAnchor, constant: 8),
      nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      nameLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      nameLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),
    ])
  }

  func display(artist: Artist, showsPlayOverlay: Bool = false) {
    self.showsPlayOverlay = showsPlayOverlay
    nameLabel.text = artist.name
    entityImage.displayAndUpdate(entity: artist)
    setupPlayOverlayIfNeeded()
    playOverlay?.isHidden = !showsPlayOverlay
  }

  // cassette redesign (Surface 3/4): overlay play is Liquid Glass (shared
  // config with AlbumCollectionCell) - no filled disc, no manual shadow.
  private func setupPlayOverlayIfNeeded() {
    guard playOverlay == nil else {
      playOverlay?.isHidden = !showsPlayOverlay
      return
    }
    let button = UIButton(
      configuration: AlbumCollectionCell.makeGlassPlayOverlayConfiguration()
    )
    button.translatesAutoresizingMaskIntoConstraints = false
    button.accessibilityLabel = "Play"
    button.isHidden = !showsPlayOverlay
    button.addAction(UIAction { [weak self] _ in self?.onPlayTapped?() }, for: .touchUpInside)
    artworkContainer.addSubview(button)
    NSLayoutConstraint.activate([
      button.widthAnchor.constraint(equalToConstant: Self.playOverlayDiameter),
      button.heightAnchor.constraint(equalToConstant: Self.playOverlayDiameter),
      button.trailingAnchor.constraint(equalTo: artworkContainer.trailingAnchor, constant: -8),
      button.bottomAnchor.constraint(equalTo: artworkContainer.bottomAnchor, constant: -8),
    ])
    playOverlay = button
  }
}
