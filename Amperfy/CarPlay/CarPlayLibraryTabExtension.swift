//
//  CarPlayLibraryTabExtension.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 02.01.26.
//  Copyright (c) 2026 Maximilian Bauer. All rights reserved.
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
import CarPlay
import CoreData
import Foundation

// Cassette CarPlay trim: the in-car Library is a fixed, driving-safe set —
// exactly Albums, Artists, Playlists and Favorite Songs (see
// `carPlayLibraryRows`). Home shelves (Newest / Recently Played Albums), flat
// Songs, Directories, Podcasts and Radios are intentionally dropped to keep the
// category list short and glanceable, so there is no longer a per-type
// visibility predicate here — `carPlayLibraryRows` is the single source of
// truth for what the Library shows.

extension CarPlaySceneDelegate {
  static let switchAccountTitle = "Switch Account"
  static let continuePlaybackMusicTitle = "Continue Music"
  static let continuePlaybackPodcastTitle = "Continue Podcasts"
  static let playRandomAlbumsTitle = "Albums"
  static let playRandomSongsTitle = "Songs"

  func createLibrarySections() -> [CPListSection] {
    let librarySections = [
      createQuickActionsSection(),
      createPlayRandomSection(),
      createLibraryNavigationTypeSection(),
    ].compactMap { $0 }

    return librarySections
  }

  func createLibraryTypeImageRowElement(type: LibraryDisplayType) -> CPListImageRowItemRowElement {
    let baseImage = type.image
    let element = CPListImageRowItemRowElement(
      image: UIImage.createArtwork(
        with: baseImage,
        iconSizeType: .small,
        theme: getPreference(activeAccountInfo).theme,
        lightDarkMode: traits.userInterfaceStyle.asModeType,
        switchColors: true
      ).carPlayImage(carTraitCollection: traits),
      title: type.displayName, subtitle: nil
    )
    return element
  }

  /// Cassette CarPlay trim: a fixed, driving-safe Library — exactly Albums,
  /// Artists and Playlists, in that order. We deliberately ignore the user's
  /// full mobile `libraryDisplaySettings` order here: the in-car list must stay
  /// short and predictable (category -> list -> play), so Home shelves (Newest
  /// / Recently Played Albums), flat Songs, Directories, Podcasts and Radios are
  /// not offered. Each row pushes a local FRC-backed browse template, so it
  /// never hangs when the server is unreachable.
  /// cassette (favorites rip-out): Favorite Songs removed from the in-car list.
  static let carPlayLibraryRows: [LibraryDisplayType] = [
    .albums,
    .artists,
    .playlists,
  ]

  func createLibraryNavigationTypeSection() -> CPListSection {
    var items = [CPListTemplateItem]()
    for type in Self.carPlayLibraryRows {
      if type == .playlists {
        // Playlists already exists as a top-level tab whose template instance
        // lives in the tab bar; pushing that same instance onto the Library
        // nav stack would duplicate it in the hierarchy (CarPlay throws). So
        // the Playlists *row* pushes a fresh, FRC-backed list instead.
        items.append(createPlaylistsLibraryRow())
        continue
      }
      guard let section = librarySection(for: type) else { continue }
      items.append(createLibraryItem(
        text: type.displayName,
        icon: type.image,
        sectionToDisplay: section
      ))
    }
    return CPListSection(items: items, header: "Library", sectionIndexTitle: nil)
  }

