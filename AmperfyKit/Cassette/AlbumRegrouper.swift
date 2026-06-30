//
//  AlbumRegrouper.swift
//  AmperfyKit
//
//  Cassette fork — Phase 1 (Gap 1): device album grouping.
//
//  Collapses the device's OWNED songs onto the catalog-blind album group keys
//  the cloud computes (buildAlbumGroupKey), so the phone's albums match the web
//  character-for-character. The regroup is the per-sync authority for album
//  identity: it find-or-creates an AlbumMO whose id == group_key, re-points each
//  owned Song onto it, folds the emptied legacy albums' annotations + art, and
//  deletes the emptied legacy albums.
//
//  Idempotent — safe to run on every sync; once every owned song already points
//  at its group-key album it makes no changes. It touches ONLY AlbumMO identity
//  and Song.album relationships: never a Song, a file, or a DeviceOwnership row,
//  so the owned-track count is invariant across a regroup. It is catalog-blind —
//  two disk albums that resolve to one catalog album (e.g. a box set) keep their
//  distinct group keys and stay separate.
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

public final class AlbumRegrouper {
  public struct Summary: Sendable {
    public var movedSongs = 0
    public var purgedAlbums = 0
    public var groups = 0
    public var createdAlbums = 0
    public var matchedByLocalId = 0
    public var skipped = 0
    /// Albums (re)pointed at their native cover id this pass — i.e. still awaiting
    /// the getCoverArt fetch. Reads high on the first post-switch pass (migration),
    /// then falls to 0 as covers land `.CustomImage`. A non-zero steady-state value
    /// means provisioning runs but the LAN fetch isn't settling the cover.
    public var coversProvisioned = 0
  }

  private let log = OSLog(subsystem: "Amperfy", category: "AlbumRegrouper")
  private let context: NSManagedObjectContext

  public init(context: NSManagedObjectContext) {
    self.context = context
  }

