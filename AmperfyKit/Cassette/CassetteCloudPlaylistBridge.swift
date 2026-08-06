//
//  CassetteCloudPlaylistBridge.swift
//  AmperfyKit
//
//  Cassette fork — cloud playlist cutover.
//
//  Replaces Subsonic getPlaylists / createPlaylist / updatePlaylist for the
//  Cassette UX. Materialises user_playlists into local PlaylistMO rows (id =
//  cloud UUID) so PlaylistsVC / PlaylistDetailVC / PlaylistSelectorVC keep
//  working, and writes every mutation back through /api/sync/playlists.
//
//  This program is free software: you can redistribute it and/or modify
//  it under the terms of the GNU General Public License as published by
//  the Free Software Foundation, either version 3 of the License, or
//  (at your option) any later version.
//

import CoreData
import Foundation
import os.log
import UIKit

@MainActor
public enum CassetteCloudPlaylistBridge {
  private static let log = OSLog(subsystem: "digital.cassette", category: "cloud-playlists")
  private static let hubImportDoneKey = "cassette.hubPlaylistImportDone"

  public static var isCloudAvailable: Bool {
    CassetteSyncAPI.bearerToken != nil
  }

  // MARK: - Item-id / cover URL side maps (cloud fields ↔ local playlist id)

  nonisolated private static func itemIdsKey(_ playlistId: String) -> String {
    "cassette.cloudPlaylistItemIds." + playlistId
  }

  nonisolated private static func coverUrlKey(_ playlistId: String) -> String {
    "cassette.cloudPlaylistCoverUrl." + playlistId
  }

  public static func storedItemIds(for playlistId: String) -> [String] {
    UserDefaults.standard.stringArray(forKey: itemIdsKey(playlistId)) ?? []
  }

  /// Absolute cover URL from the last cloud sync, if any.
  nonisolated public static func storedCoverUrl(for playlistId: String) -> String? {
    guard !playlistId.isEmpty,
          let url = UserDefaults.standard.string(forKey: coverUrlKey(playlistId)),
          !url.isEmpty
    else { return nil }
    return url
  }

  /// Bundled PNG for curated web presets (SVG on site; phones can't paint SVG).
  nonisolated public static func bundledPresetCoverImage(forCoverUrl urlString: String) -> UIImage? {
    guard let name = bundledPresetAssetName(forCoverUrl: urlString) else { return nil }
    return UIImage(named: name, in: Bundle(for: EntityImageView.self), compatibleWith: nil)
  }

  nonisolated public static func bundledPresetAssetName(forCoverUrl urlString: String) -> String? {
    guard
      let regex = try? NSRegularExpression(
        pattern: #"playlist-covers/(preset-\d+)\.(?:svg|png)"#,
        options: .caseInsensitive
      ),
      let match = regex.firstMatch(
        in: urlString,
        range: NSRange(urlString.startIndex..., in: urlString)
      ),
      match.numberOfRanges >= 2,
      let slugRange = Range(match.range(at: 1), in: urlString)
    else { return nil }
    // Asset catalog: playlist-cover-preset-07
    return "playlist-cover-\(urlString[slugRange].lowercased())"
  }

  // MARK: - Local-first materialized pick covers (offline / cold launch)

  // A playlist's own cover comes from three places: a bundled abstract preset
  // (already local), or a user PICK — a remote uploaded image. The pick used to be
  // re-fetched over the network on every render and never persisted, so it blanked
  // on a cold/offline launch (the one image type that wasn't local-first). We now
  // cache the picked bytes on disk keyed by playlist id; the source url carries
  // ?v=updated_at, so a changed pick misses the cache and re-materializes, and a
  // stale file is overwritten. Presets never come here — they render from the bundle.

