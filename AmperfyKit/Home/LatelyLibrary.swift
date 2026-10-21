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

import Foundation

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

  private static let cacheLifetime: TimeInterval = 5 * 60
  private static var cached: (at: Date, accountID: String, tagCount: Int, profileSize: Int, snapshot: Snapshot?)?

  /// The snapshot for this account, or nil when there are no mood tags yet or nothing
  /// recent to build a profile from.
  public static func snapshot(storage: PersistentStorage, account: Account, now: Date = Date()) -> Snapshot? {
    let tags = LibraryMoods.shared.byLocalID
    let accountID = account.managedObject.objectID.uriRepresentation().absoluteString
    let profileSize = LibraryMoods.shared.sharedProfile.count
    if let cached, cached.accountID == accountID, cached.tagCount == tags.count,
       cached.profileSize == profileSize, now.timeIntervalSince(cached.at) < cacheLifetime {
      return cached.snapshot
    }
    let snapshot = build(storage: storage, account: account, tags: tags, now: now)
    cached = (now, accountID, tags.count, profileSize, snapshot)
    return snapshot
  }

  /// Drop the cache, e.g. after music arrives or leaves.
  public static func invalidate() { cached = nil }

  private static func build(
    storage: PersistentStorage,
    account: Account,
    tags: [String: LibraryMoodTags],
    now: Date
  )
    -> Snapshot? {
    guard !tags.isEmpty else { return nil }
    let library = storage.main.library
    let localIDBySongID = Dictionary(
      ((try? DeviceOwnershipManager(context: storage.main.context).fetchAll()) ?? [])
        .compactMap { row in row.subsonicTrackId.map { ($0, row.cassetteLocalId) } },
      uniquingKeysWith: { first, _ in first }
    )
    guard !localIDBySongID.isEmpty else { return nil }

    var songsByID = [String: Song]()
    var tagsBySongID = [String: ListeningShelves.TagVector]()
    for song in library.getSongs(for: account) {
      guard let localID = localIDBySongID[song.id], let songTags = tags[localID] else { continue }
      songsByID[song.id] = song
      tagsBySongID[song.id] = songTags.vector
    }
    guard !songsByID.isEmpty else { return nil }

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

    var albumsByID = [String: Album]()
    var songTagsByAlbum = [String: [ListeningShelves.TagVector]]()
    var artistByAlbum = [String: String]()
    var songCandidates = [ListeningShelves.SongCandidate]()
    for (songID, song) in songsByID {
      guard let vector = tagsBySongID[songID] else { continue }
      let albumID = song.album?.id ?? ""
      songCandidates.append(.init(songID: songID, albumID: albumID, tags: vector))
      guard let album = song.album, !albumID.isEmpty else { continue }
      albumsByID[albumID] = album
      songTagsByAlbum[albumID, default: []].append(vector)
      if artistByAlbum[albumID] == nil {
        artistByAlbum[albumID] = album.artist?.id ?? song.artist?.id ?? albumID
      }
    }
    let albumCandidates = songTagsByAlbum.map { albumID, vectors in
      ListeningShelves.AlbumCandidate(
        albumID: albumID,
        artistID: artistByAlbum[albumID] ?? albumID,
        songTags: vectors
      )
    }
    return Snapshot(
      profile: profile,
      songsByID: songsByID,
      songCandidates: songCandidates,
      albumCandidates: albumCandidates,
      albumsByID: albumsByID,
      albumsPlayedRecently: albumsPlayedRecently,
      songsPlayedRecently: songsPlayedRecently
    )
  }
}
