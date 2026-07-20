//
//  SubsonicArtworkDownloadDelegate.swift
//  AmperfyKit
//
//  Created by Maximilian Bauer on 09.06.21.
//  Copyright (c) 2021 Maximilian Bauer. All rights reserved.
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

final class SubsonicArtworkDownloadDelegate: DownloadManagerDelegate {
  /// max file size of an error response from an API
  private static let maxFileSizeOfErrorResponse = 2_000

  private let subsonicServerApi: SubsonicServerApi
  private let networkMonitor: NetworkMonitorFacade
  private let fileManager = CacheFileManager.shared

  init(subsonicServerApi: SubsonicServerApi, networkMonitor: NetworkMonitorFacade) {
    self.subsonicServerApi = subsonicServerApi
    self.networkMonitor = networkMonitor
  }

  var requestPredicate: NSPredicate {
    DownloadMO.onlyArtworksPredicate
  }

  var parallelDownloadsCount: Int {
    2
  }

  @MainActor
  func prepareDownload(
    downloadInfo: DownloadElementInfo,
    storage: AsyncCoreDataAccessWrapper
  ) async throws
    -> URL {
    guard downloadInfo.type == .artwork else { throw DownloadError.fetchFailed }
    guard networkMonitor.isConnectedToNetwork else { throw DownloadError.noConnectivity }
    let artworkId = try await storage.performAndGet { asyncCompanion in
      let artwork = Artwork(
        managedObject: asyncCompanion.context
          .object(with: downloadInfo.objectId) as! ArtworkMO
      )
      // Migration safety (deferred deletion). The synthetic "cassette-album" cover
      // path is retired — no code mints these ids anymore. But an existing device
      // may still carry one until the next regroup re-points it to the native cover
      // id, and the regroup runs AFTER this backfill on the first post-switch sync.
      // Navidrome never knew these ids (getCoverArt → error 70), so keep throwing so
      // a lingering synthetic row can't 404 or poison a good .CustomImage. Remove
      // this guard in a later release once no device can hold a cassette-album row.
      guard artwork.remoteInfo.type != "cassette-album" else {
        throw DownloadError.fetchFailed
      }
      return artwork.id
    }
    return try await subsonicServerApi.generateUrl(forArtworkId: artworkId)
  }

  func validateDownloadedData(fileURL: URL?, downloadURL: URL?) -> ResponseError? {
    guard let fileURL else {
      return ResponseError(
        type: .api,
        message: "Invalid download",
        cleansedURL: downloadURL?.asCleansedURL(cleanser: subsonicServerApi),
        data: nil
      )
    }
    guard let data = fileManager.getFileDataIfNotToBig(
      url: fileURL,
      maxFileSize: Self.maxFileSizeOfErrorResponse
    ) else { return nil }
    return subsonicServerApi.checkForErrorResponse(response: APIDataResponse(
      data: data,
      url: downloadURL
    ))
  }

  func completedDownload(
    downloadInfo: DownloadElementInfo,
    fileURL: URL,
    fileMimeType: String?,
    storage: AsyncCoreDataAccessWrapper
  ) async {
    guard downloadInfo.type == .artwork else { return }
    let artworkRemoteInfo = try? await storage.performAndGet { asyncCompanion in
      let artwork = Artwork(
        managedObject: asyncCompanion.context
          .object(with: downloadInfo.objectId) as! ArtworkMO
      )
      // DIAGNOSTIC: this download is about to REPLACE bytes that are already cached
      // for this artwork. For an album row that holds a user's picked cover, that is
      // precisely the overwrite that makes a pick "only temporary" — and it is
      // invisible from the poll's side, which only ever sees a file that exists.
      // Prints the identity so the culprit can be matched against the pick log.
      if artwork.status == .CustomImage, artwork.relFilePath != nil {
        print(
          "Cassette artwork: OVERWRITING cached cover - id '\(artwork.remoteInfo.id)' "
            + "type '\(artwork.remoteInfo.type)'"
        )
      }
      return artwork.remoteInfo
    }
    guard let artworkRemoteInfo else { return }
    let relFilePath = handleCustomImage(fileURL: fileURL, artworkRemoteInfo: artworkRemoteInfo)
    try? await storage.perform { asyncCompanion in
      let artwork = Artwork(
        managedObject: asyncCompanion.context
          .object(with: downloadInfo.objectId) as! ArtworkMO
      )
      if let relFilePath {
        artwork.status = .CustomImage
        artwork.relFilePath = relFilePath
      } else {
        // Rule 1/2: the move/decode failed — never publish a blank .CustomImage
        // (which would stick with no file and never retry). markErrorIfNeeded is
        // retryable and never demotes an existing good cover, so the next sync
        // re-attempts.
        artwork.markErrorIfNeeded()
      }
      asyncCompanion.saveContext()
    }
  }

  func handleCustomImage(fileURL: URL, artworkRemoteInfo: ArtworkRemoteInfo) -> URL? {
    guard let account = subsonicServerApi.account,
          let relFilePath = fileManager.createRelPath(for: artworkRemoteInfo, account: account),
          let absFilePath = fileManager.getAbsoluteAmperfyPath(relFilePath: relFilePath)
    else { return nil }
    // Rule 1/§5: verify the download fully decodes before it touches the cache.
    // An undecodable/transient download returns nil so completedDownload leaves
    // any existing cover untouched and keeps the artwork retryable.
    guard CoverImageStore.isDecodable(fileURL: fileURL) else { return nil }
    do {
      try fileManager.moveExcludedFromBackupItem(at: fileURL, to: absFilePath, accountInfo: account)
      // cassette §art-collapse: defensively square + generate the ~480px thumb
      // tier beside the lazily-downloaded full cover, before the artwork's
      // relFilePath is published, so the display path finds both tiers.
      CoverImageStore.processStoredCover(fullFileURL: absFilePath)
      return relFilePath
    } catch {
      return nil
    }
  }

  func failedDownload(
    downloadInfo: DownloadElementInfo,
    storage: AsyncCoreDataAccessWrapper
  ) async {
    guard downloadInfo.type == .artwork else { return }
    try? await storage.perform { asyncCompanion in
      let artwork = Artwork(
        managedObject: asyncCompanion.context
          .object(with: downloadInfo.objectId) as! ArtworkMO
      )
      artwork.markErrorIfNeeded()
      asyncCompanion.saveContext()
    }
  }
}
