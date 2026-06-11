//
//  PopupPlayer+Visuals.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 11.02.24.
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
import UIKit

extension PopupPlayerVC {
  func refresh() {
    refreshContextQueueSectionHeader()
    refreshUserQueueSectionHeader()
    refreshCellMasks()
    refreshCellsContent()
    refreshCurrentlyPlayingInfoView()
  }

  func refreshCurrentlyPlayingInfoView() {
    refreshBackgroundItemArtwork()
    largeCurrentlyPlayingView?.refresh()
    for visibleCell in tableView.visibleCells {
      if let currentlyPlayingCell = visibleCell as? CurrentlyPlayingTableCell {
        currentlyPlayingCell.refresh()
        break
      }
    }
  }

  func refreshCurrentlyPlayingArtworks() {
    refreshBackgroundItemArtwork()
    largeCurrentlyPlayingView?.refreshArtwork()
    for visibleCell in tableView.visibleCells {
      if let currentlyPlayingCell = visibleCell as? CurrentlyPlayingTableCell {
        currentlyPlayingCell.refreshArtwork()
        break
      }
    }
  }

  func refreshOptionButton(button: UIButton, rootView: UIViewController?) {
    // cassette polish Part 5: per-track overflow sits plain against the player
    // background (no bg2 circular tile). 22pt ellipsis in ink; 44pt hit target
    // preserved via symmetric content insets around the ~22pt glyph.
    var config = UIButton.Configuration.plain()
    config.image = .ellipsis
    config.baseForegroundColor = CassetteTheme.UIColors.ink
    config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
      pointSize: 22,
      weight: .regular
    )
    config.contentInsets = NSDirectionalEdgeInsets(top: 11, leading: 11, bottom: 11, trailing: 11)
    button.isEnabled = true
    button.configuration = config

    if let currentlyPlaying = appDelegate.player.currentlyPlaying,
       let rootView = rootView {
      button.showsMenuAsPrimaryAction = true
      button.menu = UIMenu.lazyMenu {
        EntityPreviewActionBuilder(container: currentlyPlaying, on: rootView).createMenuActions()
      }
      button.isEnabled = true
    } else {
      button.isEnabled = false
    }
  }

  func refreshFavoriteButton(button: UIButton) {
    // cassette polish Part 5: heart sits plain against the player background
    // (no bg2 circular tile). 22pt symbol in ink, filled when favorited and
    // outlined when not; 44pt hit target via symmetric content insets.
    var config = UIButton.Configuration.plain()
    config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(
      pointSize: 22,
      weight: .regular
    )
    config.contentInsets = NSDirectionalEdgeInsets(top: 11, leading: 11, bottom: 11, trailing: 11)
    switch player.playerMode {
    case .music:
      if let playableInfo = player.currentlyPlaying,
         playableInfo.isSong {
        config.image = playableInfo.isFavorite ? .heartFill : .heartEmpty
        // cassette redesign (Surface 5): the favorited heart is one of the
        // three sanctioned orange live-state surfaces (scrubber fill,
        // playing indicator, active heart). Unfavorited stays quiet ink
        // alongside its row siblings.
        config.baseForegroundColor = playableInfo.isFavorite
          ? CassetteTheme.UIColors.orange
          : CassetteTheme.UIColors.ink
        button.isEnabled = appDelegate.storage.settings.user.isOnlineMode
      } else if let playableInfo = player.currentlyPlaying,
                let radio = playableInfo.asRadio {
        config.image = .followLink
        config.baseForegroundColor = CassetteTheme.UIColors.ink
        button.isEnabled = radio.siteURL != nil
      } else {
        config.image = .heartEmpty
        config.baseForegroundColor = CassetteTheme.UIColors.ink
        button.isEnabled = false
      }
    case .podcast:
      config.image = .info
      config.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(scale: .large)
      config.baseForegroundColor = CassetteTheme.UIColors.ink
      button.isEnabled = true
    }
    if #available(iOS 17.0, *) {
      button.isSymbolAnimationEnabled = true
    }
    button.configuration = config
  }

  /// cassette Patch 029: the popup-player background is now a flat
  /// `bg4` surface set on the host view in `PopupPlayerVC.viewDidLoad`.
  /// The blurred album-art layer + `DominantColors`-driven gradient
  /// (Patches 022/024) produced a persistently blue backdrop that
  /// clashed with the orange controls; the audit calls for stripping
  /// the album-art layer entirely. This method is intentionally a
  /// no-op so the existing `refreshCurrentlyPlayingArtworks` /
  /// `downloadFinishedSuccessful` call sites stay valid without
  /// repopulating the backdrop.
  func refreshBackgroundItemArtwork() {
    backgroundImage.image = nil
    backgroundImage.layer.sublayers?
      .filter { $0 is CAGradientLayer }
      .forEach { $0.removeFromSuperlayer() }
  }

  /// cassette Patch 029: the host view paints a flat `bg4` backdrop in
  /// `PopupPlayerVC.viewDidLoad`. Patch 024's gradient layer is gone, so
  /// this method only needs to clear any stale gradient sublayers that
  /// might have been installed before the migration.
  func applyGradientBackground() {
    view.backgroundColor = CassetteTheme.UIColors.bg4
    view.layer.sublayers?
      .filter { $0 is CAGradientLayer }
      .forEach { $0.removeFromSuperlayer() }
  }

  @objc
  internal func downloadFinishedSuccessful(notification: Notification) {
    guard let downloadNotification = DownloadNotification.fromNotification(notification),
          let curPlayable = player.currentlyPlaying
    else { return }
    if curPlayable.uniqueID == downloadNotification.id {
      Task { @MainActor in
        refreshBackgroundItemArtwork()
      }
    }
    if let artwork = curPlayable.artwork,
       artwork.uniqueID == downloadNotification.id {
      Task { @MainActor in
        refreshBackgroundItemArtwork()
      }
    }
  }

  func adjustLayoutMargins() {
    view.layoutMargins = UIEdgeInsets(top: 0.0, left: 0.0, bottom: 0.0, right: 0.0)
  }
}
