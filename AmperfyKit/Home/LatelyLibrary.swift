//
//  LatelyLibrary.swift
//  AmperfyKit
//
//  Cassette: the phone's music seen through what the person has been playing lately
//  (UX review 2026-10-20). Gathers, from Core Data and the cached mood tags, what
//  ListeningShelves needs for More Like Lately and the Lately mix: the songs on this
//  phone with their tags, the lately profile (the cloud's shared one, from every device,
//  when the phone has it; else built from this phone's plays), and what was played
//  recently. Cached for a
//  few minutes, because Home recomputes on every play and pause.
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

import CoreData
import Foundation

extension Notification.Name {
  /// Posted on the main actor when `LatelyLibrary.moodIndexIfReady` finishes a build it
  /// started in the background: ask again and the index is there.
  public static let cassetteMoodIndexReady = Notification.Name("cassette.moodIndexReady")
}

@MainActor
public enum LatelyLibrary {
  public struct Snapshot {
    public let profile: ListeningShelves.TagVector
    public let songsByID: [String: Song]
    public let songCandidates: [ListeningShelves.SongCandidate]
    public let albumCandidates: [ListeningShelves.AlbumCandidate]
    public let albumsByID: [String: Album]
    /// Albums with a play in the last 30 days.
    public let albumsPlayedRecently: Set<String>
    /// Songs played in the last three days (kept out of the mix).
    public let songsPlayedRecently: Set<String>

    public var describe: String { ListeningShelves.describe(profile) }
  }

  /// The tagged music on this phone, with no listening profile: what MORE LIKE on the
  /// artist and playlist pages ranks against. Works whenever there are mood tags, even
  /// with no recent plays (when `snapshot` is nil).
  public struct MoodIndex {
    public let songCandidates: [ListeningShelves.SongCandidate]
    public let albumCandidates: [ListeningShelves.AlbumCandidate]
    public let albumsByID: [String: Album]
    public let songsByID: [String: Song]
    /// The album's artist name (album artist, else the song's), for grouping by name.
    public let artistNameByAlbumID: [String: String]
  }

  /// Bumped every time `snapshot` rebuilds (a cache miss), so a holder of something built
  /// from a snapshot (Home's Lately mix) can tell when it is stale.
  public private(set) static var generation = 0

  private static let cacheLifetime: TimeInterval = 5 * 60
  private static var cached: (at: Date, accountID: String, tagCount: Int, profileSize: Int, snapshot: Snapshot?)?
  private static var cachedIndex: (at: Date, accountID: String, tagCount: Int, index: MoodIndex?)?
  /// The background index build in flight (`moodIndexIfReady`), if any.
  private static var indexBuild: (key: String, token: UUID)?

  /// The snapshot for this account, or nil when there are no mood tags yet or nothing
  /// recent to build a profile from.
  public static func snapshot(storage: PersistentStorage, account: Account, now: Date = Date()) -> Snapshot? {
    let tags = LibraryMoods.shared.byLocalID
    let accountID = accountKey(account)
    let profileSize = LibraryMoods.shared.sharedProfile.count
    if let cached, cached.accountID == accountID, cached.tagCount == tags.count,
       cached.profileSize == profileSize, now.timeIntervalSince(cached.at) < cacheLifetime {
      return cached.snapshot
    }
    let snapshot = build(storage: storage, account: account, tags: tags, now: now)
    cached = (now, accountID, tags.count, profileSize, snapshot)
    generation += 1
    return snapshot
  }

  /// The mood index for this account, built now on the main thread when it is not cached
  /// (five minutes, the same keys as `snapshot`). Home's snapshot builds through this, so
  /// a page that opens after Home reuses Home's index. A page opening should prefer
  /// `moodIndexIfReady`, which never blocks.
  public static func moodIndex(storage: PersistentStorage, account: Account, now: Date = Date()) -> MoodIndex? {
    let tags = LibraryMoods.shared.byLocalID
    let accountID = accountKey(account)
    if let hit = validCachedIndex(accountID: accountID, tagCount: tags.count, now: now) {
      return hit
    }
    // The main context, on the main actor: read in place.
    let context = storage.main.context
    let raw = gatherRaw(context: context, accountObjectID: account.managedObject.objectID, tags: tags)
    let index = raw.flatMap { materialize($0, context: context) }
    cachedIndex = (now, accountID, tags.count, index)
    return index
  }

