//
//  PutSomethingOn.swift
//  AmperfyKit
//
//  Cassette: the Put something on row (founder, 2026-10-26: "its own row under Resume"). One
//  tile per thing a person might be doing (Focus, Rainy day, Dinner, Game night, Wind down),
//  answered in the cloud (GET /api/sync/put-something-on): the person's own playlist when their
//  library is deep enough for it, else a live station, with the stations for it listed behind
//  either answer. Home plays the playlist when the phone holds enough of it, else the first of
//  the stations the hub holds. Kept on the phone for offline, like the made-for-you set.
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

/// One part of the day's Put something on row, as the cloud sends it.
public struct PutSomethingOnFeed: Codable, Sendable, Equatable {
  public struct Cover: Codable, Sendable, Equatable {
    public let key: String
    public let variant: String
  }

  public struct Playlist: Codable, Sendable, Equatable {
    /// "mood:focus" (a made-for-you playlist) or "activity:dinner"
    public let id: String
    /// cassette_local_ids, in play order.
    public let songs: [String]
    /// The drawn cover of a made-for-you mood playlist, else nil.
    public let cover: Cover?
  }

  public struct Station: Codable, Sendable, Equatable {
    public let slug: String
    public let name: String
    public let network: String
    public let streamUrl: String
    public let image: String?
    public let accent: String
    /// The show on now, when a live station answers (its profile says the show fits).
    public let show: String?
  }

  public struct Activity: Codable, Sendable, Equatable {
    /// "focus", "rainy-day", "dinner", "game-night", "wind-down"
    public let key: String
    public let title: String
    public let color: String
    /// The made-for-you playlist this activity stands for ("mood:focus"): Home shows it here,
    /// not in the made-for-you row.
    public let mixId: String?
    /// The person's own playlist, when their library is deep enough for it.
    public let playlist: Playlist?
    /// The stations for it, best first.
    public let stations: [Station]
  }

  public let version: Int
  /// The listener's day, "2026-10-26".
  public let day: String
  /// The listener's part of the day, "weekday-evening".
  public let slot: String
  public let activities: [Activity]
}

@MainActor
public final class PutSomethingOnStore {
  public static let shared = PutSomethingOnStore()

  /// The row held: the last one fetched, kept on disk.
  public private(set) var feed: PutSomethingOnFeed?
  /// Moves whenever a fetch brings a row that differs from the one held.
  public private(set) var revision = 0
  private var fetchedAt = Date.distantPast
  private var triedAt = Date.distantPast
  private var fetching = false

  private init() {
    if let data = try? Data(contentsOf: Self.fileURL),
       let cached = try? JSONDecoder().decode(PutSomethingOnFeed.self, from: data) {
      feed = cached
    }
  }

  /// The row held when it is this moment's (the same day and part of the day), else nil.
  public func feed(for now: Date) -> PutSomethingOnFeed? {
    guard let feed else { return nil }
    let keys = MadeForYouFeed.keys(for: now)
    return feed.day == keys.day && feed.slot == keys.slot ? feed : nil
  }

  /// Fetch when the row held is not this moment's, or ten minutes after the last fetch (a saved
  /// station counts at once in the cloud); at most once a minute. A failure keeps what is held.
  public func refreshIfDue(now: Date = Date()) async {
    let stale = feed(for: now) == nil
    guard !fetching, now.timeIntervalSince(triedAt) > 60,
          stale || now.timeIntervalSince(fetchedAt) > 10 * 60
    else { return }
    fetching = true
    triedAt = now
    defer { fetching = false }
    do {
      let fresh = try await CassetteSyncAPI.shared.getPutSomethingOn(timeZone: TimeZone.current.identifier)
      fetchedAt = Date()
      guard fresh != feed else { return }
      feed = fresh
      revision += 1
      if let data = try? JSONEncoder().encode(fresh) {
        try? FileManager.default.createDirectory(
          at: Self.fileURL.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try? data.write(to: Self.fileURL, options: .atomic)
      }
      // Home rebuilds its rows on this
      NotificationCenter.default.post(name: .cassetteLibraryMoodsChanged, object: nil)
      print("Cassette put something on: \(fresh.activities.count) activities for \(fresh.day) \(fresh.slot)")
    } catch {
      print("Cassette put something on: fetch failed - \(error.localizedDescription)")
    }
  }

  private static var fileURL: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("CassetteMoods/put-something-on.json")
  }
}
