//
//  PhoneRemoval.swift
//  AmperfyKit
//
//  Cassette: "Remove from This Phone" (UX review 2026-10-20). The person removes an
//  album from the phone; its files go now, and the phone tells the cloud to keep that
//  album off this phone. Without that, a phone set to sync Everything would get the
//  album straight back on its next inventory report. The album stays on the computer
//  and in the library; the device page in Cassette Player lists it under "Kept off
//  this phone" with a way to send it back.
//
//  Offline-safe: the songs to keep off are remembered until the cloud has them, and
//  IntentExecutor sends them before it reports inventory, so the reconcile that the
//  report triggers already knows.
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

import CoreData
import Foundation

@MainActor
public enum PhoneRemoval {
  private static let pendingKey = "cassette.phoneRemoval.pendingLocalIds"

  /// Delete these songs' files from the phone and keep their albums off it.
  /// Songs that are not on the phone are skipped. Returns how many were removed.
  @discardableResult
  public static func remove(songIds: Set<String>, context: NSManagedObjectContext) -> Int {
    guard !songIds.isEmpty else { return 0 }
    let manager = DeviceOwnershipManager(context: context)
    let rows = (try? manager.fetchAll()) ?? []
    let localIds = rows
      .filter { songIds.contains($0.subsonicTrackId ?? "") }
      .map(\.cassetteLocalId)

    var removed: [String] = []
    for localId in localIds {
      do {
        try manager.remove(cassetteLocalId: localId)
        removed.append(localId)
      } catch {
        print("Cassette remove: \(localId) failed - \(error.localizedDescription)")
      }
    }
    guard !removed.isEmpty else { return 0 }

    remember(removed)
    CassetteOwnershipNotifier.shared.ownershipDidChangeNow()
    Task { await sendPending() }
    return removed.count
  }

  /// Tell the cloud about every removal it has not heard about yet, then report the
  /// smaller inventory. Safe to call any time; a failure keeps the list for next time.
  public static func sendPending() async {
    let localIds = pending
    guard !localIds.isEmpty else { return }
    do {
      try await CassetteSyncAPI.shared.keepOffThisPhone(cassetteLocalIds: localIds)
      forget(localIds)
      try? await CassetteSyncAPI.shared.reportDeviceInventory(
        deviceId: CassetteSyncAPI.deviceId,
        deviceLabel: CassetteSyncAPI.deviceLabel,
        added: [],
        removed: localIds
      )
    } catch {
      print("Cassette remove: keep-off not sent yet - \(error.localizedDescription)")
    }
  }

  private static var pending: [String] {
    UserDefaults.standard.stringArray(forKey: pendingKey) ?? []
  }

  private static func remember(_ localIds: [String]) {
    var set = pending
    for id in localIds where !set.contains(id) { set.append(id) }
    UserDefaults.standard.set(set, forKey: pendingKey)
  }

  private static func forget(_ localIds: [String]) {
    let sent = Set(localIds)
    UserDefaults.standard.set(pending.filter { !sent.contains($0) }, forKey: pendingKey)
  }
}
