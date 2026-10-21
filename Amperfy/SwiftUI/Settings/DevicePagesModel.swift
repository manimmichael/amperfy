//
//  DevicePagesModel.swift
//  Amperfy
//
//  Cassette fork (phone-taste): the one model behind the Settings root's YOUR MAC and
//  THIS PHONE groups, the Your Mac page and the This Phone page, so the three never
//  disagree and nothing is fetched twice.
//
//  What is on the phone comes from the ownership records (DeviceOwnershipManager), read
//  off the main thread. What the Mac has comes from the cloud's live device endpoints
//  (CassetteSyncAPI.getMacSummary / getThisDeviceSummary), fetched once per page open,
//  never on the 30s poll. The server's album keys never equal a phone album id, so every
//  server row goes through `resolveLocalAlbum` before it can show a local cover or play.
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

import AmperfyKit
import Combine
import SwiftUI
import UIKit

#if !targetEnvironment(macCatalyst)

  // MARK: - DeviceAlbum

  /// An album in the phone's own library, with what a tile or a row needs to draw it.
  struct DeviceAlbum: Identifiable {
    /// The local album id (AlbumMO.id).
    let id: String
    let album: Album
    let name: String
    let artist: String
    /// The cover on disk, when there is one.
    let coverPath: String?
  }

  // MARK: - KeptOffTile

  /// An album kept off this phone, from a fresh device payload.
  struct KeptOffTile: Identifiable {
    var id: String { row.groupKey }
    let row: CassetteDeviceSummary.KeptOffAlbum
    /// The local cover, when the album's songs are still in the library.
    let coverPath: String?

    /// The cloud's cover, used only when there is no local one.
    var remoteURL: URL? {
      [row.coverOverrideUrl, row.coverArtSmallUrl, row.coverArtUrl]
        .compactMap { $0 }
        .first { !$0.isEmpty }
        .flatMap { URL(string: $0) }
    }
  }

  // MARK: - DevicePagesModel

  @MainActor
  final class DevicePagesModel: ObservableObject {
    typealias PhoneSummary = (
      bytes: Int64,
      tracks: Int,
      albums: [DeviceOwnershipManager.OnPhoneAlbum]
    )

    /// The newest arrivals with a cover, for the Settings strip.
    static let stripLimit = 14

    // MARK: On this phone

    /// The ownership summary; nil until the first read lands.
    @Published
    private(set) var phone: PhoneSummary?
    /// Up to 14 albums that arrived last and have a real cover, newest first.
    @Published
    private(set) var stripAlbums: [DeviceAlbum] = []

    // MARK: The Mac

    /// The last Mac payload: the cached copy at once, then the live one.
    @Published
    private(set) var mac: CassetteMacSummary? = CassetteSyncAPI.cachedMacSummary
    @Published
    private(set) var macState: CassetteSyncStatus.MacState = .inSync
    /// NEW ON YOUR MAC: the Mac's newest albums that are on this phone (or, with no payload,
    /// the phone's own newest arrivals).
    @Published
    private(set) var newOnMac: [DeviceAlbum] = []
    /// The catalog colour of the first NEW ON YOUR MAC album, until its cover is read.
    @Published
    private(set) var leadSeed: CoverTint?
    @Published
    private(set) var isResyncing = false

    // MARK: This phone, as the cloud sees it

    /// This page open's device payload. Never cached: KEPT OFF acts on its ids.
    @Published
    private(set) var device: CassetteDeviceSummary?
    @Published
    private(set) var keptOff: [KeptOffTile] = []
    /// Albums being put back right now (by group key).
    @Published
    private(set) var puttingBack: Set<String> = []
    @Published
    private(set) var putBackFailed = false

    private var subscriptions: Set<AnyCancellable> = []
    /// Cover paths by local album id, for the This Phone rows (cleared with each phone read).
    private var coverPaths: [String: String?] = [:]
    private var phoneGeneration = 0
    private var deviceGeneration = 0
    private var didRefreshMacThisSession = false

    private var delegate: AppDelegate {
      UIApplication.shared.delegate as! AppDelegate
    }

    init() {
      recomputeMacState()
      let center = NotificationCenter.default
      center.publisher(for: CassetteLibraryFilterProvider.filterChangedNotification)
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
          MainActor.assumeIsolated { self?.reloadPhone() }
        }
        .store(in: &subscriptions)
      center.publisher(for: .cassetteSyncActiveChanged)
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
          MainActor.assumeIsolated { self?.recomputeMacState() }
        }
        .store(in: &subscriptions)
      center.publisher(for: .cassetteMacSummaryChanged)
        .receive(on: RunLoop.main)
        .sink { [weak self] _ in
          MainActor.assumeIsolated { self?.macSummaryChanged() }
        }
        .store(in: &subscriptions)
    }

    // MARK: Entry points

    /// The Settings root appeared: read the phone, and the Mac's heartbeat once per sheet.
    func settingsAppeared() {
      if phone == nil { reloadPhone() }
      recomputeMacState()
      guard !didRefreshMacThisSession else { return }
      didRefreshMacThisSession = true
      Task { _ = await CassetteSyncStatus.refreshMacSummary(maxAge: 120) }
    }

    /// The Mac page opened: fresh Mac and device payloads (the device one for the Syncs row
    /// and the kept-off count in the coverage line). The fetches belong to the model, not
    /// the page, so leaving the page does not cancel them halfway.
    func macPageOpened() {
      if phone == nil { reloadPhone() }
      recomputeMacState()
      Task { await refreshMac(force: false) }
      Task { await refreshDevice() }
    }

    /// The This Phone page opened: a fresh device payload for KEPT OFF.
    func phonePageOpened() {
      reloadPhone()
      Task { await refreshDevice() }
    }

    // MARK: The phone

    /// Re-read the ownership summary off the main thread (the walk covers every owned
    /// song), then resolve the strip and the shelves on main.
    func reloadPhone() {
      phoneGeneration += 1
      let generation = phoneGeneration
      let storage = delegate.storage
      Task {
        let summary = try? await storage.async.performAndGet { companion in
          DeviceOwnershipManager(context: companion.context).onPhoneSummary()
        }
        guard let summary, generation == self.phoneGeneration else { return }
        self.coverPaths = [:]
        self.phone = summary
        self.stripAlbums = self.resolveStrip(summary)
        self.rebuildNewOnMac()
        self.rebuildKeptOff()
      }
    }

    private func resolveStrip(_ summary: PhoneSummary) -> [DeviceAlbum] {
      var result: [DeviceAlbum] = []
      for entry in summary.albums.sorted(by: { $0.arrivedAt > $1.arrivedAt }) {
        guard let album = localAlbum(id: entry.albumId),
              let item = deviceAlbum(album),
              item.coverPath != nil
        else { continue }
        result.append(item)
        if result.count == Self.stripLimit { break }
      }
      return result
    }

    // MARK: The Mac

    func recomputeMacState() {
      let credentials = delegate.storage.settings.accounts.activeSetting.read.loginCredentials
      let canSync = CassetteSyncAPI.bearerToken != nil
        && delegate.networkMonitor.isConnectedToNetwork
      macState = CassetteSyncStatus.macState(
        isPaired: credentials?.serverUrl != nil,
        canSync: canSync
      )
    }

    private func macSummaryChanged() {
      mac = CassetteSyncAPI.cachedMacSummary
      recomputeMacState()
      rebuildNewOnMac()
    }

    private func refreshMac(force: Bool) async {
      _ = await CassetteSyncStatus.refreshMacSummary(maxAge: force ? 0 : 30, force: force)
      macSummaryChanged()
    }

    /// The hub's display name: the paired address, else the hostname the hub reported.
    var hubName: String? {
      let serverUrl = delegate.storage.settings.accounts.activeSetting.read.loginCredentials?
        .serverUrl
      return CassetteSyncStatus.displayHubName(serverUrl: serverUrl)
    }

    /// "just now", "5 min ago", "2 hr ago", "3 days ago": the hub's last full library sync
    /// (else its last heartbeat). nil when the cloud has not said.
    var lastSyncedAgo: String? {
      guard let hub = mac?.mac, let date = hub.lastSyncDate ?? hub.lastSeenDate else { return nil }
      return Self.ago(date)
    }

    /// The mock's `ago()`, rounding as it does.
    static func ago(_ date: Date, now: Date = Date()) -> String {
      let minutes = max(0, Int((now.timeIntervalSince(date) / 60).rounded()))
      if minutes < 1 { return "just now" }
      if minutes < 60 { return "\(minutes) min ago" }
      let hours = Int((Double(minutes) / 60).rounded())
      if hours < 24 { return "\(hours) hr ago" }
      return "\(Int((Double(hours) / 24).rounded())) days ago"
    }

    /// Resync Library: the Mac rescans its disk and the phone re-reports, without stopping
    /// playback or leaving Settings (IntentExecutor.convergeAndRefresh, the same call as
    /// Home's pull-to-refresh). Then the Mac payload is read again.
    func resync() async {
      guard !isResyncing else { return }
      isResyncing = true
      await IntentExecutor.shared.convergeAndRefresh()
      isResyncing = false
      await refreshMac(force: true)
    }

    private func rebuildNewOnMac() {
      guard let phone else { return }
      let onPhoneIds = Set(phone.albums.map(\.albumId))
      guard let mac, mac.mac != nil else {
        // No payload: the phone's own newest arrivals.
        var fallback: [DeviceAlbum] = []
        for entry in phone.albums.sorted(by: { $0.arrivedAt > $1.arrivedAt }).prefix(12) {
          if let album = localAlbum(id: entry.albumId), let item = deviceAlbum(album) {
            fallback.append(item)
          }
        }
        newOnMac = fallback
        leadSeed = nil
        return
      }
      var seen = Set<String>()
      var result: [DeviceAlbum] = []
      var seed: CoverTint?
      for item in mac.recentItems {
        guard let album = resolveLocalAlbum(
          groupKey: item.groupKey,
          localCoverTrackId: item.localCoverTrackId,
          albumName: item.albumName
        ),
          onPhoneIds.contains(album.id),
          seen.insert(album.id).inserted,
          let entry = deviceAlbum(album)
        else { continue }
        if result.isEmpty { seed = Self.tint(hex: item.dominantColor) }
        result.append(entry)
      }
      newOnMac = result
      leadSeed = seed
    }

    /// "#RRGGBB" from the catalog, as a record colour.
    static func tint(hex: String?) -> CoverTint? {
      guard var hex = hex?.trimmingCharacters(in: .whitespaces), !hex.isEmpty else { return nil }
      if hex.hasPrefix("#") { hex.removeFirst() }
      guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
      return CoverTint(baseRGB: value)
    }

    // MARK: This phone, as the cloud sees it

    private func refreshDevice() async {
      deviceGeneration += 1
      let generation = deviceGeneration
      guard CassetteSyncAPI.bearerToken != nil else { return }
      let fresh = try? await CassetteSyncAPI.shared.getThisDeviceSummary()
      guard generation == deviceGeneration else { return }
      device = fresh
      putBackFailed = false
      rebuildKeptOff()
    }

    private func rebuildKeptOff() {
      guard let device else {
        keptOff = []
        return
      }
      keptOff = device.keptOffAlbums.map { row in
        let album = resolveLocalAlbum(
          groupKey: row.groupKey,
          localCoverTrackId: row.localCoverTrackId,
          albumName: row.albumName,
          onPhoneOnly: false
        )
        return KeptOffTile(row: row, coverPath: album.flatMap { coverPath(of: $0) })
      }
    }

    /// Put an album back on this phone: clear its exclusion marks, drop the tile, and report
    /// the inventory now so the cloud queues it again.
    func putBack(_ tile: KeptOffTile) async {
      guard !puttingBack.contains(tile.id) else { return }
      puttingBack.insert(tile.id)
      putBackFailed = false
      do {
        try await CassetteSyncAPI.shared.putBack(targetIds: tile.row.excludeTargetIds)
        keptOff.removeAll { $0.id == tile.id }
        Task { await IntentExecutor.shared.reportInventoryNow() }
      } catch {
        putBackFailed = true
      }
      puttingBack.remove(tile.id)
    }

    /// Remove an album from this phone (as the album menu's Remove from This Phone does),
    /// then, once the keep-off has reached the cloud, read the device again so the album
    /// shows under KEPT OFF.
    func remove(albumId: String) {
      guard let album = localAlbum(id: albumId) else { return }
      PhoneRemoval.remove(
        songIds: Set(album.playables.map(\.id)),
        context: delegate.storage.main.context
      )
      Task {
        await PhoneRemoval.sendPending()
        await self.refreshDevice()
      }
    }

    // MARK: Download quality

    /// "Lossless" or "High": the account tier the downloads follow, else the local choice.
    static func downloadQualityLabel(storage: PersistentStorage) -> String {
      if let tier = CassetteSyncAPI.downloadQualityTier {
        return tier == "lossless" ? "Lossless" : "High"
      }
      return storage.settings.user.cacheTranscodingFormatPreference == .raw ? "Lossless" : "High"
    }

    // MARK: Resolving albums

    private var account: Account? {
      guard let info = delegate.storage.settings.accounts.active else { return nil }
      return delegate.storage.main.library.getAccount(info: info)
    }

    func localAlbum(id: String) -> Album? {
      guard let account, !id.isEmpty else { return nil }
      return delegate.storage.main.library.getAlbum(
        for: account,
        id: id,
        isDetailFaultResolution: false
      )
    }

    /// The cover path of an album on this phone, by its id; looked up once per phone read.
    func coverPath(albumId: String) -> String? {
      if let known = coverPaths[albumId] { return known }
      let path = localAlbum(id: albumId).flatMap { coverPath(of: $0) }
      coverPaths[albumId] = .some(path)
      return path
    }

    func coverPath(of album: Album) -> String? {
      guard let info = delegate.storage.settings.accounts.active else { return nil }
      let preference = delegate.storage.settings.accounts.getSetting(info).read
        .artworkDisplayPreference
      return album.imagePath(setting: preference)
    }

    private func deviceAlbum(_ album: Album) -> DeviceAlbum? {
      guard !album.id.isEmpty else { return nil }
      return DeviceAlbum(
        id: album.id,
        album: album,
        name: album.name,
        artist: album.artist?.name ?? "",
        coverPath: coverPath(of: album)
      )
    }

    /// A server album row (the Mac's newest, a kept-off album) as a local album. In order:
    /// 1. the hub track the server names (`localCoverTrackId`, which the phone stores as
    ///    the song id): exact;
    /// 2. a non-catalog key, which is the phone's own album key with U+0000 where the phone
    ///    has U+001F;
    /// 3. a unique case-insensitive name match among the albums on this phone.
    /// With `onPhoneOnly`, a result counts only when the album has songs on this phone (the
    /// owned album set, the same one `fetchOwnedAlbumIds` reads).
    func resolveLocalAlbum(
      groupKey: String,
      localCoverTrackId: String?,
      albumName: String,
      onPhoneOnly: Bool = true
    )
      -> Album? {
      guard let account else { return nil }
      let library = delegate.storage.main.library
      let onPhoneIds = Set((phone?.albums ?? []).map(\.albumId))
      func accept(_ album: Album?) -> Album? {
        guard let album, !album.id.isEmpty else { return nil }
        if onPhoneOnly, !onPhoneIds.contains(album.id) { return nil }
        return album
      }
      if let trackId = localCoverTrackId, !trackId.isEmpty,
         let album = accept(library.getSong(for: account, id: trackId)?.album) {
        return album
      }
      if !groupKey.hasPrefix("catalog-album:") {
        let key = groupKey.replacingOccurrences(of: "\u{0000}", with: "\u{001F}")
        if let album = accept(library.getAlbum(
          for: account,
          id: key,
          isDetailFaultResolution: false
        )) {
          return album
        }
      }
      let wanted = albumName.lowercased()
      let matches = (phone?.albums ?? []).filter { $0.name.lowercased() == wanted }
      if matches.count == 1, let album = accept(localAlbum(id: matches[0].albumId)) {
        return album
      }
      return nil
    }
  }

  // MARK: - DeviceCoverCache

  /// Local covers for the device pages, decoded small off the main thread and kept by path
  /// and size.
  @MainActor
  enum DeviceCoverCache {
    private static let cache = NSCache<NSString, UIImage>()

    private static func key(_ path: String, _ maxPixel: Int) -> NSString {
      "\(maxPixel)|\(path)" as NSString
    }

    static func cached(path: String?, maxPixel: Int) -> UIImage? {
      guard let path else { return nil }
      return cache.object(forKey: key(path, maxPixel))
    }

    static func image(path: String?, maxPixel: Int) async -> UIImage? {
      guard let path, !path.isEmpty else { return nil }
      if let hit = cached(path: path, maxPixel: maxPixel) { return hit }
      let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
        let source = CoverImageStore.preferredSourcePath(forFullPath: path, smallSurface: true)
        return CoverImageStore.downsampledImage(atPath: source, maxPixel: maxPixel)
      }.value
      if let image { cache.setObject(image, forKey: key(path, maxPixel)) }
      return image
    }
  }

  // MARK: - DeviceCoverView

  /// A local album cover at `side` points; the cloud's cover for an album no longer on the
  /// phone; else the letter placeholder (Barlow ExtraBold 28, ink3 on bg3).
  struct DeviceCoverView: View {
    let path: String?
    let title: String
    let side: CGFloat
    let radius: CGFloat
    let remoteURL: URL?

    @State
    private var image: UIImage?

    init(path: String?, title: String, side: CGFloat, radius: CGFloat, remoteURL: URL? = nil) {
      self.path = path
      self.title = title
      self.side = side
      self.radius = radius
      self.remoteURL = remoteURL
      _image = State(initialValue: DeviceCoverCache.cached(
        path: path,
        maxPixel: Self.maxPixel(side)
      ))
    }

    private static func maxPixel(_ side: CGFloat) -> Int {
      Int((side * 3).rounded(.up))
    }

    var body: some View {
      ZStack {
        Color.cassette(.surfaceElevated)
        if let image {
          Image(uiImage: image)
            .resizable()
            .scaledToFill()
        } else if path == nil, let remoteURL {
          AsyncImage(url: remoteURL) { phase in
            if let remote = phase.image {
              remote.resizable().scaledToFill()
            } else {
              letter
            }
          }
        } else {
          letter
        }
      }
      .frame(width: side, height: side)
      .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
      .task(id: path) {
        guard let path else { return }
        if let loaded = await DeviceCoverCache.image(path: path, maxPixel: Self.maxPixel(side)) {
          image = loaded
        }
      }
    }

    private var letter: some View {
      Text(String(title.prefix(1)))
        .font(.cassetteDisplay(size: 28, weight: .extraBold))
        .foregroundStyle(Color.cassette(.textTertiary))
    }
  }

  // MARK: - DeviceFormat

  enum DeviceFormat {
    /// The mock's sizes from real bytes: "12 GB" from 10 GB up, "1.2 GB" from 1 GB, else
    /// "345 MB" (decimal units).
    static func size(_ bytes: Int64) -> String {
      let gb = Double(bytes) / 1e9
      if gb >= 10 { return "\(Int(gb.rounded())) GB" }
      if gb >= 1 { return String(format: "%.1f GB", gb) }
      return "\(Int((Double(bytes) / 1e6).rounded())) MB"
    }

    /// "1,234": thousands grouped.
    static func count(_ value: Int) -> String {
      let formatter = NumberFormatter()
      formatter.numberStyle = .decimal
      formatter.locale = Locale(identifier: "en_US")
      return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }

    /// "1 album" / "12 albums".
    static func albums(_ count: Int) -> String {
      count == 1 ? "1 album" : "\(count) albums"
    }

    /// The device idiom's name: "iPhone" or "iPad".
    @MainActor
    static var deviceName: String {
      UIDevice.current.userInterfaceIdiom == .pad ? "iPad" : "iPhone"
    }

    @MainActor
    static var deviceIcon: CassetteIcon {
      UIDevice.current.userInterfaceIdiom == .pad ? .ipad : .iphone
    }
  }

#endif
