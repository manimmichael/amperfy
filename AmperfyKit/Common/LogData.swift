//
//  LogData.swift
//  AmperfyKit
//
//  Created by Maximilian Bauer on 19.05.21.
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
import UIKit

// MARK: - LogData

public struct LogData: Encodable {
  public var basicInfo: BasicInfo?
  public var deviceInfo: DeviceInfo?
  public var playerInfo: PlayerInfo?
  public var libraryInfo: LibraryInfo?
  public var userSettings: UserSettingsLog?
  public var userStatistics: [UserStatisticsOverview]?
  public var eventInfo: EventInfo?
  // Cassette — Diagnostics Phase 1: the full in-memory rolling trace, separate
  // from `eventInfo` (which stays capped at the latest 30 CoreData entries).
  public var rollingTrace: [DiagnosticEntry]?
  // Cassette — recent MetricKit crash/diagnostic payloads (crash + hang + CPU- and
  // disk-write-exception reports from prior sessions), embedded inline so an
  // exported report carries the actual stack traces instead of leaving them
  // unreachable in the app container. Newest first; capped at `attachedCrashCount`.
  public var crashDiagnostics: [CrashDiagnostic]?

  static let latestEventsCount = 30
  static let attachedCrashCount = 3

  @MainActor
  public static func collectInformation(amperfyData: AmperKit) -> LogData {
    var logData = LogData()

    var basicInfo = BasicInfo()
    basicInfo.appName = "Amperfy"
    basicInfo.appVersion = AmperKit.version
    basicInfo.appBuildNumber = AmperKit.buildNumber
    logData.basicInfo = basicInfo

    var deviceInfo = DeviceInfo()
    let currentDevice = UIDevice.current
    deviceInfo.device = currentDevice.model
    deviceInfo.iOSVersion = currentDevice.systemVersion
    deviceInfo.totalDiskCapacity = currentDevice.totalDiskCapacityInByte?.asByteString
    deviceInfo.availableDiskCapacity = currentDevice.availableDiskCapacityInByte?.asByteString
    logData.deviceInfo = deviceInfo

    logData.libraryInfo = LibraryInfo()
    logData.libraryInfo?.version = amperfyData.storage.settings.app.librarySyncVersion.description
    let allAccountInfos = amperfyData.storage.settings.accounts.allAccounts
    for accountInfo in allAccountInfos {
      let account = amperfyData.storage.main.library.getAccount(info: accountInfo)
      let accountLibraryInfo = amperfyData.storage.main.library.getInfo(account: account)
      logData.libraryInfo?.accounts?.append(accountLibraryInfo)
    }

    var playerInfo = PlayerInfo()
    playerInfo.isPlaying = amperfyData.player.isPlaying
    playerInfo.repeatType = amperfyData.player.repeatMode.description
    playerInfo.isShuffle = amperfyData.player.isShuffle
    playerInfo.songIndex = amperfyData.player.currentlyPlaying != nil ? 0 : -99
    playerInfo.playlistItemCount = amperfyData.player.prevQueueCount + amperfyData.player
      .nextQueueCount + 1
    logData.playerInfo = playerInfo

    var userSettings = UserSettingsLog()
    let settings = amperfyData.storage.settings
    userSettings.swipeLeadingActions = settings.user.swipeActionSettings.leading
      .compactMap { $0.displayName }
    userSettings.swipeTrailingActions = settings.user.swipeActionSettings.trailing
      .compactMap { $0.displayName }
    userSettings.playerDisplayStyle = settings.user.playerDisplayStyle.description
    userSettings.isOfflineMode = settings.user.isOfflineMode
    logData.userSettings = userSettings

    let allUserStatistics = amperfyData.storage.main.library.getAllUserStatistics()
    logData.userStatistics = allUserStatistics.compactMap { $0.createLogInfo() }

    var eventInfo = EventInfo()
    let eventLogs = amperfyData.storage.main.library.getAllLogEntries()
    eventInfo.totalEventCount = eventLogs.count
    eventInfo.events = Array(eventLogs.prefix(Self.latestEventsCount))
    eventInfo.attachedEventCount = eventInfo.events?.count ?? 0
    logData.eventInfo = eventInfo

    // Cassette — Diagnostics Phase 1: attach the full rolling trace (no 30-cap).
    logData.rollingTrace = DiagnosticLog.shared.snapshot()

    // Cassette — embed the most recent MetricKit crash payloads so the exported
    // report is self-contained: the crash stack travels with the trace.
    logData.crashDiagnostics = collectCrashDiagnostics()

    return logData
  }