  /// A Library row that opens the Playlists browse on a fresh `CPListTemplate`
  /// (see `createLibraryNavigationTypeSection` for why we don't reuse the tab
  /// instance). Mirrors the playlist tab's appear behavior: ensure the fetch
  /// controller exists, then populate from local data.
  private func createPlaylistsLibraryRow() -> CPListItem {
    let item = CPListItem(
      text: LibraryDisplayType.playlists.displayName,
      detailText: nil,
      image: UIImage
        .createArtwork(
          with: LibraryDisplayType.playlists.image,
          iconSizeType: .small,
          theme: getPreference(activeAccountInfo).theme,
          lightDarkMode: traits.userInterfaceStyle.asModeType,
          switchColors: true
        )
        .carPlayImage(carTraitCollection: traits),
      accessoryImage: nil,
      accessoryType: .disclosureIndicator
    )
    item.handler = { [weak self] _, completion in
      guard let self = self else { completion(); return }
      Task { @MainActor in
        if self.playlistFetchController == nil { self.createPlaylistFetchController() }
        let template = CPListTemplate(
          title: LibraryDisplayType.playlists.displayName,
          sections: self.createPlaylistsSections()
        )
        self.playlistDetailSection = nil
        self.pushTemplateIfAllowed(template, animated: true)
        completion()
      }
    }
    return item
  }

  /// Maps a Library category to its CarPlay browse template. Only the
  /// driving-safe categories in `carPlayLibraryRows` resolve to a template
  /// here; Playlists is handled separately (see `createPlaylistsLibraryRow`),
  /// and everything else returns nil and is skipped.
  private func librarySection(for type: LibraryDisplayType) -> CPListTemplate? {
    switch type {
    case .albums: return albumsSection
    case .artists: return artistsSection
    // cassette (favorites rip-out): .favoriteSongs now falls through to nil.
    case .directories, .downloads, .favoriteSongs, .favoriteAlbums, .favoriteArtists, .genres,
         .newestAlbums, .playlists, .podcasts, .radios, .recentAlbums, .songs:
      return nil
    }
  }

  func createPlayRandomSection() -> CPListSection {
    var playRandomItems = [CPListImageRowItemRowElement]()
    let playRandomAlbumsItem = CPListImageRowItemRowElement(
      image: UIImage.createArtwork(
        with: UIImage.album,
        iconSizeType: .small,
        theme: getPreference(activeAccountInfo).theme,
        lightDarkMode: traits.userInterfaceStyle.asModeType,
        switchColors: true
      ).carPlayImage(carTraitCollection: traits),
      title: Self.playRandomAlbumsTitle, subtitle: nil
    )
    playRandomItems.append(playRandomAlbumsItem)
    let playRandomSongsItem = CPListImageRowItemRowElement(
      image: UIImage.createArtwork(
        with: UIImage.musicalNotes,
        iconSizeType: .small,
        theme: getPreference(activeAccountInfo).theme,
        lightDarkMode: traits.userInterfaceStyle.asModeType,
        switchColors: true
      ).carPlayImage(carTraitCollection: traits),
      title: Self.playRandomSongsTitle, subtitle: nil
    )
    playRandomItems.append(playRandomSongsItem)

    let playRandomRow = CPListImageRowItem(
      text: nil,
      elements: playRandomItems,
      allowsMultipleLines: false
    )
    playRandomRow.handler = { selectedRow, completion in completion() }
    playRandomRow.listImageRowHandler = { [weak self] item, index, completion in
      guard let self else { completion(); return }

      Task { @MainActor in
        if playRandomItems[index].title == Self.playRandomAlbumsTitle {
          triggerPlayRandomAlbums(onlyCached: false)
        }
        if playRandomItems[index].title == Self.playRandomSongsTitle {
          triggerPlayRandomSongsItem(onlyCached: false)
        }
      }
      completion()
    }
    let playRandomSection = CPListSection(
      items: [playRandomRow],
      header: "Play Random",
      sectionIndexTitle: nil
    )
    return playRandomSection
  }

