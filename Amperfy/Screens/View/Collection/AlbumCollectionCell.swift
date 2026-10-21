//
//  AlbumCollectionCell.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 21.01.22.
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

class AlbumCollectionCell: BasicCollectionCell {
  @IBOutlet
  weak var titleLabel: UILabel!
  @IBOutlet
  weak var subtitleLabel: UILabel!
  @IBOutlet
  weak var entityImage: EntityImageView!
  @IBOutlet
  weak var artworkImageWidthConstraint: NSLayoutConstraint!

  static let maxWidth: CGFloat = 250.0

  private var container: PlayableContainable?
  private var rootView: UICollectionViewController?
  private var rootFlowLayout: UICollectionViewDelegateFlowLayout?
  private var itemWidth: CGFloat?

  /// Single type path for album cards. IB size-class font variations used to
  /// re-apply system SF after `display()`, so Home shelves mixed faces card
  /// to card. Fonts are owned here only - awakeFromNib, every bind, and any
  /// trait change - never by the XIB.
  private func applyCassetteType() {
    titleLabel?.font = UIFont.cassette(.rowTitle)
    titleLabel?.textColor = UIColor.cassette(.textPrimary)
    titleLabel?.adjustsFontForContentSizeCategory = false
    subtitleLabel?.font = UIFont.cassette(.cardSubtitle)
    subtitleLabel?.textColor = UIColor.cassette(.textSecondary)
    subtitleLabel?.adjustsFontForContentSizeCategory = false
  }

  override func awakeFromNib() {
    super.awakeFromNib()
    applyCassetteType()
  }

  override func traitCollectionDidChange(_ previousTraitCollection: UITraitCollection?) {
    super.traitCollectionDidChange(previousTraitCollection)
    // IB variations can rewrite label fonts when size class / idiom shifts.
    // Re-stamp the Cassette faces so the shelf never falls back to SF.
    applyCassetteType()
  }

  // cassette Patch 043: play overlay split. Tap on the artwork
  // body still navigates (handled by the collection view's
  // didSelectItemAt); tap on the play disc fires the closure so the host
  // can start playback for the container.
  /// phone-taste: the mock's `.tilePlay`, a 34pt cream disc (was a 40pt glass button).
  static let playOverlayDiameter: CGFloat = 34
  private var playOverlay: UIButton?

  /// cassette Patch 043: HomeVC sets this in its cellProvider so
  /// tapping the overlay starts playback for the cell's container.
  /// Cleared in `prepareForReuse` so the closure doesn't outlive
  /// the bound container.
  var onPlayTapped: (() -> ())?
  /// Shows the one-tap play disc on the cover. Opt-in per surface ("every cover plays in
  /// one tap" on Home and the table-page shelves; the Library grid stays clean). Works
  /// whether it is set before or after `display`.
  var showsPlayOverlay = false {
    didSet {
      if showsPlayOverlay { setupPlayOverlayIfNeeded() }
      playOverlay?.isHidden = !showsPlayOverlay
    }
  }

  /// Replaces the container's own subtitle line when set (e.g. a year on an artist's
  /// album shelf). Set before `display`.
  var subtitleOverride: String?
  /// A clear card, for shelves drawn over a lit page. Set before `display`.
  var clearsBackground = false

  func display(
    container: PlayableContainable,
    rootView: UICollectionViewController,
    itemWidth: CGFloat,
    initialIndexPath: IndexPath
  ) {
    self.itemWidth = itemWidth
    rootFlowLayout = nil
    apply(
      container: container,
      rootView: rootView,
      initialIndexPath: initialIndexPath
    )
  }

  func display(
    container: PlayableContainable,
    rootView: UICollectionViewController,
    rootFlowLayout: UICollectionViewDelegateFlowLayout,
    initialIndexPath: IndexPath
  ) {
    self.rootFlowLayout = rootFlowLayout
    itemWidth = nil
    apply(
      container: container,
      rootView: rootView,
      initialIndexPath: initialIndexPath
    )
  }

  /// Patch 110 (3b): standalone use (e.g. AlbumCarouselTableCell) with a fixed
  /// item width and no hosting UICollectionViewController. The artwork is sized
  /// from `itemWidth`, so no rootView/flow-layout callback is needed.
  func display(container: PlayableContainable, itemWidth: CGFloat) {
    self.itemWidth = itemWidth
    rootFlowLayout = nil
    apply(
      container: container,
      rootView: nil,
      initialIndexPath: IndexPath(item: 0, section: 0)
    )
  }

