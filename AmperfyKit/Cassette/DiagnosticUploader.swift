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

  /// Upload a MANUAL user-feedback report (`report_type=user_feedback`). This is
  /// user-initiated, so it is ALWAYS sent regardless of the diagnostics opt-out
  /// (the flag only gates AUTO crash/hang reports). `message` becomes the report's
  /// `user_message`; an optional PNG `screenshot` rides as a `screenshot`
  /// attachment. Device fields are supplied by the caller (main actor). Returns
  /// whether the report — and its screenshot, if any — was accepted.
  func submitFeedback(
    message: String,
    screenshot: Data?,
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
  public func submitFeedback(
    message: String,
    screenshot: Data?,
    deviceModel: String,
    osVersion: String,
    breadcrumbs: [DiagnosticEntry]
  ) async
    -> Bool { false }
}

// MARK: - DiagnosticsConfig

public enum DiagnosticsConfig {
  private static let uploadEnabledKey = "cassette.diagnostics.uploadEnabled"
  private static let syncedConsentKey = "cassette.diagnostics.syncedConsent"

  /// The process-wide uploader both `DiagnosticLog`/`DiagnosticCrashReporter` (the
  /// crash drain) and the Settings export action reach through. A single shared
  /// instance so there's one URLSession and one drain gate.
  public static let sharedUploader: DiagnosticUploader = HTTPDiagnosticUploader()

  /// The device-local master switch, driven by the Diagnostics toggle. OPT-OUT:
  /// absent a stored value it is ON, so crashes/hangs auto-upload out of the box;
  /// a user can turn it off and that choice persists.
  public static var localUploadToggle: Bool {
    get {
      let defaults = UserDefaults.standard
      guard defaults.object(forKey: uploadEnabledKey) != nil else { return true }
      return defaults.bool(forKey: uploadEnabledKey)
    }
    set {
      UserDefaults.standard.set(newValue, forKey: uploadEnabledKey)
    }
  }

  /// The account-level consent mirrored from `/api/sync/account`
  /// (`diagnosticsConsent`), the same cross-device rail as theme/icon. OPT-OUT:
  /// absent a stored value it is ON, so an older deploy or an anonymous client
  /// stays always-on. Written by `CassetteSyncAPI.persistAccount` (pull) and
  /// `setDiagnosticsConsent` (push).
  public static var syncedConsent: Bool {
    get {
      let defaults = UserDefaults.standard
      guard defaults.object(forKey: syncedConsentKey) != nil else { return true }
      return defaults.bool(forKey: syncedConsentKey)
    }
    set {
      UserDefaults.standard.set(newValue, forKey: syncedConsentKey)
    }
  }

  /// Effective gate for AUTO reports (crash / hang / unhandled_error): BOTH the
  /// device-local toggle AND the synced account consent must be ON. Manual
  /// `user_feedback` and explicit exports bypass this — they are always sent. The
  /// setter writes the device-local toggle (the account consent is set via
  /// `CassetteSyncAPI.setDiagnosticsConsent`).
  public static var isUploadEnabled: Bool {
    get { localUploadToggle && syncedConsent }
    set { localUploadToggle = newValue }
  }
}