  /// Read the newest MetricKit crash/diagnostic payloads off disk (written by
  /// `DiagnosticCrashReporter` into the Diagnostics directory) and decode each as
  /// inline JSON so it embeds cleanly in the exported report. Best-effort: a
  /// missing directory or an unreadable/garbled file is skipped, never fatal.
  private static func collectCrashDiagnostics() -> [CrashDiagnostic]? {
    guard let dir = DiagnosticLog.diagnosticsDirectory(),
          let files = try? FileManager.default.contentsOfDirectory(
            at: dir,
            includingPropertiesForKeys: nil
          ) else { return nil }
    // Filenames are `crash-yyyyMMdd-HHmmss-<index>.json`, so a reverse
    // lexicographic sort is newest-first.
    let newestCrashFiles = files
      .filter { $0.lastPathComponent.hasPrefix("crash-") }
      .sorted { $0.lastPathComponent > $1.lastPathComponent }
      .prefix(attachedCrashCount)
    let decoder = JSONDecoder()
    let decoded: [CrashDiagnostic] = newestCrashFiles.compactMap { url in
      guard let data = try? Data(contentsOf: url),
            let payload = try? decoder.decode(JSONValue.self, from: data)
      else { return nil }
      return CrashDiagnostic(filename: url.lastPathComponent, payload: payload)
    }
    return decoded.isEmpty ? nil : decoded
  }
}

// MARK: - BasicInfo

public struct BasicInfo: Encodable {
  public var date: Date = .init()
  public var appName: String?
  public var appVersion: String?
  public var appBuildNumber: String?
}

// MARK: - DeviceInfo

public struct DeviceInfo: Encodable {
  public var device: String?
  public var iOSVersion: String?
  public var totalDiskCapacity: String?
  public var availableDiskCapacity: String?
}

// MARK: - LibraryInfo

public struct LibraryInfo: Encodable {
  public var version: String?
  public var accounts: [AccountLibraryInfo]?
}

// MARK: - AccountLibraryInfo

public struct AccountLibraryInfo: Encodable {
  public var apiType: String?
  public var genreCount: Int?
  public var artistCount: Int?
  public var albumCount: Int?
  public var songCount: Int?
  public var cachedSongCount: Int?
  public var playlistCount: Int?
  public var musicFolderCount: Int?
  public var directoryCount: Int?
  public var podcastCount: Int?
  public var podcastEpisodeCount: Int?
  public var radioCount: Int?
  public var artworkCount: Int?
  public var cachedSongSize: String?
}

// MARK: - PlayerInfo

public struct PlayerInfo: Encodable {
  public var isPlaying: Bool?
  public var repeatType: String?
  public var isShuffle: Bool?
  public var songIndex: Int?
  public var playlistItemCount: Int?
}

// MARK: - UserSettingsLog

public struct UserSettingsLog: Encodable {
  public var swipeLeadingActions: [String]?
  public var swipeTrailingActions: [String]?
  public var playerDisplayStyle: String?
  public var isOfflineMode: Bool?
}

// MARK: - EventInfo

public struct EventInfo: Encodable {
  public var totalEventCount: Int?
  public var attachedEventCount: Int?
  public var events: [LogEntry]?
}

// MARK: - CrashDiagnostic

/// One MetricKit diagnostic payload from a previous session (crash / hang / CPU /
/// disk-write exception), embedded in the exported report as inline JSON alongside
/// the filename it was captured to.
public struct CrashDiagnostic: Encodable {
  public var filename: String
  public var payload: JSONValue
}

// MARK: - JSONValue

/// A minimal JSON tree used to embed an already-encoded JSON document (a MetricKit
/// payload) INLINE inside the export — as real nested JSON rather than an escaped
/// string, so the crash report stays human- and tool-readable. Whole numbers
/// re-encode without a decimal point, and all strings (binary names, symbols,
/// termination reason, OS version) are preserved verbatim.
public enum JSONValue: Codable {
  case null
  case bool(Bool)
  case number(Double)
  case string(String)
  case array([JSONValue])
  case object([String: JSONValue])

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if container.decodeNil() {
      self = .null
    } else if let value = try? container.decode(Bool.self) {
      self = .bool(value)
    } else if let value = try? container.decode(Double.self) {
      self = .number(value)
    } else if let value = try? container.decode(String.self) {
      self = .string(value)
    } else if let value = try? container.decode([JSONValue].self) {
      self = .array(value)
    } else if let value = try? container.decode([String: JSONValue].self) {
      self = .object(value)
    } else {
      throw DecodingError.dataCorruptedError(
        in: container,
        debugDescription: "Unsupported JSON value"
      )
    }
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .null: try container.encodeNil()
    case let .bool(value): try container.encode(value)
    case let .number(value): try container.encode(value)
    case let .string(value): try container.encode(value)
    case let .array(value): try container.encode(value)
    case let .object(value): try container.encode(value)
    }
  }
}
