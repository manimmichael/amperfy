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

  // Sync Reconciliation (Phase 1): throttle for the periodic full-state
  // inventory report — the device's complete owned-set, posted on poll so the
  // server's "actual" self-heals. The per-transfer differential report keeps
  // things live during active sync; this corrects drift (missed reports,
  // out-of-band deletions). nil until the first report this launch.
  private var lastFullInventoryReportAt: Date?
  private let fullInventoryReportMinInterval: TimeInterval = 120

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
      // Fast Album Art (artists): heal already-synced albums whose artist image
      // was never materialized — READ-ONLY manifest, off-main, idempotent.
      await backfillOwnedArtistImages(accountInfo: accountInfo)
    }

    // Sync Reconciliation (Phase 1): report the device's COMPLETE owned-set so
    // the server's "actual" inventory self-heals from any missed differential
    // report or out-of-band deletion. Throttled — see fullInventoryReportMinInterval.
    await reportFullInventoryIfDue()
  }

  /// Post the device's complete owned-set (full-state inventory) to the server,
  /// throttled so the 30s foreground timer doesn't spam it — a background poll
  /// always exceeds the interval. The server replaces this device's rows with
  /// the snapshot and stamps `inventory_as_of` (the reconciler's freshness
  /// signal). Best-effort: a failure just retries on the next poll, and the
  /// per-transfer differential report keeps the server live in the meantime.
  private func reportFullInventoryIfDue() async {
    if let last = lastFullInventoryReportAt,
       Date().timeIntervalSince(last) < fullInventoryReportMinInterval {
      return
    }

    let manager = DeviceOwnershipManager(context: AmperKit.shared.storage.main.context)
    let items: [(cassetteLocalId: String, mbid: String?, downloadedAt: Date)]
    do {
      items = try manager.fetchAllInventory()
    } catch {
      print("Cassette poll: full-inventory snapshot failed - \(error.localizedDescription)")
      return
    }

    // A full-state report is a complete snapshot; the server replaces the
    // device's rows with exactly what we send. The inventory endpoint caps a
    // request at 5000 items, so for a larger library we must NOT send a
    // truncated list — that would read as a smaller "actual" and (once removes
    // go live) orphan the rest. Skip instead; the differential report keeps the
    // server live, and the freshness gate treats a missing snapshot as stale.
    if items.count > 5000 {
      print("Cassette poll: skipping full-state inventory — \(items.count) items exceeds the 5000 server cap")
      return
    }

    let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? "unknown-device"
    let deviceLabel = UIDevice.current.name
    do {
      try await api.reportFullInventory(
        deviceId: deviceId,
        deviceLabel: deviceLabel,
        items: items
      )
      lastFullInventoryReportAt = Date()
      print("Cassette poll: reported full-state inventory (\(items.count) item(s))")
    } catch {
      print("Cassette poll: full-state inventory report failed - \(error.localizedDescription)")
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

  /// Fast Album Art (artists) backfill: the album-cover backfill's sibling for
  /// artist images. Albums already on the device — synced before artist-image
  /// bundling, or whose artist image was never materialized — get the album
  /// artist's catalog photo here, with no remove/re-add. Strictly READ-ONLY:
  /// it reads only the already-stored manifest the server returns for the
  /// device's owned albums and never triggers an upstream enrichment.
  ///
  /// Off the main actor, throttled the same way (once per poll, after the cover
  /// backfill), and idempotent: enumerate owned albums on a background context,
  /// skip any whose artist image is already local, and materialize the rest via
  /// the Task-A path (which itself resolves/provisions the artist + artwork and
  /// no-ops when nothing changed). Skips cleanly with no bearer token / account.
  private func backfillOwnedArtistImages(accountInfo: AccountInfo) async {
    guard CassetteSyncAPI.bearerToken != nil else { return }

    // Sendable value types so the @Sendable background closure captures only
    // immutable, concurrency-safe state.
    struct ManifestArtistImage: Sendable { let artist: String; let imageUrl: String }

    // 1. Server manifest: the album artist's catalog image per owned album.
    //    Keyed by normalized album name → [(normalized artist, imageUrl)] so a
    //    device album resolves even when its local artist string differs from
    //    the catalog one we keyed the image on.
    let manifest: CassetteDeviceArtworkResponse
    do {
      manifest = try await api.getDeviceArtwork(deviceId: CassetteSyncAPI.deviceId)
    } catch {
      print("Cassette poll: artist-image manifest fetch failed - \(error.localizedDescription)")
      return
    }
    var manifestByAlbum = [String: [ManifestArtistImage]]()
    for album in manifest.albums {
      guard let imageUrl = album.artistImageUrl, !imageUrl.isEmpty else { continue }
      let key = album.albumName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
      manifestByAlbum[key, default: []].append(ManifestArtistImage(
        artist: album.artistName.lowercased().trimmingCharacters(in: .whitespacesAndNewlines),
        imageUrl: imageUrl
      ))
    }
    guard !manifestByAlbum.isEmpty else { return }
    // Bind to a `let` so the @Sendable background closure captures an immutable
    // (and Sendable) value rather than a captured `var`.
    let byAlbum = manifestByAlbum

    // 2. Off-main: group owned songs by album, resolve the target artist's
    //    image from the manifest, gate out albums whose artist image is already
    //    local, and collect a worklist of (imageUrl, subsonicIds).
    struct ArtistImageJob: Sendable { let imageUrl: String; let subsonicIds: [String] }
    let jobs: [ArtistImageJob]
    do {
      jobs = try await AmperKit.shared.storage.async.performAndGet { asyncCompanion in
        let context = asyncCompanion.context
        let trackIds = DeviceOwnershipManager(context: context).fetchAllSubsonicTrackIds()
        guard !trackIds.isEmpty else { return [ArtistImageJob]() }

        let request: NSFetchRequest<SongMO> = SongMO.fetchRequest()
        request.predicate = NSPredicate(format: "id IN %@", Array(trackIds))
        request.returnsObjectsAsFaults = false
        let songMOs = (try? context.fetch(request)) ?? []

        // Group the owned tracks by their album's identity.
        var subsonicIdsByAlbum = [String: [String]]()
        var albumNameByKey = [String: String]()
        var artistNamesByKey = [String: Set<String>]()
        var artistHasLocalImageByKey = [String: Bool]()
        for songMO in songMOs {
          let song = Song(managedObject: songMO)
          let songId = songMO.id
          guard !songId.isEmpty,
                let albumName = songMO.album?.name, !albumName.isEmpty else { continue }
          let artistName = songMO.artist?.name ?? ""
          // Album bucket key: album name + the album's own artist if linked,
          // else the track artist — enough to keep distinct albums apart while
          // matching the manifest's album-name lookup.
          let albumArtist = song.album?.artist?.name ?? artistName
          let key = "\(albumName.lowercased())\u{0}\(albumArtist.lowercased())"
          subsonicIdsByAlbum[key, default: []].append(songId)
          albumNameByKey[key] = albumName
          artistNamesByKey[key, default: []].insert(artistName.lowercased())
          artistNamesByKey[key]?.insert(albumArtist.lowercased())

          // Gate: is the target artist's image already local? Prefer the
          // album's artist, else the song's artist (the Task-A target order).
          if artistHasLocalImageByKey[key] == nil {
            let targetArtist = song.album?.artist ?? song.artist
            if let artwork = targetArtist?.artwork,
               artwork.status == .CustomImage,
               let path = artwork.imagePath,
               FileManager.default.fileExists(atPath: path) {
              artistHasLocalImageByKey[key] = true
            } else {
              artistHasLocalImageByKey[key] = false
            }
          }
        }

        var result = [ArtistImageJob]()
        for (key, subsonicIds) in subsonicIdsByAlbum {
          if artistHasLocalImageByKey[key] == true { continue } // already local
          guard let albumName = albumNameByKey[key] else { continue }
          let lookupKey = albumName.lowercased()
            .trimmingCharacters(in: .whitespacesAndNewlines)
          guard let candidates = byAlbum[lookupKey], !candidates.isEmpty else { continue }

          // Prefer a candidate whose artist matches one of this album's artist
          // strings; otherwise, if there's exactly one candidate for the album
          // name, use it (unambiguous).
          let artists = artistNamesByKey[key] ?? []
          let chosen = candidates.first(where: { artists.contains($0.artist) })
            ?? (candidates.count == 1 ? candidates.first : nil)
          guard let chosen else { continue }
          result.append(ArtistImageJob(imageUrl: chosen.imageUrl, subsonicIds: subsonicIds))
        }
        return result
      }
    } catch {
      return
    }
    guard !jobs.isEmpty else { return }

    print("Cassette poll: backfilling artist images for \(jobs.count) owned album(s)")
    for job in jobs {
      await materializeArtistImage(
        imageUrl: job.imageUrl,
        subsonicIds: job.subsonicIds,
        accountInfo: accountInfo
      )
    }
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
      await materializeArtistImage(
        imageUrl: albumArtist.imageUrl,
        subsonicIds: tracks.map(\.subsonicTrackId),
        accountInfo: accountInfo
      )
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
  /// `Artwork` — the same end-state as `materializeAlbumCover`, for the album
  /// artist. Best-effort and idempotent: honors the artwork-download
  /// preference, skips when a local artist image already exists, and no-ops on
  /// any failure.
  ///
  /// Unlike covers (one hop: `song.album?.artwork`), the artist image must NOT
  /// depend on the inherited `album → artist → artwork` graph. Cassette
  /// downloads build no Core Data graph and `SsSongParserDelegate` never links
  /// `album → artist`, so `song.album?.artist` is almost always nil — the old
  /// implementation dead-ended at its nil guard even though the server sent a
  /// URL. We instead resolve the artist the on-device library UI actually
  /// renders: the Artists list / Artist detail are keyed on the song→artist
  /// relationship (`DeviceOwnershipManager.fetchOwnedArtistIds` collects
  /// `song.artist?.id`; the FRC predicate is `id IN <thatSet>`), i.e.
  /// `song.artist`, which `SsSongParserDelegate` DOES populate. We:
  ///   1. resolve the target `Artist` robustly (`song.album?.artist`, else
  ///      `song.artist`, else create/link one by the song's artist name),
  ///   2. ensure it has an `Artwork` (create + attach one when nil), and
  ///   3. write the bytes + flip it to `.CustomImage`, exactly as the cover path.
  /// We attach to `song.artist` (the proven UI source) and, when present and
  /// distinct, also to `song.album?.artist` so either display path renders.
  ///
  /// Takes the raw `imageUrl` + the owned tracks' `subsonicIds` so both the
  /// transfer path (a fresh intent) and the backfill path (already-synced
  /// albums) drive the identical end-state.
  private func materializeArtistImage(
    imageUrl: String,
    subsonicIds: [String],
    accountInfo: AccountInfo
  ) async {
    guard AmperKit.shared.storage.settings.accounts
      .getSetting(accountInfo).read.artworkDownloadSetting != .never else { return }
    guard !subsonicIds.isEmpty else { return }

    let context = AmperKit.shared.storage.main.context

    // Resolve (or provision) the artist's Artwork from any of the intent's
    // tracks, attaching to the entity the UI reads (song.artist). Capture the
    // artwork's objectID + remoteInfo; skip if a local image already exists.
    var artworkObjectID: NSManagedObjectID?
    var remoteInfo: ArtworkRemoteInfo?
    context.performAndWait {
      let library = LibraryStorage(context: context)
      let account = library.getAccount(info: accountInfo)

      let request: NSFetchRequest<SongMO> = SongMO.fetchRequest()
      request.predicate = NSPredicate(format: "id IN %@", subsonicIds)
      request.fetchLimit = 1
      guard let songMO = try? context.fetch(request).first else { return }
      let song = Song(managedObject: songMO)

      // 1. Target artist: prefer the album's artist (matches the catalog
      //    artist the server keyed the image on), else the song's own artist
      //    (populated by SsSongParserDelegate), else create/link one by name.
      //    The last branch is a defensive net — on device `song.artist` is the
      //    populated relationship, and when it's nil there's no on-device name
      //    string to key on, so provisioning only fires if the raw MO somehow
      //    still carries an artist name.
      let artist: Artist
      if let albumArtist = song.album?.artist {
        artist = albumArtist
      } else if let songArtist = song.artist {
        artist = songArtist
      } else {
        guard let artistName = songMO.artist?.name, !artistName.isEmpty else { return }
        let resolved = library.getArtistByExactName(for: account, name: artistName)
          ?? {
            let created = library.createArtist(account: account)
            created.name = artistName
            return created
          }()
        // Link it onto the song so the on-device Artists list (keyed on
        // song.artist) actually surfaces this artist.
        song.artist = resolved
        artist = resolved
      }

      // 2. Ensure the artist has an Artwork. Reuse the existing one (real
      //    Subsonic coverArt id) when present; otherwise create one with a
      //    stable synthetic remoteInfo — type "artist" nests it under its own
      //    artwork subdir, so the file path never collides with album covers
      //    (whose remoteInfo type is empty), and is stable across re-runs so
      //    the idempotent gate holds.
      let artwork: Artwork
      if let existing = artist.artwork {
        artwork = existing
      } else {
        let created = library.createArtwork(account: account)
        // Sanitize the name into a single safe path component (no separators).
        let safeName = artist.name
          .replacingOccurrences(of: "/", with: "_")
          .replacingOccurrences(of: ":", with: "_")
        let syntheticId = !artist.id.isEmpty
          ? artist.id
          : "cassette-artist-\(safeName)"
        created.remoteInfo = ArtworkRemoteInfo(id: syntheticId, type: "artist")
        created.status = .NotChecked
        artist.artwork = created
        artwork = created
      }

      // Cheap dual-attach: when both the song's artist and the album's artist
      // exist, are distinct, and the other lacks artwork, point it at the same
      // Artwork so whichever entity a surface reads still renders the image.
      if let albumArtist = song.album?.artist,
         albumArtist.managedObject != artist.managedObject,
         albumArtist.artwork == nil {
        albumArtist.artwork = artwork
      }
      if let songArtist = song.artist,
         songArtist.managedObject != artist.managedObject,
         songArtist.artwork == nil {
        songArtist.artwork = artwork
      }

      // Idempotent gate: nothing to do if the image is already on disk.
      if artwork.status == .CustomImage,
         let path = artwork.imagePath,
         FileManager.default.fileExists(atPath: path) {
        return
      }

      // Persist the (possibly newly created) artist/artwork + links before the
      // download so the objectID resolves afterward.
      try? context.save()
      artworkObjectID = artwork.managedObject.objectID
      remoteInfo = artwork.remoteInfo
    }
    guard let artworkObjectID, let remoteInfo else { return }

    guard let url = URL(string: imageUrl) else { return }
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
      // Refresh the on-device-only library views now that these are gone.
      CassetteOwnershipNotifier.shared.ownershipDidChange()
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
