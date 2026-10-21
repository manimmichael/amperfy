//
//  ListeningShelves.swift
//  AmperfyKit
//
//  Cassette: two Home rows built from the phone's own play log (UX review 2026-10-20).
//  The phone keeps a timestamp for every song played to the end (ScrobbleEntry), which
//  Home never used: it only read each song's last-played date and running count.
//
//   On Repeat         what you are into right now: albums ranked by how often you have
//                     played them in the last two weeks, recent plays counting more.
//   Around This Time  what you tend to play now: albums you play in this part of the day,
//                     on this kind of day (weekday or weekend), over the last two months.
//
//  Pure ranking over (date, album id) pairs, so it is testable without Core Data.
//  Never reads the retired albums.time_of_day concept: habits come only from real plays.
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

public struct ListeningPlay: Sendable, Equatable {
  public let date: Date
  public let albumID: String

  public init(date: Date, albumID: String) {
    self.date = date
    self.albumID = albumID
  }
}

public enum ListeningShelves {
  /// How far back the play log is read for either row.
  public static let lookbackDays = 60

  // On Repeat
  static let onRepeatWindowDays = 14
  static let onRepeatHalfLifeDays = 5.0
  static let onRepeatMinPlays = 3

  // Around This Time
  static let aroundNowHalfLifeDays = 21.0
  static let aroundNowMinPlays = 2

  public enum Daypart: Int, Sendable, CaseIterable {
    case morning, afternoon, evening, late

    public init(hour: Int) {
      switch hour {
      case 5 ... 10: self = .morning
      case 11 ... 16: self = .afternoon
      case 17 ... 21: self = .evening
      default: self = .late
      }
    }

    var name: String {
      switch self {
      case .morning: return "Mornings"
      case .afternoon: return "Afternoons"
      case .evening: return "Evenings"
      case .late: return "Late Nights"
      }
    }
  }

  /// Albums you have played at least three times in the last two weeks, by plays with
  /// recent ones weighted up (a five-day half-life), so a run of listening outranks one
  /// busy afternoon a fortnight ago.
  public static func onRepeat(_ plays: [ListeningPlay], now: Date) -> [String] {
    let since = now.addingTimeInterval(-Double(onRepeatWindowDays) * 86400)
    let recent = plays.filter { $0.date >= since && $0.date <= now }
    return rank(recent, now: now, halfLifeDays: onRepeatHalfLifeDays, minPlays: onRepeatMinPlays)
  }

  /// Albums you play in this part of the day on this kind of day, at least twice in the
  /// last two months, recent habits weighted up (a three-week half-life).
  public static func aroundNow(
    _ plays: [ListeningPlay],
    now: Date,
    calendar: Calendar = .current
  )
    -> [String] {
    let slot = slot(of: now, calendar: calendar)
    let since = now.addingTimeInterval(-Double(lookbackDays) * 86400)
    let matching = plays.filter {
      $0.date >= since && $0.date <= now && Self.slot(of: $0.date, calendar: calendar) == slot
    }
    return rank(matching, now: now, halfLifeDays: aroundNowHalfLifeDays, minPlays: aroundNowMinPlays)
  }

  /// The row's title for this moment: "Weekday Mornings", "Weekend Evenings", ...
  public static func aroundNowTitle(now: Date, calendar: Calendar = .current) -> String {
    let slot = slot(of: now, calendar: calendar)
    return "\(slot.weekend ? "Weekend" : "Weekday") \(slot.daypart.name)"
  }

  // MARK: - Internals

  struct Slot: Equatable {
    let weekend: Bool
    let daypart: Daypart
  }

  static func slot(of date: Date, calendar: Calendar) -> Slot {
    Slot(
      weekend: calendar.isDateInWeekend(date),
      daypart: Daypart(hour: calendar.component(.hour, from: date))
    )
  }

  /// Albums with at least `minPlays` plays, by decayed weight, ties by plain count, then id
  /// so the order is stable.
  static func rank(
    _ plays: [ListeningPlay],
    now: Date,
    halfLifeDays: Double,
    minPlays: Int
  )
    -> [String] {
    var weight: [String: Double] = [:]
    var count: [String: Int] = [:]
    for play in plays {
      let ageDays = max(0, now.timeIntervalSince(play.date) / 86400)
      weight[play.albumID, default: 0] += pow(0.5, ageDays / halfLifeDays)
      count[play.albumID, default: 0] += 1
    }
    return count
      .filter { $0.value >= minPlays }
      .keys
      .sorted { lhs, rhs in
        let lw = weight[lhs] ?? 0, rw = weight[rhs] ?? 0
        if lw != rw { return lw > rw }
        let lc = count[lhs] ?? 0, rc = count[rhs] ?? 0
        if lc != rc { return lc > rc }
        return lhs < rhs
      }
  }
}
