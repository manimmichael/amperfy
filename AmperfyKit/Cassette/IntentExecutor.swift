//
//  IntentExecutor.swift
//  AmperfyKit
//
//  Cassette fork — Layer 3 Phase 3.1 (Transfer Mechanism).
//
//  Polls cassette.digital for actionable sync intents and drives them to
//  completion: marks syncing, checks the Cassette Player is reachable on the
//  LAN, resolves the album's track list server-side, and enqueues background
//  downloads (or removals). State transitions are reported back so the admin
//  test tool can observe progress.
//
//  Idempotent by design: re-running an intent skips already-owned tracks and
//  already-in-flight downloads, then completes once everything is present.
//  This makes crash/relaunch recovery and the 30s foreground poll safe.
//
//  Phase 3.1 handles `scope == "album"` only. Other scopes fail with
//  `unsupported_scope_in_phase_31`.
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
import os.log
import UIKit

@MainActor
public final class IntentExecutor {
  public static let shared = IntentExecutor()

  private let log = OSLog(subsystem: "Amperfy", category: "IntentExecutor")
  private let api = CassetteSyncAPI.shared
  private let transferSession = CassetteTransferSession.shared

  private var isRunning = false
  // Once-per-launch device registration (user_devices upsert). The header
  // keep-alive rides every request; this full registration also refreshes
  // platform/model/app_version.
  private var hasRegisteredDevice = false

  public init() {}

  /// Entry point for polling (foreground + 30s timer). No-op if no account or
  /// no bearer token yet, or if a run is already in progress.
  public func handlePendingIntents() async {
    // Verbose-but-temporary logging (Phase 3.1) — `print` is guaranteed
    // visible in the Xcode console, unlike os_log .info which is filtered.
    print("Cassette poll: handlePendingIntents() entered")
    guard !isRunning else {
      print("Cassette poll: skip - a run is already in progress")
      return
    }
    guard CassetteSyncAPI.bearerToken != nil else {
      print("Cassette poll: skip - NO BEARER TOKEN (re-link in Settings > Developer)")
      return
    }
    guard AmperKit.shared.storage.settings.accounts.active != nil else {
      print("Cassette poll: skip - no active account")
      return
    }

    isRunning = true
    defer { isRunning = false }

    if !hasRegisteredDevice {
      do {
        try await api.registerDevice()
        hasRegisteredDevice = true
      } catch {
        // Non-fatal: the X-Cassette-Device-Id header on the poll below still
        // upserts the registry row. Retry the full registration next poll.
        print("Cassette poll: device registration failed - \(error.localizedDescription)")
      }
    }

    let intents: [CassetteSyncIntent]
    do {
      print("Cassette poll: fetching pending intents from cassette.digital")
      intents = try await api.getActionableIntents()
    } catch {
      print("Cassette poll: failed to fetch intents - \(error.localizedDescription)")
      os_log(
        "failed to fetch intents: %{public}@",
        log: self.log,
        type: .error,
        error.localizedDescription
      )
      return
    }

    print("Cassette poll: received \(intents.count) actionable intent(s)")
    for intent in intents {
      await executeIntent(intent)
    }

    // Fast Album Art: fill covers for albums already on the device — not just
    // fresh transfers. Off-main, throttled, idempotent; reconciles every sync
    // so existing albums get and keep their art.
    if let accountInfo = AmperKit.shared.storage.settings.accounts.active {
      await backfillOwnedAlbumCovers(accountInfo: accountInfo)
    }
  }

