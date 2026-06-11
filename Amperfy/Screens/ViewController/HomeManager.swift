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

/// cassette Patch 042: identity is now a stable composite key
/// (`album-<id>`, `playlist-<id>`, `artist-<id>`, …) so diffable
/// snapshot updates animate correctly across rebuilds and so the
/// Recent shelf can dedupe items out of the lower shelves with a
/// simple `Set<String>` lookup.
struct HomeItem: Hashable, @unchecked Sendable {
  let stableID: String
  var playableContainable: PlayableContainable

  static func == (lhs: HomeItem, rhs: HomeItem) -> Bool {
    lhs.stableID == rhs.stableID
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(stableID)
  }
}

// MARK: - HomeManager

/// cassette Patch 042: drives the four-shelf Cassette home IA
/// (Recent / Playlists / Albums / Artists). The Recent shelf merges
/// recently-played albums, playlists, and artists (folding in newest
/// albums when the library has no play history yet) sorted by
/// interaction date desc; the lower three shelves filter out anything
/// already surfaced in Recent so the user never sees the same item
/// twice on Home.
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

  // Recent shelf merges these fetch controllers' results by
  // interaction date desc, then optionally prepends the player's
  // currently-playing album so the first card always reflects the
  // live queue.
  private var albumsRecentFetch: AlbumFetchedResultsController?
  private var playlistsLastPlayedFetch: PlaylistFetchedResultsController?
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
    // cassette Patch 042: four-shelf IA is fixed. Legacy
    // `accountSettings.homeSections` is left on disk untouched so a
    // future rollback or re-introduction of editable shelves can
    // still decode it, but it no longer influences what renders.
    self.orderedVisibleSections = HomeSection.defaultValue
    super.init()
    // Recompute Recent whenever playback transitions so the first
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

    // cassette Patch 038: feeds the Artists shelf and the artist
    // entries inside the Recent shelf. Reuses the shared
    // SongsFetchedResultsController so we inherit the per-account /
    // exclude-server-deleted predicates and the
    // `keepAllResultsUpdated = false` CPU-load mitigation.
    recentArtistsSongFetch = SongsFetchedResultsController(
      coreDataCompanion: storage.main,
      account: account,
      sortType: .lastPlayedDate,
      isGroupedInAlphabeticSections: false,
      fetchLimit: Self.recentArtistsSongFetchLimit
    )
    recentArtistsSongFetch?.delegate = self
    recentArtistsSongFetch?.fetch()

    recomputeAllShelves()
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
          topic: "Recent Sync",
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

  /// cassette Patch 042: stable composite key per container so
  /// diffable snapshots animate predictably and so cross-shelf
  /// dedupe is a single `Set<String>` membership check. Falls back
  /// to `ObjectIdentifier` for any container type we haven't
  /// special-cased; never needs to fire today since every Home cell
  /// is a recognized library entity.
  static func stableID(for container: PlayableContainable) -> String {
    if let album = container as? Album { return "album-\(album.id)" }
    if let playlist = container as? Playlist { return "playlist-\(playlist.id)" }
    if let artist = container as? Artist { return "artist-\(artist.id)" }
    if let podcast = container as? Podcast { return "podcast-\(podcast.id)" }
    if let episode = container as? PodcastEpisode { return "podcastEpisode-\(episode.id)" }
    if let radio = container as? Radio { return "radio-\(radio.id)" }
    if let genre = container as? Genre { return "genre-\(genre.id)" }
    return "obj-\(ObjectIdentifier(container as AnyObject).hashValue)"
  }

  /// Drive every shelf in dependency order: Recent first (it sets
  /// the dedupe baseline), then the three lower shelves which
  /// filter against `data[.recent]`.
  private func recomputeAllShelves() {
    updateRecent()
    updatePlaylists()
    updateAlbums()
    updateRecentArtists()
  }

  /// `Set<String>` of stable IDs already surfaced in Resume + Recent —
  /// used by the lower shelves to skip duplicates (and to keep diffable
  /// item identifiers unique across the whole snapshot).
  private var recentStableIDs: Set<String> {
    Set((data[.resume] ?? []).map { $0.stableID })
      .union((data[.recent] ?? []).map { $0.stableID })
  }

  /// Heterogeneous merge: recently-played albums + playlists +
  /// recently-played-artists (deduped from the song fetch). Folds
  /// in newest albums when nothing has been played yet so a brand-
  /// new library still shows fresh content. Prepends the live
  /// queue's source album.
  func updateRecent() {
    let distantPast = Date.distantPast
    var entries: [(date: Date, container: PlayableContainable, id: String)] = []

    if let albumMOs = albumsRecentFetch?.fetchedObjects as? [AlbumMO] {
      for mo in albumMOs.prefix(Self.sectionMaxItemCount) {
        let album = Album(managedObject: mo)
        let date = album.lastTimePlayed ?? distantPast
        entries.append((date, album, Self.stableID(for: album)))
      }
    }

    if let playlistMOs = playlistsLastPlayedFetch?.fetchedObjects as? [PlaylistMO] {
      for mo in playlistMOs.prefix(Self.sectionMaxItemCount) {
        let playlist = Playlist(library: storage.main.library, managedObject: mo)
        let date = playlist.lastTimePlayed ?? distantPast
        entries.append((date, playlist, Self.stableID(for: playlist)))
      }
    }

    if let songMOs = recentArtistsSongFetch?.fetchedObjects as? [SongMO] {
      var seenArtistIDs = Set<String>()
      for mo in songMOs {
        let song = Song(managedObject: mo)
        guard let artist = song.artist, let date = song.lastTimePlayed else { continue }
        if seenArtistIDs.insert(artist.id).inserted {
          entries.append((date, artist, Self.stableID(for: artist)))
        }
      }
    }

    entries.sort { $0.date > $1.date }

    var merged: [PlayableContainable] = []
    var seenIDs = Set<String>()
    for entry in entries where entry.date > distantPast {
      if seenIDs.insert(entry.id).inserted {
        merged.append(entry.container)
      }
    }

    // First-run fallback: if nothing has been played yet, fold in
    // newest albums so the shelf isn't empty on a freshly synced
    // library.
    if merged.isEmpty, let albumMOs = albumsNewestFetch?.fetchedObjects as? [AlbumMO] {
      for mo in albumMOs.prefix(Self.sectionMaxItemCount) {
        let album = Album(managedObject: mo)
        let id = Self.stableID(for: album)
        if seenIDs.insert(id).inserted {
          merged.append(album)
        }
      }
    }

    // Prepend live queue's source album if present and not already
    // in the top slot. Drop any later occurrence so the live album
    // only appears once.
    var hasLiveAlbum = false
    if let song = player.currentlyPlaying?.asSong, let liveAlbum = song.album {
      hasLiveAlbum = true
      let liveID = Self.stableID(for: liveAlbum)
      let isAlreadyTop = merged.first.map { Self.stableID(for: $0) == liveID } ?? false
      if !isAlreadyTop {
        merged.removeAll { Self.stableID(for: $0) == liveID }
        merged.insert(liveAlbum, at: 0)
      }
    }

    // cassette redesign (Surface 4): the head of the merged recency list
    // becomes the Resume card (live queue first, otherwise the most
    // recently played container) and drops out of the Recent shelf. On a
    // fresh library with no play history (first-run fallback only) there
    // is nothing to resume, so the card hides.
    let hasPlayHistory = hasLiveAlbum || entries.contains { $0.date > distantPast }
    if hasPlayHistory, let resumeContainer = merged.first {
      data[.resume] = [HomeItem(
        stableID: Self.stableID(for: resumeContainer),
        playableContainable: resumeContainer
      )]
      merged.removeFirst()
    } else {
      data[.resume] = []
    }

    data[.recent] = merged.prefix(Self.sectionMaxItemCount).map {
      HomeItem(stableID: Self.stableID(for: $0), playableContainable: $0)
    }
    applySnapshotCB?()
  }

  /// Recently-played playlists, with anything already in Recent
  /// filtered out.
  func updatePlaylists() {
    guard let playlistMOs = playlistsLastPlayedFetch?.fetchedObjects as? [PlaylistMO] else {
      data[.yourPlaylists] = []
      applySnapshotCB?()
      return
    }
    let recentSet = recentStableIDs
    let playlists = playlistMOs.prefix(Self.sectionMaxItemCount * 2)
      .compactMap { Playlist(library: storage.main.library, managedObject: $0) }
    data[.yourPlaylists] = playlists
      .filter { !recentSet.contains(Self.stableID(for: $0)) }
      .prefix(Self.sectionMaxItemCount)
      .map { HomeItem(stableID: Self.stableID(for: $0), playableContainable: $0) }
    applySnapshotCB?()
  }

  /// Recently-active albums: union of recently-played and recently-
  /// added, weighted toward playing. Albums with a real
  /// `lastTimePlayed` come first sorted by date desc; never-played
  /// albums fill the remainder ordered newest-first. Filters out
  /// anything already in Recent.
  func updateAlbums() {
    let distantPast = Date.distantPast
    var albumByID: [String: Album] = [:]
    var playedDateByID: [String: Date] = [:]
    var newestIdxByID: [String: Int] = [:]

    if let recentMOs = albumsRecentFetch?.fetchedObjects as? [AlbumMO] {
      for mo in recentMOs.prefix(Self.sectionMaxItemCount) {
        let album = Album(managedObject: mo)
        let id = Self.stableID(for: album)
        albumByID[id] = album
        playedDateByID[id] = album.lastTimePlayed ?? distantPast
      }
    }

    if let newestMOs = albumsNewestFetch?.fetchedObjects as? [AlbumMO] {
      for (idx, mo) in newestMOs.prefix(Self.sectionMaxItemCount).enumerated() {
        let album = Album(managedObject: mo)
        let id = Self.stableID(for: album)
        if albumByID[id] == nil { albumByID[id] = album }
        newestIdxByID[id] = idx
        if playedDateByID[id] == nil {
          playedDateByID[id] = album.lastTimePlayed ?? distantPast
        }
      }
    }

    let sortedIDs = albumByID.keys.sorted { lhs, rhs in
      let lDate = playedDateByID[lhs] ?? distantPast
      let rDate = playedDateByID[rhs] ?? distantPast
      let lPlayed = lDate > distantPast
      let rPlayed = rDate > distantPast
      if lPlayed != rPlayed { return lPlayed }
      if lPlayed { return lDate > rDate }
      return (newestIdxByID[lhs] ?? .max) < (newestIdxByID[rhs] ?? .max)
    }

    let recentSet = recentStableIDs
    data[.recentlyAdded] = sortedIDs
      .filter { !recentSet.contains($0) }
      .prefix(Self.sectionMaxItemCount)
      .compactMap { id -> HomeItem? in
        guard let album = albumByID[id] else { return nil }
        return HomeItem(stableID: id, playableContainable: album)
      }
    applySnapshotCB?()
  }

  /// Walk the most-recently-played songs in order and dedupe by
  /// artist. Filters out artists already surfaced in Recent. If
  /// fewer than `recentArtistsMinUnique` distinct artists have play
  /// history, surface an empty list — HomeVC's applySnapshot filter
  /// then hides the whole shelf.
  func updateRecentArtists() {
    guard let songMOs = recentArtistsSongFetch?.fetchedObjects as? [SongMO] else {
      data[.recentlyPlayedArtists] = []
      applySnapshotCB?()
      return
    }
    let recentSet = recentStableIDs
    var seenArtistIDs = Set<String>()
    var orderedArtists: [Artist] = []
    for songMO in songMOs {
      let song = Song(managedObject: songMO)
      guard song.lastTimePlayed != nil, let artist = song.artist else { continue }
      let id = Self.stableID(for: artist)
      guard !recentSet.contains(id) else { continue }
      if seenArtistIDs.insert(artist.id).inserted {
        orderedArtists.append(artist)
        if orderedArtists.count >= Self.recentArtistsCap { break }
      }
    }
    if orderedArtists.count < Self.recentArtistsMinUnique {
      data[.recentlyPlayedArtists] = []
    } else {
      data[.recentlyPlayedArtists] = orderedArtists.map {
        HomeItem(stableID: Self.stableID(for: $0), playableContainable: $0)
      }
    }
    applySnapshotCB?()
  }

  // MARK: - Player observer

  @objc
  private func handlePlayerChanged() {
    Task { @MainActor in
      // cassette Patch 042: live queue change can shuffle the live-
      // album to the top of Recent and shift dedupe membership for
      // the lower shelves, so recompute the full set.
      recomputeAllShelves()
    }
  }
}

extension HomeManager: @preconcurrency NSFetchedResultsControllerDelegate {
  func controllerDidChangeContent(_ controller: NSFetchedResultsController<NSFetchRequestResult>) {
    // fetch controllers are created on Main thread -> Runtime Error if this function call is not on Main thread
    MainActor.assumeIsolated {
      // cassette Patch 042: every FRC change can shift cross-shelf
      // dedupe membership (e.g. a newly-played album promotes from
      // Albums to Recent and must drop from the Albums shelf), so
      // recompute the full set rather than a single shelf.
      if controller == albumsRecentFetch?.fetchResultsController
        || controller == playlistsLastPlayedFetch?.fetchResultsController
        || controller == albumsNewestFetch?.fetchResultsController
        || controller == recentArtistsSongFetch?.fetchResultsController {
        recomputeAllShelves()
      }
    }
  }
}
