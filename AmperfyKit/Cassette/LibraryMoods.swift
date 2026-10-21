//
//  LibraryMoods.swift
//  AmperfyKit
//
//  Cassette: the catalog's mood tags for the songs on this phone (UX review 2026-10-20),
//  for More Like Lately and the Lately mix (ListeningShelves). Fetched from
//  GET /api/sync/library-moods at most twice a day and kept in a small file, so Home can
//  match moods offline and on launch without waiting on the network.
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

public struct LibraryMoodTags: Codable, Sendable, Equatable {
  public let moods: [String]
  public let energy: String?
  public let valence: String?

  public var vector: ListeningShelves.TagVector {
    ListeningShelves.tagVector(moods: moods, energy: energy, valence: valence)
  }
}

struct LibraryMoodsResponse: Decodable {
  struct Track: Decodable {
    let cassetteLocalId: String
    let moods: [String]
    let energy: String?
    let valence: String?

    enum CodingKeys: String, CodingKey {
      case cassetteLocalId = "cassette_local_id"
      case moods, energy, valence
    }
  }

  let tracks: [Track]
}

@MainActor
public final class LibraryMoods {
  public static let shared = LibraryMoods()

  private static let refreshInterval: TimeInterval = 12 * 3600
  private static let lastFetchKey = "cassette.libraryMoods.lastFetchAt"

  public private(set) var byLocalID: [String: LibraryMoodTags] = [:]
  public var hasTags: Bool { !byLocalID.isEmpty }

  private init() {
    if let data = try? Data(contentsOf: Self.fileURL),
       let cached = try? JSONDecoder().decode([String: LibraryMoodTags].self, from: data) {
      byLocalID = cached
    }
  }

  /// Fetch the tags when the cache is older than twelve hours (or `force`). A failure
  /// keeps the cached tags and tries again on a later pass.
  public func refreshIfDue(force: Bool = false) async {
    let last = UserDefaults.standard.object(forKey: Self.lastFetchKey) as? Date ?? .distantPast
    guard force || Date().timeIntervalSince(last) > Self.refreshInterval else { return }
    do {
      let fresh = try await CassetteSyncAPI.shared.getLibraryMoods()
      UserDefaults.standard.set(Date(), forKey: Self.lastFetchKey)
      guard fresh != byLocalID else { return }
      byLocalID = fresh
      if let data = try? JSONEncoder().encode(fresh) {
        try? FileManager.default.createDirectory(
          at: Self.fileURL.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try? data.write(to: Self.fileURL, options: .atomic)
      }
      print("Cassette moods: \(fresh.count) tagged songs")
    } catch {
      print("Cassette moods: fetch failed - \(error.localizedDescription)")
    }
  }

  private static var fileURL: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("CassetteMoods/library-moods.json")
  }
}