  /// Fast Album Art backfill: albums already on the device whose cover was
  /// never fetched (transferred before cover-bundling, or never viewed) get
  /// filled here. Idempotent and cheap — enumerate owned albums off-main, skip
  /// any that already have a local cover, and hand the rest to the artwork
  /// download manager: an actor-based, 2-wide-throttled, off-main queue that
  /// pulls the materialized cover.jpg from the LAN Player's getCoverArt and
  /// lands the same `.CustomImage` end-state as a transfer (honoring
  /// artworkDownloadSetting and de-duping in-flight).
  private func backfillOwnedAlbumCovers(accountInfo: AccountInfo) async {
    // Enumerate + gate OFF the main thread, on a background context.
    let artworkIDs: [NSManagedObjectID]
    do {
      artworkIDs = try await AmperKit.shared.storage.async.performAndGet { asyncCompanion in
        let context = asyncCompanion.context
        let albumIds = DeviceOwnershipManager(context: context).fetchOwnedAlbumIds()
        guard !albumIds.isEmpty else { return [NSManagedObjectID]() }

        let request: NSFetchRequest<AlbumMO> = AlbumMO.fetchRequest()
        request.predicate = NSPredicate(format: "id IN %@", Array(albumIds))
        request.returnsObjectsAsFaults = false
        let albumMOs = (try? context.fetch(request)) ?? []

        var ids = [NSManagedObjectID]()
        for albumMO in albumMOs {
          guard let artwork = Album(managedObject: albumMO).artwork else { continue }
          // Cheap gate: skip albums that already have a local cover.
          if artwork.status == .CustomImage,
             let path = artwork.imagePath,
             FileManager.default.fileExists(atPath: path) {
            continue
          }
          ids.append(artwork.managedObject.objectID)
        }
        return ids
      }
    } catch {
      return
    }
    guard !artworkIDs.isEmpty else { return }

    // Re-wrap on the main context (cheap object-id lookups) and enqueue. The
    // download manager itself runs the fetches off-main, throttled, idempotent.
    let mainContext = AmperKit.shared.storage.main.context
    let artworks = artworkIDs.compactMap { id -> Artwork? in
      guard let mo = try? mainContext.existingObject(with: id) as? ArtworkMO else { return nil }
      return Artwork(managedObject: mo)
    }
    guard !artworks.isEmpty else { return }
    print("Cassette poll: backfilling covers for \(artworks.count) owned album(s)")
    AmperKit.shared.getMeta(accountInfo).artworkDownloadManager.download(objects: artworks)
  }

  private func executeIntent(_ intent: CassetteSyncIntent) async {
    print(
      "Cassette poll: executing intent \(intent.id) " +
        "scope=\(intent.scope) kind=\(intent.intentKind) target=\(intent.targetId)"
    )
    // Phase 3.1: album scope only.
    guard intent.scope == "album" else {
      print("Cassette poll: intent \(intent.id) - unsupported scope '\(intent.scope)', failing")
      try? await api.updateIntent(
        id: intent.id,
        state: "failed",
        error: "unsupported_scope_in_phase_31"
      )
      return
    }

    if intent.state == "pending" {
      try? await api.updateIntent(id: intent.id, state: "syncing")
    }

    // Reachability: the Cassette Player must be on the LAN to pull files.
    let reachable = await isCassettePlayerReachable()
    print("Cassette poll: intent \(intent.id) - Cassette Player reachable=\(reachable)")
    guard reachable else {
      try? await api.updateIntent(
        id: intent.id,
        state: "waiting",
        error: "cassette_player_unreachable"
      )
      return
    }

    let tracks: [CassetteSyncTrack]
    let albumCover: CassetteSyncAlbumCover?
    let albumArtist: CassetteSyncArtist?
    do {
      let response = try await api.getIntentTracks(intentId: intent.id)
      tracks = response.tracks
      albumCover = response.cover
      albumArtist = response.artist
    } catch {
      print(
        "Cassette poll: intent \(intent.id) - track resolve failed: \(error.localizedDescription)"
      )
      try? await api.updateIntent(
        id: intent.id,
        state: "failed",
        error: "track_resolve_failed"
      )
      return
    }
    print("Cassette poll: intent \(intent.id) - resolved \(tracks.count) track(s)")

    let manager = DeviceOwnershipManager(context: AmperKit.shared.storage.main.context)

    if intent.intentKind == "remove" {
      await executeRemoval(intent: intent, tracks: tracks, manager: manager)
      return
    }

    // Add: enqueue downloads for any track not already owned.
    guard let accountInfo = AmperKit.shared.storage.settings.accounts.active else { return }
    let backendApi = AmperKit.shared.getMeta(accountInfo).backendApi

    var enqueued = 0
    for track in tracks {
      if manager.exists(cassetteLocalId: track.cassetteLocalId) { continue }
      do {
        let url = try await backendApi
          .cassetteDownloadUrl(forSubsonicTrackId: track.subsonicTrackId)
        await transferSession.enqueueDownload(
          url: url,
          cassetteLocalId: track.cassetteLocalId,
          mbid: track.mbid,
          subsonicTrackId: track.subsonicTrackId,
          fileExtension: track.fileExtension,
          intentId: intent.id
        )
        enqueued += 1
        print("Cassette poll: intent \(intent.id) - enqueued download for \(track.cassetteLocalId)")
      } catch {
        print(
          "Cassette poll: intent \(intent.id) - failed to build download URL " +
            "for \(track.subsonicTrackId): \(error.localizedDescription)"
        )
        os_log(
          "failed to build download URL for %{public}@: %{public}@",
          log: self.log,
          type: .error,
          track.subsonicTrackId,
          error.localizedDescription
        )
      }
    }
    print("Cassette poll: intent \(intent.id) - enqueued \(enqueued) new download(s)")

    // Fast Album Art: bundle the album cover so it's on-device the moment the
    // album is — no display-time getCoverArt fetch. Best-effort; on failure the
    // existing lazy artwork path still applies. Idempotent (skips once local).
    if let albumCover {
      await materializeAlbumCover(albumCover, tracks: tracks, accountInfo: accountInfo)
    }
    if let albumArtist {
      await materializeArtistImage(albumArtist, tracks: tracks, accountInfo: accountInfo)
    }

    // Complete the intent once everything it covers is on disk. Otherwise
    // leave it `syncing`; a later poll (or the next foreground) finalizes it
    // as background downloads land.
    let allOwned = tracks.allSatisfy { manager.exists(cassetteLocalId: $0.cassetteLocalId) }
    if allOwned {
      print("Cassette poll: intent \(intent.id) - all tracks owned, marking complete")
      try? await api.updateIntent(id: intent.id, state: "complete")
    } else {
      print("Cassette poll: intent \(intent.id) - downloads in flight, leaving syncing")
    }
  }

