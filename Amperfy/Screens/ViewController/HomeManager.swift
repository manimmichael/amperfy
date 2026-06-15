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

// MARK: - ShelfScore

/// cassette Home Shelves v1 foundation. Read-time play signals aggregated for
/// a container (album or artist) from a bounded sample of its songs. The
/// per-song `playCount` / `lastTimePlayed` are maintained on the play path;
/// album/artist counts are not, so we derive them here with no new writes.
///
/// Structured for reuse by the v2 themed rows: "all-time favorites" is
/// `playCount`, "recent favorites" / "this time last year" layer a windowed
/// `ScrobbleEntryMO` query on top of the same shape.
struct ShelfScore {
  var lastPlayed: Date? // max song.lastTimePlayed → recency
  var playCount: Int // sum song.playCount → affinity
  var newestAdded: Date? // max song.addedDate → recency-of-addition (backfill)
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
  // Remote-sync batch size (newest / recent album sync). Distinct from the
  // on-screen shelf sizing below.
  public static let sectionMaxItemCount = 20

  // cassette Home Shelves v1. Two distinct ideas: a *target* fill (the
  // minimum so a shelf is never sparse) and a *cap* (the max shown in the
  // carousel; the remainder routes to "See all"). `songSampleLimit` bounds
  // every song fetch so read-time aggregation never scans the whole library;
  // `libraryBackfillLimit` bounds the stable at-large fallback.
  private static let shelfTargetCount = 10
  private static let shelfCarouselCap = 12
  private static let songSampleLimit = 100
  private static let libraryBackfillLimit = 60

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

  // cassette Home Shelves v1: rank albums & artists from maintained *song*
  // play data (the per-song playCount / lastTimePlayed are bumped on the play
  // path; album/artist counts and the server-assigned recentIndex/newestIndex
  // are not). We sample three bounded song fetches and aggregate per container
  // at read time — the proven Artists-shelf pattern, now applied to albums too.
  private var recentSongsFetch: SongsFetchedResultsController? // lastPlayedDate desc → recency
  private var topSongsFetch: SongsFetchedResultsController? // playCount desc → affinity
  private var newestSongsFetch: SongsFetchedResultsController? // addedDate desc → newest-added
  private var playlistsLastPlayedFetch: PlaylistFetchedResultsController?

  // Stable library-at-large backfill (alphabetical; no dependency on the
  // server-assigned indices) so a shelf never renders below target when the
  // items exist.
  private var albumsAllFetch: AlbumFetchedResultsController?
  private var artistsAllFetch: ArtistFetchedResultsController?

  // Transient per-recompute scoring, rebuilt at the top of
  // `recomputeAllShelves` and consumed by the shelf builders in that pass.
  private var albumScores: [String: (container: Album, score: ShelfScore)] = [:]
  private var artistScores: [String: (container: Artist, score: ShelfScore)] = [:]
  private var rankedAlbumIDs: [String] = []
  private var rankedArtistIDs: [String] = []

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
    playlistsLastPlayedFetch = PlaylistFetchedResultsController(
      coreDataCompanion: storage.main, account: account,
      sortType: .lastPlayed,
      isGroupedInAlphabeticSections: false,
      fetchLimit: Self.songSampleLimit
    )
    playlistsLastPlayedFetch?.delegate = self
    playlistsLastPlayedFetch?.search(
      searchText: "",
      playlistSearchCategory: isOfflineMode ? .cached : .all
    )

    // Bounded song samples — recency, affinity, newest-added. Aggregated per
    // album/artist in memory (see scoreContainers); no writes on the play
    // path. Reuses SongsFetchedResultsController so we inherit the per-account
    // / exclude-server-deleted predicates and `keepAllResultsUpdated = false`.
    recentSongsFetch = makeSongSample(sortType: .lastPlayedDate)
    topSongsFetch = makeSongSample(sortType: .playCount)
    newestSongsFetch = makeSongSample(sortType: .addedDate)

    // Stable at-large backfill (alphabetical) so shelves fill to target on a
    // tiny library without leaning on the unset server indices.
    albumsAllFetch = AlbumFetchedResultsController(
      coreDataCompanion: storage.main, account: account,
      sortType: .name,
      isGroupedInAlphabeticSections: false,
      fetchLimit: Self.libraryBackfillLimit
    )
    albumsAllFetch?.delegate = self
    albumsAllFetch?.search(searchText: "", onlyCached: isOfflineMode, displayFilter: .all)

    artistsAllFetch = ArtistFetchedResultsController(
      coreDataCompanion: storage.main, account: account,
      sortType: .name,
      isGroupedInAlphabeticSections: false,
      fetchLimit: Self.libraryBackfillLimit
    )
    artistsAllFetch?.delegate = self
    artistsAllFetch?.search(searchText: "", onlyCached: isOfflineMode, displayFilter: .all)

