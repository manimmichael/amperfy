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
import UIKit

// MARK: - HomeItem

/// cassette: diffable identity is **section-scoped** — the owning `HomeSection`
/// is folded into Hashable/Equatable, so the diffable identifier is effectively
/// `"\(section):\(stableID)"`. This lets the same underlying album/artist appear
/// in Recent AND its typed shelf as two distinct items, with no diffable
/// "identifiers already exist" collision and no expensive cross-section move.
/// With this, no shelf needs to subtract any other shelf — the old cross-shelf
/// dedup is fully retired (overlap is allowed everywhere). `stableID` stays the
/// per-container key (`album-<id>` etc.) used for intra-shelf dedup and CarPlay.
struct HomeItem: Hashable, @unchecked Sendable {
  let section: HomeSection
  let stableID: String
  var playableContainable: PlayableContainable

  static func == (lhs: HomeItem, rhs: HomeItem) -> Bool {
    lhs.section == rhs.section && lhs.stableID == rhs.stableID
  }

  func hash(into hasher: inout Hasher) {
    hasher.combine(section)
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
  /// cassette (CarPlay feel-good, Job 1.3): when true, this instance also builds
  /// the two album-forward shelves (`.recentlyPlayedAlbums` / `.newestAlbums`)
  /// that CarPlay Home renders. iOS Home leaves it false — its section set
  /// (`HomeSection.defaultValue`) doesn't include them, so it neither builds nor
  /// renders them, keeping the extra work + snapshot fan-out off the iOS path.
  private let buildsAlbumShelves: Bool
  /// cassette (Forgotten Albums): when true, this instance builds the iOS-only
  /// "From Your Collection" anti-recency shelf (`.forgottenAlbums`). CarPlay
  /// leaves it false (its section list doesn't include it).
  private let buildsForgottenShelf: Bool

  // cassette (Forgotten Albums) tuning knobs.
  private static let forgottenCandidateFetchLimit = 150
  private static let forgottenTurnoverDays = 7
  private static let forgottenColdSeconds: TimeInterval = 60 * 24 * 60 * 60 // 60 days
  private static let forgottenRekindleMinPlays: Int = 5

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
  // cassette (Forgotten Albums): owned-album candidate pool (the on-device
  // ownership predicate auto-applies), newest-sorted so the older end
  // approximates "added long ago".
  private var forgottenAlbumsFetch: AlbumFetchedResultsController?

  // Transient per-recompute scoring, rebuilt at the top of
  // `recomputeAllShelves` and consumed by the shelf builders in that pass.
  private var albumScores: [String: (container: Album, score: ShelfScore)] = [:]
  private var artistScores: [String: (container: Artist, score: ShelfScore)] = [:]
  private var rankedAlbumIDs: [String] = []
  // cassette (BUG-036): `rankedArtistIDs` (song-derived artist ranking) retired —
  // the Artists shelf now ranks by the real artist-play signal in
  // `updateRecentArtists()`, so album plays no longer surface artists.

  // Part 2a: coalesce the FRC-change burst (~30 callbacks in 0.1s as Core Data
  // settles after a play / sync) and player transitions into a single debounced
  // recompute, so one snapshot is applied instead of a storm. The initial
  // build in `createFetchController` runs immediately for first paint.
  private var pendingRecompute: DispatchWorkItem?
  private static let recomputeDebounce: TimeInterval = 0.12
  // cassette (CarPlay off-window crash): when this HomeManager's host view is not
  // on screen — the phone Home while CarPlay drives playback — defer recomputes
  // instead of rebuilding and applying an animated snapshot to an off-window
  // collection view (the production SIGTRAP cluster). The phone HomeVC sets this;
  // CarPlay's own HomeManager leaves it nil so its templates keep updating live. A
  // deferred recompute is flushed once by the host on next appearance
  // (`recomputeIfDeferred()`).
  public var isHostVisible: (() -> Bool)?
  private var needsRecomputeWhileHidden = false
  // cassette (CarPlay off-window crash): coalesce the per-builder snapshot
  // callbacks fired within one `recomputeAllShelves` into a SINGLE apply, so a
  // rebuild is one diff/animation instead of 4-6 overlapping animated applies.
  private var isBatchingSnapshot = false

  init(
    account: Account,
    storage: PersistentStorage,
    getMeta: @escaping (_ accountInfo: AccountInfo) -> MetaManager,
    eventLogger: EventLogger,
    player: PlayerFacade,
    buildsAlbumShelves: Bool = false,
    buildsForgottenShelf: Bool = false
  ) {
    self.account = account
    self.storage = storage
    self.getMeta = getMeta
    self.eventLogger = eventLogger
    self.player = player
    self.buildsAlbumShelves = buildsAlbumShelves
    self.buildsForgottenShelf = buildsForgottenShelf
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
    // pendingRecompute uses [weak self], so a stale fire after dealloc no-ops;
    // no explicit cancel needed (and deinit is nonisolated, can't touch it).
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

    // cassette (Forgotten Albums): iOS-only owned-album candidate FRC. In
    // on-device-only mode the AlbumFetchedResultsController's ownership predicate
    // already constrains this to owned albums.
    if buildsForgottenShelf {
      forgottenAlbumsFetch = AlbumFetchedResultsController(
        coreDataCompanion: storage.main, account: account,
        sortType: .newest,
        isGroupedInAlphabeticSections: false,
        fetchLimit: Self.forgottenCandidateFetchLimit
      )
      forgottenAlbumsFetch?.delegate = self
      forgottenAlbumsFetch?.search(searchText: "", onlyCached: isOfflineMode, displayFilter: .all)
    }

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
    guard storage.settings.user.isOnlineMode else {
      print("Cassette recency: updateFromRemote SKIPPED — app is in offline mode")
      return
    }
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
    // cassette: fold plays made on the user's OTHER devices (e.g. their
    // computer) into local recency, so the Home "Recent" shelf reflects
    // cross-device listening. Advance-only; read-only against the network.
    Task { @MainActor in
      let changed = await CloudPlayReconciler.reconcile(
        storage: self.storage,
        account: self.account
      )
      if changed { self.scheduleRecompute() }
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

  /// Debounced entry point (Part 2a): coalesce a burst of FRC-change / player-
  /// transition callbacks into one recompute after the burst settles, so a play
  /// action or library sync applies a single snapshot instead of ~30.
  private func scheduleRecompute() {
    if let isHostVisible, !isHostVisible() {
      // Host (phone Home) is off-window — e.g. CarPlay is driving playback. Rebuilding
      // and applying an animated snapshot to an off-window collection view is the
      // production crash; defer and let the host flush one recompute on reappearance.
      needsRecomputeWhileHidden = true
      return
    }
    pendingRecompute?.cancel()
    let work = DispatchWorkItem { [weak self] in self?.recomputeAllShelves() }
    pendingRecompute = work
    DispatchQueue.main.asyncAfter(deadline: .now() + Self.recomputeDebounce, execute: work)
  }

  /// Flushed by the host (phone Home) when it becomes visible again: runs one
  /// coalesced recompute if any were deferred while the host was off-window.
  public func recomputeIfDeferred() {
    guard needsRecomputeWhileHidden else { return }
    needsRecomputeWhileHidden = false
    scheduleRecompute()
  }

  /// Fire the host's snapshot callback, unless we're mid-rebuild — during a
  /// `recomputeAllShelves` the per-builder calls are suppressed and collapse into
  /// the single apply that recompute fires when the whole rebuild finishes.
  private func notifySnapshot() {
    guard !isBatchingSnapshot else { return }
    applySnapshotCB?()
  }

  /// Rebuild the song-derived scores once, then every shelf. Order is Recent →
  /// Resume → Playlists → Albums → Artists. Shelves no longer subtract one
  /// another (section-scoped `HomeItem` identity allows overlap), so this is a
  /// straight rebuild with no cross-shelf dedup.
  private func recomputeAllShelves() {
    // Suppress the per-builder snapshot callbacks and fire exactly one apply for
    // the whole rebuild (via defer, so it still fires if a builder bails early).
    isBatchingSnapshot = true
    defer {
      isBatchingSnapshot = false
      applySnapshotCB?()
    }
    let songs = sampledSongs()
    albumScores = scoreContainers(from: songs) { $0.album }
    artistScores = scoreContainers(from: songs) { $0.artist }
    rankedAlbumIDs = rankedContainerIDs(albumScores)

    updateRecent()
    updatePlaylists()
    updateAlbums()
    // cassette: the Albums + Artists shelves now run the SHARED home-shelf engine
    // (the same algorithm as web + Android, kept in sync by the conformance
    // fixtures). Built ONCE from Core Data here, AFTER Recent so its items can be
    // excluded. The old updateRecentArtists / updateForgottenAlbums are retired in
    // favour of the engine (their forgotten/deep-dive logic is what the engine was
    // ported from; the engine additionally gives Artists the added/cold/affinity
    // blend iOS lacked).
    let shelfInput = buildShelfInput()
    updateArtistsViaEngine(shelfInput)
    // cassette (Job 1.3): CarPlay-only album-forward shelves. Gated so iOS
    // neither computes nor snapshots them.
    if buildsAlbumShelves {
      updateRecentlyPlayedAlbums()
      updateNewestAlbums()
    }
    // cassette (Forgotten Albums): iOS-only anti-recency shelf, now engine-backed.
    if buildsForgottenShelf {
      updateAlbumsViaEngine(shelfInput)
    }
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

  /// Heterogeneous merge: recently-played albums + playlists +
  /// recently-played-artists (deduped from the song fetch). Folds
  /// in newest albums when nothing has been played yet so a brand-
  /// new library still shows fresh content. Prepends the live
  /// queue's source album.
  func updateRecent() {
    var entries: [(date: Date, container: PlayableContainable, id: String)] = []

    // cassette Home Shelves v1 — album vs. artist recency are DELIBERATELY
    // asymmetric here; do not "unify" them:
    //  • Albums use song-derived recency (scored.score.lastPlayed). Load-bearing:
    //    an album can reach Recent via a non-containable play context (queue,
    //    mix) where Album.playedViaContext() never fires, so the song rollup is
    //    the only path that surfaces it. (BUG-037: album.lastTimePlayed IS
    //    written on PlayContext(containable: album) — just not on those
    //    queue/mix paths — hence the rollup.)
    //  • Artists use the container signal (scored.container.lastTimePlayed,
    //    written by Artist.playedViaContext()). An artist only reaches a queue by
    //    being CHOSEN as an artist, which always writes that signal — so the song
    //    rollup would re-surface an artist whenever an album of theirs played
    //    ("Bleachers doubling", BUG-038). Ranking by the container signal means an
    //    album play no longer promotes the artist into Recent. Same read-side fix
    //    as BUG-036 on the Artists shelf (updateRecentArtists), second builder.
    for (id, scored) in albumScores {
      if let date = scored.score.lastPlayed {
        entries.append((date, scored.container, id))
      }
    }
    for (id, scored) in artistScores {
      if let date = scored.container.lastTimePlayed {
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
    //
    // cassette (Resume on-device gate): in the default on-device-only mode the
    // phone shows only downloaded content, so the Resume card must not point at
    // an album that's been removed from the device. We pick the first container
    // in the recency-ordered `merged` list that is still on-device, falling
    // through to the next owned one (and hiding the card entirely if none
    // remain). In Server Mode the gate is bypassed — Resume shows the
    // most-recent container regardless of local ownership, unchanged behavior.
    let hasPlayHistory = hasLiveAlbum || !entries.isEmpty
    if hasPlayHistory, let resumeIndex = firstResumeEligibleIndex(in: merged) {
      let resumeContainer = merged[resumeIndex]
      // Section-scoped HomeItem identity already makes Resume vs a shelf a
      // distinct item, so a container moving between them is a delete+insert
      // that re-runs the cell provider — the Patch-104 "resume:" stableID
      // prefix is no longer needed.
      data[.resume] = [HomeItem(
        section: .resume,
        stableID: Self.stableID(for: resumeContainer),
        playableContainable: resumeContainer
      )]
      merged.remove(at: resumeIndex)
    } else {
      data[.resume] = []
    }

    data[.recent] = merged.prefix(Self.shelfCarouselCap).map {
      HomeItem(section: .recent, stableID: Self.stableID(for: $0), playableContainable: $0)
    }
    notifySnapshot()
  }

  /// cassette (Resume on-device gate): index of the first container in the
  /// recency-ordered list that may surface as the Resume card.
  ///
  /// In Server Mode the head is always eligible (catalog-wide), so this is just
  /// `0` when the list is non-empty. In the default on-device-only mode it
  /// returns the first container whose content is still on the device, so a
  /// removed album falls through to the next owned one (or the card hides when
  /// nothing owned remains).
  ///
  /// The owned-album / owned-artist id sets are resolved ONCE here — not per
  /// container — so this is one Core Data pass per recompute, not one per item.
  /// Albums and Artists are gated by their owned-id sets; Playlists (and any
  /// other container type) are treated as eligible because device-ownership is
  /// tracked per track, not per playlist — gating them here would surprise-hide
  /// a playlist whose tracks are partially on-device, so we leave the existing
  /// behavior for those.
  private func firstResumeEligibleIndex(in merged: [PlayableContainable]) -> Int? {
    guard CassetteLibraryFilterProvider.shared.isOnDeviceOnly else {
      return merged.isEmpty ? nil : 0
    }
    let ownership = DeviceOwnershipManager(context: storage.main.context)
    let ownedAlbumIds = ownership.fetchOwnedAlbumIds()
    let ownedArtistIds = ownership.fetchOwnedArtistIds()
    return merged.firstIndex { container in
      if let album = container as? Album { return ownedAlbumIds.contains(album.id) }
      if let artist = container as? Artist { return ownedArtistIds.contains(artist.id) }
      // Non-album/artist containers (e.g. playlists): ownership is per-track,
      // not per-container, so don't hide them — keep prior behavior.
      return true
    }
  }

  /// Recently-played playlists. Overlap with Recent is allowed (section-scoped
  /// identity), so no cross-shelf subtraction.
  func updatePlaylists() {
    guard let playlistMOs = playlistsLastPlayedFetch?.fetchedObjects as? [PlaylistMO] else {
      data[.yourPlaylists] = []
      notifySnapshot()
      return
    }
    // cassette: dedup by stableID like every other shelf builder (updateRecent's
    // seenIDs, filledShelf's seen, blendForgotten). Two PlaylistMOs sharing a
    // playlist id — a row materialized twice, or a degenerate/empty id on a
    // local playlist — otherwise map to two identical HomeItems in one section,
    // a duplicate diffable identifier that hard-crashes applySnapshot (SIGTRAP).
    var seenPlaylistIDs = Set<String>()
    data[.yourPlaylists] = playlistMOs
      .compactMap { Playlist(library: storage.main.library, managedObject: $0) }
      .filter { seenPlaylistIDs.insert(Self.stableID(for: $0)).inserted }
      .prefix(Self.shelfCarouselCap)
      .map { HomeItem(
        section: .yourPlaylists,
        stableID: Self.stableID(for: $0),
        playableContainable: $0
      ) }
    notifySnapshot()
  }

  /// Albums ranked from maintained song play data: played first (recency then
  /// affinity), then newest-added, then a stable at-large backfill — filled to
  /// target so the shelf is never sparse, capped for the carousel. No reliance
  /// on the unset server indices; overlap with Recent is allowed.
  func updateAlbums() {
    data[.recentlyAdded] = filledShelf(
      section: .recentlyAdded,
      rankedIDs: rankedAlbumIDs,
      containerForID: { albumScores[$0]?.container },
      atLargeMOs: albumsAllFetch?.fetchedObjects as? [AlbumMO],
      wrap: { Album(managedObject: $0) }
    )
    notifySnapshot()
  }

  /// cassette (BUG-036): rank by the REAL artist-play signal, not song-rollup.
  /// `Artist.playedViaContext()` (AbstractLibraryEntity) writes `lastTimePlayed`
  /// on every `PlayContext(containable: artist)`, so an artist that was actually
  /// played leads — whereas playing an *album* stamps the album's `lastTimePlayed`,
  /// not the artist's, so it no longer surfaces the artist here (the old
  /// song-rollup couldn't tell the two apart). Candidates still come from
  /// `artistScores` (a played artist's songs are in the recent sample, so it is
  /// present); we just rank by `container.lastTimePlayed`. Backfill (fill-to-N) is
  /// unchanged so the shelf never renders empty — an artist that only appears via
  /// alphabetical backfill is there by library membership, not "surfaced" by a play.
  func updateRecentArtists() {
    let rankedByArtistPlay = artistScores
      .filter { $0.value.container.lastTimePlayed != nil }
      .sorted {
        ($0.value.container.lastTimePlayed ?? .distantPast) >
          ($1.value.container.lastTimePlayed ?? .distantPast)
      }
      .map { $0.key }
    data[.recentlyPlayedArtists] = filledShelf(
      section: .recentlyPlayedArtists,
      rankedIDs: rankedByArtistPlay,
      containerForID: { artistScores[$0]?.container },
      atLargeMOs: artistsAllFetch?.fetchedObjects as? [ArtistMO],
      wrap: { Artist(managedObject: $0) }
    )
    notifySnapshot()
  }

  // MARK: - Engine-backed shelves (shared home-shelf algorithm)

  /// cassette: the Albums + Artists shelves run the SHARED home-shelf engine
  /// (`AmperfyKit/HomeShelfEngine`) — the same algorithm the web and Android run,
  /// kept genuinely in sync by the golden conformance fixtures. `HomeManager`'s job
  /// is only the adapter: turn Core Data into the engine's `ShelfInput`, call the
  /// engine, and map its ordered keys back to `HomeItem`s. Recent stays iOS's own
  /// `updateRecent` (its Resume split + live-queue prepend are iOS-specific).
  private struct EngineShelfData {
    let input: ShelfInput
    let albumsByKey: [String: Album]
    let artistsByKey: [String: Artist]
  }

  /// Adapt Core Data → `ShelfInput` (+ key→container maps to render the result).
  /// Candidate pools reuse the existing fetches (forgotten-album + all-artist)
  /// unioned with the played containers from the song sample, then each candidate's
  /// tracks are rolled up into the engine's per-container signals. Keys are the same
  /// stableIDs the rest of Home uses, so exclusion and mapping line up. On the phone
  /// (a deliberate subset of the full library) this per-candidate roll-up is bounded.
  private func buildShelfInput() -> EngineShelfData {
    func ms(_ d: Date?) -> Int64? { d.map { Int64($0.timeIntervalSince1970 * 1000) } }

    // Albums: forgotten-candidate fetch ∪ played albums from the sample.
    var albumsByKey: [String: Album] = [:]
    for mo in (forgottenAlbumsFetch?.fetchedObjects as? [AlbumMO]) ?? [] {
      let album = Album(managedObject: mo)
      albumsByKey[Self.stableID(for: album)] = album
    }
    for (_, scored) in albumScores {
      albumsByKey[Self.stableID(for: scored.container)] = scored.container
    }
    var shelfAlbums: [ShelfAlbum] = []
    for (key, album) in albumsByKey {
      let tracks = album.playables
      var played = 0, total = 0
      var last: Date?, added: Date?
      for track in tracks {
        if track.playCount > 0 { played += 1 }
        total += track.playCount
        if let lp = track.lastTimePlayed, last == nil || lp > last! { last = lp }
        if let ad = (track as? Song)?.addedDate, added == nil || ad < added! { added = ad }
      }
      shelfAlbums.append(ShelfAlbum(
        key: key, title: album.name, artist: album.artist?.name ?? "",
        genre: album.genre?.name, trackCount: tracks.count,
        playedTrackCount: played, totalPlays: total,
        lastPlayedAt: ms(last), addedAt: ms(added)))
    }

    // Artists: all-artist fetch ∪ played artists from the sample.
    var artistsByKey: [String: Artist] = [:]
    for mo in (artistsAllFetch?.fetchedObjects as? [ArtistMO]) ?? [] {
      let artist = Artist(managedObject: mo)
      artistsByKey[Self.stableID(for: artist)] = artist
    }
    for (_, scored) in artistScores {
      artistsByKey[Self.stableID(for: scored.container)] = scored.container
    }
    var shelfArtists: [ShelfArtist] = []
    for (key, artist) in artistsByKey {
      let songs = artist.songs
      var total = 0
      var last: Date?, added: Date?
      for song in songs {
        total += song.playCount
        if let lp = song.lastTimePlayed, last == nil || lp > last! { last = lp }
        if let ad = (song as? Song)?.addedDate, added == nil || ad < added! { added = ad }
      }
      shelfArtists.append(ShelfArtist(
        key: key, name: artist.name, genre: artist.genre?.name,
        trackCount: songs.count, albumCount: artist.albums.count,
        totalPlays: total, lastPlayedAt: ms(last), addedAt: ms(added)))
    }

    let input = ShelfInput(
      albums: shelfAlbums, artists: shelfArtists, playlists: [],
      recentArtistKeys: nil,
      now: Int64(Date().timeIntervalSince1970 * 1000),
      seed: "cassette-home")
    return EngineShelfData(input: input, albumsByKey: albumsByKey, artistsByKey: artistsByKey)
  }

  /// Keys already surfaced in Resume/Recent — excluded from the engine shelves so
  /// nothing shows twice (matches the web engine's cross-shelf exclusion).
  private func recentExclusions() -> Set<String> {
    var out = Set<String>()
    for section in [HomeSection.resume, .recent] {
      for item in data[section] ?? [] { out.insert(item.stableID) }
    }
    return out
  }

  private func updateAlbumsViaEngine(_ shelf: EngineShelfData) {
    let picks = buildAlbums(
      shelf.input.albums, HOME_SHELF_CONFIG, shelf.input.now, shelf.input.seed, recentExclusions())
    data[.forgottenAlbums] = picks.compactMap { shelf.albumsByKey[$0.key] }.map {
      HomeItem(section: .forgottenAlbums, stableID: Self.stableID(for: $0), playableContainable: $0)
    }
    notifySnapshot()
  }

  private func updateArtistsViaEngine(_ shelf: EngineShelfData) {
    let picks = buildArtists(shelf.input, HOME_SHELF_CONFIG, recentExclusions())
    data[.recentlyPlayedArtists] = picks.compactMap { shelf.artistsByKey[$0.key] }.map {
      HomeItem(section: .recentlyPlayedArtists, stableID: Self.stableID(for: $0), playableContainable: $0)
    }
    notifySnapshot()
  }

  /// cassette (Job 1.3): "Recently Played Albums" — albums actually played
  /// (`album.lastTimePlayed` via `Album.playedViaContext()`), most-recent first.
  /// Played-only (no backfill) so the title stays honest; the CarPlay empty-shelf
  /// guard hides it when there are no album plays yet. CarPlay-only — built only
  /// when `buildsAlbumShelves` is set (see `recomputeAllShelves`).
  func updateRecentlyPlayedAlbums() {
    let played = albumScores.values
      .filter { $0.container.lastTimePlayed != nil }
      .sorted {
        ($0.container.lastTimePlayed ?? .distantPast) >
          ($1.container.lastTimePlayed ?? .distantPast)
      }
      .prefix(Self.shelfCarouselCap)
    data[.recentlyPlayedAlbums] = played.map {
      HomeItem(
        section: .recentlyPlayedAlbums,
        stableID: Self.stableID(for: $0.container),
        playableContainable: $0.container
      )
    }
    notifySnapshot()
  }

  /// cassette (Job 1.3): "Newest Albums" — albums by recency-of-addition
  /// (`album.addedDate` ~ `ShelfScore.newestAdded`), newest first, filled to
  /// target from the stable at-large list so it isn't sparse. CarPlay-only.
  func updateNewestAlbums() {
    let rankedByAdded = albumScores
      .sorted {
        ($0.value.score.newestAdded ?? .distantPast) >
          ($1.value.score.newestAdded ?? .distantPast)
      }
      .map { $0.key }
    data[.newestAlbums] = filledShelf(
      section: .newestAlbums,
      rankedIDs: rankedByAdded,
      containerForID: { albumScores[$0]?.container },
      atLargeMOs: albumsAllFetch?.fetchedObjects as? [AlbumMO],
      wrap: { Album(managedObject: $0) }
    )
    notifySnapshot()
  }

  /// cassette (Forgotten Albums): the anti-recency shelf — owned albums the user
  /// has drifted from or never explored. iOS-only (`buildsForgottenShelf`). Draws
  /// from three pools, forgotten-purchase-weighted (the deep pool at launch):
  ///  • forgotten purchase — owned & never played, from the older (added-long-ago) end
  ///  • deep cut — 1-2 tracks ever played, the rest at zero ("kept for one song")
  ///  • rekindle — real lifetime plays, gone cold
  /// Turnover-aware: albums surfaced on a recent PRIOR day are held back so the set
  /// changes day to day (HomeVC stamps `lastSurfacedOnHomeDate` when the shelf shows).
  /// Song iteration for deep-cut/rekindle is confined to the *touched* subset, so a
  /// fresh install (only forgotten-purchase populated) does no per-song work.
  func updateForgottenAlbums() {
    guard let albumMOs = forgottenAlbumsFetch?.fetchedObjects as? [AlbumMO] else {
      data[.forgottenAlbums] = []
      notifySnapshot()
      return
    }
    // FRC is newest-first; the OLDER end approximates "added long ago".
    let owned = albumMOs.map { Album(managedObject: $0) }

    // Never repeat what Resume / Recent already show on the same screen.
    var excludedIDs = Set<String>()
    for section in [HomeSection.resume, .recent] {
      for item in data[section] ?? [] { excludedIDs.insert(item.stableID) }
    }

    // Turnover cooldown: hold back albums surfaced on a recent *prior* day, so
    // today's set stays stable while yesterday's rotates out.
    let cal = Calendar.current
    let startOfToday = cal.startOfDay(for: Date())
    let cooldownStart = cal.date(
      byAdding: .day,
      value: -Self.forgottenTurnoverDays,
      to: startOfToday
    ) ?? startOfToday
    func isEligible(_ album: Album) -> Bool {
      if excludedIDs.contains(Self.stableID(for: album)) { return false }
      if let d = album.lastSurfacedOnHomeDate, d >= cooldownStart, d < startOfToday {
        return false
      }
      return true
    }

    // Pool 1 — forgotten purchase: owned & never played, oldest-added first.
    let forgottenPurchase = owned.reversed().filter {
      $0.lastTimePlayed == nil && $0.playCount == 0 && isEligible($0)
    }

    // Pools 2 & 3 — over the TOUCHED subset only (bounded song iteration).
    let coldCutoff = Date().addingTimeInterval(-Self.forgottenColdSeconds)
    var deepCut: [Album] = []
    var rekindle: [(album: Album, plays: Int)] = []
    for album in owned
      where (album.lastTimePlayed != nil || album.playCount > 0) && isEligible(album) {
      let tracks = album.playables
      let playedTracks = tracks.reduce(0) { $0 + ($1.playCount > 0 ? 1 : 0) }
      if tracks.count >= 3, (1 ... 2).contains(playedTracks) {
        deepCut.append(album)
      }
      let playSum = tracks.reduce(0) { $0 + $1.playCount }
      let isCold = album.lastTimePlayed.map { $0 < coldCutoff } ?? true
      if playSum >= Self.forgottenRekindleMinPlays, isCold {
        rekindle.append((album, playSum))
      }
    }
    let rekindleRanked = rekindle.sorted { $0.plays > $1.plays }.map(\.album)

    var blended = blendForgotten(
      forgottenPurchase: Array(forgottenPurchase),
      deepCut: deepCut,
      rekindle: rekindleRanked
    )
    // Fill-to-target: the three forgotten pools are legitimately sparse on a
    // library with little play history (a fresh install populates only the
    // forgotten-purchase pool), and this shelf — unlike the album/artist shelves'
    // `filledShelf` — had NO backfill, so the "Albums" row collapsed to a couple
    // of items. Top up from the owned albums at-large (oldest-added first, matching
    // the "added long ago" lean), skipping Resume/Recent and dupes, so the shelf
    // always reads as a full row.
    if blended.count < Self.shelfTargetCount {
      var included = Set(blended.map { Self.stableID(for: $0) })
      for album in owned.reversed() where blended.count < Self.shelfTargetCount {
        let id = Self.stableID(for: album)
        if included.contains(id) || excludedIDs.contains(id) { continue }
        included.insert(id)
        blended.append(album)
      }
    }
    data[.forgottenAlbums] = blended.prefix(Self.shelfCarouselCap).map {
      HomeItem(
        section: .forgottenAlbums,
        stableID: Self.stableID(for: $0),
        playableContainable: $0
      )
    }
    notifySnapshot()
  }

  /// Forgotten-weighted interleave: ~3 forgotten-purchase to 1 secondary (deep-cut
  /// / rekindle, alternating), deduped within the shelf, capped at the carousel max.
  private func blendForgotten(
    forgottenPurchase: [Album],
    deepCut: [Album],
    rekindle: [Album]
  )
    -> [Album] {
    var out: [Album] = []
    var seen = Set<String>()
    func push(_ album: Album) {
      let id = Self.stableID(for: album)
      guard !seen.contains(id) else { return }
      seen.insert(id)
      out.append(album)
    }
    var fi = 0, di = 0, ri = 0
    var preferDeep = true
    while out.count < Self.shelfCarouselCap {
      let before = out.count
      var f = 0
      while f < 3, fi < forgottenPurchase.count, out.count < Self.shelfCarouselCap {
        push(forgottenPurchase[fi]); fi += 1; f += 1
      }
      if out.count < Self.shelfCarouselCap {
        if preferDeep, di < deepCut.count {
          push(deepCut[di]); di += 1
        } else if ri < rekindle.count {
          push(rekindle[ri]); ri += 1
        } else if di < deepCut.count {
          push(deepCut[di]); di += 1
        }
        preferDeep.toggle()
      }
      if out.count == before { break } // all pools exhausted
    }
    return out
  }

  /// Shared fill-to-N builder for the album & artist shelves: the song-derived
  /// ranking (played → newest-added) first, then the stable at-large fetch
  /// until the target is reached, deduped *within* the shelf and capped at the
  /// carousel max. No cross-shelf subtraction — section-scoped identity lets an
  /// item also live in Recent, so the old two-pass "minus Recent then add it
  /// back" dance is gone.
  private func filledShelf<C: PlayableContainable, MO: NSManagedObject>(
    section: HomeSection,
    rankedIDs: [String],
    containerForID: (String) -> C?,
    atLargeMOs: [MO]?,
    wrap: (MO) -> C
  )
    -> [HomeItem] {
    var ordered: [PlayableContainable] = []
    var seen = Set<String>()

    for id in rankedIDs {
      guard let container = containerForID(id), seen.insert(id).inserted else { continue }
      ordered.append(container)
      if ordered.count >= Self.shelfCarouselCap { break }
    }

    if ordered.count < Self.shelfTargetCount, let atLargeMOs {
      for mo in atLargeMOs {
        let container = wrap(mo)
        guard seen.insert(Self.stableID(for: container)).inserted else { continue }
        ordered.append(container)
        if ordered.count >= Self.shelfTargetCount { break }
      }
    }

    return ordered.prefix(Self.shelfCarouselCap).map {
      HomeItem(section: section, stableID: Self.stableID(for: $0), playableContainable: $0)
    }
  }

  // MARK: - Player observer

  @objc
  private func handlePlayerChanged() {
    // A play/pause/stop can move the live album to the top of Recent / Resume.
    // This is a real play event (HomeManager does not observe per-tick elapsed
    // time, and popup-open posts none of these), but the matching countPlayed
    // write also fires an FRC-change burst — so coalesce both into one
    // debounced recompute rather than recomputing per notification.
    Task { @MainActor in
      self.scheduleRecompute()
    }
  }
}

extension HomeManager: @preconcurrency NSFetchedResultsControllerDelegate {
  func controllerDidChangeContent(_ controller: NSFetchedResultsController<NSFetchRequestResult>) {
    // fetch controllers are created on Main thread -> Runtime Error if this function call is not on Main thread
    MainActor.assumeIsolated {
      // Any of our FRCs changing means the play-data / library moved; coalesce
      // the burst (~30 callbacks in 0.1s as Core Data settles) into a single
      // debounced recompute.
      if controller == recentSongsFetch?.fetchResultsController
        || controller == topSongsFetch?.fetchResultsController
        || controller == newestSongsFetch?.fetchResultsController
        || controller == playlistsLastPlayedFetch?.fetchResultsController
        || controller == albumsAllFetch?.fetchResultsController
        || controller == artistsAllFetch?.fetchResultsController
        || controller == forgottenAlbumsFetch?.fetchResultsController {
        scheduleRecompute()
      }
    }
  }
}