  /// Download the album's bundled cover and wire it into the album's `Artwork`
  /// so it displays locally with no network getCoverArt fetch — the same move
  /// `SubsonicArtworkDownloadDelegate` makes on a successful fetch, but sourced
  /// from the cassette.digital cover URL bundled in the tracks response.
  ///
  /// Best-effort and idempotent: honors the artwork-download preference, skips
  /// when a local cover already exists, and silently falls back to the existing
  /// lazy artwork path on any failure (album/artwork not yet in the library,
  /// download error, etc.). The full original is stored verbatim — full image,
  /// square, no crop.
  private func materializeAlbumCover(
    _ cover: CassetteSyncAlbumCover,
    tracks: [CassetteSyncTrack],
    accountInfo: AccountInfo
  ) async {
    // Honor the artwork-download preference (e.g. user set it to "never").
    guard AmperKit.shared.storage.settings.accounts
      .getSetting(accountInfo).read.artworkDownloadSetting != .never else { return }

    let context = AmperKit.shared.storage.main.context
    let subsonicIds = tracks.map(\.subsonicTrackId)

    // 1. Resolve the album's Artwork from any of the intent's tracks
    //    (SongMO.id == subsonic_track_id). Skip if a local cover already exists.
    var artworkObjectID: NSManagedObjectID?
    var remoteInfo: ArtworkRemoteInfo?
    context.performAndWait {
      let request: NSFetchRequest<SongMO> = SongMO.fetchRequest()
      request.predicate = NSPredicate(format: "id IN %@", subsonicIds)
      request.fetchLimit = 1
      guard let songMO = try? context.fetch(request).first,
            let artwork = Song(managedObject: songMO).album?.artwork else { return }
      if artwork.status == .CustomImage,
         let path = artwork.imagePath,
         FileManager.default.fileExists(atPath: path) {
        return // already local — nothing to do
      }
      artworkObjectID = artwork.managedObject.objectID
      remoteInfo = artwork.remoteInfo
    }
    guard let artworkObjectID, let remoteInfo else { return }

    // 2. Download the full cover (stored verbatim).
    guard let url = URL(string: cover.url) else { return }
    let data: Data
    do {
      let (downloaded, response) = try await URLSession.shared.data(from: url)
      guard let http = response as? HTTPURLResponse,
            (200 ..< 300).contains(http.statusCode), !downloaded.isEmpty
      else { return }
      data = downloaded
    } catch {
      print("Cassette poll: cover download failed - \(error.localizedDescription)")
      return
    }

    // 3. Write the file into the artwork dir and flip the Artwork to
    //    .CustomImage — identical to SubsonicArtworkDownloadDelegate, so
    //    imagePath / LibraryEntityImage then serve it with zero network.
    let fileManager = CacheFileManager.shared
    guard let relFilePath = fileManager.createRelPath(for: remoteInfo, account: accountInfo),
          let absFilePath = fileManager.getAbsoluteAmperfyPath(relFilePath: relFilePath)
    else { return }
    do {
      try fileManager.writeDataExcludedFromBackup(
        data: data,
        to: absFilePath,
        accountInfo: accountInfo
      )
    } catch {
      print("Cassette poll: cover write failed - \(error.localizedDescription)")
      return
    }
    context.performAndWait {
      guard let artworkMO = try? context.existingObject(with: artworkObjectID) as? ArtworkMO
      else { return }
      let artwork = Artwork(managedObject: artworkMO)
      artwork.status = .CustomImage
      artwork.relFilePath = relFilePath
      try? context.save()
    }
    print("Cassette poll: materialized album cover (\(data.count) bytes)")
  }

