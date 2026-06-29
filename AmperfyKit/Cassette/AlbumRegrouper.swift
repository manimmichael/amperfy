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
    public var deletedAlbums = 0
    public var groups = 0
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

    var byTrackId = [String: CassetteDeviceGroupingItem]()
    for item in items { byTrackId[item.subsonicTrackId] = item }

    // The owned set drives the regroup. fetchAllSubsonicTrackIds wraps its own
    // context.performAndWait; call it before opening ours.
    let ownedIds = DeviceOwnershipManager(context: context).fetchAllSubsonicTrackIds()
    guard !ownedIds.isEmpty else { return summary }

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
      var legacyById = [String: Album]() // emptied-legacy delete candidates

      func target(for item: CassetteDeviceGroupingItem) -> Album {
        if let cached = targetByKey[item.groupKey] { return cached }
        let album = library.getAlbum(
          for: account,
          id: item.groupKey,
          isDetailFaultResolution: false
        ) ?? {
          let created = library.createAlbum(account: account)
          created.id = item.groupKey
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
        return album
      }

      for songMO in songMOs {
        guard let item = byTrackId[songMO.id] else { continue }
        let song = Song(managedObject: songMO)
        let current = song.album
        if current?.id == item.groupKey { continue } // already grouped → no-op

        let targetAlbum = target(for: item)

        if let legacy = current, legacy.id != item.groupKey {
          if !mergedLegacyIds.contains(legacy.id) {
            mergeAnnotations(from: legacy, into: targetAlbum)
            // Carry the existing local cover so the merged album keeps its art
            // (no new fetch — the art-backfill path still heals covers later).
            if targetAlbum.artwork == nil, let art = legacy.artwork {
              targetAlbum.artwork = art
            }
            mergedLegacyIds.insert(legacy.id)
          }
          legacyById[legacy.id] = legacy
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

      // Delete legacy albums emptied by the re-point. Tested on the LIVE songs
      // relationship (not the cached songCount) — a legacy album still holding
      // non-owned songs is left untouched (it just won't appear in the owned view).
      for (_, legacy) in legacyById where legacy.songs.isEmpty {
        library.deleteAlbum(album: legacy)
        summary.deletedAlbums += 1
      }

      summary.groups = targetByKey.count
      do {
        try context.save()
      } catch {
        os_log(
          "regroup save failed: %{public}@",
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
