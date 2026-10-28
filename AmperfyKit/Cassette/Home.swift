//
//  Home.swift
//  AmperfyKit
//
//  Cassette: One Home (founder, 2026-10-28). The cloud makes Home once, for every device:
//  which rows, in what order, under what names and with what in them, from every device's
//  plays (GET /api/sync/home, shape in apps/cassette/src/lib/home/types.ts). The iPhone, the
//  Mac app and CarPlay all draw it, each showing only what it holds. A copy is kept on the
//  phone, so Home opens at once and offline, and the car reads the same copy. The phone's own
//  Home recipe only stands in while no answer has ever been held (a first launch offline).
//
//  Everything arrives in ids every device shares: a record as its songs' cassette_local_ids,
//  a playlist by its cloud id, a station by its slug on the dial, an artist by a few songs.
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

/// Home as the cloud makes it (`HomeAnswer` in lib/home/types.ts).
public struct HomeAnswer: Codable, Sendable, Equatable {
  /// The answer shape this phone reads (the cloud's HOME_VERSION). A newer one is not drawn.
  public static let readableVersion = 1

  /// A record, found on the phone by any of its songs. `key` is made for you's album key.
  public struct Record: Codable, Sendable, Equatable {
    public let key: String
    public let title: String
    public let artist: String
    public let year: Int?
    /// cassette_local_ids
    public let songs: [String]
  }

  /// An artist, found on the phone by any of the songs listed.
  public struct Artist: Codable, Sendable, Equatable {
    public let key: String
    public let name: String
    public let songs: [String]
  }

  /// A made-for-you playlist (or Nostalgia's mix of songs from its years), in the made-for-you
  /// route's own shape.
  public typealias Mix = MadeForYouFeed.Mix

  public struct Playlist: Codable, Sendable, Equatable {
    /// The cloud id, the phone's PlaylistMO id.
    public let id: String
    public let name: String
    public let songs: Int
    public let cover: String?
    public let lastPlayedAt: String?
  }

  /// A reaching shelf: one sits on Home at a time, every one made today on All shelves.
  public struct Shelf: Codable, Sendable, Equatable {
    /// Stable for the day: "loud", "corner:pop punk", "nostalgia:1997-2003".
    public let id: String
    /// "loud", "quiet", "bops", "deep-dive", "nostalgia", "corner", "more-like", "rekindle"
    public let kind: String
    public let shout: String
    public let answer: String
    /// In the order drawn; Deep dive shows the first as its one big card.
    public let records: [Record]
    /// Nostalgia's mix, drawn before its records; else nil.
    public let mix: Mix?
    /// The shelf in Home's reaching row right now.
    public let onHome: Bool

    public var isDeepDive: Bool { kind == "deep-dive" }
  }

  /// What a row holds. A kind this phone does not know is kept as `.unknown` and not drawn.
  public enum Content: Sendable, Equatable {
    /// What you played last, on any device: a record (and the song), or a playlist.
    case resume(record: Record?, song: String?, playlist: String?)
    case records([Record])
    case mixes([Mix])
    case playlists([Playlist])
    /// Station slugs, in order.
    case stations([String])
    case reach(Shelf)
    case artists([Artist])
    /// The way to every shelf made today.
    case allShelves(count: Int)
    case unknown(kind: String)
  }

  /// One row: its id ("on-repeat"), its name in two voices (the shout and its answer, drawn
  /// as is: no row carries a reason line), and what it holds.
  public struct Row: Codable, Sendable, Equatable {
    public let id: String
    public let shout: String
    public let answer: String
    public let content: Content

    private enum Keys: String, CodingKey {
      case id, kind, shout, answer, record, song, playlist, records, mixes, playlists, stations,
           shelf, artists, count
    }

