//
//  CassetteLocalID.swift
//  AmperfyKit
//
//  Cassette fork — Layer 1 (Identity). Additive only.
//
//  Cassette local-ID — the cross-device track identity fallback.
//
//  This MUST stay byte-for-byte compatible with:
//    - Go:  apps/cassette-player/sidecar/local-id.go
//    - TS:  apps/cassette/src/lib/cassette-local-id.ts
//
//  The shared fixture at apps/cassette/test/fixtures/local-id-vectors.json is
//  the locked source of truth. CassetteLocalIDTest.swift asserts every vector.
//
//  Pipeline (locked; mirrors the Go/TS comments):
//    1. NFKD-normalize each string (decompose + compatibility).
//    2. Strip Unicode combining marks (general category Mn).
//    3. NFKC-normalize (recompose to canonical form).
//    4. Lowercase (Unicode default, locale-independent).
//    5. Trim leading/trailing whitespace.
//    6. Collapse runs of whitespace to a single ASCII space.
//    7. Concatenate normalized artist, normalized title, and the
//       half-away-from-zero rounded integer duration, joined by U+001F
//       (unit separator) — a character no plausible artist/title contains.
//    8. SHA-256 the UTF-8 bytes.
//    9. Take the first 16 bytes (128 bits) and lowercase-hex-encode them.
//
//  Output is always exactly 32 lowercase hexadecimal characters.
//
//  NOTE on combining-mark stripping (audit-flagged divergence):
//  Go strips ALL Unicode Mn marks (runes.In(unicode.Mn)); TS strips only the
//  U+0300–U+036F "Combining Diacritical Marks" block. Every fixture vector uses
//  marks inside that block, so the two agree on the locked contract but can
//  diverge on exotic marks. This Swift port intentionally follows the broader,
//  more-correct Go rule (strip-all-Mn) — it passes the fixture AND matches the
//  sidecar exactly. See FORK_NOTES for the recommendation to align TS to all-Mn.
//

import CryptoKit
import Foundation

public enum CassetteLocalID {
  private static let unitSeparator = "\u{001f}"

  /// Compute the Cassette local-ID for a track.
  ///
  /// - Parameters:
  ///   - artist: Artist name. Whitespace and case are ignored; diacritics stripped.
  ///   - title: Track title. Same normalisation as artist.
  ///   - durationSeconds: Length in seconds, rounded to the nearest integer
  ///     (half away from zero). Non-finite or negative values are treated as 0.
  /// - Returns: A 32-character lowercase hex string.
  public static func compute(
    artist: String,
    title: String,
    durationSeconds: Double
  )
    -> String {
    let a = normalize(artist)
    let t = normalize(title)
    let d = durationKey(durationSeconds)

    let payload = a + unitSeparator + t + unitSeparator + d
    let digest = SHA256.hash(data: Data(payload.utf8))
    // First 16 bytes (128 bits) → 32 lowercase hex chars.
    return digest.prefix(16).map { String(format: "%02x", $0) }.joined()
  }

  /// Ergonomic helper for callers that already have an integer duration
  /// (e.g. Subsonic responses). Mirrors `CassetteLocalIDFromSeconds` in Go.
  public static func compute(
    artist: String,
    title: String,
    durationSeconds: Int
  )
    -> String {
    compute(artist: artist, title: title, durationSeconds: Double(durationSeconds))
  }

  // MARK: - Normalization (steps 1–6)

  static func normalize(_ input: String) -> String {
    if input.isEmpty { return "" }
    let stripped = stripDiacritics(input)
    let lowered = stripped.lowercased()
    return collapseWhitespace(lowered)
  }

  /// NFKD → remove combining marks (category Mn) → NFKC.
  private static func stripDiacritics(_ s: String) -> String {
    // `decomposedStringWithCompatibilityMapping` is NFKD.
    let decomposed = s.decomposedStringWithCompatibilityMapping
    var scalars = String.UnicodeScalarView()
    for scalar in decomposed.unicodeScalars
      where scalar.properties.generalCategory != .nonspacingMark {
      scalars.append(scalar)
    }
    // `precomposedStringWithCompatibilityMapping` is NFKC.
    return String(scalars).precomposedStringWithCompatibilityMapping
  }

  /// Trim leading/trailing whitespace and collapse internal runs of Unicode
  /// whitespace to a single ASCII space. Mirrors Go's
  /// `strings.Join(strings.FieldsFunc(s, unicode.IsSpace), " ")` and JS's
  /// `.trim().replace(/\s+/g, " ")`. Uses the Unicode White_Space property
  /// (`scalar.properties.isWhitespace`), matching Go's `unicode.IsSpace`.
  private static func collapseWhitespace(_ s: String) -> String {
    var result = String.UnicodeScalarView()
    var pendingSpace = false
    var started = false
    for scalar in s.unicodeScalars {
      if scalar.properties.isWhitespace {
        if started { pendingSpace = true }
      } else {
        if pendingSpace {
          result.append(" ")
          pendingSpace = false
        }
        result.append(scalar)
        started = true
      }
    }
    return String(result)
  }

  // MARK: - Duration key (step 7 input)

  /// Half-away-from-zero rounding for non-negative finite inputs; NaN, ±Inf,
  /// and negatives collapse to "0" — matching the Go/TS guards.
  private static func durationKey(_ d: Double) -> String {
    guard d.isFinite, d >= 0 else { return "0" }
    return String(Int64(d.rounded(.toNearestOrAwayFromZero)))
  }
}
