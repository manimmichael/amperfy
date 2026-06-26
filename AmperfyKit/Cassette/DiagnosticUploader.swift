//
//  DiagnosticUploader.swift
//  AmperfyKit
//
//  Cassette fork — Diagnostics Phase 1 (upload seam, switched OFF).
//
//  The seam for a future Phase 2 backend, designed in now so enabling it is a
//  flip, not a refactor. This phase ships ONLY the no-op implementation and a
//  flag that defaults off. There is deliberately no network client, no endpoint
//  URL and no POST logic here — the real uploader, the cassette.digital
//  receiving endpoint, the R2 write and the Switchboard view are a separate
//  Phase 2 audit + spec, and that backend does not exist yet.
//
//  The contract Phase 1 delivers: everything that would be uploaded
//  (mark-moment / background flushes / MetricKit crash reports) is already
//  captured and snapshotted locally, so Phase 2 only has to implement
//  `DiagnosticUploader` and turn `DiagnosticsConfig.isUploadEnabled` on.
//

import Foundation

// MARK: - DiagnosticUploader

public protocol DiagnosticUploader: Sendable {
  /// Send a serialized diagnostic payload (rolling-buffer snapshot or crash
  /// report). Async + throwing-free so call sites stay trivial; a real
  /// implementation handles its own retry/backoff internally.
  func upload(_ payload: Data) async
}

// MARK: - NoopDiagnosticUploader

/// The only implementation this phase. Does nothing.
public struct NoopDiagnosticUploader: DiagnosticUploader {
  public init() {}
  public func upload(_ payload: Data) async {
    // Phase 2: route to cassette.digital. Intentionally empty for now.
  }
}

// MARK: - DiagnosticsConfig

public enum DiagnosticsConfig {
  /// Master switch for the upload seam. OFF in Phase 1 — no network code exists
  /// to honour it. `nonisolated(unsafe)` because this is a developer-/Phase-2-
  /// flipped flag rather than something mutated concurrently; Phase 2 should
  /// replace it with a real persisted setting.
  public nonisolated(unsafe) static var isUploadEnabled = false
}
