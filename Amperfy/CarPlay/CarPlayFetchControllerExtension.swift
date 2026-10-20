//
//  CarPlayFetchControllerExtension.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 31.01.24.
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
import CarPlay
import CoreData
import Foundation

extension CarPlaySceneDelegate {
  func createPlaylistFetchController() {
    let sortType = appDelegate.storage.settings.user.playlistsSortSetting
    playlistFetchController = PlaylistFetchedResultsController(
      coreDataCompanion: appDelegate.storage.main, account: activeAccount,
      sortType: sortType,
      isGroupedInAlphabeticSections: sortType.asSectionIndexType == .alphabet
    )
    playlistFetchController?.delegate = self
    if isOfflineMode {
      playlistFetchController?.search(searchText: "", playlistSearchCategory: .cached)
    } else {
      playlistFetchController?.fetch()
    }
  }

  func createArtistsFetchController() {
    artistsFetchController = ArtistFetchedResultsController(
      coreDataCompanion: appDelegate.storage.main, account: activeAccount,
      sortType: .name,
      isGroupedInAlphabeticSections: true
    )
    artistsFetchController?.delegate = self
    artistsFetchController?.search(
      searchText: "",
      onlyCached: isOfflineMode,
      displayFilter: appDelegate.storage.settings.user.artistsFilterSetting
    )
  }

  func createAlbumsFetchController() {
    albumsFetchController = AlbumFetchedResultsController(
      coreDataCompanion: appDelegate.storage.main, account: activeAccount,
      sortType: .name,
      isGroupedInAlphabeticSections: true
    )
    albumsFetchController?.delegate = self
    albumsFetchController?.search(
      searchText: "",
      onlyCached: isOfflineMode,
      displayFilter: .all
    )
  }

  func createPlaylistDetailFetchController(playlist: Playlist) {
    playlistDetailFetchController = PlaylistItemsFetchedResultsController(
      forPlaylist: playlist,
      coreDataCompanion: appDelegate.storage.main,
      isGroupedInAlphabeticSections: false
    )
    playlistDetailFetchController?.delegate = self
    playlistDetailFetchController?.search(onlyCachedSongs: isOfflineMode)
  }
}