  /// The non-blocking mood index for a page opening: the cached index when there is one.
  /// On a cache miss it starts a build off the main thread (in a background context) and
  /// returns this account's previous index while that runs (nil when there is none);
  /// `.cassetteMoodIndexReady` is posted on the main actor when the build lands, and the
  /// next call returns it. Never stalls the main thread.
  public static func moodIndexIfReady(
    storage: PersistentStorage,
    account: Account,
    now: Date = Date()
  )
    -> MoodIndex? {
    let tags = LibraryMoods.shared.byLocalID
    let accountID = accountKey(account)
    if let hit = validCachedIndex(accountID: accountID, tagCount: tags.count, now: now) {
      return hit
    }
    if tags.isEmpty {
      cachedIndex = (now, accountID, 0, nil)
      return nil
    }
    // While a fresh index builds, the last one for this account still reads well.
    let previous = cachedIndex?.accountID == accountID ? cachedIndex?.index : nil
    let key = "\(accountID)#\(tags.count)"
    if indexBuild?.key == key { return previous }
    let token = UUID()
    indexBuild = (key, token)
    let accountObjectID = account.managedObject.objectID
    let background = storage.async
    Task { @MainActor in
      let raw: RawIndex? = try? await background.performAndGet { companion in
        LatelyLibrary.gatherRaw(context: companion.context, accountObjectID: accountObjectID, tags: tags)
      }
      guard indexBuild?.token == token else { return }
      indexBuild = nil
      let index = raw.flatMap { materialize($0, context: storage.main.context) }
      cachedIndex = (Date(), accountID, tags.count, index)
      NotificationCenter.default.post(name: .cassetteMoodIndexReady, object: nil)
    }
    return previous
  }

  /// A Lately mix from a snapshot: `count` songs on the phone matching the profile, at most
  /// three per album, skipping songs played in the last three days, freshly shuffled.
  public static func makeLatelyMix(snapshot: Snapshot, count: Int = 40) -> [Song] {
    var rng = SystemRandomNumberGenerator()
    let ids = ListeningShelves.latelyMix(
      snapshot.songCandidates,
      profile: snapshot.profile,
      playedRecently: snapshot.songsPlayedRecently,
      count: count,
      using: &rng
    )
    return ids.compactMap { snapshot.songsByID[$0] }
  }

  /// Drop the cache, e.g. after music arrives or leaves.
  public static func invalidate() {
    cached = nil
    cachedIndex = nil
    indexBuild = nil
  }

  private static func accountKey(_ account: Account) -> String {
    account.managedObject.objectID.uriRepresentation().absoluteString
  }

  /// The cached index when it is fresh for these keys. The outer optional is "cache
  /// valid", the inner one is the index (nil when there is nothing to index).
  private static func validCachedIndex(accountID: String, tagCount: Int, now: Date) -> MoodIndex?? {
    guard let cachedIndex, cachedIndex.accountID == accountID, cachedIndex.tagCount == tagCount,
          now.timeIntervalSince(cachedIndex.at) < cacheLifetime
    else { return nil }
    return .some(cachedIndex.index)
  }

  private static func build(
    storage: PersistentStorage,
    account: Account,
    tags: [String: LibraryMoodTags],
    now: Date
  )
    -> Snapshot? {
    guard !tags.isEmpty, let index = moodIndex(storage: storage, account: account, now: now)
    else { return nil }
    let library = storage.main.library
    var tagsBySongID = [String: ListeningShelves.TagVector]()
    for candidate in index.songCandidates {
      tagsBySongID[candidate.songID] = candidate.tags
    }

    let since = now.addingTimeInterval(-Double(ListeningShelves.latelyWindowDays) * 86400)
    let entries = library.getScrobbleEntries(for: account, since: since, fetchLimit: 5000)
    var plays = [(date: Date, songID: String)]()
    var albumsPlayedRecently = Set<String>()
    var songsPlayedRecently = Set<String>()
    let recentSongCutoff = now.addingTimeInterval(-Double(ListeningShelves.mixRecentlyPlayedDays) * 86400)
    for entry in entries {
      guard let date = entry.date, let song = entry.playable?.asSong else { continue }
      plays.append((date, song.id))
      if let albumID = song.album?.id, !albumID.isEmpty { albumsPlayedRecently.insert(albumID) }
      if date >= recentSongCutoff { songsPlayedRecently.insert(song.id) }
    }
    let shared = LibraryMoods.shared.sharedProfile
    let profile = shared.isEmpty
      ? ListeningShelves.latelyProfile(plays: plays, tagsForSong: { tagsBySongID[$0] }, now: now)
      : shared
    guard !profile.isEmpty else { return nil }

    return Snapshot(
      profile: profile,
      songsByID: index.songsByID,
      songCandidates: index.songCandidates,
      albumCandidates: index.albumCandidates,
      albumsByID: index.albumsByID,
      albumsPlayedRecently: albumsPlayedRecently,
      songsPlayedRecently: songsPlayedRecently
    )
  }

  // MARK: - Gathering (shared by the snapshot and the mood index)