    /// Lenient: a part of a row that does not read leaves that part empty instead of losing
    /// the whole answer.
    public init(from decoder: Decoder) throws {
      let c = try decoder.container(keyedBy: Keys.self)
      id = (try? c.decode(String.self, forKey: .id)) ?? ""
      shout = (try? c.decode(String.self, forKey: .shout)) ?? ""
      answer = (try? c.decode(String.self, forKey: .answer)) ?? ""
      let kind = (try? c.decode(String.self, forKey: .kind)) ?? ""
      switch kind {
      case "resume":
        content = .resume(
          record: try? c.decodeIfPresent(Record.self, forKey: .record),
          song: try? c.decodeIfPresent(String.self, forKey: .song),
          playlist: try? c.decodeIfPresent(String.self, forKey: .playlist)
        )
      case "records":
        content = .records((try? c.decode([Record].self, forKey: .records)) ?? [])
      case "mixes":
        content = .mixes((try? c.decode([Mix].self, forKey: .mixes)) ?? [])
      case "playlists":
        content = .playlists((try? c.decode([Playlist].self, forKey: .playlists)) ?? [])
      case "stations":
        content = .stations((try? c.decode([String].self, forKey: .stations)) ?? [])
      case "reach":
        if let shelf = try? c.decode(Shelf.self, forKey: .shelf) {
          content = .reach(shelf)
        } else {
          content = .unknown(kind: kind)
        }
      case "artists":
        content = .artists((try? c.decode([Artist].self, forKey: .artists)) ?? [])
      case "all-shelves":
        content = .allShelves(count: (try? c.decode(Int.self, forKey: .count)) ?? 0)
      default:
        content = .unknown(kind: kind)
      }
    }

    public func encode(to encoder: Encoder) throws {
      var c = encoder.container(keyedBy: Keys.self)
      try c.encode(id, forKey: .id)
      try c.encode(shout, forKey: .shout)
      try c.encode(answer, forKey: .answer)
      switch content {
      case let .resume(record, song, playlist):
        try c.encode("resume", forKey: .kind)
        try c.encodeIfPresent(record, forKey: .record)
        try c.encodeIfPresent(song, forKey: .song)
        try c.encodeIfPresent(playlist, forKey: .playlist)
      case let .records(records):
        try c.encode("records", forKey: .kind)
        try c.encode(records, forKey: .records)
      case let .mixes(mixes):
        try c.encode("mixes", forKey: .kind)
        try c.encode(mixes, forKey: .mixes)
      case let .playlists(playlists):
        try c.encode("playlists", forKey: .kind)
        try c.encode(playlists, forKey: .playlists)
      case let .stations(stations):
        try c.encode("stations", forKey: .kind)
        try c.encode(stations, forKey: .stations)
      case let .reach(shelf):
        try c.encode("reach", forKey: .kind)
        try c.encode(shelf, forKey: .shelf)
      case let .artists(artists):
        try c.encode("artists", forKey: .kind)
        try c.encode(artists, forKey: .artists)
      case let .allShelves(count):
        try c.encode("all-shelves", forKey: .kind)
        try c.encode(count, forKey: .count)
      case let .unknown(kind):
        try c.encode(kind, forKey: .kind)
      }
    }
  }

  public let version: Int
  /// When the cloud made this answer (ISO).
  public let madeAt: String
  /// The listener's day and part of the day it was made for ("2026-10-28", "weekday-evening").
  public let day: String
  public let slot: String
  /// The day the day's playlists and shelves belong to (it turns at 4 am).
  public let madeOn: String
  /// Home, top to bottom. A row the phone can't fill from what it holds, it hides.
  public let rows: [Row]
  /// Every reaching shelf made today, for All shelves.
  public let shelves: [Shelf]

  private enum Keys: String, CodingKey {
    case version, madeAt, day, slot, madeOn, rows, shelves
  }

