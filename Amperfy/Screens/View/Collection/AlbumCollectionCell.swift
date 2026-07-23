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

  // cassette Patch 043: play overlay split. Tap on the artwork
  // body still navigates (handled by the collection view's
  // didSelectItemAt); tap on this 40pt circular orange button fires
  // the closure so HomeVC can start playback for the container.
  private static let playOverlayDiameter: CGFloat = 40.0
  private var playOverlay: UIButton?

  /// cassette Patch 043: HomeVC sets this in its cellProvider so
  /// tapping the overlay starts playback for the cell's container.
  /// Cleared in `prepareForReuse` so the closure doesn't outlive
  /// the bound container.
  var onPlayTapped: (() -> ())?
  /// cassette Patch 069: only the Recent shelf resume card shows the overlay.
  var showsPlayOverlay = false

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
    subtitleLabel.text = container.subtitle
    // cassette Patch 032: route through the canonical scale. Title bumps
    // 15pt -> 16pt rowTitle to align with the rest of the row hierarchy;
    // subtitle bumps 11pt -> 12pt caption (the user's 12pt mono floor).
    titleLabel.font = UIFont.cassette(.rowTitle)
    titleLabel.textColor = CassetteTheme.UIColors.ink
    subtitleLabel.font = UIFont.cassette(.caption)
    subtitleLabel.textColor = CassetteTheme.UIColors.ink2
    contentView.backgroundColor = CassetteTheme.UIColors.bg
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
    entityImage.layer.borderColor = CassetteTheme.UIColors.ink
      .withAlphaComponent(0.08).cgColor
    setupPlayOverlayIfNeeded()
    playOverlay?.isHidden = !showsPlayOverlay
    updateArtworkImageConstraint(indexPath: initialIndexPath)
    layoutIfNeeded()
  }

  override func prepareForReuse() {
    super.prepareForReuse()
    onPlayTapped = nil
    showsPlayOverlay = false
    playOverlay?.isHidden = true
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

  /// cassette redesign (Surface 3/4): lazily install a 40pt circular Liquid
  /// Glass `play.fill` button anchored 8pt inside the artwork's bottom-right
  /// corner. The bg3 disc + manual CALayer drop shadow are retired — the
  /// overlay sits directly on artwork, which is exactly where system glass
  /// earns its keep (this overlay only shows on the Home Resume card, so it
  /// is the Resume play affordance). Idempotent — safe to call from every
  /// `apply(...)`.
  private func setupPlayOverlayIfNeeded() {
    guard playOverlay == nil else {
      playOverlay?.isHidden = !showsPlayOverlay
      return
    }
    let button = UIButton(configuration: Self.makeGlassPlayOverlayConfiguration())
    button.translatesAutoresizingMaskIntoConstraints = false
    button.accessibilityLabel = "Play"
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

  /// Shared Liquid Glass overlay-play configuration for cards (album +
  /// artist circle). Matches the footer's system-glass material.
  static func makeGlassPlayOverlayConfiguration() -> UIButton.Configuration {
    var config = UIButton.Configuration.glass()
    config.baseForegroundColor = CassetteTheme.UIColors.ink
    config.cornerStyle = .capsule
    config.image = UIImage(systemName: "play.fill")?
      .withConfiguration(UIImage.SymbolConfiguration(pointSize: 16, weight: .bold))
    return config
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
