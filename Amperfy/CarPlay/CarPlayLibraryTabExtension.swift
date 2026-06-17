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

extension LibraryDisplayType {
  fileprivate var isVisibleInCarPlay: Bool {
    switch self {
    case .albums, .artists, .favoriteAlbums, .favoriteArtists, .favoriteSongs, .genres,
         .newestAlbums,
         .podcasts,
         .radios, .recentAlbums:
      return true
    case .directories, .downloads, .songs:
      return false
    case .playlists:
      return false // playlists have their own tab
    }
  }
}

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

  /// D5: mirror the mobile Library — a clean category LIST (one tappable row
  /// per category, in the user's configured order from
  /// `libraryDisplaySettings.inUse`) instead of the horizontal type-chooser
  /// carousel with the folder-ish icons. Each row pushes the matching section
  /// template; browse reads from local FRC data, so it never hangs when the
  /// server is unreachable. Categories are filtered to `isVisibleInCarPlay`
  /// (Songs/Directories/Downloads hidden; Playlists has its own tab).
  func createLibraryNavigationTypeSection() -> CPListSection {
    var items = [CPListTemplateItem]()
    for type in appDelegate.storage.settings.accounts.getSetting(activeAccountInfo).read
      .libraryDisplaySettings.inUse {
      guard type.isVisibleInCarPlay, let section = librarySection(for: type) else { continue }
      items.append(createLibraryItem(
        text: type.displayName,
        icon: type.image,
        sectionToDisplay: section
      ))
    }
    return CPListSection(items: items, header: "Library", sectionIndexTitle: nil)
  }

  /// Maps a Library category to its CarPlay browse template.
  private func librarySection(for type: LibraryDisplayType) -> CPListTemplate? {
    switch type {
    case .genres: return genresSection
    case .artists: return artistsSection
    case .albums: return albumsSection
    case .podcasts: return podcastSection
    case .favoriteSongs: return songsFavoriteSection
    case .favoriteAlbums: return albumsFavoriteSection
    case .favoriteArtists: return artistsFavoriteSection
    case .newestAlbums: return albumsNewestSection
    case .recentAlbums: return albumsRecentSection
    case .radios: return radioSection
    case .directories, .downloads, .playlists, .songs: return nil
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
    if appDelegate.player.podcastItemCount > 0 {
      let item = CPListImageRowItemRowElement(
        image: UIImage.createArtwork(
          with: UIImage.podcast,
          iconSizeType: .small,
          theme: getPreference(activeAccountInfo).theme,
          lightDarkMode: traits.userInterfaceStyle.asModeType,
          switchColors: true
        ).carPlayImage(carTraitCollection: traits),
        title: Self.continuePlaybackPodcastTitle, subtitle: nil
      )
      quickActionItems.append(item)
    }
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
