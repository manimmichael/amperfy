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
  /// Set by executeRemoval when a remove intent deleted owned tracks; drives the
  /// single guaranteed library repaint at the end of a poll cycle.
  private var didRemoveThisCycle = false
  // Once-per-launch device registration (user_devices upsert). The header
  // keep-alive rides every request; this full registration also refreshes
  // platform/model/app_version.
  private var hasRegisteredDevice = false
  // Once-per-launch account-identity refresh (name/email for the account
  // menu). Reset only on relaunch; the persisted copy carries between runs.
  private var hasRefreshedAccountIdentity = false

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
    didRemoveThisCycle = false

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
    // The fetch above round-tripped to cassette.digital with a valid bearer
    // token, so the device is paired and reachable: stamp the freshness signal
    // the account menu reads ("Synced 5m ago"). Persisted (not just the
    // in-memory lastFullInventoryReportAt) so it survives relaunch.
    Self.recordSuccessfulSync()

    // Refresh the caller's ACCOUNT identity (name/email) so the account menu
    // shows the user's Cassette account — not the paired Player's LAN
    // hostname. Best-effort, once per launch (the 30s foreground timer must
    // not hammer it); the persisted copy survives relaunch, so a missed fetch
    // just keeps the last-known label. Off the critical path of intent work.
    await refreshAccountIdentityIfNeeded()
    for intent in intents {
      await executeIntent(intent)
    }

    // Removals just deleted owned tracks: repaint the on-device-only library ONCE,
    // immediately, now that the whole burst has settled and the main thread is free.
    // A removed album's tracks are no longer owned, so the rebuilt FRC drops it in
    // place — no relaunch. Fired here (right after the loop) rather than per-removal
    // so the burst can't cancel it and it can't race the regroup below.
    if didRemoveThisCycle {
      await MainActor.run { CassetteOwnershipNotifier.shared.ownershipDidChangeNow() }
    }

    // Fast Album Art: fill covers for albums already on the device — not just
    // fresh transfers. Off-main, throttled, idempotent; reconciles every sync
    // so existing albums get and keep their art.
    if let accountInfo = AmperKit.shared.storage.settings.accounts.active {
      await backfillOwnedAlbumCovers(accountInfo: accountInfo)
      // Fast Album Art (artists): heal already-synced albums whose artist image
      // was never materialized — READ-ONLY manifest, off-main, idempotent.
      await backfillOwnedArtistImages(accountInfo: accountInfo)
      // cassette §art-collapse: re-tier existing local covers (generate the
      // ~480px thumb) for any that predate tiering. Idempotent + off-main.
      await backfillCoverThumbnails(accountInfo: accountInfo)
    }

    // Sync Reconciliation (Phase 1): report the device's COMPLETE owned-set so
    // the server's "actual" inventory self-heals from any missed differential
    // report or out-of-band deletion. Throttled — see fullInventoryReportMinInterval.
    // The response carries the catalog-blind album grouping (Phase 1, Gap 1) —
    // apply it so the device's albums match the web.
    let inventoryResponse = await reportFullInventoryIfDue()
    if let inventoryResponse {
      await applyAlbumGrouping(inventoryResponse)
    }
  }

  /// Pull-to-refresh entry point (B2). Drives the full on-demand convergence
  /// chain so the user's gesture reflects the Mac's CURRENT disk: (1) ask the
  /// paired Player's sidecar to re-read the disk and push the refreshed index to
  /// the cloud (scan-first convergence over the LAN), then (2) re-report this
  /// device's full inventory (foreground throttle bypassed) and apply the intents
  /// the cloud reconcile produces. Best-effort throughout — if the sidecar is
  /// unreachable or its port is unknown, convergeOnPlayer returns a non-fatal
  /// result and we still fall through to the normal poll, so the refresh degrades
  /// to lazy convergence (watcher + heartbeat) rather than failing.
  ///
  /// Wire the library view's pull-to-refresh (UIRefreshControl / .refreshable)
  /// to `await …intentExecutor.convergeAndRefresh()`.
  public func convergeAndRefresh() async {
    let serverUrl = AmperKit.shared.storage.settings.accounts.activeSetting.read
      .loginCredentials?.serverUrl
    _ = await CassetteSyncAPI.shared.convergeOnPlayer(serverUrl: serverUrl)
    // Force a fresh full-inventory report (bypass the throttle) so the cloud
    // reconcile runs against current truth, then apply what it queued.
    lastFullInventoryReportAt = nil
    await handlePendingIntents()
  }

  /// Post the device's complete owned-set (full-state inventory) to the server,
  /// throttled so the 30s foreground timer doesn't spam it — a background poll
  /// always exceeds the interval. The server replaces this device's rows with
  /// the snapshot and stamps `inventory_as_of` (the reconciler's freshness
  /// signal). Best-effort: a failure just retries on the next poll, and the
  /// per-transfer differential report keeps the server live in the meantime.
  private func reportFullInventoryIfDue() async -> CassetteDeviceInventoryResponse? {
    if let last = lastFullInventoryReportAt,
       Date().timeIntervalSince(last) < fullInventoryReportMinInterval {
      return nil
    }

    let manager = DeviceOwnershipManager(context: AmperKit.shared.storage.main.context)
    let items: [(cassetteLocalId: String, mbid: String?, downloadedAt: Date)]
    do {
      items = try manager.fetchAllInventory()
    } catch {
      print("Cassette poll: full-inventory snapshot failed - \(error.localizedDescription)")
      return nil
    }

    // A full-state report is a complete snapshot; the server replaces the
    // device's rows with exactly what we send. The inventory endpoint caps a
    // request at 5000 items, so for a larger library we must NOT send a
    // truncated list — that would read as a smaller "actual" and (once removes
    // go live) orphan the rest. Skip instead; the differential report keeps the
    // server live, and the freshness gate treats a missing snapshot as stale.
    if items.count > 5000 {
      print(
        "Cassette poll: skipping full-state inventory — \(items.count) items exceeds the 5000 server cap"
      )
      return nil
    }

    let deviceId = UIDevice.current.identifierForVendor?.uuidString ?? "unknown-device"
    let deviceLabel = UIDevice.current.name
    do {
      let response = try await api.reportFullInventory(
        deviceId: deviceId,
        deviceLabel: deviceLabel,
        items: items
      )
      lastFullInventoryReportAt = Date()
      print("Cassette poll: reported full-state inventory (\(items.count) item(s))")
      return response
    } catch {
      print("Cassette poll: full-state inventory report failed - \(error.localizedDescription)")
      return nil
    }
  }

  /// Apply the catalog-blind album grouping (Phase 1, Gap 1) the cloud returned
  /// on the inventory report: collapse owned songs onto their group-key albums so
  /// the device's albums match the web. Idempotent; runs on every sync that
  /// returns grouping. Records the applied model version for diagnostics.
  private func applyAlbumGrouping(_ response: CassetteDeviceInventoryResponse) async {
    guard !response.grouping.isEmpty else { return }
    guard let accountInfo = AmperKit.shared.storage.settings.accounts.active else { return }

    let context = AmperKit.shared.storage.main.context
    let summary = AlbumRegrouper(context: context).regroup(
      items: response.grouping,
      accountInfo: accountInfo
    )

    if AmperKit.shared.storage.settings.app.appliedGroupingModelVersion
      != response.groupingModelVersion {
      AmperKit.shared.storage.settings.app.appliedGroupingModelVersion =
        response.groupingModelVersion
    }

    // Covers are served by the native getCoverArt byte path (Navidrome → the
    // local-drive folder cover.jpg over the LAN): the regroup provisions each
    // album's Artwork with its native cover id (AlbumRegrouper), and the owned-
    // album backfill below enqueues the fetch. There is no catalog/R2 cover path.
    let ctx: [String: String] = [
      "version": String(response.groupingModelVersion),
      "groups": String(summary.groups),
      "moved": String(summary.movedSongs),
      "created": String(summary.createdAlbums),
      "createdSongs": String(summary.createdSongs),
      "purged": String(summary.purgedAlbums),
      "byLocalId": String(summary.matchedByLocalId),
      "skipped": String(summary.skipped),
      "provisioned": String(summary.coversProvisioned),
    ]
    DiagnosticLog.shared.log(.lifecycle, "album regroup", context: ctx)
    print("Cassette regroup: v\(response.groupingModelVersion) \(ctx)")
    os_log(
      "regroup v%d groups=%d moved=%d created=%d purged=%d byLocalId=%d skipped=%d provisioned=%d",
      log: self.log,
      type: .info,
      response.groupingModelVersion,
      summary.groups,
      summary.movedSongs,
      summary.createdAlbums,
      summary.purgedAlbums,
      summary.matchedByLocalId,
      summary.skipped,
      summary.coversProvisioned
    )

    // The regroup may have created new group-key albums (and SongMOs for owned
    // tracks that had no catalog record). Two follow-ups so they show up right,
    // in-place, without an app relaunch:
    //  1. Those albums are NOT in the library FRC's owned-album-id predicate (a
    //     snapshot from FRC setup), so they stay hidden until it's rebuilt — the
    //     "invisible until relaunch" symptom. The ownership notifier's observers
    //     rebuild the FRC with a fresh owned-album set.
    //  2. The cover backfill (backfillOwnedAlbumCovers) ran BEFORE the regroup
    //     this poll, so the just-created albums missed it and render coverless.
    //     Re-run it now (idempotent — skips albums that already have a local
    //     cover) so their covers fetch on this same sync.
    if summary.createdSongs > 0 || summary.createdAlbums > 0 {
      await MainActor.run { CassetteOwnershipNotifier.shared.ownershipDidChange() }
    }
    // Re-run the cover backfill (which ran BEFORE the regroup this poll) whenever
    // the regroup provisioned an album cover id — for newly-created albums OR
    // already-owned albums an earlier build left coverless — so their covers fetch
    // on this same sync. Idempotent: skips albums that already have a local cover,
    // and self-terminates once coversProvisioned falls to 0.
    if summary.coversProvisioned > 0 || summary.createdSongs > 0 {
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

  /// cassette §art-collapse: one-time re-tier heal. Walks the account's artworks
  /// directory and generates the ~480px thumb for any full cover that predates
  /// tiering. Idempotent (CoverImageStore.ensureThumb skips covers that already
  /// have a thumb) and entirely off-main, so it's safe to reconcile every sync.
  private func backfillCoverThumbnails(accountInfo: AccountInfo) async {
    guard let artworksDir = CacheFileManager.shared
      .getOrCreateAbsoluteArtworksDirectory(for: accountInfo)
    else { return }
    await Task.detached(priority: .utility) {
      guard let entries = try? FileManager.default.contentsOfDirectory(
        at: artworksDir,
        includingPropertiesForKeys: nil
      ) else { return }
      var healed = 0
      for url in entries {
        let stem = (url.lastPathComponent as NSString).deletingPathExtension
        if stem.hasSuffix("_thumb") { continue } // skip thumbs themselves
        if FileManager.default
          .fileExists(atPath: CoverImageStore.thumbPath(forFullPath: url.path)) {
          continue
        }
        CoverImageStore.ensureThumb(forFullPath: url.path)
        healed += 1
      }
      if healed > 0 {
        print("Cassette: re-tiered \(healed) existing cover(s)")
      }
    }.value
  }

  /// Fast Album Art backfill + refresh-on-change (content reconciliation
  /// increment 2): the album-cover backfill's sibling for both the album
  /// ARTIST image and the album COVER. Albums already on the device — synced
  /// before artist-image bundling, or whose artwork was never materialized, or
  /// whose catalog artwork has since CHANGED — get the album artist's catalog
  /// photo and the album cover here, with no remove/re-add. Strictly READ-ONLY:
  /// it reads only the already-stored manifest the server returns for the
  /// device's owned albums and never triggers an upstream enrichment.
  ///
  /// Change detection is driven by the manifest's `content_version` (a hash of
  /// the artwork URLs), compared against a small per-album applied-version store
  /// in UserDefaults (see `appliedArtworkVersion`). For each manifest album we
  /// compute its albumKey and read the stored version:
  ///   - stored == nil (first run): materialize once, record the version.
  ///   - stored != manifest.contentVersion (changed): force-materialize the
  ///     artist image (bypassing the on-disk idempotent gate so the changed bytes
  ///     overwrite the old file), then record the version.
  ///   - stored == manifest.contentVersion (unchanged): skip entirely — cheap.
  ///
  /// Off the main actor for the enumeration/matching, throttled the same way
  /// (once per poll, after the cover backfill). Skips cleanly with no bearer
  /// token / account.
  private func backfillOwnedArtistImages(accountInfo: AccountInfo) async {
    guard CassetteSyncAPI.bearerToken != nil else { return }

    // Sendable value types so the @Sendable background closure captures only
    // immutable, concurrency-safe state. A candidate carries the manifest's
    // artwork URLs (either may be nil) + the album's content version.
    struct ManifestCandidate: Sendable {
      let artist: String
      let albumKey: String
      let artistImageUrl: String?
      let contentVersion: String
    }

    // 1. Server manifest: the album artist's catalog image + the album cover,
    //    per owned album. Keyed by normalized album name → [candidate] so a
    //    device album resolves even when its local artist string differs from
    //    the catalog one we keyed the image on. We keep EVERY album (even one
    //    with no image URLs) so a cover-only change still refreshes and the
    //    version is recorded.
    let manifest: CassetteDeviceArtworkResponse
    do {
      manifest = try await api.getDeviceArtwork(deviceId: CassetteSyncAPI.deviceId)
    } catch {
      print("Cassette poll: artwork manifest fetch failed - \(error.localizedDescription)")
      return
    }
    var manifestByAlbum = [String: [ManifestCandidate]]()
    for album in manifest.albums {
      let albumNorm = Self.normalizeForVersionKey(album.albumName)
      let artistNorm = Self.normalizeForVersionKey(album.artistName)
      let imageUrl = (album.artistImageUrl?.isEmpty == false) ? album.artistImageUrl : nil
      manifestByAlbum[albumNorm, default: []].append(ManifestCandidate(
        artist: artistNorm,
        albumKey: Self.albumVersionKey(artist: album.artistName, album: album.albumName),
        artistImageUrl: imageUrl,
        contentVersion: album.contentVersion
      ))
    }
    guard !manifestByAlbum.isEmpty else { return }
    // Bind to a `let` so the @Sendable background closure captures an immutable
    // (and Sendable) value rather than a captured `var`.
    let byAlbum = manifestByAlbum

    // 2. Off-main: group owned songs by album, match each device album to its
    //    manifest candidate (same album-name lookup + artist disambiguation as
    //    before), and collect a worklist carrying the manifest's artwork URLs,
    //    version, and albumKey alongside the resolved subsonicIds. No on-disk
    //    gate here — change detection is the version compare on the main actor.
    struct ArtworkJob: Sendable {
      let albumKey: String
      let contentVersion: String
      let artistImageUrl: String?
      let subsonicIds: [String]
    }
    let jobs: [ArtworkJob]
    do {
      jobs = try await AmperKit.shared.storage.async.performAndGet { asyncCompanion in
        let context = asyncCompanion.context
        let trackIds = DeviceOwnershipManager(context: context).fetchAllSubsonicTrackIds()
        guard !trackIds.isEmpty else { return [ArtworkJob]() }

        let request: NSFetchRequest<SongMO> = SongMO.fetchRequest()
        request.predicate = NSPredicate(format: "id IN %@", Array(trackIds))
        request.returnsObjectsAsFaults = false
        let songMOs = (try? context.fetch(request)) ?? []

        // Group the owned tracks by their album's identity.
        var subsonicIdsByAlbum = [String: [String]]()
        var albumNameByKey = [String: String]()
        var artistNamesByKey = [String: Set<String>]()
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
        }

        var result = [ArtworkJob]()
        for (key, subsonicIds) in subsonicIdsByAlbum {
          guard let albumName = albumNameByKey[key] else { continue }
          let lookupKey = Self.normalizeForVersionKey(albumName)
          guard let candidates = byAlbum[lookupKey], !candidates.isEmpty else { continue }

          // Prefer a candidate whose artist matches one of this album's artist
          // strings; otherwise, if there's exactly one candidate for the album
          // name, use it (unambiguous).
          let artists = artistNamesByKey[key] ?? []
          let chosen = candidates.first(where: { artists.contains($0.artist) })
            ?? (candidates.count == 1 ? candidates.first : nil)
          guard let chosen else { continue }
          result.append(ArtworkJob(
            albumKey: chosen.albumKey,
            contentVersion: chosen.contentVersion,
            artistImageUrl: chosen.artistImageUrl,
            subsonicIds: subsonicIds
          ))
        }
        return result
      }
    } catch {
      return
    }
    guard !jobs.isEmpty else { return }

    // 3. Main actor: version-gate each job. Unchanged → skip (cheap). Changed
    //    or first-run → force-materialize both artworks, then record the
    //    version so the next poll no-ops. De-dupe by albumKey in case two
    //    device buckets resolved to the same manifest album.
    var appliedThisPass = Set<String>()
    var refreshed = 0
    for job in jobs {
      if appliedThisPass.contains(job.albumKey) { continue }
      let stored = appliedArtworkVersion(forAlbumKey: job.albumKey)
      guard stored != job.contentVersion else { continue } // unchanged
      let force = stored != nil // first-run materializes once (no force needed)

      if let imageUrl = job.artistImageUrl {
        await materializeArtistImage(
          imageUrl: imageUrl,
          subsonicIds: job.subsonicIds,
          accountInfo: accountInfo,
          force: force
        )
      }
      // Record the applied version after the best-effort artist-image refresh.
      // Album covers are served by native getCoverArt (the local-drive cover.jpg),
      // never the manifest, so there is nothing more to settle here.
      setAppliedArtworkVersion(job.contentVersion, forAlbumKey: job.albumKey)
      appliedThisPass.insert(job.albumKey)
      refreshed += 1
    }
    if refreshed > 0 {
      print("Cassette poll: refreshed artwork for \(refreshed) owned album(s)")
    }
  }

  // MARK: - Sync freshness (account-menu status line)

  /// Wall-clock time of the last successful poll round-trip to cassette.digital,
  /// persisted in UserDefaults so it survives relaunch (unlike the per-launch
  /// in-memory `lastFullInventoryReportAt`). The account menu renders this as a
  /// relative "Synced 5m ago" line. `nonisolated`/`static` so a UI surface can
  /// read it cheaply and synchronously off the main actor without touching the
  /// executor's actor-isolated state.
  nonisolated private static let lastSyncAtKey = "cassette.lastSyncAt"

  nonisolated public static var lastSyncAt: Date? {
    let t = UserDefaults.standard.double(forKey: lastSyncAtKey)
    return t > 0 ? Date(timeIntervalSince1970: t) : nil
  }

  nonisolated static func recordSuccessfulSync() {
    UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: lastSyncAtKey)
  }

  /// Fetch + persist the caller's account identity (name/email) once per
  /// launch, so the account menu leads with the user's Cassette account name
  /// (or email) instead of the paired Player's hostname. Best-effort: a
  /// failure just leaves the last-persisted value (or "Connected" before any
  /// fetch) and retries next launch. `getAccount()` persists internally.
  private func refreshAccountIdentityIfNeeded() async {
    guard !hasRefreshedAccountIdentity else { return }
    do {
      let account = try await api.getAccount()
      hasRefreshedAccountIdentity = true
      print("Cassette poll: account identity refreshed (\(account.name ?? account.email))")
    } catch {
      // Leave hasRefreshedAccountIdentity false so the next poll retries.
      print("Cassette poll: account identity fetch failed - \(error.localizedDescription)")
    }
  }

  // MARK: - Applied-artwork-version store (refresh-on-change)

  /// Per-album last-applied `content_version`, persisted in UserDefaults as a
  /// `[albumKey: version]` map. Lets the backfill detect when an album's
  /// catalog artwork has CHANGED (version differs) versus is merely absent, so
  /// a changed cover/artist photo refreshes on-device without a remove/re-add.
  private static let appliedArtworkVersionsKey = "cassette.appliedArtworkVersions"

  /// The version-store key for a manifest album. Reuses the same per-field
  /// normalization the manifest↔device matching uses (lowercased + whitespace-
  /// trimmed), joined with a NUL so "<artist><NUL><album>" can't collide with a
  /// differently-split pair. Same (artist, album) ⇒ same key on every poll.
  /// `nonisolated` so the off-main enumeration closure can call it.
  nonisolated private static func albumVersionKey(artist: String, album: String) -> String {
    "\(normalizeForVersionKey(artist))\u{0}\(normalizeForVersionKey(album))"
  }

  /// Lowercase + whitespace-trim — the exact normalization the manifest lookup
  /// already applies to album/artist names. `nonisolated` so the off-main
  /// enumeration closure can call it.
  nonisolated private static func normalizeForVersionKey(_ value: String) -> String {
    value.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
  }

  private func appliedArtworkVersion(forAlbumKey albumKey: String) -> String? {
    let map = UserDefaults.standard
      .dictionary(forKey: Self.appliedArtworkVersionsKey) as? [String: String]
    return map?[albumKey]
  }

  private func setAppliedArtworkVersion(_ version: String, forAlbumKey albumKey: String) {
    var map = (
      UserDefaults.standard
        .dictionary(forKey: Self.appliedArtworkVersionsKey) as? [String: String]
    ) ?? [:]
    map[albumKey] = version
    UserDefaults.standard.set(map, forKey: Self.appliedArtworkVersionsKey)
  }

  /// The cassette_local_id if `targetId` is an id-keyed remove target
  /// (`localid@<clid>`), else nil. Mirrors the cloud's LOCAL_ID_REMOVE_PREFIX +
  /// decodeLocalIdRemoveTargetId (sync-intents.ts).
  private static let localIdRemovePrefix = "localid@"
  static func decodeLocalIdRemoveTarget(_ targetId: String) -> String? {
    guard targetId.hasPrefix(localIdRemovePrefix) else { return nil }
    let clid = targetId.dropFirst(localIdRemovePrefix.count)
      .trimmingCharacters(in: .whitespaces)
    return clid.isEmpty ? nil : clid
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

    let isRemove = intent.intentKind == "remove"

    // Reachability: only an ADD needs the LAN Player (to pull files). A REMOVE
    // deletes local files + ownership rows, so it must run even with the Mac
    // off-LAN — gating removes on reachability used to strand them in "waiting".
    if !isRemove {
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
    }

    // Tracks: an id-keyed remove (`localid@<clid>`) carries its target in the
    // intent id, so skip the network resolve entirely — a local delete needs only
    // the cassette_local_id. This is the fast path for the reconciler's per-track
    // removes. Everything else (adds, legacy album-keyed removes) resolves via the
    // tracks endpoint.
    let tracks: [CassetteSyncTrack]
    let albumArtist: CassetteSyncArtist?
    if isRemove, let clid = Self.decodeLocalIdRemoveTarget(intent.targetId) {
      tracks = [CassetteSyncTrack(
        subsonicTrackId: "",
        cassetteLocalId: clid,
        mbid: nil,
        title: nil,
        duration: nil,
        fileExtension: ""
      )]
      albumArtist = nil
    } else {
      do {
        let response = try await api.getIntentTracks(intentId: intent.id)
        tracks = response.tracks
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

    // Fast Album Art (artist photo): bundle the album artist's image so it's
    // on-device with the album. Covers come from native getCoverArt (the local-
    // drive cover.jpg over the LAN), not a bundled URL. Best-effort; idempotent.
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

  /// Download the album artist's bundled image and wire it into the artist's
  /// `Artwork` — a local `.CustomImage` for the album artist, the same disk
  /// end-state a successful getCoverArt would land. Best-effort and idempotent:
  /// honors the artwork-download preference, skips when a local artist image
  /// already exists, and no-ops on any failure.
  ///
  /// Artist photos have no local-drive equivalent the way album covers do (no
  /// folder cover.jpg over getCoverArt), so they keep this catalog-sourced
  /// materialize path — unlike album covers, which are now native getCoverArt only.
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
  ///
  /// Pass `force: true` to BYPASS the "already .CustomImage on disk" gate so a
  /// CHANGED artist image overwrites the old file (content reconciliation
  /// increment 2). The artist/artwork resolution + provisioning still runs; only
  /// the on-disk skip is suppressed. The default preserves the absence-only
  /// behavior of every existing caller.
  private func materializeArtistImage(
    imageUrl: String,
    subsonicIds: [String],
    accountInfo: AccountInfo,
    force: Bool = false
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

      // Idempotent gate: nothing to do if the image is already on disk —
      // UNLESS forcing a refresh (the artist image changed in the catalog).
      if !force,
         artwork.status == .CustomImage,
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
      // Mark the cycle dirty; handlePendingIntents fires ONE immediate library
      // refresh after the whole burst settles. (The old per-removal debounced
      // ownershipDidChange got repeatedly cancelled during a fast multi-track
      // burst and the last one raced the main-thread-blocking regroup, so the
      // removed album could linger on screen until an app relaunch.)
      didRemoveThisCycle = true
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
