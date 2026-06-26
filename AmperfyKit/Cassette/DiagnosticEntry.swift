//
//  DiagnosticEntry.swift
//  AmperfyKit
//
//  Cassette fork — Diagnostics Phase 1 (rolling diagnostic log).
//
//  The lightweight value type stored in the in-memory ring buffer
//  (`DiagnosticLog`). One entry is one breadcrumb: a timestamp, a coarse
//  category for filtering, a human-readable message, and an optional small
//  string→string context bag. Kept deliberately cheap (no rich object graphs)
//  so appending thousands per session never pressures memory or the allocator.
//
//  `Codable` so a snapshot serializes straight into the export payload
//  (see `LogData.rollingTrace`); `Sendable` so it can cross the serial queue
//  that backs the buffer under Swift 6 strict concurrency.
//

import Foundation

// MARK: - DiagnosticCategory

/// Coarse bucket for a diagnostic breadcrumb. Used only for filtering/reading;
/// the full detail always lives in `DiagnosticEntry.message`, so an imperfect
/// category never loses information.
public enum DiagnosticCategory: String, Codable, Sendable, CaseIterable {
  case playback
  case api
  case carplay
  case network
  case lifecycle
  case marker
  case crashContext

  /// Best-effort classification for entries mirrored out of `EventLogger`.
  /// Server/connection errors dominate that funnel, so the default is `.api`;
  /// player-topic'd reports are surfaced as `.playback`. The original topic is
  /// preserved verbatim in the message regardless of bucket.
  public static func forEventLog(topic: String, isApiError: Bool) -> DiagnosticCategory {
    let t = topic.lowercased()
    if t.contains("player") || t.contains("playback") || t.contains("stream") {
      return .playback
    }
    return .api
  }
}

// MARK: - DiagnosticEntry

public struct DiagnosticEntry: Codable, Sendable {
  public let timestamp: Date
  public let category: DiagnosticCategory
  public let message: String
  public let context: [String: String]?

  public init(
    timestamp: Date,
    category: DiagnosticCategory,
    message: String,
    context: [String: String]? = nil
  ) {
    self.timestamp = timestamp
    self.category = category
    self.message = message
    self.context = context
  }
}
