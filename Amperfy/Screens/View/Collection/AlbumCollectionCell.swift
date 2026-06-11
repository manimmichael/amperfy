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

  private func apply(
    container: PlayableContainable,
    rootView: UICollectionViewController,
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
    entityImage.display(
      theme: appDelegate.storage.settings.accounts.getSetting(container.account?.info).read
        .themePreference,
      container: container,
      cornerRadius: .big
    )
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
    }
    super.layoutSubviews()
  }

  /// cassette Patch 043: lazily install a 40pt circular orange
  /// `play.fill` button anchored 8pt inside the artwork's bottom-
  /// right corner. Idempotent — safe to call from every `apply(...)`.
  private func setupPlayOverlayIfNeeded() {
    guard playOverlay == nil else {
      playOverlay?.isHidden = !showsPlayOverlay
      return
    }
    // cassette Patch 051 (Phase F): play overlay drops the orange fill in
    // favor of a bg3 disc with an ink glyph. Shadow + capsule shape carry
    // the "tap to play" affordance; orange is reserved for the scrubber +
    // waveform exceptions. If the bg3 disc lacks contrast on bright
    // artwork during device review, swap to ink4 here or add a 1pt ink4
    // border (no geometry change needed).
    var config = UIButton.Configuration.filled()
    config.baseBackgroundColor = CassetteTheme.UIColors.bg3
    config.baseForegroundColor = CassetteTheme.UIColors.ink
    config.cornerStyle = .capsule
    config.image = UIImage(systemName: "play.fill")?
      .withConfiguration(UIImage.SymbolConfiguration(pointSize: 16, weight: .bold))
    config.contentInsets = NSDirectionalEdgeInsets(
      top: 0, leading: 0, bottom: 0, trailing: 0
    )
    let button = UIButton(configuration: config)
    button.translatesAutoresizingMaskIntoConstraints = false
    button.accessibilityLabel = "Play"
    button.layer.shadowColor = UIColor.black.cgColor
    button.layer.shadowOpacity = 0.25
    button.layer.shadowRadius = 4
    button.layer.shadowOffset = CGSize(width: 0, height: 2)
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

  func updateArtworkImageConstraint(indexPath: IndexPath) {
    guard let rootView else { return }
    if let rootFlowLayout = rootFlowLayout,
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
