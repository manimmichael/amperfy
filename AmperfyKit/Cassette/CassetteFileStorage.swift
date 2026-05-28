//
//  CassetteFileStorage.swift
//  AmperfyKit
//
//  Cassette fork — Layer 3 Phase 3.1 (Transfer Mechanism).
//
//  Pure file-system utility over a known directory:
//    Application Support/CassetteMusic/
//
//  This is the storage layer for *owned* files transferred from the user's
//  Cassette Player. It is entirely separate from Amperfy's existing
//  download cache and never touches it. No Core Data, no networking — just
//  the file system.
//
//  Files are left backup-eligible (no excludedFromBackup) so a user
//  restoring from an iCloud backup gets their music back. Revisit later.
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

public final class CassetteFileStorage: Sendable {
  public static let shared = CassetteFileStorage()

  private let musicDirURL: URL

  public init() {
    let appSupport = FileManager.default.urls(
      for: .applicationSupportDirectory,
      in: .userDomainMask
    ).first!
    musicDirURL = appSupport.appendingPathComponent("CassetteMusic", isDirectory: true)

    try? FileManager.default.createDirectory(
      at: musicDirURL,
      withIntermediateDirectories: true
    )
  }

  public func musicDirectory() -> URL { musicDirURL }

  public func filePath(for cassetteLocalId: String, extension ext: String) -> URL {
    musicDirURL.appendingPathComponent("\(cassetteLocalId).\(ext)")
  }

  public func fileExists(for cassetteLocalId: String, extension ext: String) -> Bool {
    FileManager.default
      .fileExists(atPath: filePath(for: cassetteLocalId, extension: ext).path)
  }

  /// Move a freshly-downloaded temp file into its final location.
  /// Last-write-wins on re-syncs: an existing target is replaced.
  public func moveTempFile(
    _ tempURL: URL,
    to cassetteLocalId: String,
    extension ext: String
  ) throws {
    let dest = filePath(for: cassetteLocalId, extension: ext)
    if FileManager.default.fileExists(atPath: dest.path) {
      try FileManager.default.removeItem(at: dest)
    }
    try FileManager.default.moveItem(at: tempURL, to: dest)
  }

  public func delete(cassetteLocalId: String, extension ext: String) throws {
    let url = filePath(for: cassetteLocalId, extension: ext)
    if FileManager.default.fileExists(atPath: url.path) {
      try FileManager.default.removeItem(at: url)
    }
  }

  public func fileSize(for cassetteLocalId: String, extension ext: String) -> Int64 {
    let url = filePath(for: cassetteLocalId, extension: ext)
    let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
    return (attrs?[.size] as? Int64) ?? 0
  }
}