  /// The tagged songs on this phone as plain values, so the gathering can run in any
  /// context (the main one, or a background one) and hop back as object ids.
  private struct RawIndex: Sendable {
    struct Row: Sendable {
      let songID: String
      let songObjectID: NSManagedObjectID
      let albumID: String
      let albumObjectID: NSManagedObjectID?
      let artistKey: String
      let artistName: String?
      let tags: ListeningShelves.TagVector
    }

    let rows: [Row]
  }

  /// Must run on `context`'s queue. nil when there are no tags, nothing is on the phone,
  /// or no song on the phone is tagged.
  nonisolated private static func gatherRaw(
    context: NSManagedObjectContext,
    accountObjectID: NSManagedObjectID,
    tags: [String: LibraryMoodTags]
  )
    -> RawIndex? {
    guard !tags.isEmpty else { return nil }
    // Song id -> the phone's local id, newest download first when an id repeats (the same
    // order and tie rule as DeviceOwnershipManager.fetchAll + uniquing by first).
    let ownership: NSFetchRequest<DeviceOwnershipMO> = DeviceOwnershipMO.fetchRequest()
    ownership.sortDescriptors = [NSSortDescriptor(key: "downloadedAt", ascending: false)]
    var localIDBySongID = [String: String]()
    for row in (try? context.fetch(ownership)) ?? [] {
      guard let songID = row.subsonicTrackId, localIDBySongID[songID] == nil else { continue }
      localIDBySongID[songID] = row.cassetteLocalId
    }
    guard !localIDBySongID.isEmpty else { return nil }

    let request: NSFetchRequest<SongMO> = SongMO.fetchRequest()
    request.predicate = NSPredicate(
      format: "account == %@ AND id IN %@",
      accountObjectID,
      Array(localIDBySongID.keys)
    )
    request.relationshipKeyPathsForPrefetching = ["album", "artist", "album.artist"]
    request.returnsObjectsAsFaults = false
    var rows = [RawIndex.Row]()
    for songMO in (try? context.fetch(request)) ?? [] {
      guard let localID = localIDBySongID[songMO.id], let songTags = tags[localID] else { continue }
      let album = songMO.album
      let albumID = album?.id ?? ""
      rows.append(RawIndex.Row(
        songID: songMO.id,
        songObjectID: songMO.objectID,
        albumID: albumID,
        albumObjectID: album?.objectID,
        artistKey: album?.artist?.id ?? songMO.artist?.id ?? albumID,
        artistName: album?.artist?.name ?? songMO.artist?.name,
        tags: songTags.vector
      ))
    }
    guard !rows.isEmpty else { return nil }
    return RawIndex(rows: rows)
  }

  /// The index in `context` (the main one): wrappers over faults by object id, no fetch.
  private static func materialize(_ raw: RawIndex, context: NSManagedObjectContext) -> MoodIndex? {
    var songsByID = [String: Song]()
    var songCandidates = [ListeningShelves.SongCandidate]()
    var albumsByID = [String: Album]()
    var songTagsByAlbum = [String: [ListeningShelves.TagVector]]()
    var artistByAlbum = [String: String]()
    var artistNameByAlbum = [String: String]()
    var seenSongs = Set<String>()
    for row in raw.rows {
      guard seenSongs.insert(row.songID).inserted,
            let songMO = context.object(with: row.songObjectID) as? SongMO
      else { continue }
      songsByID[row.songID] = Song(managedObject: songMO)
      songCandidates.append(.init(songID: row.songID, albumID: row.albumID, tags: row.tags))
      guard !row.albumID.isEmpty, let albumObjectID = row.albumObjectID else { continue }
      if albumsByID[row.albumID] == nil,
         let albumMO = context.object(with: albumObjectID) as? AlbumMO {
        albumsByID[row.albumID] = Album(managedObject: albumMO)
      }
      songTagsByAlbum[row.albumID, default: []].append(row.tags)
      if artistByAlbum[row.albumID] == nil { artistByAlbum[row.albumID] = row.artistKey }
      if artistNameByAlbum[row.albumID] == nil, let name = row.artistName, !name.isEmpty {
        artistNameByAlbum[row.albumID] = name
      }
    }
    guard !songsByID.isEmpty else { return nil }
    let albumCandidates = songTagsByAlbum.map { albumID, vectors in
      ListeningShelves.AlbumCandidate(
        albumID: albumID,
        artistID: artistByAlbum[albumID] ?? albumID,
        songTags: vectors
      )
    }
    return MoodIndex(
      songCandidates: songCandidates,
      albumCandidates: albumCandidates,
      albumsByID: albumsByID,
      songsByID: songsByID,
      artistNameByAlbumID: artistNameByAlbum
    )
  }
}
