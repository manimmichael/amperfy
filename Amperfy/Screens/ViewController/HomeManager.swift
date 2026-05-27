//
//  HomeManager.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 29.12.25.
//  Copyright (c) 2025 Maximilian Bauer. All rights reserved.
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
import CoreData
import OSLog
import UIKit

// MARK: - HomeItem

struct HomeItem: Hashable, @unchecked Sendable {
  let id = UUID()
  var playableContainable: PlayableContainable

  static func == (lhs: HomeItem, rhs: HomeItem) -> Bool {
    lhs.id == rhs.id
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(id)
  }
}

// MARK: - HomeManager

/// cassette Patch 035: rewritten to drive the three-shelf Cassette
/// home IA (Resume / Your Playlists / Recently Added). Legacy
/// random/podcast/radio carousels are no longer materialised here —
/// see `HomeSection.editableSections` for the user-visible surface.
@MainActor
class HomeManager: NSObject {
  public static let sectionMaxItemCount = 20

  public var orderedVisibleSections: [HomeSection]
  public var data: [HomeSection: [HomeItem]] = [:]
  public var applySnapshotCB: VoidFunctionCallback?

  private let account: Account
  private let storage: PersistentStorage
  private let getMeta: (_ accountInfo: AccountInfo) -> MetaManager
  private let eventLogger: EventLogger
  private let player: PlayerFacade

  var isOfflineMode: Bool {
    storage.settings.user.isOfflineMode
  }

  // Resume shelf merges these two fetch controllers' results by
  // `lastPlayedDate` desc, then optionally prepends the player's
  // currently-playing album so the first card always reflects the
  // live queue.
  private var albumsRecentFetch: AlbumFetchedResultsController?
  private var playlistsLastPlayedFetch: PlaylistFetchedResultsController?

  private var playlistsLastChangedFetch: PlaylistFetchedResultsController?
  private var albumsNewestFetch: AlbumFetchedResultsController?

  // cassette Patch 038: Artists shelf. ArtistMO.lastPlayedDate
  // isn't bumped per song-play, so we fetch the most-recently-played
  // songs and dedupe by song.artist. fetchLimit caps Core Data round-
  // trip cost; we keep it generous (100) so a heavy rotation of
  // ~10 songs each across many artists still surfaces 15 unique
  // artists.
  private static let recentArtistsSongFetchLimit = 100
  private static let recentArtistsCap = 15
  private static let recentArtistsMinUnique = 3
  private var recentArtistsSongFetch: SongsFetchedResultsController?

