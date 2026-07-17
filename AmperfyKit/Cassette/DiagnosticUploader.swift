//
//  DiagnosticUploader.swift
//  AmperfyKit
//
//  Cassette fork — Diagnostics Phase 2 (upload seam, switched ON).
//
//  The seam the Phase 1 no-op reserved. The live implementation
//  (`HTTPDiagnosticUploader`) posts to the diagnostics spine at
//  cassette.digital; this file owns the protocol both call sites reach through,
//  the retained no-op (for previews / non-uploading builds), and the shared
//  configuration: the process-wide uploader instance and the opt-out master
//  switch.
//
//  Consent model: crashes and hangs auto-upload (OPT-OUT — `isUploadEnabled`
//  defaults ON), while a full diagnostic export is only sent when the user
//  explicitly shares it. See HTTPDiagnosticUploader.
//

import Foundation

// MARK: - DiagnosticUploader

public protocol DiagnosticUploader: Sendable {
  /// Upload every not-yet-acknowledged MetricKit crash file on disk. Called at
  /// launch and again whenever MetricKit delivers new payloads (both are
  /// idempotent via the upload ledger). A real implementation handles its own
  /// retry/backoff internally; nothing is dropped unsent.
  func drainPendingCrashReports() async

  /// Upload a user-consented full diagnostics export. Device fields are supplied
  /// by the caller (read on the main actor). Returns whether the whole export —
  /// report plus its attachment — was accepted.
  func submitExport(
    payload: Data,
    occurredAt: Date,
    deviceModel: String,
    osVersion: String,
    breadcrumbs: [DiagnosticEntry]
  ) async -> Bool
}

// MARK: - NoopDiagnosticUploader

/// Retained for SwiftUI previews and any build that shouldn't touch the network.
/// Does nothing.
public struct NoopDiagnosticUploader: DiagnosticUploader {
  public init() {}
  public func drainPendingCrashReports() async {}
  public func submitExport(
    payload: Data,
    occurredAt: Date,
    deviceModel: String,
    osVersion: String,
    breadcrumbs: [DiagnosticEntry]
  ) async
    -> Bool { false }
}

// MARK: - DiagnosticsConfig

public enum DiagnosticsConfig {
  private static let uploadEnabledKey = "cassette.diagnostics.uploadEnabled"

  /// The process-wide uploader both `DiagnosticLog`/`DiagnosticCrashReporter` (the
  /// crash drain) and the Settings export action reach through. A single shared
  /// instance so there's one URLSession and one drain gate.
  public static let sharedUploader: DiagnosticUploader = HTTPDiagnosticUploader()

  /// Master switch for diagnostics upload. OPT-OUT: absent a stored value it is
  /// ON, so crashes/hangs auto-upload out of the box; a user can turn it off and
  /// that choice persists.
  public static var isUploadEnabled: Bool {
    get {
      let defaults = UserDefaults.standard
      guard defaults.object(forKey: uploadEnabledKey) != nil else { return true }
      return defaults.bool(forKey: uploadEnabledKey)
    }
    set {
      UserDefaults.standard.set(newValue, forKey: uploadEnabledKey)
    }
  }
}
