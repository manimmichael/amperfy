//
//  Artwork.swift
//  AmperfyKit
//
//  Created by Maximilian Bauer on 01.01.20.
//  Copyright (c) 2020 Maximilian Bauer. All rights reserved.
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
import UIKit

// MARK: - ImageStatus

public enum ImageStatus: Int16, Sendable {
  case IsDefaultImage = 0
  case NotChecked = 1
  case CustomImage = 2
  case FetchError = 3
}

// MARK: - ArtworkRemoteInfo

public struct ArtworkRemoteInfo: Sendable, Hashable {
  public var id: String
  public var type: String
}

// MARK: - Artwork

public class Artwork: NSObject {
  public let managedObject: ArtworkMO
  private let fileManager = CacheFileManager.shared

  public init(managedObject: ArtworkMO) {
    self.managedObject = managedObject
  }

  public var id: String {
    get { managedObject.id }
    set { if managedObject.id != newValue { managedObject.id = newValue } }
  }

  public var account: Account? {
    get {
      guard let accountMO = managedObject.account else { return nil }
      return Account(managedObject: accountMO)
    }
    set {
      if managedObject.account != newValue?
        .managedObject { managedObject.account = newValue?.managedObject }
    }
  }

  public var type: String {
    get { managedObject.type }
    set { if managedObject.type != newValue { managedObject.type = newValue } }
  }

  public var status: ImageStatus {
    get { ImageStatus(rawValue: managedObject.status) ?? .NotChecked }
    set { managedObject.status = newValue.rawValue }
  }

  public func markErrorIfNeeded() {
    if status != .CustomImage {
      status = .FetchError
    } else if relFilePath.map({ !fileManager.fileExits(relFilePath: $0) }) ?? true {
      // A .CustomImage row whose backing file is GONE is not a real custom cover —
      // demote + clear it so it stops serving a dead path and becomes re-fetchable.
      // Without this, every download failure was a no-op on exactly the broken rows
      // (they stayed .CustomImage forever and never fell back to a placeholder).
      // A present file — a real folder cover or a user's pick — is never touched.
      status = .FetchError
      relFilePath = nil
    }
  }

  public var relFilePath: URL? {
    get {
      if let relFilePathString = managedObject.relFilePath {
        return URL(string: relFilePathString)
      }
      return nil
    }
    set {
      managedObject.relFilePath = newValue?.path
    }
  }

  /// The on-disk path of this artwork's image, or nil when there genuinely isn't one.
  ///
  /// The existence check is load-bearing. A row can carry .CustomImage plus a
  /// relFilePath whose file is GONE — a retired synthetic shell, or a cover removed
  /// out from under us. Returning that dead path made every surface hand it to the
  /// image decoder (the "can't open ... (fileExists == false)" spam and the
  /// black-band covers) AND made every "does this already have a good cover?" gate
  /// lie, so the backfills skipped the broken albums and nothing ever re-fetched
  /// them. Returning nil instead means the UI falls back to its generated
  /// placeholder and the backfills correctly see the cover as missing and heal it.
  public var imagePath: String? {
    guard status == .CustomImage, let relFilePath else { return nil }
    guard fileManager.fileExits(relFilePath: relFilePath),
          let absFilePath = fileManager.getAbsoluteAmperfyPath(relFilePath: relFilePath)
    else { return nil }
    return absFilePath.path
  }

  public var owners: [AbstractLibraryEntity] {
    var returnOwners = [AbstractLibraryEntity]()
    guard let ownersSet = managedObject.owners,
          let ownersMO = ownersSet.allObjects as? [AbstractLibraryEntityMO]
    else { return returnOwners }

    for ownerMO in ownersMO {
      returnOwners.append(AbstractLibraryEntity(managedObject: ownerMO))
    }
    return returnOwners
  }

  public var remoteInfo: ArtworkRemoteInfo {
    get { ArtworkRemoteInfo(id: managedObject.id, type: managedObject.type) }
    set {
      id = newValue.id
      type = newValue.type
    }
  }

  override public func isEqual(_ object: Any?) -> Bool {
    guard let object = object as? Artwork else { return false }
    return managedObject == object.managedObject
  }
}

// MARK: Downloadable

extension Artwork: Downloadable {
  public var objectID: NSManagedObjectID { managedObject.objectID }
  public var isCached: Bool { false }
  public var displayString: String {
    "Artwork account: \(account?.shortLogIdent ?? "-"), id: \(id), type: \(type)"
  }

  public var threadSafeInfo: DownloadElementInfo? { DownloadElementInfo(
    objectId: objectID,
    type: .artwork
  ) }
}