  init(
    account: Account,
    storage: PersistentStorage,
    getMeta: @escaping (_ accountInfo: AccountInfo) -> MetaManager,
    eventLogger: EventLogger,
    player: PlayerFacade
  ) {
    self.account = account
    self.storage = storage
    self.getMeta = getMeta
    self.eventLogger = eventLogger
    self.player = player
    // cassette Patch 035: the three shelves are fixed. Legacy
    // `accountSettings.homeSections` is left on disk untouched so a
    // future rollback or re-introduction of editable shelves can
    // still decode it, but it no longer influences what renders.
    self.orderedVisibleSections = HomeSection.defaultValue
    super.init()
    // Recompute Resume whenever playback transitions so the first
    // card reflects the live queue (or vanishes when the user stops
    // and the recency list still wants the next item).
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handlePlayerChanged),
      name: .playerPlay,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handlePlayerChanged),
      name: .playerPause,
      object: nil
    )
    NotificationCenter.default.addObserver(
      self,
      selector: #selector(handlePlayerChanged),
      name: .playerStop,
      object: nil
    )
  }

  deinit {
    NotificationCenter.default.removeObserver(self)
  }

  func createFetchController() {
    albumsRecentFetch = AlbumFetchedResultsController(
      coreDataCompanion: storage.main, account: account,
      sortType: .recent,
      isGroupedInAlphabeticSections: false,
      fetchLimit: Self.sectionMaxItemCount
    )
    albumsRecentFetch?.delegate = self
    albumsRecentFetch?.search(
      searchText: "",
      onlyCached: isOfflineMode,
      displayFilter: .recent
    )

    playlistsLastPlayedFetch = PlaylistFetchedResultsController(
      coreDataCompanion: storage.main, account: account,
      sortType: .lastPlayed,
      isGroupedInAlphabeticSections: false,
      fetchLimit: Self.sectionMaxItemCount
    )
    playlistsLastPlayedFetch?.delegate = self
    playlistsLastPlayedFetch?.search(
      searchText: "",
      playlistSearchCategory: isOfflineMode ? .cached : .all
    )

    playlistsLastChangedFetch = PlaylistFetchedResultsController(
      coreDataCompanion: storage.main, account: account,
      sortType: .lastChanged,
      isGroupedInAlphabeticSections: false,
      fetchLimit: Self.sectionMaxItemCount
    )
    playlistsLastChangedFetch?.delegate = self
    playlistsLastChangedFetch?.search(
      searchText: "",
      playlistSearchCategory: isOfflineMode ? .cached : .userOnly
    )

    albumsNewestFetch = AlbumFetchedResultsController(
      coreDataCompanion: storage.main, account: account,
      sortType: .newest,
      isGroupedInAlphabeticSections: false,
      fetchLimit: Self.sectionMaxItemCount
    )
    albumsNewestFetch?.delegate = self
    albumsNewestFetch?.search(
      searchText: "",
      onlyCached: isOfflineMode,
      displayFilter: .newest
    )

    // cassette Patch 038: feeds the Artists shelf. Reuses the
    // shared SongsFetchedResultsController so we inherit the
    // per-account / exclude-server-deleted predicates and the
    // `keepAllResultsUpdated = false` CPU-load mitigation. The
    // .lastPlayedDate sort case was added in the same patch.
    recentArtistsSongFetch = SongsFetchedResultsController(
      coreDataCompanion: storage.main,
      account: account,
      sortType: .lastPlayedDate,
      isGroupedInAlphabeticSections: false,
      fetchLimit: Self.recentArtistsSongFetchLimit
    )
    recentArtistsSongFetch?.delegate = self
    recentArtistsSongFetch?.fetch()

    updateResume()
    updateYourPlaylists()
    updateRecentlyAdded()
    updateRecentArtists()
  }

  func updateFromRemote() {
    guard storage.settings.user.isOnlineMode else { return }
    Task { @MainActor in
      do {
        try await AutoDownloadLibrarySyncer(
          storage: self.storage,
          account: self.account,
          librarySyncer: self.getMeta(self.account.info).librarySyncer,
          playableDownloadManager: self.getMeta(self.account.info)
            .playableDownloadManager
        )
        .syncNewestLibraryElements(offset: 0, count: Self.sectionMaxItemCount)
      } catch {
        // cassette Patch 040: Home tab background sync — silenced.
        self.eventLogger.report(
          topic: "Recently Added Sync",
          error: error,
          isBackground: true
        )
      }
    }
    Task { @MainActor in
      do {
        try await self.getMeta(self.account.info).librarySyncer
          .syncRecentAlbums(
            offset: 0,
            count: Self.sectionMaxItemCount
          )
      } catch {
        self.eventLogger.report(
          topic: "Resume Sync",
          error: error,
          isBackground: true
        )
      }
    }
    Task { @MainActor in
      do {
        try await self.getMeta(self.account.info).librarySyncer
          .syncDownPlaylistsWithoutSongs()
      } catch {
        self.eventLogger.report(
          topic: "Playlists Sync",
          error: error,
          isBackground: true
        )
      }
    }
  }

  // MARK: - Shelf builders

  /// Merge recent albums and recently-played playlists by
  /// `lastPlayedDate` desc, prepend the player's currently-playing
  /// album so the first card reflects the live queue, and cap.
  func updateResume() {
    var albums: [Album] = []
    if let albumMOs = albumsRecentFetch?.fetchedObjects as? [AlbumMO] {
      albums = albumMOs.prefix(Self.sectionMaxItemCount)
        .compactMap { Album(managedObject: $0) }
    }

    var playlists: [Playlist] = []
    if let playlistMOs = playlistsLastPlayedFetch?.fetchedObjects as? [PlaylistMO] {
      playlists = playlistMOs.prefix(Self.sectionMaxItemCount)
        .compactMap { Playlist(library: storage.main.library, managedObject: $0) }
    }

    var entries: [(date: Date, container: PlayableContainable, id: String)] = []
    let distantPast = Date.distantPast
    for album in albums {
      let date = album.lastTimePlayed ?? distantPast
      entries.append((date, album, "album-\(album.id)"))
    }
    for playlist in playlists {
      let date = playlist.lastTimePlayed ?? distantPast
      entries.append((date, playlist, "playlist-\(playlist.id)"))
    }
    entries.sort { $0.date > $1.date }

    var merged: [PlayableContainable] = []
    var seenIDs = Set<String>()
    for entry in entries where entry.date > distantPast {
      if seenIDs.insert(entry.id).inserted {
        merged.append(entry.container)
      }
    }

    // Prepend live queue's album if not already in the top slot.
    if let song = player.currentlyPlaying?.asSong,
       let liveAlbum = song.album {
      let liveID = "album-\(liveAlbum.id)"
      if merged.first.map({ container -> Bool in
        if let albumContainer = container as? Album {
          return "album-\(albumContainer.id)" == liveID
        }
        return false
      }) != true {
        // Drop any later occurrence so the live album only appears once.
        merged.removeAll { container in
          (container as? Album).map { "album-\($0.id)" == liveID } ?? false
        }
        merged.insert(liveAlbum, at: 0)
      }
    }

    data[.resume] = merged.prefix(Self.sectionMaxItemCount).map {
      HomeItem(playableContainable: $0)
    }
    applySnapshotCB?()
  }

  func updateYourPlaylists() {
    guard let playlistMOs = playlistsLastChangedFetch?.fetchedObjects as? [PlaylistMO] else {
      data[.yourPlaylists] = []
      applySnapshotCB?()
      return
    }
    data[.yourPlaylists] = playlistMOs.prefix(Self.sectionMaxItemCount)
      .compactMap { Playlist(library: storage.main.library, managedObject: $0) }
      .map { HomeItem(playableContainable: $0) }
    applySnapshotCB?()
  }

  func updateRecentlyAdded() {
    guard let albumMOs = albumsNewestFetch?.fetchedObjects as? [AlbumMO] else {
      data[.recentlyAdded] = []
      applySnapshotCB?()
      return
    }
    data[.recentlyAdded] = albumMOs.prefix(Self.sectionMaxItemCount)
      .compactMap { Album(managedObject: $0) }
      .map { HomeItem(playableContainable: $0) }
    applySnapshotCB?()
  }

  /// Walk the most-recently-played songs in order and dedupe by
  /// artist. If fewer than `recentArtistsMinUnique` distinct artists
  /// have play history, surface an empty list — HomeVC's
  /// applySnapshot filter then hides the whole shelf.
  func updateRecentArtists() {
    guard let songMOs = recentArtistsSongFetch?.fetchedObjects as? [SongMO] else {
      data[.recentlyPlayedArtists] = []
      applySnapshotCB?()
      return
    }
    var seenArtistIDs = Set<String>()
    var orderedArtists: [Artist] = []
    for songMO in songMOs {
      let song = Song(managedObject: songMO)
      guard song.lastTimePlayed != nil, let artist = song.artist else { continue }
      if seenArtistIDs.insert(artist.id).inserted {
        orderedArtists.append(artist)
        if orderedArtists.count >= Self.recentArtistsCap { break }
      }
    }
    if orderedArtists.count < Self.recentArtistsMinUnique {
      data[.recentlyPlayedArtists] = []
    } else {
      data[.recentlyPlayedArtists] = orderedArtists.map {
        HomeItem(playableContainable: $0)
      }
    }
    applySnapshotCB?()
  }

  // MARK: - Player observer

  @objc
  private func handlePlayerChanged() {
    Task { @MainActor in
      updateResume()
      // cassette Patch 038: lastPlayedDate updates land on the SongMO
      // before our fetched results controller fires its delegate, so
      // recompute the Artists shelf here too — keeps the recency
      // ordering live as the user advances through tracks.
      updateRecentArtists()
    }
  }
}

extension HomeManager: @preconcurrency NSFetchedResultsControllerDelegate {
  func controllerDidChangeContent(_ controller: NSFetchedResultsController<NSFetchRequestResult>) {
    // fetch controllers are created on Main thread -> Runtime Error if this function call is not on Main thread
    MainActor.assumeIsolated {
      if controller == albumsRecentFetch?.fetchResultsController
        || controller == playlistsLastPlayedFetch?.fetchResultsController {
        updateResume()
      } else if controller == playlistsLastChangedFetch?.fetchResultsController {
        updateYourPlaylists()
      } else if controller == albumsNewestFetch?.fetchResultsController {
        updateRecentlyAdded()
      } else if controller == recentArtistsSongFetch?.fetchResultsController {
        updateRecentArtists()
      }
    }
  }
}
