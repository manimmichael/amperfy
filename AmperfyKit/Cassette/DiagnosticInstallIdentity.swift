//
//  DiagnosticInstallIdentity.swift
//  AmperfyKit
//
//  Cassette fork — Diagnostics Phase 2 (anonymous install correlation id).
//
//  `install_id` is the anonymous, client-persistent UUID the diagnostics spine
//  uses to correlate a device's reports and to rate-limit them. It is NOT an
//  identity — it carries no account, name or email. It must survive a normal app
//  reinstall so a device that crashes, gets deleted and reinstalled still lines
//  up as one install, so it lives in the Keychain (which outlives the app
//  container) with a UserDefaults mirror as a fallback for the rare case where a
//  Keychain read/write is denied (e.g. a locked device before first unlock).
//
//  This is the small Keychain-backed identity the rest of the code has deferred
//  ("Keychain is a later hardening step", Settings.swift). It is intentionally
//  scoped to this one non-sensitive value.
//

import Foundation
import os.log
import Security

// MARK: - DiagnosticInstallIdentity

public enum DiagnosticInstallIdentity {
  private static let log = OSLog(subsystem: "Amperfy", category: "DiagnosticInstallIdentity")

  private static let keychainService = "digital.cassette.diagnostics"
  private static let keychainAccount = "install_id"
  private static let defaultsKey = "cassette.diagnostics.installId"

  /// The stable anonymous install id, minted once and reused forever. Resolution
  /// order: Keychain → UserDefaults mirror → mint. Any value found in one store
  /// is written back to the other so the two converge. Safe to call off the main
  /// actor and early in launch (uses `AfterFirstUnlockThisDeviceOnly` so the
  /// background crash drain can read it).
  public static var installId: String {
    if let existing = readKeychain() {
      // Keep the fallback mirror in step so a later Keychain failure still works.
      UserDefaults.standard.set(existing, forKey: defaultsKey)
      return existing
    }

    if let mirrored = UserDefaults.standard.string(forKey: defaultsKey),
       !mirrored.isEmpty {
      // Keychain was empty (first run after adopting it, or a prior write was
      // denied) but the mirror has a value — promote it into the Keychain.
      writeKeychain(mirrored)
      return mirrored
    }

    let minted = UUID().uuidString
    writeKeychain(minted)
    UserDefaults.standard.set(minted, forKey: defaultsKey)
    return minted
  }

  // MARK: Keychain

  private static func readKeychain() -> String? {
    let query: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: keychainAccount,
      kSecReturnData as String: true,
      kSecMatchLimit as String: kSecMatchLimitOne,
    ]
    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    guard status == errSecSuccess,
          let data = item as? Data,
          let value = String(data: data, encoding: .utf8),
          !value.isEmpty else {
      if status != errSecItemNotFound {
        os_log("install-id Keychain read failed: %d", log: log, type: .error, Int(status))
      }
      return nil
    }
    return value
  }

  private static func writeKeychain(_ value: String) {
    guard let data = value.data(using: .utf8) else { return }
    // Delete any prior row first so this is an upsert (SecItemAdd fails with
    // errSecDuplicateItem otherwise).
    let base: [String: Any] = [
      kSecClass as String: kSecClassGenericPassword,
      kSecAttrService as String: keychainService,
      kSecAttrAccount as String: keychainAccount,
    ]
    SecItemDelete(base as CFDictionary)

    var attributes = base
    attributes[kSecValueData as String] = data
    attributes[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
    let status = SecItemAdd(attributes as CFDictionary, nil)
    if status != errSecSuccess {
      os_log("install-id Keychain write failed: %d", log: log, type: .error, Int(status))
    }
  }
}
