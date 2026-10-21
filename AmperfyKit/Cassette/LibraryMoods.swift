//
//  LibraryMoods.swift
//  AmperfyKit
//
//  Cassette: the catalog's mood tags for the songs on this phone (UX review 2026-10-20),
//  for More Like Lately and the Lately mix (ListeningShelves). Fetched from
//  GET /api/sync/library-moods at most twice a day and kept in a small file, so Home can
//  match moods offline and on launch without waiting on the network.
//
//  It also keeps the shared lately profile (GET /api/sync/taste-lately), built in the
//  cloud from every device's plays, so the Mac's listening shapes the phone's rows too.
//  LatelyLibrary falls back to the phone's own plays when there is none.
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

extension Notification.Name {
  /// Posted on the main actor when a refresh changed the mood tags or the shared lately
  /// profile, so rows built from them (Home's mood rows, MORE LIKE) can rebuild.
  public static let cassetteLibraryMoodsChanged = Notification.Name("cassette.libraryMoodsChanged")
}

public struct LibraryMoodTags: Codable, Sendable, Equatable {
  public let moods: [String]
  public let energy: String?
  public let valence: String?
  /// The song's sound (its subgenres, else its record's), nil from a server or a cache
  /// from before sound (BUG-498).
  public let subgenres: [String]?
  /// What the song is for (road_trip, workout, winding_down...), nil from an older server or
  /// cache. Only the mood playlists read it.
  public let scenarios: [String]?

  public var vector: ListeningShelves.TagVector {
    ListeningShelves.tagVector(
      moods: moods,
      energy: energy,
      valence: valence,
      sound: subgenres ?? [],
      scenarios: scenarios ?? []
    )
  }
}

struct LibraryMoodsResponse: Decodable {
  struct Track: Decodable {
    let cassetteLocalId: String
    let moods: [String]
    let energy: String?
    let valence: String?
    let subgenres: [String]?
    let scenarios: [String]?

    enum CodingKeys: String, CodingKey {
      case cassetteLocalId = "cassette_local_id"
      case moods, energy, valence, subgenres, scenarios
    }
  }

  let tracks: [Track]
}

@MainActor
public final class LibraryMoods {
  public static let shared = LibraryMoods()

  private static let refreshInterval: TimeInterval = 12 * 3600
  private static let lastFetchKey = "cassette.libraryMoods.lastFetchAt"
  /// Bumped when the payload grows, so a phone holding an older cache fetches at once instead
  /// of waiting out the twelve hours (2: each song's sound and scenarios, and the profile's
  /// sound, BUG-498). Set
  /// only once a fetch actually carries the new fields; until then the phone asks again
  /// hourly (a phone can be built before the server it talks to is deployed).
  private static let formatKey = "cassette.libraryMoods.format"
  private static let formatTriedKey = "cassette.libraryMoods.formatTriedAt"
  private static let format = 2
  private static let formatRetryInterval: TimeInterval = 3600

  public private(set) var byLocalID: [String: LibraryMoodTags] = [:]
  public var hasTags: Bool { !byLocalID.isEmpty }
  /// The cloud's lately profile, or empty when it has not been fetched.
  public private(set) var sharedProfile: ListeningShelves.TagVector = [:]

  private init() {
    if let data = try? Data(contentsOf: Self.fileURL),
       let cached = try? JSONDecoder().decode([String: LibraryMoodTags].self, from: data) {
      byLocalID = cached
    }
    if let data = try? Data(contentsOf: Self.profileURL),
       let cached = try? JSONDecoder().decode(ListeningShelves.TagVector.self, from: data) {
      sharedProfile = cached
    }
  }

  /// Fetch the tags when the cache is older than twelve hours (or `force`). A failure
  /// keeps the cached tags and tries again on a later pass.
  public func refreshIfDue(force: Bool = false) async {
    let defaults = UserDefaults.standard
    let last = defaults.object(forKey: Self.lastFetchKey) as? Date ?? .distantPast
    let formatTried = defaults.object(forKey: Self.formatTriedKey) as? Date ?? .distantPast
    let formatDue = defaults.integer(forKey: Self.formatKey) < Self.format
      && Date().timeIntervalSince(formatTried) > Self.formatRetryInterval
    guard force || formatDue || Date().timeIntervalSince(last) > Self.refreshInterval else { return }
    if formatDue { defaults.set(Date(), forKey: Self.formatTriedKey) }
    var changed = false
    defer {
      if changed {
        NotificationCenter.default.post(name: .cassetteLibraryMoodsChanged, object: nil)
      }
    }
    if let profile = try? await CassetteSyncAPI.shared.getLatelyProfile() {
      if profile != sharedProfile { changed = true }
      sharedProfile = profile
      if let data = try? JSONEncoder().encode(profile) {
        try? FileManager.default.createDirectory(
          at: Self.profileURL.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try? data.write(to: Self.profileURL, options: .atomic)
      }
    }
    do {
      let fresh = try await CassetteSyncAPI.shared.getLibraryMoods()
      UserDefaults.standard.set(Date(), forKey: Self.lastFetchKey)
      if fresh.values.contains(where: { $0.subgenres != nil }) {
        UserDefaults.standard.set(Self.format, forKey: Self.formatKey)
      }
      guard fresh != byLocalID else { return }
      byLocalID = fresh
      changed = true
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

  private static var profileURL: URL {
    fileURL.deletingLastPathComponent().appendingPathComponent("lately-profile.json")
  }

  private static var fileURL: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("CassetteMoods/library-moods.json")
  }
}