  public init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: Keys.self)
    version = try c.decode(Int.self, forKey: .version)
    madeAt = (try? c.decode(String.self, forKey: .madeAt)) ?? ""
    day = (try? c.decode(String.self, forKey: .day)) ?? ""
    slot = (try? c.decode(String.self, forKey: .slot)) ?? ""
    madeOn = (try? c.decode(String.self, forKey: .madeOn)) ?? ""
    rows = try c.decode([Row].self, forKey: .rows)
    shelves = (try? c.decode([Shelf].self, forKey: .shelves)) ?? []
  }

  public func encode(to encoder: Encoder) throws {
    var c = encoder.container(keyedBy: Keys.self)
    try c.encode(version, forKey: .version)
    try c.encode(madeAt, forKey: .madeAt)
    try c.encode(day, forKey: .day)
    try c.encode(slot, forKey: .slot)
    try c.encode(madeOn, forKey: .madeOn)
    try c.encode(rows, forKey: .rows)
    try c.encode(shelves, forKey: .shelves)
  }
}

extension Notification.Name {
  /// Posted on the main actor when the Home answer held on the phone changes.
  public static let cassetteHomeChanged = Notification.Name("cassette.homeChanged")
}

/// The Home answer held on the phone: the last one fetched, kept on disk. Asked for when the
/// app opens, when it comes back to the front, after plays are sent to the cloud, and every
/// half hour while the app is open; never more than once a minute. A failed ask keeps what is
/// held: offline, Home is the last answer.
@MainActor
public final class HomeStore {
  public static let shared = HomeStore()

  /// The answer held, or nil while none has ever been fetched (the phone's own Home stands
  /// in).
  public private(set) var answer: HomeAnswer?
  /// Moves whenever a fetch brings an answer that differs from the one held.
  public private(set) var revision = 0

  private var fetchedAt = Date.distantPast
  private var triedAt = Date.distantPast
  private var fetching = false
  private var timer: Timer?

  private static let askEvery: TimeInterval = 30 * 60
  private static let askAtMostEvery: TimeInterval = 60

  private init() {
    if let data = try? Data(contentsOf: Self.fileURL),
       let held = try? JSONDecoder().decode(HomeAnswer.self, from: data),
       held.version <= HomeAnswer.readableVersion {
      answer = held
    }
  }

  /// Ask when nothing has been fetched since launch, or half an hour after the last fetch.
  public func refreshIfDue(now: Date = Date()) async {
    startTimer()
    guard now.timeIntervalSince(fetchedAt) > Self.askEvery else { return }
    await fetch(now: now)
  }

  /// Ask now (the app came to the front, or plays just reached the cloud), unless an ask went
  /// out in the last minute.
  public func refresh(now: Date = Date()) async {
    startTimer()
    await fetch(now: now)
  }

  /// The half-hour ask while the app is open. A timer on the main run loop only fires while
  /// the app runs, which is when Home can be looked at.
  private func startTimer() {
    guard timer == nil else { return }
    timer = Timer.scheduledTimer(withTimeInterval: Self.askEvery, repeats: true) { _ in
      Task { @MainActor in await HomeStore.shared.refreshIfDue() }
    }
  }

  private func fetch(now: Date) async {
    guard !fetching, now.timeIntervalSince(triedAt) > Self.askAtMostEvery,
          CassetteSyncAPI.bearerToken != nil
    else { return }
    fetching = true
    triedAt = now
    defer { fetching = false }
    do {
      let fresh = try await CassetteSyncAPI.shared.getHome(timeZone: TimeZone.current.identifier)
      fetchedAt = Date()
      guard fresh.version <= HomeAnswer.readableVersion else {
        print("Cassette home: answer version \(fresh.version) is newer than this build reads")
        return
      }
      guard fresh != answer else { return }
      answer = fresh
      revision += 1
      if let data = try? JSONEncoder().encode(fresh) {
        try? FileManager.default.createDirectory(
          at: Self.fileURL.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try? data.write(to: Self.fileURL, options: .atomic)
      }
      NotificationCenter.default.post(name: .cassetteHomeChanged, object: nil)
      print("Cassette home: \(fresh.rows.count) rows, \(fresh.shelves.count) shelves for \(fresh.day) \(fresh.slot)")
    } catch {
      print("Cassette home: fetch failed - \(error.localizedDescription)")
    }
  }

  private static var fileURL: URL {
    let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
    return base.appendingPathComponent("CassetteHome/home.json")
  }
}