  /// Apply the cloud grouping to this device's owned songs. `items` is the
  /// per-track grouping from the device-inventory response, keyed by Subsonic
  /// track id (which equals SongMO.id on this device).
  @discardableResult
  public func regroup(
    items: [CassetteDeviceGroupingItem],
    accountInfo: AccountInfo
  )
    -> Summary {
    var summary = Summary()
    guard !items.isEmpty else { return summary }

    // Match a device song to a payload entry by EITHER key: the Subsonic id is
    // the fast path, but a re-sync can reassign Subsonic ids out from under us, so
    // the cassette_local_id (stable, content-derived) is the fallback that keeps a
    // drifted song from being stranded on its old album. These are `let` so they
    // stay Sendable when captured inside context.performAndWait's closure.
    let byTrackId: [String: CassetteDeviceGroupingItem] = {
      var d = [String: CassetteDeviceGroupingItem]()
      for item in items { d[item.subsonicTrackId] = item }
      return d
    }()
    let byLocalId: [String: CassetteDeviceGroupingItem] = {
      var d = [String: CassetteDeviceGroupingItem]()
      for item in items {
        if let lid = item.cassetteLocalId, !lid.isEmpty { d[lid] = item }
      }
      return d
    }()

    let manager = DeviceOwnershipManager(context: context)
    let ownedIds = manager.fetchAllSubsonicTrackIds()
    guard !ownedIds.isEmpty else { return summary }
    // SongMO.id (Subsonic) -> cassette_local_id, for the fallback match above.
    let localIdBySubsonic: [String: String] = {
      var d = [String: String]()
      if let rows = try? manager.fetchAll() {
        for r in rows where r.subsonicTrackId != nil { d[r.subsonicTrackId!] = r.cassetteLocalId }
      }
      return d
    }()

    context.performAndWait {
      let library = LibraryStorage(context: context)
      let account = library.getAccount(info: accountInfo)

      // One fetch of every owned Song, with its album prefetched.
      let request: NSFetchRequest<SongMO> = SongMO.fetchRequest()
      request.predicate = NSPredicate(format: "id IN %@", ownedIds)
      request.relationshipKeyPathsForPrefetching = [#keyPath(SongMO.album)]
      request.returnsObjectsAsFaults = false
      let songMOs = (try? context.fetch(request)) ?? []

      var targetByKey = [String: Album]()
      var mergedLegacyIds = Set<String>() // legacy album ids already folded in
      var coverProvisioned = Set<String>() // album ids whose cover we've settled this pass
      var createdCount = 0 // local — nested target() can't mutate the outer summary
      var provisionedCount = 0 // local — albums (re)pointed at a native cover id this pass

      func validLocalCover(_ aw: Artwork?) -> Bool {
        guard let aw, aw.status == .CustomImage, let p = aw.imagePath else { return false }
        return FileManager.default.fileExists(atPath: p)
      }

      // Give an owned album an Artwork keyed on the owned song's NATIVE Subsonic
      // cover id, so the (un-gated) getCoverArt byte path pulls the local-drive
      // cover.jpg from the LAN Player (Navidrome serves the folder cover.* ahead of
      // embedded art). One path for matched and unmatched albums alike — there is
      // no catalog/R2 cover path anymore.
      //
      // Runs for EVERY owned album every regroup, not only when a song moves: an
      // already-grouped device (steady-state moved=0) reaches ONLY the no-move
      // branch, and must still provision + migrate its covers. Deduped per album
      // id; an album with no native id from this song is left for a later song.
      //
      // Migration: an existing device may still hold a synthetic "cassette-album"
      // Artwork from the retired R2 path — a stale .NotChecked/.FetchError shell OR
      // a materialized .CustomImage carrying the WRONG catalog cover (the "green vs
      // gold" case). Re-point either to the native id and reset .NotChecked so
      // getCoverArt re-fetches the correct disk cover.
      func provisionNativeCover(on album: Album, nativeCover: ArtworkRemoteInfo?) {
        guard !coverProvisioned.contains(album.id) else { return }
        let isSyntheticShell = album.artwork?.remoteInfo.type == "cassette-album"
        if !isSyntheticShell, validLocalCover(album.artwork) {
          coverProvisioned.insert(album.id) // already has a good local cover
          return
        }
        guard let nativeCover, !nativeCover.id.isEmpty else { return } // try a later song
        let aw = album.artwork ?? library.createArtwork(account: account)
        let native = ArtworkRemoteInfo(id: nativeCover.id, type: nativeCover.type)
        if aw.remoteInfo != native { aw.remoteInfo = native }
        if aw.status != .CustomImage { aw.status = .NotChecked }
        album.artwork = aw
        coverProvisioned.insert(album.id)
        provisionedCount += 1
      }

      func target(for item: CassetteDeviceGroupingItem, nativeCover: ArtworkRemoteInfo?) -> Album {
        let album: Album
        if let cached = targetByKey[item.groupKey] {
          album = cached
        } else {
          album = library.getAlbum(
            for: account,
            id: item.groupKey,
            isDetailFaultResolution: false
          ) ?? {
            let created = library.createAlbum(account: account)
            created.id = item.groupKey
            createdCount += 1
            return created
          }()
          if album.name != item.displayAlbum { album.name = item.displayAlbum }
          // Display artist: only adopt an artist that ALREADY exists locally by
          // this exact name — never mint a synthetic artist (that would pollute
          // the Artists list). Otherwise keep whatever materialization assigned.
          if let artist = library.getArtistByExactName(for: account, name: item.displayArtist),
             album.artist?.id != artist.id {
            album.artist = artist
          }
          targetByKey[item.groupKey] = album
        }
        provisionNativeCover(on: album, nativeCover: nativeCover)
        return album
      }

      for songMO in songMOs {
        let item = byTrackId[songMO.id] ?? localIdBySubsonic[songMO.id].flatMap { byLocalId[$0] }
        guard let item else { summary.skipped += 1; continue }
        if byTrackId[songMO.id] == nil { summary.matchedByLocalId += 1 }
        let song = Song(managedObject: songMO)
        let current = song.album
        let nativeCover = song.artwork?.remoteInfo
        if current?.id == item.groupKey {
          // Already grouped → no move, but STILL provision + migrate the cover.
          // A steady-state device (moved=0) reaches ONLY this branch, so without
          // this its covers would never get a native id and never paint.
          if let current { provisionNativeCover(on: current, nativeCover: nativeCover) }
          continue
        }

        // Pass the owned song's native Subsonic cover id so getCoverArt can load
        // the album's local-drive cover.jpg over the LAN.
        let targetAlbum = target(for: item, nativeCover: nativeCover)

        if let legacy = current, legacy.id != item.groupKey {
          if !mergedLegacyIds.contains(legacy.id) {
            mergeAnnotations(from: legacy, into: targetAlbum)
            // Preserve a working LOCAL cover from a legacy album (the original
            // downloaded art) when the group album doesn't already have one. If
            // target() provisioned a placeholder shell (a non-.CustomImage native
            // or synthetic Artwork with no file on disk), the real legacy cover
            // supersedes it — delete the orphaned shell so the regroup never leaks
            // a dangling Artwork row (no-orphans invariant).
            if !validLocalCover(targetAlbum.artwork), validLocalCover(legacy.artwork) {
              let superseded = targetAlbum.artwork
              targetAlbum.artwork = legacy.artwork
              if let superseded, superseded.managedObject !== legacy.artwork?.managedObject {
                library.deleteArtwork(artwork: superseded)
              }
            }
            mergedLegacyIds.insert(legacy.id)
          }
        }

        song.album = targetAlbum
        summary.movedSongs += 1
      }

      // Refresh each group album's DENORMALIZED song count (Album.songCount reads
      // the cached managedObject.songCount, not the live relationship, so the
      // "N Songs" header would otherwise read 0 after a re-point).
      for (_, targetAlbum) in targetByKey {
        let count = Int16(clamping: targetAlbum.songs.count)
        if targetAlbum.managedObject.songCount != count {
          targetAlbum.managedObject.songCount = count
        }
      }

      summary.groups = targetByKey.count
      summary.createdAlbums = createdCount
      summary.coversProvisioned = provisionedCount

      // SAVE #1 — re-points + new group-key albums + refreshed counts. This is
      // the user-visible change: the grid settles onto the correct albums in one
      // atomic FRC update. Every owned song already points at its group-key album
      // (the loop above), so no song is album-less across this save; the emptied
      // legacy albums simply hold zero songs until the purge save below.
      do {
        try context.save()
      } catch {
        os_log(
          "regroup save #1 (re-points) failed: %{public}@",
          log: self.log,
          type: .error,
          error.localizedDescription
        )
      }

      // PURGE every empty album — not only the ones we re-pointed off this run.
      // This sweeps the NUL-era + Subsonic duplicate leftovers the old
      // (re-pointed-only) deletion missed: once the consolidation above moves a
      // duplicate's last owned song away, the duplicate is empty and meaningless
      // in this download-only model, so it goes. An album still holding songs
      // (owned or not) is untouched. Done as a SECOND save so the moves above are
      // durably persisted before any delete (a crash between can't strand a song)
      // and the grid sees the moves before the removals — never an insert+delete
      // churn in one batch. No empty AlbumMO survives the operation.
      let albumReq: NSFetchRequest<AlbumMO> = AlbumMO.fetchRequest()
      let allAlbums = (try? context.fetch(albumReq)) ?? []
      for albumMO in allAlbums where (albumMO.songs?.count ?? 0) == 0 {
        context.delete(albumMO)
        summary.purgedAlbums += 1
      }

      // SAVE #2 — the purge of emptied legacy albums.
      do {
        try context.save()
      } catch {
        os_log(
          "regroup save #2 (purge) failed: %{public}@",
          log: self.log,
          type: .error,
          error.localizedDescription
        )
      }
    }
    return summary
  }

  /// Fold an emptied legacy album's user annotations into the group-key album.
  /// Policy: OR isFavorite, max rating, sum playCount, earliest starredDate,
  /// latest lastTimePlayed. Run once per legacy album (the legacy is deleted
  /// after), so playCount never double-counts across syncs.
  private func mergeAnnotations(from legacy: Album, into target: Album) {
    if legacy.isFavorite { target.isFavorite = true }
    if legacy.rating > target.rating { target.rating = legacy.rating }
    if legacy.playCount > 0 { target.playCount = target.playCount + legacy.playCount }
    if let ls = legacy.starredDate {
      target.starredDate = min(target.starredDate ?? ls, ls)
    }
    if let ll = legacy.lastTimePlayed {
      target.lastTimePlayed = max(target.lastTimePlayed ?? ll, ll)
    }
  }
}
