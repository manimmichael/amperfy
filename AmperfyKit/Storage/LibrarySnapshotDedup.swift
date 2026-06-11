//
//  LibrarySnapshotDedup.swift
//  AmperfyKit
//
//  cassette Patch 059: render-time guardrail for duplicate ArtistMO/AlbumMO ids.

import CoreData
import Foundation
import UIKit

public enum LibrarySnapshotDedup {
  public static func suppressingDuplicateServerIds(
    snapshot: NSDiffableDataSourceSnapshot<Int, NSManagedObjectID>,
    context: NSManagedObjectContext
  )
    -> NSDiffableDataSourceSnapshot<Int, NSManagedObjectID> {
    // Mutate a copy in place and delete the duplicate "loser" object IDs. This reads only the
    // flat `itemIdentifiers` ([NSManagedObjectID]) and never the typed `sectionIdentifiers`, whose
    // underlying NSFetchedResultsController section keys are NSString and would crash a
    // [NSString] -> [Int] force cast.
    var result = snapshot
    let losers = duplicateLoserObjectIDs(snapshot.itemIdentifiers, context: context)
    if !losers.isEmpty {
      result.deleteItems(losers)
    }
    return result
  }

  private static func duplicateLoserObjectIDs(
    _ items: [NSManagedObjectID],
    context: NSManagedObjectContext
  )
    -> [NSManagedObjectID] {
    var winnersById = [String: NSManagedObjectID]()
    for objectID in items {
      guard let serverId = serverId(for: objectID, context: context), !serverId.isEmpty else {
        continue
      }
      if let existing = winnersById[serverId] {
        winnersById[serverId] = preferredObjectID(existing, objectID, context: context)
      } else {
        winnersById[serverId] = objectID
      }
    }

    return items.filter { objectID in
      guard let serverId = serverId(for: objectID, context: context), !serverId.isEmpty else {
        return false
      }
      return winnersById[serverId] != objectID
    }
  }

  private static func serverId(
    for objectID: NSManagedObjectID,
    context: NSManagedObjectContext
  )
    -> String? {
    guard let object = try? context.existingObject(with: objectID) else { return nil }
    if let artistMO = object as? ArtistMO { return artistMO.id }
    if let albumMO = object as? AlbumMO { return albumMO.id }
    return nil
  }

  private static func preferredObjectID(
    _ first: NSManagedObjectID,
    _ second: NSManagedObjectID,
    context: NSManagedObjectContext
  )
    -> NSManagedObjectID {
    let firstScore = richnessScore(for: first, context: context)
    let secondScore = richnessScore(for: second, context: context)
    if firstScore == secondScore { return first }
    return firstScore > secondScore ? first : second
  }

  private static func richnessScore(
    for objectID: NSManagedObjectID,
    context: NSManagedObjectContext
  )
    -> Int {
    guard let object = try? context.existingObject(with: objectID) else { return 0 }
    if let artistMO = object as? ArtistMO {
      // Cassette fork — Patch 102 (Phase 3.3). The empty-artist-detail bug came
      // from this winner picking a metadata-only stub over the relationship-rich
      // duplicate with the same server id. ArtistDetailVC binds to the winning
      // objectID and its FRCs match by object identity (song.artist == self /
      // album.artist == self), so a stub with scalar counts + artwork but no
      // related songs/albums renders an empty page. Actual related content must
      // dominate: weight the real relationship counts far above the scalar
      // songCount + artwork tiebreakers so a relationship-rich artist always wins.
      let relationshipCount = (artistMO.songs?.count ?? 0) + (artistMO.albums?.count ?? 0)
      var score = relationshipCount * 1_000_000
      let artist = Artist(managedObject: artistMO)
      score += artist.songCount
      if artist.artwork != nil { score += 1_000 }
      return score
    }
    if let albumMO = object as? AlbumMO {
      let album = Album(managedObject: albumMO)
      var score = album.songs.count
      if album.isSongsMetaDataSynced { score += 1_000 }
      if album.artwork != nil { score += 100 }
      return score
    }
    return 0
  }
}
