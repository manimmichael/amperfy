//
//  MadeForYou.swift
//  AmperfyKit
//
//  Cassette: the made-for-you playlists, made in the cloud (founder, 2026-10-22: "track and
//  tune their quality across both"). Lately, this part of the day, Been a While and the mood
//  mixes come from GET /api/sync/made-for-you, the same set the desktop app plays, as
//  cassette_local_ids; Home plays the ones on the phone. A copy is kept on the phone for
//  offline and CarPlay. The phone's own recipe (ListeningShelves' made-for-you maths) only
//  stands in when it holds no set for this part of the day (a first launch offline).
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

/// One part of the day's made-for-you playlists, as the cloud sends them.
public struct MadeForYouFeed: Codable, Sendable, Equatable {
  public struct Cover: Codable, Sendable, Equatable {
    public let key: String
    public let variant: String
  }

  public struct Mix: Codable, Sendable, Equatable {
    /// "lately", "daypart", "been-a-while" or "mood:<key>"
    public let id: String
    /// "lately", "daypart", "been-a-while" or "mood"
    public let kind: String
    public let title: String
    public let subtitle: String?
    public let color: String?
    /// A mood mix's drawn cover for the day.
    public let cover: Cover?
    /// cassette_local_ids, in play order.
    public let songs: [String]
  }

  public let version: Int
  /// The listener's day, "2026-10-22".
  public let day: String
  /// The listener's part of the day, "weekday-evening".
  public let slot: String
  public let mixes: [Mix]

  /// A moment's day and part of the day, written as the cloud writes them.
  public static func keys(for date: Date, calendar: Calendar = .current) -> (day: String, slot: String) {
    let parts = calendar.dateComponents([.year, .month, .day, .hour], from: date)
    let day = String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    let daypart = ListeningShelves.Daypart(hour: parts.hour ?? 0)
    return (day, "\(calendar.isDateInWeekend(date) ? "weekend" : "weekday")-\(daypart)")
  }
}

@MainActor
public final class MadeForYouStore {
  public static let shared = MadeForYouStore()

  /// The set held: the last one fetched, kept on disk.
  public private(set) var feed: MadeForYouFeed?
  /// Moves whenever a fetch brings a set that differs from the one held.
  public private(set) var revision = 0
  private var fetchedAt = Date.distantPast
  private var triedAt = Date.distantPast
  private var fetching = false

  private init() {
    if let data = try? Data(contentsOf: Self.fileURL),
       let cached = try? JSONDecoder().decode(MadeForYouFeed.self, from: data) {
      feed = cached
    }
  }

  /// The set held when it is this moment's (the same day and part of the day), else nil.
  public func feed(for now: Date) -> MadeForYouFeed? {
    guard let feed else { return nil }
    let keys = MadeForYouFeed.keys(for: now)
    return feed.day == keys.day && feed.slot == keys.slot ? feed : nil
  }

  /// Fetch when the set held is not this moment's, or half an hour after the last fetch; at
  /// most once a minute. A failure keeps what is held.
  public func refreshIfDue(now: Date = Date()) async {
    let stale = feed(for: now) == nil
    guard !fetching, now.timeIntervalSince(triedAt) > 60,
          stale || now.timeIntervalSince(fetchedAt) > 30 * 60
    else { return }
    fetching = true
    triedAt = now
    defer { fetching = false }
    do {
      let fresh = try await CassetteSyncAPI.shared.getMadeForYou(timeZone: TimeZone.current.identifier)
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
      // Home and CarPlay rebuild their made-for-you rows on this
      NotificationCenter.default.post(name: .cassetteLibraryMoodsChanged, object: nil)
      print("Cassette made for you: \(fresh.mixes.count) playlists for \(fresh.day) \(fresh.slot)")
    } catch {
      print("Cassette made for you: fetch failed - \(error.localizedDescription)")
    }
  }

  private static var fileURL: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("CassetteMoods/made-for-you.json")
  }
}
