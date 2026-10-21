//
//  PlayerUtil.swift
//  AmperfyKit
//
//  Created by Maximilian Bauer on 18.11.21.
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

import Foundation
import Intents
import MediaPlayer

// MARK: - MusicPlayable

@MainActor
public protocol MusicPlayable: AnyObject {
  func didStartPlayingFromBeginning()
  func didStartPlaying()
  func didPause()
  func didStopPlaying()
  func didElapsedTimeChange()
  func didLyricsTimeChange(time: CMTime) // high refresh count
  func didPlaylistChange()
  func didArtworkChange()
  func didNowPlayingInfoChange()
  func didShuffleChange()
  func didRepeatChange()
  func didPlaybackRateChange()
}

extension MusicPlayable {
  public func didLyricsTimeChange(time: CMTime) {} // make it an optional method
  public func didNowPlayingInfoChange() {}
}

extension MusicPlayable {
  func didShuffleChange() {}
  func didRepeatChange() {}
  func didPlaybackRateChange() {}
  func errorOccurred(error: Error) {}
}

// MARK: - RadioNowPlayingInfo

public struct RadioNowPlayingInfo: Equatable, Sendable {
  public let title: String
  public let artist: String

  public init(title: String, artist: String) {
    self.title = title
    self.artist = artist
  }

  public var isEmpty: Bool {
    title.isEmpty && artist.isEmpty
  }
}

// MARK: - RadioLiveInfo

/// cassette 2026-10-21: what cassette.digital knows about the station on air,
/// read from the station's own feed (docs/reference/CASSETTE_RADIO.md): the song
/// or the show, the show's picture, when it ends and what comes next. The app's
/// radio feed sets it while a registry station plays; the in-stream title still
/// fills in where the feed names no song.
public struct RadioLiveInfo: Equatable, Sendable {
  public var songTitle: String?
  public var songArtist: String?
  public var show: String?
  public var host: String?
  public var until: Date?
  /// What comes next: a show's name, or "Song · Artist" on a station that
  /// publishes its running order.
  public var next: String?
  public var nextStarts: Date?
  /// The picture to wear, by URL: the record we carry, else the song's cover from the
  /// station, else the show's own.
  public var artworkURL: String?
  /// cassette 2026-10-21: the record on Cassette the song matched, when it did (its web
  /// slug and title), so the player can offer to go and see it.
  public var albumSlug: String?
  public var albumTitle: String?

  public init(
    songTitle: String? = nil,
    songArtist: String? = nil,
    show: String? = nil,
    host: String? = nil,
    until: Date? = nil,
    next: String? = nil,
    nextStarts: Date? = nil,
    artworkURL: String? = nil,
    albumSlug: String? = nil,
    albumTitle: String? = nil
  ) {
    self.songTitle = songTitle
    self.songArtist = songArtist
    self.show = show
    self.host = host
    self.until = until
    self.next = next
    self.nextStarts = nextStarts
    self.artworkURL = artworkURL
    self.albumSlug = albumSlug
    self.albumTitle = albumTitle
  }

  /// "Until 1:00 PM, then MARTELO" / "Until 1:00 PM · 3:00 PM: Drive Time" /
  /// "Next: Waterloo Sunset · The Kinks". Times in the listener's own clock.
  public var whenLine: String? {
    let clock = { (d: Date) in d.formatted(date: .omitted, time: .shortened) }
    // A feed can lag past a show's end; a time already gone drops out.
    let now = Date()
    let until = self.until.flatMap { $0 > now ? $0 : nil }
    let nextStarts = self.nextStarts.flatMap { $0 > now ? $0 : nil }
    let untilText = until.map { "Until \(clock($0))" }
    guard let next, !next.isEmpty else { return untilText }
    var backToBack = false
    if let until, let nextStarts { backToBack = abs(nextStarts.timeIntervalSince(until)) < 120 }
    let nextText: String
    if let nextStarts, !backToBack {
      nextText = "\(clock(nextStarts)): \(next)"
    } else {
      nextText = untilText == nil ? "Next: \(next)" : "then \(next)"
    }
    guard let untilText else { return nextText }
    return backToBack || nextStarts == nil ? "\(untilText), \(nextText)" : "\(untilText) · \(nextText)"
  }
}

// MARK: - RepeatMode

public enum RepeatMode: Int16, CaseIterable {
  case off
  case all
  case single

  public var nextMode: RepeatMode {
    switch self {
    case .off:
      return .all
    case .all:
      return .single
    case .single:
      return .off
    }
  }

  public var description: String {
    switch self {
    case .off: return "Off"
    case .all: return "All"
    case .single: return "Single"
    }
  }

  public var asMPRepeatType: MPRepeatType {
    switch self {
    case .off: return .off
    case .all: return .all
    case .single: return .one
    }
  }

  public static func fromMPRepeatType(type: MPRepeatType) -> RepeatMode {
    switch type {
    case .off:
      return .off
    case .one:
      return .single
    case .all:
      return .all
    default:
      return .off
    }
  }

  public static func fromINPlaybackRepeatMode(mode: INPlaybackRepeatMode) -> RepeatMode {
    switch mode {
    case .unknown:
      return .off
    case .none:
      return .off
    case .all:
      return .all
    case .one:
      return .single
    @unknown default:
      return .off
    }
  }
}

// MARK: - PlaybackRate

public enum PlaybackRate: Int, CaseIterable {
  case dot5 = 0
  case dot75
  case one
  case oneDot25
  case oneDot5
  case oneDot75
  case two

  public static func create(from playbackRate: Double) -> PlaybackRate {
    var rate = PlaybackRate.one
    if playbackRate < 0.4 {
      rate = .one
    } else if playbackRate < 0.6 {
      rate = .dot5
    } else if playbackRate < 0.8 {
      rate = .dot75
    } else if playbackRate < 1.1 {
      rate = .one
    } else if playbackRate < 1.3 {
      rate = .oneDot25
    } else if playbackRate < 1.6 {
      rate = .oneDot5
    } else if playbackRate < 1.8 {
      rate = .oneDot75
    } else if playbackRate < 2.1 {
      rate = .two
    } else {
      rate = .one
    }
    return rate
  }

  public var asDouble: Double {
    switch self {
    case .dot5: return 0.5
    case .dot75: return 0.75
    case .one: return 1
    case .oneDot25: return 1.25
    case .oneDot5: return 1.5
    case .oneDot75: return 1.75
    case .two: return 2
    }
  }

  public var description: String {
    switch self {
    case .dot5: return "0.5x"
    case .dot75: return "0.75x"
    case .one: return "1x"
    case .oneDot25: return "1.25x"
    case .oneDot5: return "1.5x"
    case .oneDot75: return "1.75x"
    case .two: return "2x"
    }
  }
}

// MARK: - PlayerQueueType

public enum PlayerQueueType: Int, CaseIterable {
  case prev = 0
  case user = 2
  case next = 3

  public var description: String {
    switch self {
    case .prev: return "Previous"
    case .user: return "Next in Queue"
    case .next: return "Next"
    }
  }
}

// MARK: - PlayerIndex

public struct PlayerIndex: Equatable {
  let queueType: PlayerQueueType
  let index: Int

  public init(queueType: PlayerQueueType, index: Int) {
    self.queueType = queueType
    self.index = index
  }

  public static func create(from indexPath: IndexPath) -> PlayerIndex? {
    guard let queueType = PlayerQueueType(rawValue: indexPath.section) else { return nil }
    return PlayerIndex(queueType: queueType, index: indexPath.row)
  }

  public var asIndexPath: IndexPath {
    IndexPath(row: index, section: queueType.rawValue)
  }
}
