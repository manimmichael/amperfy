//
//  ArtistCircleCollectionCell.swift
//  Amperfy
//
//  Created by Cassette Patch 038.
//  Copyright (c) 2026 Cassette. All rights reserved.
//
//  cassette Patch 070: album-sized card with circular photo + "Artist" subtitle.

import AmperfyKit
import UIKit

final class ArtistCircleCollectionCell: BasicCollectionCell {
  static let artworkRegionHeight: CGFloat = 160
  static let circleDiameter: CGFloat = 120
  static let playOverlayDiameter: CGFloat = 40

  private let artworkContainer: UIView = {
    let view = UIView()
    view.translatesAutoresizingMaskIntoConstraints = false
    view.backgroundColor = CassetteTheme.UIColors.bg2
    view.layer.cornerRadius = CornerRadius.small.asCGFloat
    view.clipsToBounds = true
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

  private let roleLabel: UILabel = {
    let label = UILabel()
    label.translatesAutoresizingMaskIntoConstraints = false
    label.font = UIFont.cassette(.metadata)
    label.textColor = CassetteTheme.UIColors.ink2
    label.text = "Artist"
    label.numberOfLines = 1
    return label
  }()

  private var playOverlay: UIButton?
  var showsPlayOverlay = false
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
    showsPlayOverlay = false
    playOverlay?.isHidden = true
  }

  override func layoutSubviews() {
    super.layoutSubviews()
    entityImage.layer.cornerRadius = entityImage.bounds.width / 2.0
  }

  private func setupSubviews() {
    contentView.backgroundColor = CassetteTheme.UIColors.bg
    contentView.addSubview(artworkContainer)
    artworkContainer.addSubview(entityImage)
    contentView.addSubview(nameLabel)
    contentView.addSubview(roleLabel)

    NSLayoutConstraint.activate([
      artworkContainer.topAnchor.constraint(equalTo: contentView.topAnchor),
      artworkContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      artworkContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      artworkContainer.heightAnchor.constraint(equalToConstant: Self.artworkRegionHeight),

      entityImage.centerXAnchor.constraint(equalTo: artworkContainer.centerXAnchor),
      entityImage.centerYAnchor.constraint(equalTo: artworkContainer.centerYAnchor),
      entityImage.widthAnchor.constraint(equalToConstant: Self.circleDiameter),
      entityImage.heightAnchor.constraint(equalToConstant: Self.circleDiameter),

      nameLabel.topAnchor.constraint(equalTo: artworkContainer.bottomAnchor, constant: 8),
      nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      nameLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),

      roleLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
      roleLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      roleLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      roleLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),
    ])
  }

  func display(artist: Artist, showsPlayOverlay: Bool = false) {
    self.showsPlayOverlay = showsPlayOverlay
    nameLabel.text = artist.name
    entityImage.displayAndUpdate(entity: artist)
    setupPlayOverlayIfNeeded()
    playOverlay?.isHidden = !showsPlayOverlay
  }

  private func setupPlayOverlayIfNeeded() {
    guard playOverlay == nil else {
      playOverlay?.isHidden = !showsPlayOverlay
      return
    }
    var config = UIButton.Configuration.filled()
    config.baseBackgroundColor = CassetteTheme.UIColors.bg3
    config.baseForegroundColor = CassetteTheme.UIColors.ink
    config.cornerStyle = .capsule
    config.image = UIImage(systemName: "play.fill")?
      .withConfiguration(UIImage.SymbolConfiguration(pointSize: 16, weight: .bold))
    let button = UIButton(configuration: config)
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