  private func apply(
    container: PlayableContainable,
    rootView: UICollectionViewController?,
    initialIndexPath: IndexPath
  ) {
    self.container = container
    self.rootView = rootView
    titleLabel.text = container.name
    subtitleLabel.text = subtitleOverride ?? container.subtitle
    // Barlow title + mono artist (legible at the 13pt floor).
    applyCassetteType()
    contentView.backgroundColor = clearsBackground ? .clear : UIColor.cassette(.surfaceBase)
    // cassette: album covers get a minimal 3pt corner (.verySmall), matching the
    // album detail hero, so bordered / edge-to-edge cover art keeps crisp corners
    // instead of having its edge shaved by the rounding. (Was .big = 15pt.)
    entityImage.display(
      theme: appDelegate.storage.settings.accounts.getSetting(container.account?.info).read
        .themePreference,
      container: container,
      cornerRadius: .verySmall
    )
    // cassette redesign (Surface 3): subtle content-level highlight — a
    // hairline ink ring that lifts dark covers off the dark background.
    // Content styling the OS doesn't provide; not a material.
    entityImage.layer.borderWidth = 1.0 / max(traitCollection.displayScale, 1.0)
    entityImage.layer.borderColor = UIColor.cassette(.textPrimary)
      .withAlphaComponent(0.08).cgColor
    if showsPlayOverlay { setupPlayOverlayIfNeeded() }
    playOverlay?.isHidden = !showsPlayOverlay
    updateArtworkImageConstraint(indexPath: initialIndexPath)
    layoutIfNeeded()
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    onPlayTapped = nil
    showsPlayOverlay = false
    playOverlay?.isHidden = true
    subtitleOverride = nil
    clearsBackground = false
  }

  override func layoutSubviews() {
    if let indexPath = rootView?.collectionView.indexPath(for: self) {
      updateArtworkImageConstraint(indexPath: indexPath)
    } else if itemWidth != nil {
      // Standalone (no hosting collection-view controller): width is fixed.
      updateArtworkImageConstraint(indexPath: IndexPath(item: 0, section: 0))
    }
    super.layoutSubviews()
  }

  /// Lazily install the play disc 8pt inside the artwork's bottom-right corner (the
  /// mock's `.tilePlay`: right 8, bottom 8). Idempotent.
  private func setupPlayOverlayIfNeeded() {
    guard playOverlay == nil else { return }
    let button = Self.makePlayOverlayButton()
    button.isHidden = !showsPlayOverlay
    button.addAction(UIAction { [weak self] _ in self?.onPlayTapped?() }, for: .touchUpInside)
    contentView.addSubview(button)
    NSLayoutConstraint.activate([
      button.widthAnchor.constraint(equalToConstant: Self.playOverlayDiameter),
      button.heightAnchor.constraint(equalToConstant: Self.playOverlayDiameter),
      button.trailingAnchor.constraint(equalTo: entityImage.trailingAnchor, constant: -8),
      button.bottomAnchor.constraint(equalTo: entityImage.bottomAnchor, constant: -8),
    ])
    playOverlay = button
  }

  /// The one-tap play disc for covers (album tiles, artist circles; the mock's
  /// `.tilePlay`): a cream disc with a bold filled play glyph nudged 2pt for optical
  /// centring and a soft shadow. Draws at `playOverlayDiameter`; touches land on a 44pt
  /// circle around it. A UIButton cancels on pan, so scrolling a shelf never plays.
  /// The SwiftUI twin is `CassettePlayDisc`.
  static func makePlayOverlayButton() -> UIButton {
    var config = UIButton.Configuration.filled()
    config.baseBackgroundColor = UIColor.cassette(.fillSelected)
    config.baseForegroundColor = UIColor.cassette(.textOnFill)
    config.cornerStyle = .capsule
    config.image = CassetteIcon.play.symbolImage
    config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
      pointSize: 15,
      weight: .bold
    )
    config.contentInsets = NSDirectionalEdgeInsets(top: 0, leading: 2, bottom: 0, trailing: 0)
    let button = CassettePlayOverlayButton(configuration: config)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.accessibilityLabel = "Play"
    button.clipsToBounds = false
    button.layer.shadowColor = UIColor.black.cgColor
    button.layer.shadowOpacity = 0.45
    button.layer.shadowRadius = 6
    button.layer.shadowOffset = CGSize(width: 0, height: 4)
    return button
  }

  func updateArtworkImageConstraint(indexPath: IndexPath) {
    if let rootView, let rootFlowLayout = rootFlowLayout,
       let itemSize = rootFlowLayout.collectionView?(
         rootView.collectionView,
         layout: rootView.collectionView.collectionViewLayout,
         sizeForItemAt: indexPath
       ) {
      let newImageWidth = min(itemSize.width, itemSize.height)
      artworkImageWidthConstraint.constant = newImageWidth
    } else if let itemWidth {
      artworkImageWidthConstraint.constant = itemWidth
    }
  }
}

// MARK: - CassettePlayOverlayButton

/// The play disc's hit area grows to 44pt around its smaller drawn circle.
private final class CassettePlayOverlayButton: UIButton {
  private static let minimumHitSide: CGFloat = 44

  override func layoutSubviews() {
    super.layoutSubviews()
    // A shadow path keeps the soft shadow cheap in a scrolling shelf.
    layer.shadowPath = UIBezierPath(ovalIn: bounds).cgPath
  }

  override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
    let dx = min(0, (bounds.width - Self.minimumHitSide) / 2)
    let dy = min(0, (bounds.height - Self.minimumHitSide) / 2)
    return bounds.insetBy(dx: dx, dy: dy).contains(point)
  }
}