  nonisolated private static func coverCacheDir() -> URL? {
    guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first
    else { return nil }
    let dir = caches.appendingPathComponent("cassette-playlist-covers", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }

  nonisolated private static func coverFileURL(_ playlistId: String) -> URL? {
    guard !playlistId.isEmpty, let dir = coverCacheDir() else { return nil }
    return dir.appendingPathComponent(playlistId + ".img")
  }

  nonisolated private static func materializedUrlKey(_ playlistId: String) -> String {
    "cassette.playlistCoverMaterializedUrl." + playlistId
  }

  /// The playlist's picked cover already on disk, IF it was materialized for this
  /// exact url — so a cold/offline launch renders it with no network.
  nonisolated public static func materializedCoverImage(for playlistId: String, url: String) -> UIImage? {
    guard UserDefaults.standard.string(forKey: materializedUrlKey(playlistId)) == url,
          let file = coverFileURL(playlistId),
          let data = try? Data(contentsOf: file),
          let image = UIImage(data: data)
    else { return nil }
    return image
  }

  /// Persist freshly-downloaded pick bytes so the next cold/offline launch reads local.
  nonisolated public static func storeMaterializedCover(
    _ data: Data,
    for playlistId: String,
    url: String
  ) {
    guard let file = coverFileURL(playlistId) else { return }
    do {
      try data.write(to: file, options: .atomic)
      UserDefaults.standard.set(url, forKey: materializedUrlKey(playlistId))
    } catch {
      // Best-effort cache — a failed write just means the next launch re-fetches.
    }
  }

  /// Drop a playlist's materialized cover (on delete / cover cleared).
  nonisolated private static func removeMaterializedCover(_ playlistId: String) {
    if let file = coverFileURL(playlistId) { try? FileManager.default.removeItem(at: file) }
    UserDefaults.standard.removeObject(forKey: materializedUrlKey(playlistId))
  }

  /// UserDefaults only — safe to call from a background Core Data perform.
  nonisolated private static func storeItemIds(_ ids: [String], for playlistId: String) {
    UserDefaults.standard.set(ids, forKey: itemIdsKey(playlistId))
  }

  nonisolated private static func storeCoverUrl(_ url: String?, for playlistId: String) {
    guard !playlistId.isEmpty else { return }
    if let normalized = Self.normalizeCoverUrl(url) {
      UserDefaults.standard.set(normalized, forKey: coverUrlKey(playlistId))
    } else {
      UserDefaults.standard.removeObject(forKey: coverUrlKey(playlistId))
      // Cover cleared / playlist gone — drop the on-disk pick too. A CHANGED pick
      // reuses the same per-playlist file (overwritten on re-materialize), so only
      // removal needs cleanup; no orphans accumulate.
      removeMaterializedCover(playlistId)
    }
  }

  /// Absolute http(s) URL phones can load. Relative site paths and preset
  /// SVGs are normalized the same way the sync API does (defense in depth).
  nonisolated private static func normalizeCoverUrl(_ url: String?) -> String? {
    guard var out = url?.trimmingCharacters(in: .whitespacesAndNewlines), !out.isEmpty
    else { return nil }
    if out.hasPrefix("/") {
      out = "https://cassette.digital" + out
    }
    if out.contains("/playlist-covers/preset-"), out.hasSuffix(".svg") {
      out = String(out.dropLast(4)) + ".png"
    }
    return out
  }

  private static func newUUID() -> String {
    UUID().uuidString.lowercased()
  }

  // MARK: - Resolve cassette_local_id → Song

  public static func resolveSong(
    cassetteLocalId: String,
    mbid: String?,
    storage: PersistentStorage,
    account: Account
  ) -> Song? {
    let ownership = DeviceOwnershipManager(context: storage.main.context)
    let owned =
      (mbid.flatMap { try? ownership.fetchOne(mbid: $0) })
      ?? (try? ownership.fetchOne(cassetteLocalId: cassetteLocalId))
    guard let owned, let subsonicId = owned.subsonicTrackId else { return nil }
    return storage.main.library.getSong(for: account, id: subsonicId)
  }

  public static func cassetteLocalId(for song: Song) -> String {
    let ownership = DeviceOwnershipManager(context: song.managedObject.managedObjectContext!)
    if let owned = try? ownership.fetchOne(subsonicTrackId: song.id) {
      let lid = owned.cassetteLocalId
      if !lid.isEmpty { return lid }
    }
    return CassetteLocalID.compute(
      artist: song.artist?.name ?? song.album?.artist?.name ?? "",
      title: song.title,
      durationSeconds: song.duration
    )
  }

  // MARK: - Sync down (cloud → Core Data)

  public static func syncDownPlaylists(
    storage: PersistentStorage,
    accountObjectId: NSManagedObjectID
  ) async throws {
    guard isCloudAvailable else { return }

    let cloud = try await CassetteSyncAPI.shared.listPlaylists(includeItems: true)
    let cloudIds = Set(cloud.map(\.id))

    try await storage.async.perform { asyncCompanion in
      let account = asyncCompanion.library.getAccount(managedObjectId: accountObjectId)
      let existing = asyncCompanion.library.getPlaylists(for: account)

      // Drop local playlists that are no longer in the cloud. Skip empty-id
      // rows (Amperfy player queues) and anything still linked as a player
      // context/queue playlist.
      for pl in existing where !pl.id.isEmpty && !cloudIds.contains(pl.id) {
        let mo = pl.managedObject
        if mo.playersContextPlaylist != nil
          || mo.playersPodcastPlaylist != nil
          || mo.playersShuffledContextPlaylist != nil
          || mo.playersUserQueuePlaylist != nil {
          continue
        }
        asyncCompanion.library.deletePlaylist(pl)
        storeCoverUrl(nil, for: pl.id)
        UserDefaults.standard.removeObject(forKey: itemIdsKey(pl.id))
      }

      for remote in cloud {
        var playlist = existing.first(where: { $0.id == remote.id })
        if playlist == nil {
          let created = asyncCompanion.library.createPlaylist(account: account)
          created.id = remote.id
          playlist = created
        }
        guard let playlist else { continue }
        playlist.name = remote.name
        playlist.updateChangeDate()
        // cassette (cover unification): the user's own pick wins; else the server's
        // deterministic preset (rendered from the bundled asset — local + offline).
        storeCoverUrl(remote.coverImageUrl ?? remote.derivedCoverUrl, for: remote.id)

        // Rebuild items from resolved songs.
        playlist.removeAllItems()
        var itemIds: [String] = []
        let items = (remote.items ?? []).filter { $0.removedAt == nil }
          .sorted { $0.position < $1.position }
        for item in items {
          let ownership = DeviceOwnershipManager(context: asyncCompanion.context)
          let owned =
            (item.mbid.flatMap { try? ownership.fetchOne(mbid: $0) })
            ?? (try? ownership.fetchOne(cassetteLocalId: item.cassetteLocalId))
          guard let owned, let sid = owned.subsonicTrackId,
                let song = asyncCompanion.library.getSong(for: account, id: sid)
          else { continue }
          playlist.append(playable: song)
          itemIds.append(item.id)
        }
        playlist.remoteSongCount = items.count
        storeItemIds(itemIds, for: remote.id)
      }
    }
    os_log(
      "Cloud playlists: synced %d playlists",
      log: log,
      type: .info,
      cloud.count
    )
  }

  public static func syncDownPlaylistDetail(
    playlist: Playlist,
    storage: PersistentStorage,
    accountObjectId: NSManagedObjectID
  ) async throws {
    guard isCloudAvailable, !playlist.id.isEmpty else { return }
    let remote = try await CassetteSyncAPI.shared.getPlaylist(id: playlist.id)
    let playlistObjectId = playlist.managedObject.objectID
    try await storage.async.perform { asyncCompanion in
      let account = asyncCompanion.library.getAccount(managedObjectId: accountObjectId)
      let playlistAsync = Playlist(
        library: asyncCompanion.library,
        managedObject: asyncCompanion.context.object(with: playlistObjectId) as! PlaylistMO
      )
      playlistAsync.name = remote.name
      // cassette (cover unification): user pick wins; else the server preset (bundled).
      storeCoverUrl(remote.coverImageUrl ?? remote.derivedCoverUrl, for: remote.id)
      playlistAsync.removeAllItems()
      var itemIds: [String] = []
      let items = (remote.items ?? []).filter { $0.removedAt == nil }
        .sorted { $0.position < $1.position }
      for item in items {
        let ownership = DeviceOwnershipManager(context: asyncCompanion.context)
        let owned =
          (item.mbid.flatMap { try? ownership.fetchOne(mbid: $0) })
          ?? (try? ownership.fetchOne(cassetteLocalId: item.cassetteLocalId))
        guard let owned, let sid = owned.subsonicTrackId,
              let song = asyncCompanion.library.getSong(for: account, id: sid)
        else { continue }
        playlistAsync.append(playable: song)
        itemIds.append(item.id)
      }
      playlistAsync.remoteSongCount = items.count
      storeItemIds(itemIds, for: remote.id)
    }
  }

  // MARK: - Uploads (local → cloud)

  public static func createPlaylistRemote(playlist: Playlist) async throws {
    guard isCloudAvailable else { return }
    let id = playlist.id.isEmpty ? newUUID() : playlist.id
    if playlist.id.isEmpty { playlist.id = id }
    _ = try await CassetteSyncAPI.shared.createPlaylist(id: id, name: playlist.name)
    storeItemIds([], for: id)
    os_log("Cloud playlists: created %{public}@", log: log, type: .info, id)
  }

  public static func updateName(playlist: Playlist) async throws {
    guard isCloudAvailable else { return }
    if playlist.id.isEmpty {
      try await createPlaylistRemote(playlist: playlist)
      return
    }
    _ = try await CassetteSyncAPI.shared.updatePlaylist(id: playlist.id, name: playlist.name)
  }

  public static func addSongs(playlist: Playlist, songs: [Song]) async throws {
    guard isCloudAvailable, !songs.isEmpty else { return }
    if playlist.id.isEmpty {
      try await createPlaylistRemote(playlist: playlist)
    }
    var ids = storedItemIds(for: playlist.id)
    var ops: [CassettePlaylistOp] = []
    let base = Double(Date().timeIntervalSince1970 * 1000)
    let addedAt = ISO8601DateFormatter().string(from: Date())
    for (i, song) in songs.enumerated() {
      let itemId = newUUID()
      let localId = cassetteLocalId(for: song)
      ops.append(
        .add(
          itemId: itemId,
          cassetteLocalId: localId,
          mbid: song.musicBrainzId,
          position: base + Double(i),
          addedAt: addedAt,
          addedByDevice: "ios"
        )
      )
      ids.append(itemId)
    }
    let updated = try await CassetteSyncAPI.shared.applyPlaylistOps(
      playlistId: playlist.id,
      ops: ops
    )
    if let items = updated.items?.filter({ $0.removedAt == nil }).sorted(by: {
      $0.position < $1.position
    }) {
      storeItemIds(items.map(\.id), for: playlist.id)
    } else {
      storeItemIds(ids, for: playlist.id)
    }
  }

  public static func deleteSong(playlist: Playlist, index: Int) async throws {
    guard isCloudAvailable, !playlist.id.isEmpty else { return }
    var ids = storedItemIds(for: playlist.id)
    if index < 0 || index >= ids.count {
      let remote = try await CassetteSyncAPI.shared.getPlaylist(id: playlist.id)
      ids = (remote.items ?? []).filter { $0.removedAt == nil }
        .sorted { $0.position < $1.position }.map(\.id)
      storeItemIds(ids, for: playlist.id)
      guard index >= 0, index < ids.count else { return }
    }
    let itemId = ids[index]
    _ = try await CassetteSyncAPI.shared.applyPlaylistOps(
      playlistId: playlist.id,
      ops: [.remove(itemId: itemId)]
    )
    ids.remove(at: index)
    storeItemIds(ids, for: playlist.id)
  }

  public static func updateOrder(playlist: Playlist) async throws {
    guard isCloudAvailable, !playlist.id.isEmpty else { return }
    var ids = storedItemIds(for: playlist.id)
    let playables = playlist.playables
    if ids.count != playables.count {
      let remote = try await CassetteSyncAPI.shared.getPlaylist(id: playlist.id)
      ids = (remote.items ?? []).filter { $0.removedAt == nil }
        .sorted { $0.position < $1.position }.map(\.id)
    }
    guard ids.count == playables.count, !ids.isEmpty else { return }
    let base = Double(Date().timeIntervalSince1970 * 1000)
    let ops: [CassettePlaylistOp] = ids.enumerated().map { i, itemId in
      .reorder(itemId: itemId, position: base + Double(i))
    }
    _ = try await CassetteSyncAPI.shared.applyPlaylistOps(playlistId: playlist.id, ops: ops)
    storeItemIds(ids, for: playlist.id)
  }

  public static func deletePlaylist(id: String) async throws {
    guard isCloudAvailable, !id.isEmpty else { return }
    try await CassetteSyncAPI.shared.deletePlaylist(id: id)
    UserDefaults.standard.removeObject(forKey: itemIdsKey(id))
    storeCoverUrl(nil, for: id)
  }

  // MARK: - One-shot hub Subsonic → cloud import

  /// Pull any leftover Subsonic playlists into user_playlists once, then never
  /// again. Best-effort: empty/unreachable hub is fine. Does not mutate Core
  /// Data — reads Subsonic XML and writes straight to the cloud.
  /// Internal (not public): `SubsonicServerApi` is an internal type.
  static func importHubPlaylistsIfNeeded(
    subsonicApi: SubsonicServerApi,
    storage: PersistentStorage,
    accountObjectId: NSManagedObjectID
  ) async {
    guard isCloudAvailable else { return }
    guard !UserDefaults.standard.bool(forKey: hubImportDoneKey) else { return }
    defer { UserDefaults.standard.set(true, forKey: hubImportDoneKey) }

    do {
      let response = try await subsonicApi.requestPlaylists()
      let hubPlaylists = parseHubPlaylistSummaries(from: response.data)
      guard !hubPlaylists.isEmpty else {
        os_log("Cloud playlists: hub import — no Subsonic playlists", log: log, type: .info)
        return
      }

      let existing = (try? await CassetteSyncAPI.shared.listPlaylists()) ?? []
      let existingNames = Set(existing.map(\.name))

      for hub in hubPlaylists {
        if existingNames.contains(hub.name) { continue }
        let cloudId = newUUID()
        _ = try await CassetteSyncAPI.shared.createPlaylist(id: cloudId, name: hub.name)

        let songsResponse = try await subsonicApi.requestPlaylistSongs(id: hub.id)
        let songIds = parseHubSongIds(from: songsResponse.data)
        let base = Double(Date().timeIntervalSince1970 * 1000)

        // Resolve songs on the Core Data queue, then build ops on the main actor
        // (avoids mutating a captured [[String: Any]] inside a @Sendable closure).
        let resolved: [HubImportSong] = try await storage.async.performAndGet {
          asyncCompanion in
          let account = asyncCompanion.library.getAccount(managedObjectId: accountObjectId)
          var out: [HubImportSong] = []
          for (i, sid) in songIds.enumerated() {
            guard let song = asyncCompanion.library.getSong(for: account, id: sid) else {
              continue
            }
            let localId = CassetteLocalID.compute(
              artist: song.artist?.name ?? song.album?.artist?.name ?? "",
              title: song.title,
              durationSeconds: song.duration
            )
            out.append(HubImportSong(localId: localId, index: i))
          }
          return out
        }

        if !resolved.isEmpty {
          let addedAt = ISO8601DateFormatter().string(from: Date())
          let ops: [CassettePlaylistOp] = resolved.map { song in
            .add(
              itemId: UUID().uuidString.lowercased(),
              cassetteLocalId: song.localId,
              mbid: nil,
              position: base + Double(song.index),
              addedAt: addedAt,
              addedByDevice: "ios-hub-import"
            )
          }
          _ = try await CassetteSyncAPI.shared.applyPlaylistOps(
            playlistId: cloudId,
            ops: ops
          )
        }
      }
      os_log(
        "Cloud playlists: hub import done (%d)",
        log: log,
        type: .info,
        hubPlaylists.count
      )
    } catch {
      os_log(
        "Cloud playlists: hub import skipped/failed: %{public}@",
        log: log,
        type: .info,
        String(describing: error)
      )
    }
  }

  /// Extract `(id, name)` pairs from a Subsonic `getPlaylists` XML body.
  private static func parseHubPlaylistSummaries(from data: Data) -> [(id: String, name: String)] {
    guard let xml = String(data: data, encoding: .utf8) else { return [] }
    var out: [(id: String, name: String)] = []
    let pattern = #"<playlist\b[^>]*>"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let ns = xml as NSString
    for match in regex.matches(in: xml, range: NSRange(location: 0, length: ns.length)) {
      let tag = ns.substring(with: match.range)
      guard let id = attr(tag, "id"), let name = attr(tag, "name"), !id.isEmpty else {
        continue
      }
      out.append((id: id, name: name.htmlUnescaped))
    }
    return out
  }

  private static func parseHubSongIds(from data: Data) -> [String] {
    guard let xml = String(data: data, encoding: .utf8) else { return [] }
    var out: [String] = []
    let pattern = #"<entry\b[^>]*\bid="([^"]+)"[^>]*>"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let ns = xml as NSString
    for match in regex.matches(in: xml, range: NSRange(location: 0, length: ns.length)) {
      if match.numberOfRanges >= 2 {
        out.append(ns.substring(with: match.range(at: 1)))
      }
    }
    if out.isEmpty {
      let entryPattern = #"<entry\b[^>]*>"#
      if let entryRegex = try? NSRegularExpression(pattern: entryPattern) {
        for match in entryRegex.matches(in: xml, range: NSRange(location: 0, length: ns.length)) {
          let tag = ns.substring(with: match.range)
          if let id = attr(tag, "id") { out.append(id) }
        }
      }
    }
    return out
  }

  private static func attr(_ tag: String, _ name: String) -> String? {
    let pattern = #"\#(name)="([^"]*)""#
    guard let regex = try? NSRegularExpression(pattern: pattern),
          let match = regex.firstMatch(
            in: tag,
            range: NSRange(location: 0, length: (tag as NSString).length)
          ),
          match.numberOfRanges >= 2
    else { return nil }
    return (tag as NSString).substring(with: match.range(at: 1))
  }
}

/// Sendable song identity collected inside a Core Data perform for hub import.
private struct HubImportSong: Sendable {
  let localId: String
  let index: Int
}

private extension String {
  var htmlUnescaped: String {
    replacingOccurrences(of: "&amp;", with: "&")
      .replacingOccurrences(of: "&lt;", with: "<")
      .replacingOccurrences(of: "&gt;", with: ">")
      .replacingOccurrences(of: "&quot;", with: "\"")
      .replacingOccurrences(of: "&apos;", with: "'")
  }
}