  /// Download the album artist's bundled image and wire it into the artist's
  /// `Artwork` — the same move as `materializeAlbumCover`, for the album
  /// artist (the artist list + detail already render `Artist.artwork`, so once
  /// it's `.CustomImage` they show it with no network fetch). Best-effort and
  /// idempotent: honors the artwork-download preference, skips when a local
  /// artist image already exists, and no-ops on any failure.
  private func materializeArtistImage(
    _ artistImage: CassetteSyncArtist,
    tracks: [CassetteSyncTrack],
    accountInfo: AccountInfo
  ) async {
    guard AmperKit.shared.storage.settings.accounts
      .getSetting(accountInfo).read.artworkDownloadSetting != .never else { return }

    let context = AmperKit.shared.storage.main.context
    let subsonicIds = tracks.map(\.subsonicTrackId)

    // Resolve the album artist's Artwork from any of the intent's tracks (the
    // catalog artist is the album's artist). Skip if already local.
    var artworkObjectID: NSManagedObjectID?
    var remoteInfo: ArtworkRemoteInfo?
    context.performAndWait {
      let request: NSFetchRequest<SongMO> = SongMO.fetchRequest()
      request.predicate = NSPredicate(format: "id IN %@", subsonicIds)
      request.fetchLimit = 1
      guard let songMO = try? context.fetch(request).first,
            let artwork = Song(managedObject: songMO).album?.artist?.artwork else { return }
      if artwork.status == .CustomImage,
         let path = artwork.imagePath,
         FileManager.default.fileExists(atPath: path) {
        return
      }
      artworkObjectID = artwork.managedObject.objectID
      remoteInfo = artwork.remoteInfo
    }
    guard let artworkObjectID, let remoteInfo else { return }

    guard let url = URL(string: artistImage.imageUrl) else { return }
    let data: Data
    do {
      let (downloaded, response) = try await URLSession.shared.data(from: url)
      guard let http = response as? HTTPURLResponse,
            (200 ..< 300).contains(http.statusCode), !downloaded.isEmpty
      else { return }
      data = downloaded
    } catch {
      print("Cassette poll: artist image download failed - \(error.localizedDescription)")
      return
    }

    let fileManager = CacheFileManager.shared
    guard let relFilePath = fileManager.createRelPath(for: remoteInfo, account: accountInfo),
          let absFilePath = fileManager.getAbsoluteAmperfyPath(relFilePath: relFilePath)
    else { return }
    do {
      try fileManager.writeDataExcludedFromBackup(
        data: data,
        to: absFilePath,
        accountInfo: accountInfo
      )
    } catch {
      print("Cassette poll: artist image write failed - \(error.localizedDescription)")
      return
    }
    context.performAndWait {
      guard let artworkMO = try? context.existingObject(with: artworkObjectID) as? ArtworkMO
      else { return }
      let artwork = Artwork(managedObject: artworkMO)
      artwork.status = .CustomImage
      artwork.relFilePath = relFilePath
      try? context.save()
    }
    print("Cassette poll: materialized artist image (\(data.count) bytes)")
  }

  private func executeRemoval(
    intent: CassetteSyncIntent,
    tracks: [CassetteSyncTrack],
    manager: DeviceOwnershipManager
  ) async {
    var removed: [String] = []
    for track in tracks {
      guard manager.exists(cassetteLocalId: track.cassetteLocalId) else { continue }
      do {
        try manager.remove(cassetteLocalId: track.cassetteLocalId)
        removed.append(track.cassetteLocalId)
      } catch {
        os_log(
          "failed to remove %{public}@: %{public}@",
          log: self.log,
          type: .error,
          track.cassetteLocalId,
          error.localizedDescription
        )
      }
    }

    print("Cassette poll: intent \(intent.id) - removed \(removed.count) owned track(s)")
    if !removed.isEmpty {
      let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? "unknown-device"
      try? await api.reportDeviceInventory(
        deviceId: deviceId,
        deviceLabel: UIDevice.current.name,
        added: [],
        removed: removed
      )
    }
    try? await api.updateIntent(id: intent.id, state: "complete")
  }

  // MARK: - Reachability

  /// A quick GET to the active account's LAN server with a 5s timeout. Any
  /// HTTP response means reachable; only network errors / timeouts mean not.
  private func isCassettePlayerReachable() async -> Bool {
    guard let serverUrl = AmperKit.shared.storage.settings.accounts.activeSetting.read
      .loginCredentials?.serverUrl,
      let url = URL(string: serverUrl)
    else { return false }

    var request = URLRequest(url: url)
    request.httpMethod = "GET"
    request.timeoutInterval = 5

    let config = URLSessionConfiguration.ephemeral
    config.timeoutIntervalForRequest = 5
    config.waitsForConnectivity = false
    let session = URLSession(configuration: config)

    do {
      let (_, response) = try await session.data(for: request)
      return response is HTTPURLResponse
    } catch {
      return false
    }
  }
}