  func createQuickActionsSection() -> CPListSection? {
    var quickActionItems = [CPListImageRowItemRowElement]()
    if appDelegate.player.musicItemCount > 0 {
      let item = CPListImageRowItemRowElement(
        image: UIImage.createArtwork(
          with: UIImage.musicalNotes,
          iconSizeType: .small,
          theme: getPreference(activeAccountInfo).theme,
          lightDarkMode: traits.userInterfaceStyle.asModeType,
          switchColors: true
        ).carPlayImage(carTraitCollection: traits),
        title: Self.continuePlaybackMusicTitle, subtitle: nil
      )
      quickActionItems.append(item)
    }
    // cassette: "Continue Podcasts" quick action removed — podcasts are hidden
    // as a browse/quick-action surface in-car (the Podcasts library row is also
    // gone). Podcast *playback* itself is untouched; the shared handler below
    // still tolerates the podcast title (now unreachable) via continuePlaybackPodcastTitle.
    if appDelegate.storage.settings.accounts.allAccounts.count > 1 {
      let switchAccountItem = CPListImageRowItemRowElement(
        image: UIImage.createArtwork(
          with: UIImage.userPerson,
          iconSizeType: .small,
          theme: getPreference(activeAccountInfo).theme,
          lightDarkMode: traits.userInterfaceStyle.asModeType,
          switchColors: true
        ).carPlayImage(carTraitCollection: traits),
        title: Self.switchAccountTitle, subtitle: nil
      )
      quickActionItems.append(switchAccountItem)
    }

    guard !quickActionItems.isEmpty else { return nil }

    let quickActionsRow = CPListImageRowItem(
      text: nil,
      elements: quickActionItems,
      allowsMultipleLines: false
    )
    quickActionsRow.handler = { selectedRow, completion in completion() }
    quickActionsRow.listImageRowHandler = { [weak self] item, index, completion in
      guard let self else { completion(); return }

      Task { @MainActor in
        if quickActionItems[index].title == Self.switchAccountTitle {
          self.pushTemplateIfAllowed(accountSection, animated: true)
        }
        if quickActionItems[index].title == Self.continuePlaybackMusicTitle ||
          quickActionItems[index].title == Self.continuePlaybackPodcastTitle {
          if quickActionItems[index].title == Self.continuePlaybackMusicTitle,
             appDelegate.player.playerMode != .music {
            appDelegate.player.setPlayerMode(.music)
          } else if quickActionItems[index].title == Self.continuePlaybackPodcastTitle,
                    appDelegate.player.playerMode != .podcast {
            appDelegate.player.setPlayerMode(.podcast)
          }
          appDelegate.player.play()
          displayNowPlaying {}
        }
      }

      completion()
    }
    let quickActionsSection = CPListSection(
      items: [quickActionsRow],
      header: "Quick Actions",
      sectionIndexTitle: nil
    )
    return quickActionsSection
  }

  func createAccountsSections() -> [CPListSection] {
    let accountInfos = appDelegate.storage.settings.accounts.allAccounts
    var items: [CPListItem] = []
    for accountInfo in accountInfos {
      let name = appDelegate.storage.settings.accounts.getSetting(accountInfo).read
        .loginCredentials?.username ?? ""
      let displayServerUrl = appDelegate.storage.settings.accounts.getSetting(accountInfo).read
        .loginCredentials?.displayServerUrl ?? ""
      let isActive = (accountInfo == activeAccountInfo)
      let item = CPListItem(
        text: name,
        detailText: displayServerUrl,
        image: UIImage.createArtwork(
          with: isActive ? UIImage.userCircleCheckmark : UIImage.userCircle(),
          iconSizeType: .big,
          theme: getPreference(accountInfo).theme,
          lightDarkMode: traits.userInterfaceStyle.asModeType,
          switchColors: true
        ).carPlayImage(carTraitCollection: traits),
        accessoryImage: nil,
        accessoryType: isActive ? .none : .disclosureIndicator
      )
      item.handler = { [weak self] _, completion in
        guard let self = self,
              appDelegate.storage.settings.accounts.active != accountInfo
        else { completion(); return }
        appDelegate.switchAccount(accountInfo: accountInfo)
        accountSection.updateSections(createAccountsSections())
        completion()
      }
      items.append(item)
    }
    return [CPListSection(items: items)]
  }
}