    recomputeAllShelves()
  }

  private func makeSongSample(sortType: SongElementSortType) -> SongsFetchedResultsController {
    let frc = SongsFetchedResultsController(
      coreDataCompanion: storage.main,
      account: account,
      sortType: sortType,
      isGroupedInAlphabeticSections: false,
      fetchLimit: Self.songSampleLimit
    )
    frc.delegate = self
    frc.search(searchText: "", onlyCachedSongs: isOfflineMode, displayFilter: .all)
    return frc
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

  /// Drive every shelf in dependency order: rebuild the song-derived scores
  /// once, then Recent first (it sets the dedupe baseline), then the three
  /// lower shelves which filter against `data[.recent]`.
  private func recomputeAllShelves() {
    let songs = sampledSongs()
    albumScores = scoreContainers(from: songs) { $0.album }
    artistScores = scoreContainers(from: songs) { $0.artist }
    rankedAlbumIDs = rankedContainerIDs(albumScores)
    rankedArtistIDs = rankedContainerIDs(artistScores)

    updateRecent()
    updatePlaylists()
    updateAlbums()
    updateRecentArtists()
  }

  // MARK: - Play scoring (Home Shelves v1 foundation)

  /// Deduplicated union of the bounded song samples (recency + most-played +
  /// newest-added). Each song is wrapped once so affinity sums aren't inflated
  /// by a song appearing in more than one sample.
  private func sampledSongs() -> [Song] {
    var seen = Set<NSManagedObjectID>()
    var songs: [Song] = []
    for fetch in [recentSongsFetch, topSongsFetch, newestSongsFetch] {
      for mo in (fetch?.fetchedObjects as? [SongMO]) ?? [] where seen.insert(mo.objectID).inserted {
        songs.append(Song(managedObject: mo))
      }
    }
    return songs
  }

  /// Fold a song sample into per-container scores keyed by stable id. `key`
  /// extracts the album/artist for a song, or nil to skip it.
  private func scoreContainers<C: PlayableContainable>(
    from songs: [Song],
    key: (Song) -> C?
  )
    -> [String: (container: C, score: ShelfScore)] {
    var out: [String: (container: C, score: ShelfScore)] = [:]
    for song in songs {
      guard let container = key(song) else { continue }
      let id = Self.stableID(for: container)
      var entry = out[id] ??
        (container: container, score: ShelfScore(lastPlayed: nil, playCount: 0, newestAdded: nil))
      if let lastPlayed = song.lastTimePlayed,
         entry.score.lastPlayed == nil || lastPlayed > entry.score.lastPlayed! {
        entry.score.lastPlayed = lastPlayed
      }
      entry.score.playCount += song.playCount
      if let added = song.addedDate,
         entry.score.newestAdded == nil || added > entry.score.newestAdded! {
        entry.score.newestAdded = added
      }
      out[id] = entry
    }
    return out
  }

  /// Rank container ids: played first (most-recent play, then affinity), then
  /// unplayed by recency-of-addition, then a stable id tiebreak so the order
  /// doesn't reshuffle across Home reloads.
  private func rankedContainerIDs<C>(
    _ scored: [String: (container: C, score: ShelfScore)]
  )
    -> [String] {
    scored.keys.sorted { lhs, rhs in
      guard let a = scored[lhs]?.score, let b = scored[rhs]?.score else { return lhs < rhs }
      let aPlayed = a.lastPlayed != nil, bPlayed = b.lastPlayed != nil
      if aPlayed != bPlayed { return aPlayed }
      if aPlayed, let la = a.lastPlayed, let lb = b.lastPlayed, la != lb { return la > lb }
      if a.playCount != b.playCount { return a.playCount > b.playCount }
      let na = a.newestAdded ?? .distantPast, nb = b.newestAdded ?? .distantPast
      if na != nb { return na > nb }
      return lhs < rhs
    }
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
    var entries: [(date: Date, container: PlayableContainable, id: String)] = []

    // cassette Home Shelves v1: albums are now eligible here via song-derived
    // recency (album.lastTimePlayed is never written), so a played album
    // actually appears in Recent — not just playlists and artists.
    for (id, scored) in albumScores {
      if let date = scored.score.lastPlayed {
        entries.append((date, scored.container, id))
      }
    }
    for (id, scored) in artistScores {
      if let date = scored.score.lastPlayed {
        entries.append((date, scored.container, id))
      }
    }
    if let playlistMOs = playlistsLastPlayedFetch?.fetchedObjects as? [PlaylistMO] {
      for mo in playlistMOs.prefix(Self.shelfCarouselCap) {
        let playlist = Playlist(library: storage.main.library, managedObject: mo)
        if let date = playlist.lastTimePlayed {
          entries.append((date, playlist, Self.stableID(for: playlist)))
        }
      }
    }

    entries.sort { $0.date > $1.date }

    var merged: [PlayableContainable] = []
    var seenIDs = Set<String>()
    for entry in entries {
      if seenIDs.insert(entry.id).inserted {
        merged.append(entry.container)
      }
    }

    // First-run fallback: nothing played yet → fold in newest content (the
    // song-derived ranking already leads with newest-added albums, then the
    // stable at-large list) so a freshly synced library isn't empty.
    if merged.isEmpty {
      for id in rankedAlbumIDs {
        guard let album = albumScores[id]?.container, seenIDs.insert(id).inserted else { continue }
        merged.append(album)
        if merged.count >= Self.shelfCarouselCap { break }
      }
      if merged.count < Self.shelfTargetCount,
         let albumMOs = albumsAllFetch?.fetchedObjects as? [AlbumMO] {
        for mo in albumMOs {
          let album = Album(managedObject: mo)
          let id = Self.stableID(for: album)
          guard seenIDs.insert(id).inserted else { continue }
          merged.append(album)
          if merged.count >= Self.shelfTargetCount { break }
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
    let hasPlayHistory = hasLiveAlbum || !entries.isEmpty
    if hasPlayHistory, let resumeContainer = merged.first {
      // cassette Patch 104: namespace the Resume identity. With the raw
      // container stableID, a container moving between the Resume section
      // and a shelf reads as a *move* to the diffable data source, so the
      // old shelf AlbumCollectionCell gets recycled into the full-width
      // Resume slot instead of dequeuing a ResumeCardCell. A distinct ID
      // makes the transition a delete+insert, which re-runs the cell
      // provider's section check.
      data[.resume] = [HomeItem(
        stableID: "resume:" + Self.stableID(for: resumeContainer),
        playableContainable: resumeContainer
      )]
      merged.removeFirst()
    } else {
      data[.resume] = []
    }

    data[.recent] = merged.prefix(Self.shelfCarouselCap).map {
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
    let playlists = playlistMOs.prefix(Self.shelfCarouselCap * 2)
      .compactMap { Playlist(library: storage.main.library, managedObject: $0) }
    data[.yourPlaylists] = playlists
      .filter { !recentSet.contains(Self.stableID(for: $0)) }
      .prefix(Self.shelfCarouselCap)
      .map { HomeItem(stableID: Self.stableID(for: $0), playableContainable: $0) }
    applySnapshotCB?()
  }

  /// Albums ranked from maintained song play data: played first (recency then
  /// affinity), then newest-added, then a stable at-large backfill — filled to
  /// target so the shelf is never sparse, capped for the carousel. Filters out
  /// anything already in Recent. No reliance on the unset server indices.
  func updateAlbums() {
    data[.recentlyAdded] = filledShelf(
      rankedIDs: rankedAlbumIDs,
      containerForID: { albumScores[$0]?.container },
      atLargeMOs: albumsAllFetch?.fetchedObjects as? [AlbumMO],
      wrap: { Album(managedObject: $0) }
    )
    applySnapshotCB?()
  }

  /// Artists, same proven recency-then-affinity ranking the shelf already used,
  /// now with the fill-to-N backfill. The old hard "hide below 3 played
  /// artists" guard is dropped — backfill reaches the target, so a real shelf
  /// renders whenever the library has artists at all.
  func updateRecentArtists() {
    data[.recentlyPlayedArtists] = filledShelf(
      rankedIDs: rankedArtistIDs,
      containerForID: { artistScores[$0]?.container },
      atLargeMOs: artistsAllFetch?.fetchedObjects as? [ArtistMO],
      wrap: { Artist(managedObject: $0) }
    )
    applySnapshotCB?()
  }

  /// Shared fill-to-N builder for the album & artist shelves. Priority:
  /// 1. the song-derived ranking (played, then newest-added),
  /// 2. the stable at-large fetch until the target is reached,
  /// excluding anything already in Resume/Recent, deduped, capped at the
  /// carousel max.
  private func filledShelf<C: PlayableContainable, MO: NSManagedObject>(
    rankedIDs: [String],
    containerForID: (String) -> C?,
    atLargeMOs: [MO]?,
    wrap: (MO) -> C
  )
    -> [HomeItem] {
    let recentSet = recentStableIDs
    var ordered: [PlayableContainable] = []
    var seen = Set<String>()

    for id in rankedIDs where !recentSet.contains(id) {
      guard let container = containerForID(id), seen.insert(id).inserted else { continue }
      ordered.append(container)
      if ordered.count >= Self.shelfCarouselCap { break }
    }

    if ordered.count < Self.shelfTargetCount, let atLargeMOs {
      for mo in atLargeMOs {
        let container = wrap(mo)
        let id = Self.stableID(for: container)
        guard !recentSet.contains(id), seen.insert(id).inserted else { continue }
        ordered.append(container)
        if ordered.count >= Self.shelfTargetCount { break }
      }
    }

    return ordered.prefix(Self.shelfCarouselCap).map {
      HomeItem(stableID: Self.stableID(for: $0), playableContainable: $0)
    }
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
      if controller == recentSongsFetch?.fetchResultsController
        || controller == topSongsFetch?.fetchResultsController
        || controller == newestSongsFetch?.fetchResultsController
        || controller == playlistsLastPlayedFetch?.fetchResultsController
        || controller == albumsAllFetch?.fetchResultsController
        || controller == artistsAllFetch?.fetchResultsController {
        recomputeAllShelves()
      }
    }
  }
}
