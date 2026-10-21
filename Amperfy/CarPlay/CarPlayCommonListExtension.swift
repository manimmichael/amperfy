//
//  CarPlayCommonListExtension.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 02.01.26.
//  Copyright (c) 2026 Maximilian Bauer. All rights reserved.
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
import CarPlay
import CoreData
import Foundation
import OSLog

// MARK: - CarPlayBrowseKind

/// cassette (BUG-337): which browse tab a list belongs to. Playlists joined in Wave 1 of the
/// design-system audit, so the Playlists tab pages instead of silently stopping at the car's
/// item count (it used the raw report and had no paging row).
enum CarPlayBrowseKind: Sendable {
  case albums, artists, playlists

  var tabTitle: String {
    switch self {
    case .albums: return "Albums"
    case .artists: return "Artists"
    case .playlists: return "Playlists"
    }
  }

  func noun(_ n: Int) -> String {
    switch self {
    case .albums: return n == 1 ? "album" : "albums"
    case .artists: return n == 1 ? "artist" : "artists"
    case .playlists: return n == 1 ? "playlist" : "playlists"
    }
  }

  @MainActor
  var glyph: UIImage {
    switch self {
    case .albums: return UIImage.lucideAlbums
    case .artists: return UIImage.lucideArtists
    case .playlists: return UIImage.lucidePlaylists
    }
  }

  /// Albums and Artists split into alphabetic ranges when they outgrow the budget. Playlists
  /// follow the person's own sort, which may not be alphabetic, so they page in order instead.
  var packsAlphabetically: Bool { self != .playlists }
}

// MARK: - CarPlayBrowseDescriptor

/// cassette (BUG-337): the only state a browse list carries, stored in `CPTemplate.userInfo`
/// of the two tabs and of every pushed range list. The live template stack is the registry;
/// nothing on the delegate remembers a pushed list.
struct CarPlayBrowseDescriptor: Sendable {
  let kind: CarPlayBrowseKind
  /// nil = the tab itself; a pushed range list renders this bucket's keys and never re-plans.
  let bucket: AlphabeticBucket?
  /// Only meaningful while the list pages; clamped on every render.
  var page: Int = 0
  /// Signature of the last "CarPlay browse render" log line, so FRC bursts log once per change.
  var lastRenderLogSignature: String? = nil
}

extension CarPlaySceneDelegate {
  /// Every list limit comes from here (`CarPlayLimits`, unit-tested in AmperfyKit). Read at
  /// every render, never cached at connect, so a value the car reports late is honoured.
  var carPlayLimits: CarPlayLimits {
    CarPlayLimits(
      reportedItems: CPListTemplate.maximumItemCount,
      reportedSections: CPListTemplate.maximumSectionCount
    )
  }

  /// CarPlay raises an uncaught `NSInvalidArgumentException` when a pushed
  /// `CPListTemplate` exceeds the connected vehicle's item limit. Leaf lists (album tracks,
  /// All Songs, playlist songs, the queue) prepend `reserved` action rows (Shuffle / All
  /// Songs), so the content leaves room for them.
  func carPlayLeafItemLimit(reserved: Int) -> Int {
    carPlayLimits.leafItems(reserved: reserved)
  }

  /// cassette (BUG-337): the browse ceiling, see `CarPlayLimits.browseCeiling`. The car's
  /// reported `CPListTemplate.maximumItemCount` is NOT trusted above it: the reported symptom
  /// ("#, A, part of B") can only happen when the phone built the whole list and the head
  /// unit drew about 24 rows of it. The leaf lists still use the raw report and are the probe.
  /// Lift rule, from the "CarPlay budget" line of the first drive's diagnostics export:
  /// a 500 report and a long leaf list that scrolls to the end means the car honours what it
  /// reports, so raise the ceiling to `LibraryStorage.carPlayMaxElements`; a 500 report and a
  /// leaf list that stops near 24 means keep it.
  static let carPlayBrowseBudgetCeiling = CarPlayLimits.browseCeiling

  /// Rows in a browse list (the three tabs and every pushed range list), paging row included.
  var carPlayBrowseItemBudget: Int { carPlayLimits.browseItems }

  // MARK: - On this phone (phone-taste)

  /// What CarPlay may show and queue from `containable`: only songs on this phone, by the
  /// foundation's OneTapPlay rule (the DeviceOwnership set in on-device mode; in Server Mode
  /// cached items while offline). `onlyCached` keeps a caller's explicit cached-only request
  /// in Server Mode; owned songs play from the phone in on-device mode and need no cache.
  func onPhonePlayables(
    of containable: PlayableContainable,
    onlyCached: Bool = false
  )
    -> [AbstractPlayable] {
    let playables = OneTapPlay.playables(of: containable)
    guard onlyCached, !CassetteLibraryFilterProvider.shared.isOnDeviceOnly else { return playables }
    return playables.filterCached(dependigOn: true)
  }

  /// The same rule for a list that is not a container (a mix): in on-device mode only the
  /// songs this phone owns; in Server Mode only cached items while offline.
  func onPhonePlayables(_ list: [AbstractPlayable]) -> [AbstractPlayable] {
    guard CassetteLibraryFilterProvider.shared.isOnDeviceOnly else {
      return list.filterCached(dependigOn: isOfflineMode)
    }
    let owned = DeviceOwnershipManager(context: appDelegate.storage.main.context)
      .fetchAllSubsonicTrackIds()
    return list.filter { playable in
      guard let song = playable.asSong else { return true }
      return owned.contains(song.id)
    }
  }

  var carPlayBrowseSectionBudget: Int { carPlayLimits.sections }

  // MARK: - Browse tabs (cassette, BUG-337)

  /// The fetch controller sections for a browse kind, created on demand. nil only with no
  /// account. The tab's own `albumsFetchController` / `artistsFetchController` serve every
  /// pushed range list too; no extra fetch controllers exist.
  private func ensureBrowseFetchController(_ kind: CarPlayBrowseKind)
    -> [NSFetchedResultsSectionInfo]? {
    guard activeAccount != nil else { return nil }
    switch kind {
    case .albums:
      if albumsFetchController == nil { createAlbumsFetchController() }
      return albumsFetchController?.sections ?? []
    case .artists:
      if artistsFetchController == nil { createArtistsFetchController() }
      return artistsFetchController?.sections ?? []
    case .playlists:
      if playlistFetchController == nil { createPlaylistFetchController() }
      return playlistFetchController?.sections ?? []
    }
  }

  /// (index key, managed object) pairs for the given section keys (nil = every section), in
  /// fetch order. Cheap: the objects are already materialised and no image is decoded here.
  private func browseEntities(
    kind: CarPlayBrowseKind,
    in sections: [NSFetchedResultsSectionInfo],
    sectionNames: [String]?
  )
    -> [(key: String, object: NSManagedObject)] {
    var entities = [(key: String, object: NSManagedObject)]()
    let wanted: Set<String>? = sectionNames.map { Set($0) }
    for section in sections {
      if let wanted, !wanted.contains(section.name) { continue }
      let objects: [NSManagedObject]?
      switch kind {
      case .albums: objects = section.objects as? [AlbumMO]
      case .artists: objects = section.objects as? [ArtistMO]
      case .playlists: objects = section.objects as? [PlaylistMO]
      }
      guard let objects else { continue }
      let key = String(section.name.prefix(1))
      for object in objects {
        entities.append((key, object))
      }
    }
    return entities
  }

  /// One row for one entity, through the same builders the rest of the library uses, so a
  /// tap opens the same detail and the artwork walk refreshes it through its `userInfo`.
  private func browseRow(
    kind: CarPlayBrowseKind,
    object: NSManagedObject,
    onlyCached: Bool
  )
    -> CPListItem? {
    switch kind {
    case .albums:
      guard let mo = object as? AlbumMO else { return nil }
      return createDetailTemplate(for: Album(managedObject: mo), onlyCached: onlyCached)
    case .artists:
      guard let mo = object as? ArtistMO else { return nil }
      return createDetailTemplate(for: Artist(managedObject: mo), onlyCached: onlyCached)
    case .playlists:
      guard let mo = object as? PlaylistMO else { return nil }
      return createPlaylistRow(Playlist(
        library: appDelegate.storage.main.library,
        managedObject: mo
      ))
    }
  }

  /// The index row for one bucket: glyph, label, "21 albums", disclosure. The handler pushes
  /// the range list; it runs at stack count 1 (the tab bar only), so the push is always
  /// allowed. Captures only Sendable values, never a managed object. No `userInfo`, so the
  /// artwork walk skips it.
  private func makeBrowseBucketRow(
    kind: CarPlayBrowseKind,
    bucket: AlphabeticBucket,
    label: String
  )
    -> CPListItem {
    let item = CPListItem(
      text: label,
      detailText: "\(bucket.itemCount) \(kind.noun(bucket.itemCount))",
      image: style.glyph(kind.glyph),
      accessoryImage: nil,
      accessoryType: .disclosureIndicator
    )
    item.handler = { [weak self] _, completion in
      guard let self = self else { completion(); return }
      pushTemplateIfAllowed(
        makeBrowseRangeTemplate(kind: kind, bucket: bucket, label: label),
        animated: true
      )
      completion()
    }
    return item
  }

  /// The "More" / "Back to the start" row of a paged list. Turning the page is an
  /// `updateSections` on the same template, never a push, so paging never deepens the stack.
  /// No image, no `userInfo`.
  private func makeBrowseNavigationRow(
    template: CPListTemplate,
    page: Int,
    pageCount: Int,
    first: Int,
    last: Int,
    total: Int
  )
    -> CPListItem {
    let isLastPage = page >= pageCount - 1
    let item = CPListItem(
      text: isLastPage ? "Back to the start" : "More",
      detailText: "Showing \(first) to \(last) of \(total)",
      image: nil,
      accessoryImage: nil,
      accessoryType: .none
    )
    item.handler = { [weak self, weak template] _, completion in
      guard let self = self, let template,
            var descriptor = template.userInfo as? CarPlayBrowseDescriptor
      else { completion(); return }
      descriptor.page = (descriptor.page + 1) % max(1, pageCount)
      template.userInfo = descriptor
      renderBrowseList(template)
      completion()
    }
    return item
  }

  /// Group (key, item) rows into sections by consecutive key, `sectionIndexTitle = key`
  /// (nil keys -> one unindexed section). Collapses to one unindexed section when the distinct
  /// key count plus `reservingSections` (the paging row's own section) exceeds the car's
  /// section budget, so nothing is ever trimmed by the head unit.
  private func browseSections(
    from rows: [(key: String?, item: CPListItem)],
    reservingSections: Int
  )
    -> [CPListSection] {
    guard !rows.isEmpty else { return [] }
    let keys = rows.compactMap { $0.key }
    let distinctKeys = Set(keys).count
    if keys.count != rows.count || distinctKeys + reservingSections > carPlayBrowseSectionBudget {
      return [CPListSection(items: rows.map { $0.item }, header: nil, sectionIndexTitle: nil)]
    }
    var sections = [CPListSection]()
    var currentKey: String?
    var currentItems = [CPListItem]()
    for row in rows {
      if row.key != currentKey {
        if let currentKey, !currentItems.isEmpty {
          sections.append(CPListSection(
            items: currentItems,
            header: nil,
            sectionIndexTitle: currentKey
          ))
        }
        currentKey = row.key
        currentItems = []
      }
      currentItems.append(row.item)
    }
    if let currentKey, !currentItems.isEmpty {
      sections.append(CPListSection(
        items: currentItems,
        header: nil,
        sectionIndexTitle: currentKey
      ))
    }
    return sections
  }

  /// Build a range list, populated before the push from the live fetch controller. Depth is
  /// always 1 (tab bar only) when this runs; `templateWillAppear` renders it again on push
  /// and on every pop back to it (the playlist detail's double render).
  func makeBrowseRangeTemplate(
    kind: CarPlayBrowseKind,
    bucket: AlphabeticBucket,
    label: String
  )
    -> CPListTemplate {
    let template = CPListTemplate(title: "\(kind.tabTitle) \(label)", sections: [])
    template.userInfo = CarPlayBrowseDescriptor(kind: kind, bucket: bucket)
    template.emptyViewTitleVariants = ["Nothing here any more"]
    renderBrowseList(template)
    return template
  }

  /// THE render entry point for the two browse tabs and every pushed range list. Reads the
  /// descriptor from `userInfo`, plans a tab (flat, index, or paged index) at the current
  /// budget, renders a pushed range from ITS keys against the live fetch controller (never
  /// re-plans, never re-titles; pages in place when the range outgrew the budget), and writes
  /// the descriptor back. No-op without a descriptor, an account, or an interface controller.
  /// Idempotent: running twice for one event has no visible effect.
  func renderBrowseList(_ template: CPListTemplate) {
    guard interfaceController != nil,
          var descriptor = template.userInfo as? CarPlayBrowseDescriptor,
          let frcSections = ensureBrowseFetchController(descriptor.kind) else { return }
    let budget = carPlayBrowseItemBudget
    let sectionBudget = carPlayBrowseSectionBudget
    let onlyCached = isOfflineMode
    let counts = frcSections
      .map { AlphabeticSectionCount(name: $0.name, count: $0.numberOfObjects) }
    let total = counts.reduce(0) { $0 + $1.count }
    var rows = [(key: String?, item: CPListItem)]()
    var mode = "flat"
    var pageCount = 1
    var pageRange = 0 ..< 0
    var pagedRowCount = 0

    // Rows for `entities` at the current page, paging in place past the budget. A section
    // without a name (a list not grouped alphabetically) gives rows no index key.
    func renderPaged(_ entities: [(key: String, object: NSManagedObject)]) {
      let bounds = AlphabeticBucketPacker.pageBounds(
        rowCount: entities.count,
        budget: budget,
        page: descriptor.page
      )
      descriptor.page = bounds.page
      pageCount = bounds.pageCount
      pageRange = bounds.range
      pagedRowCount = entities.count
      for entity in entities[bounds.range] {
        if let item = browseRow(
          kind: descriptor.kind,
          object: entity.object,
          onlyCached: onlyCached
        ) {
          rows.append((key: entity.key.isEmpty ? nil : entity.key, item: item))
        }
      }
    }

    if let bucket = descriptor.bucket {
      // A pushed range: render ITS keys against the live FRC. Never re-plan, never re-title.
      var entities = browseEntities(
        kind: descriptor.kind,
        in: frcSections,
        sectionNames: bucket.sectionNames
      )
      if let chunk = bucket.chunk {
        // Even split of the CURRENT letter count into the PLANNED number of chunks, so a
        // letter that moved by a few entries shifts a boundary by one or two and never
        // drops an entry; a slice that outgrew the budget pages below like any range.
        let slice = AlphabeticBucketPacker.chunkRange(
          count: entities.count,
          chunks: chunk.count,
          index: chunk.index
        )
        entities = slice.map { Array(entities[$0.clamped(to: 0 ..< entities.count)]) } ?? []
      }
      renderPaged(entities)
      mode = pageCount > 1 ? "leafPaged" : "leaf"
    } else if !descriptor.kind.packsAlphabetically {
      // Playlists: the person's own order, paged in place.
      renderPaged(browseEntities(kind: descriptor.kind, in: frcSections, sectionNames: nil))
      mode = pageCount > 1 ? "flatPaged" : "flat"
    } else {
      let buckets = AlphabeticBucketPacker.pack(
        sections: counts,
        itemBudget: budget,
        sectionBudget: sectionBudget
      )
      if buckets.isEmpty {
        descriptor.page = 0
        renderPaged(browseEntities(kind: descriptor.kind, in: frcSections, sectionNames: nil))
        mode = "flat"
      } else {
        let bounds = AlphabeticBucketPacker.pageBounds(
          rowCount: buckets.count,
          budget: budget,
          page: descriptor.page
        )
        descriptor.page = bounds.page
        pageCount = bounds.pageCount
        pageRange = bounds.range
        pagedRowCount = buckets.count
        for bucket in buckets[bounds.range] {
          let label = AlphabeticBucketPacker.label(for: bucket)
          rows.append((
            key: nil,
            item: makeBrowseBucketRow(kind: descriptor.kind, bucket: bucket, label: label)
          ))
        }
        mode = pageCount > 1 ? "indexPaged" : "index"
      }
    }

    var sections = browseSections(from: rows, reservingSections: pageCount > 1 ? 1 : 0)
    if pageCount > 1 {
      let navigationRow = makeBrowseNavigationRow(
        template: template,
        page: descriptor.page,
        pageCount: pageCount,
        first: pageRange.lowerBound + 1,
        last: pageRange.upperBound,
        total: pagedRowCount
      )
      if sections.count < sectionBudget {
        sections.append(CPListSection(items: [navigationRow], header: nil, sectionIndexTitle: nil))
      } else {
        // The section budget leaves no room for a second section: the paging row joins the
        // single unindexed section instead of being trimmed away by the head unit.
        sections = [CPListSection(
          items: rows.map { $0.item } + [navigationRow],
          header: nil,
          sectionIndexTitle: nil
        )]
      }
    }
    template.userInfo = descriptor
    template.updateSections(sections)
    logBrowseRender(
      template: template,
      descriptor: &descriptor,
      mode: mode,
      total: total,
      sectionCount: counts.count,
      budget: budget,
      built: rows.count + (pageCount > 1 ? 1 : 0),
      pageCount: pageCount
    )
    template.userInfo = descriptor // persists the log signature
  }

  /// Re-render every pushed range list of `kind` found in `templates` (the array the caller
  /// already read; no second IPC read).
  func refreshPushedBrowseLists(kind: CarPlayBrowseKind, in templates: [CPTemplate]) {
    for case let list as CPListTemplate in templates {
      if let descriptor = list.userInfo as? CarPlayBrowseDescriptor,
         descriptor.kind == kind, descriptor.bucket != nil {
        renderBrowseList(list)
      }
    }
  }

  /// Change-only diagnostic: one "CarPlay browse render" line per real change of what was
  /// built versus what the template reports it holds. `maxItems` is re-read at render time so
  /// a value that arrives late is visible. FRC bursts during a sync log at most once per change.
  private func logBrowseRender(
    template: CPListTemplate,
    descriptor: inout CarPlayBrowseDescriptor,
    mode: String,
    total: Int,
    sectionCount: Int,
    budget: Int,
    built: Int,
    pageCount: Int
  ) {
    let context: [String: String] = [
      "kind": descriptor.kind.tabTitle,
      "list": template.title ?? "",
      "mode": mode,
      "total": String(total),
      "sections": String(sectionCount),
      "budget": String(budget),
      "maxItems": String(CPListTemplate.maximumItemCount),
      "built": String(built),
      "shown": String(template.itemCount),
      "shownSections": String(template.sectionCount),
      "page": String(descriptor.page),
      "pageCount": String(pageCount),
    ]
    let signature = context.keys.sorted().map { "\($0)=\(context[$0] ?? "")" }
      .joined(separator: " ")
    guard signature != descriptor.lastRenderLogSignature else { return }
    descriptor.lastRenderLogSignature = signature
    DiagnosticLog.shared.log(.carplay, "CarPlay browse render", context: context)
    os_log("CarPlay: browse render %{public}@", log: self.log, type: .info, signature)
  }

  func createPlaylistDetailItems(
    from fetchedController: PlaylistItemsFetchedResultsController
  )
    -> [CPListTemplateItem] {
    let playlist = fetchedController.playlist
    var items = [CPListItem]()

    guard let playables = fetchedController.getContextSongs(onlyCachedSongs: isOfflineMode)
    else { return items }

    // Shuffle only when there is something to shuffle: an offline playlist with nothing on
    // the phone used to offer a Shuffle that opened an empty Now Playing (CPS-11).
    let shufflePlayables = playlist.playables.filterCached(dependigOn: isOfflineMode)
    if !shufflePlayables.isEmpty {
      items.append(createPlayShuffledListItem(playContext: PlayContext(
        containable: playlist,
        playables: shufflePlayables
      )))
    }
    // cassette (LIST-3): clamp by the ITEM limit, not maximumSectionCount (a section
    // ceiling), so a long playlist isn't silently cut to a handful of rows. The reserved
    // count leaves room for the Shuffle row prepended above.
    let displayedSongs = playables.prefix(carPlayLeafItemLimit(reserved: items.count))
    for (index, song) in displayedSongs.enumerated() {
      let listItem = createDetailTemplate(
        for: song,
        playContext: PlayContext(containable: playlist, index: index, playables: playables)
      )
      items.append(listItem)
    }
    return items
  }

  func createDetailTemplate(for artist: Artist, onlyCached: Bool) -> CPListItem {
    let section = CPListItem(
      text: artist.name,
      detailText: artist.subtitle,
      image: style.artwork(
        for: artist,
        artworkDisplayPreference: getPreference(activeAccountInfo).artworkDisplayPreference
      ),
      accessoryImage: nil,
      accessoryType: .disclosureIndicator
    )
    if let artwork = artist.artwork, let accountInfo = artwork.account?.info {
      appDelegate.getMeta(accountInfo).artworkDownloadManager.download(object: artwork)
    }
    section.userInfo = [
      CarPlayListUserInfoKeys.artworkDownloadID.rawValue: artist.artwork?.uniqueID as Any,
      CarPlayListUserInfoKeys.artworkOwnerObjectID.rawValue: artist.managedObject.objectID as Any,
      CarPlayListUserInfoKeys.artworkOwnerType.rawValue: ArtworkType.artist as Any,
    ]
    section.handler = { [weak self] item, completion in
      guard let self = self,
            let template = makeArtistDetailTemplate(for: artist, onlyCached: onlyCached)
      else { completion(); return }
      pushTemplateIfAllowed(template, animated: true)
      completion()
    }
    return section
  }

  // cassette (CarPlay open-a-view): the artist detail as a REUSABLE template, shared by
  // the library artist row, the Home row list and Now Playing's artist button.
  //
  // cassette 2026-10-20 (driving pass): built to be usable at a glance. Shuffle sits in
  // the header as a large button; then the artist's most played songs (five at most),
  // then their albums as one row of covers (a cover plays the album). The long All Songs
  // list is offered only while parked: when the car limits lists, it is left out.
  func makeArtistDetailTemplate(for artist: Artist, onlyCached: Bool) -> CPListTemplate? {
    guard let activeAccount else { return nil }
    // phone-taste: only songs on this phone (OneTapPlay's rule), for Most Played and Shuffle.
    let artistPlayables = onPhonePlayables(of: artist, onlyCached: onlyCached || isOfflineMode)
    var sections = [CPListSection]()

    let topSongs = artistPlayables
      .filter { $0.playCount > 0 }
      .sorted { $0.playCount > $1.playCount }
      .prefix(Self.artistTopSongCount)
    if !topSongs.isEmpty {
      let context = Array(topSongs)
      // phone-taste: a top song's second line is its album (the artist is the page).
      let rows: [CPListItem] = context.enumerated().map { index, song in
        createDetailTemplate(
          for: song,
          playContext: PlayContext(containable: artist, index: index, playables: context),
          detail: .some(song.subsubtitle)
        )
      }
      sections.append(CPListSection(items: rows, header: "Most Played", sectionIndexTitle: nil))
    }

    let artistAlbums = appDelegate.storage.main.library.getAlbums(
      for: activeAccount,
      whichContainsSongsWithArtist: artist,
      onlyCached: onlyCached || isOfflineMode
    )
    if !artistAlbums.isEmpty {
      sections.append(CPListSection(
        items: [makeAlbumCoverRow(artistAlbums, onlyCached: onlyCached)],
        header: nil,
        sectionIndexTitle: nil
      ))
    }

    if !isDriving, !artistPlayables.isEmpty {
      sections.append(CPListSection(items: [
        createDetailAllSongsTemplate(for: artist, onlyCached: onlyCached),
      ]))
    }

    let template = CPListTemplate(title: artist.name, sections: sections)
    template.emptyViewTitleVariants = ["Nothing by this artist on this phone"]
    // phone-taste: "N albums", counted from the same list the Albums row shows, so the number
    // and the covers always agree; nothing at zero.
    let albumCount = artistAlbums.count
    applyPlayHeader(
      to: template,
      image: artistHeaderImage(artist, albums: artistAlbums),
      title: artist.name,
      subtitle: albumCount == 0 ? nil : (albumCount == 1 ? "1 album" : "\(albumCount) albums"),
      play: nil,
      shuffle: artistPlayables.isEmpty ? nil : PlayContext(
        containable: artist,
        playables: artistPlayables
      )
    )
    return template
  }

  static let artistTopSongCount = 5

  /// phone-taste: the artist page's header picture. Their own photo keeps the circle (tested
  /// with `hasOwnPhotoOnDisk`, never "has any image": a shared artwork row can carry someone
  /// else's face). Without one, the first of their albums with a cover, square, as in the car
  /// mock; with neither, the initial in a circle as before.
  private func artistHeaderImage(_ artist: Artist, albums: [Album]) -> UIImage {
    let preference = getPreference(activeAccountInfo).artworkDisplayPreference
    if artist.hasOwnPhotoOnDisk,
       let photo = LibraryEntityImage.coverImage(
         libraryEntity: artist,
         artworkDisplayPreference: preference,
         useCache: false
       ) {
      return style.artwork(photo, kind: .artist, name: artist.name, circle: true)
    }
    for album in albums {
      if let cover = LibraryEntityImage.coverImage(
        libraryEntity: album,
        artworkDisplayPreference: preference,
        useCache: false
      ) {
        return style.artwork(cover, kind: .album, name: album.name, circle: false)
      }
    }
    return style.artwork(nil, kind: .artist, name: artist.name, circle: true)
  }

  /// One row of album covers. A cover plays its album from the top; the row's title opens
  /// the albums as a plain list for browsing.
  private func makeAlbumCoverRow(_ albums: [Album], onlyCached: Bool) -> CPListImageRowItem {
    let shown = Array(albums.prefix(carPlayLeafItemLimit(reserved: 0)))
    let preference = getPreference(activeAccountInfo).artworkDisplayPreference
    let elements = shown.map { album in
      CPListImageRowItemRowElement(
        image: style.artwork(for: album, artworkDisplayPreference: preference, slot: .shelf),
        title: album.name,
        subtitle: album.year > 0 ? String(album.year) : nil
      )
    }
    let row = CPListImageRowItem(text: "Albums", elements: elements, allowsMultipleLines: false)
    row.listImageRowHandler = { [weak self] _, index, completion in
      guard let self, index >= 0, index < shown.count else { completion(); return }
      let album = shown[index]
      // phone-taste: only the album's songs on this phone; none, and nothing plays.
      let playables = onPhonePlayables(of: album, onlyCached: onlyCached || isOfflineMode)
      guard !playables.isEmpty else { completion(); return }
      appDelegate.player.play(context: PlayContext(containable: album, playables: playables))
      displayNowPlaying { completion() }
    }
    row.handler = { [weak self] _, completion in
      guard let self else { completion(); return }
      let rows = shown.map { createDetailTemplate(for: $0, onlyCached: onlyCached) }
      pushTemplateIfAllowed(
        CPListTemplate(title: "Albums", sections: [CPListSection(items: rows)]),
        animated: true
      )
      completion()
    }
    return row
  }

  /// Play and Shuffle as large buttons at the top of an album or artist page: with the
  /// cover beside them where the car's iOS has the details header (26.4), as header
  /// buttons otherwise. Either button plays and shows Now Playing.
  func applyPlayHeader(
    to template: CPListTemplate,
    image: UIImage,
    title: String,
    subtitle: String?,
    play: PlayContext?,
    shuffle: PlayContext?
  ) {
    let startPlay: (PlayContext, Bool) -> () = { [weak self] context, shuffled in
      guard let self else { return }
      if shuffled {
        appDelegate.player.playShuffled(context: context)
      } else {
        appDelegate.player.play(context: context)
      }
      displayNowPlaying {}
    }
    var actions: [(String, UIImage, PlayContext, Bool)] = []
    if let play { actions.append(("Play", style.glyph(UIImage.play), play, false)) }
    if let shuffle { actions.append(("Shuffle", style.glyph(UIImage.lucideShuffle), shuffle, true)) }
    guard !actions.isEmpty else { return }

    if #available(iOS 26.4, *) {
      let buttons: [CPButton] = actions.map { title, glyph, context, shuffled in
        let button = CPButton(image: glyph) { _ in startPlay(context, shuffled) }
        button.title = title
        return button
      }
      template.listHeader = CPListTemplateDetailsHeader(
        thumbnail: CPThumbnailImage(image: image),
        title: title,
        subtitle: subtitle,
        actionButtons: buttons
      )
    } else {
      template.headerGridButtons = actions.map { title, glyph, context, shuffled in
        CPGridButton(titleVariants: [title], image: glyph) { _ in startPlay(context, shuffled) }
      }
    }
  }

  func createDetailAllSongsTemplate(for artist: Artist, onlyCached: Bool) -> CPListItem {
    let section = CPListItem(
      text: "All Songs",
      detailText: nil,
      image: style.glyph(UIImage.lucideSongs),
      accessoryImage: nil,
      accessoryType: .disclosureIndicator
    )
    section.handler = { [weak self] item, completion in
      guard let self = self else { completion(); return }
      var songItems = [CPListItem]()
      // phone-taste: only songs on this phone (OneTapPlay's rule).
      let artistPlayables = onPhonePlayables(of: artist, onlyCached: onlyCached || isOfflineMode)
      if !artistPlayables.isEmpty {
        songItems.append(createPlayShuffledListItem(playContext: PlayContext(
          containable: artist,
          playables: artistPlayables
        )))
      }
      let artistSongs = artistPlayables
        .sortByTitle().prefix(carPlayLeafItemLimit(reserved: songItems.count))
      for (index, song) in artistSongs.enumerated() {
        let listItem = createDetailTemplate(
          for: song,
          playContext: PlayContext(containable: artist, index: index, playables: Array(artistSongs))
        )
        songItems.append(listItem)
      }
      let albumTemplate = CPListTemplate(title: artist.name, sections: [
        CPListSection(items: songItems),
      ])
      // cassette (BUG-337): a refused push used to be a silent dead tap. No path in the
      // shipped IA reaches the depth limit here, so this only guards a future level: play
      // the artist's songs instead of doing nothing.
      if !pushTemplateIfAllowed(albumTemplate, animated: true) {
        appDelegate.player.play(context: PlayContext(
          containable: artist,
          playables: Array(artistSongs)
        ))
        displayNowPlaying { completion() }
        return
      }
      completion()
    }
    return section
  }

  func createDetailTemplate(for album: Album, onlyCached: Bool) -> CPListItem {
    let section = CPListItem(
      text: album.name,
      detailText: album.subtitle,
      image: style.artwork(
        for: album,
        artworkDisplayPreference: getPreference(activeAccountInfo).artworkDisplayPreference
      ),
      accessoryImage: nil,
      accessoryType: .disclosureIndicator
    )
    if let artwork = album.artwork, let accountInfo = artwork.account?.info {
      appDelegate.getMeta(accountInfo).artworkDownloadManager.download(object: artwork)
    }
    section.userInfo = [
      CarPlayListUserInfoKeys.artworkDownloadID.rawValue: album.artwork?.uniqueID as Any,
      CarPlayListUserInfoKeys.artworkOwnerObjectID.rawValue: album.managedObject.objectID as Any,
      CarPlayListUserInfoKeys.artworkOwnerType.rawValue: ArtworkType.album as Any,
    ]
    section.handler = { [weak self] item, completion in
      guard let self = self else { completion(); return }
      // cassette (BUG-337): a refused push used to be a silent dead tap. Unreachable in the
      // shipped IA (see the depth proof); if a future level makes it reachable, play the
      // album in track order instead of doing nothing.
      if !pushTemplateIfAllowed(
        makeAlbumDetailTemplate(for: album, onlyCached: onlyCached),
        animated: true
      ) {
        // phone-taste: only the album's songs on this phone.
        let playables = onPhonePlayables(of: album, onlyCached: onlyCached || isOfflineMode)
        guard !playables.isEmpty else { completion(); return }
        appDelegate.player.play(context: PlayContext(containable: album, playables: playables))
        displayNowPlaying { completion() }
        return
      }
      completion()
    }
    return section
  }

  // cassette (CarPlay open-a-view): the album detail as a REUSABLE template, so the library
  // album row and the Home row list open the same view.
  //
  // cassette 2026-10-20 (driving pass): Play and Shuffle are large header buttons above
  // the track list instead of a Shuffle row inside it.
  func makeAlbumDetailTemplate(for album: Album, onlyCached: Bool) -> CPListTemplate {
    var songItems = [CPListItem]()
    // phone-taste: only the album's songs on this phone (OneTapPlay's rule), for the rows and
    // for the header's Play and Shuffle.
    let albumPlayables = onPhonePlayables(of: album, onlyCached: onlyCached || isOfflineMode)
    let albumSongs = albumPlayables.prefix(carPlayLeafItemLimit(reserved: 0))
    for (index, song) in albumSongs.enumerated() {
      // phone-taste: a row's second line is the song's length (the artist is in the header).
      let listItem = createDetailTemplate(
        for: song,
        playContext: PlayContext(containable: album, index: index, playables: Array(albumSongs)),
        isTrackDisplayed: true,
        detail: .some(song.duration > 0 ? song.duration.asColonDurationString : nil)
      )
      songItems.append(listItem)
    }
    let template = CPListTemplate(title: album.name, sections: [
      CPListSection(items: songItems),
    ])
    template.emptyViewTitleVariants = ["No songs from this album on this phone"]
    let context = albumPlayables.isEmpty ? nil : PlayContext(
      containable: album,
      playables: albumPlayables
    )
    applyPlayHeader(
      to: template,
      image: style.artwork(
        for: album,
        artworkDisplayPreference: getPreference(activeAccountInfo).artworkDisplayPreference
      ),
      title: album.name,
      subtitle: albumHeaderLine(album),
      play: context,
      shuffle: context
    )
    return template
  }

  /// phone-taste: the album header's line, "Artist · Year", either part left out when unknown.
  private func albumHeaderLine(_ album: Album) -> String? {
    let parts = [album.artist?.name, album.year > 0 ? String(album.year) : nil]
      .compactMap { $0 }
      .filter { !$0.isEmpty }
    return parts.isEmpty ? nil : parts.joined(separator: " · ")
  }

  /// One playlist row (local cover, name, subtitle, disclosure; tap pushes the playlist
  /// detail). Shared by the Playlists tab and the Home shelf list (cassette, BUG-338).
  func createPlaylistRow(_ playlist: Playlist) -> CPListItem {
    // cassette (Wave 2b): playlists used to render blank in CarPlay (image: nil).
    // Resolve the LOCAL cover (a bundled preset, or a materialized pick), else a
    // generated playlist placeholder, so every playlist shows art in the car.
    let item = CPListItem(
      text: playlist.name,
      detailText: playlist.subtitle,
      image: style.artwork(
        CassetteCloudPlaylistBridge.localCoverImage(for: playlist.id),
        kind: .playlist,
        name: playlist.name
      ),
      accessoryImage: nil,
      accessoryType: .disclosureIndicator
    )
    item.handler = { [weak self] item, completion in
      guard let self = self else { completion(); return }
      pushPlaylistDetail(playlist) { completion() }
    }
    return item
  }

  // cassette (CarPlay open-a-view): push a playlist's detail (empty template + async
  // FRC populate), shared by the library playlist row and the Home playlist tile.
  func pushPlaylistDetail(_ playlist: Playlist, completion: @escaping () -> () = {}) {
    let playlistDetailTemplate = CPListTemplate(title: playlist.name, sections: [
      CPListSection(items: [CPListTemplateItem]()),
    ])
    playlistDetailSection = playlistDetailTemplate
    createPlaylistDetailFetchController(playlist: playlist)
    guard pushTemplateIfAllowed(playlistDetailTemplate, animated: true) else {
      // A refused push (depth limit) used to leave a dead tap plus a live fetch controller and
      // a stored template that never appeared (CPS-9). Play the playlist instead, as the
      // album and artist rows do.
      playlistDetailFetchController?.delegate = nil
      playlistDetailFetchController = nil
      playlistDetailSection = nil
      appDelegate.player.play(context: PlayContext(
        containable: playlist,
        playables: playlist.playables.filterCached(dependigOn: isOfflineMode)
      ))
      displayNowPlaying { completion() }
      return
    }
    completion()
  }

  func createPlayShuffledListItem(
    playContext: PlayContext,
    text: String = "Shuffle"
  )
    -> CPListItem {
    let img = style.glyph(UIImage.lucideShuffle)
    let listItem = CPListItem(text: text, detailText: nil, image: img)
    listItem.handler = { [weak self] item, completion in
      guard let self = self else { completion(); return }
      appDelegate.player.playShuffled(context: playContext)
      displayNowPlaying {
        completion()
      }
    }
    return listItem
  }

  enum CarPlayListUserInfoKeys: String {
    case playableDownloadID
    case artworkDownloadID
    case artworkOwnerType
    case artworkOwnerObjectID
    case isTrackDisplayed
  }

  /// One song row. `detail` overrides the second line (`.some(nil)` leaves it empty); left out,
  /// it is the song's artist, as everywhere before phone-taste.
  func createDetailTemplate(
    for playable: AbstractPlayable,
    playContext: PlayContext,
    isTrackDisplayed: Bool = false,
    detail: String?? = .none
  )
    -> CPListItem {
    // Cassette CarPlay: the cloud/"cached" badge is gated to Server Mode
    // (Navidrome native streaming). In the default on-device-only experience
    // everything browsable in-car is already local, so the badge is pure noise
    // — keep rows clean. In streaming mode it marks which rows are cached.
    let accessoryType: CPListItemAccessoryType = CassetteLibraryFilterProvider.shared
      .isOnDeviceOnly ? .none : (playable.isCached ? .cloud : .none)
    let image = style.artwork(
      for: playable,
      isTrackDisplayed: isTrackDisplayed,
      artworkDisplayPreference: getPreference(activeAccountInfo).artworkDisplayPreference
    )
    if let artwork = playable.artwork, let accountInfo = artwork.account?.info {
      appDelegate.getMeta(accountInfo).artworkDownloadManager.download(object: artwork)
    }
    let detailText: String?
    switch detail {
    case let .some(override): detailText = override
    case .none: detailText = playable.subtitle
    }
    let listItem = CPListItem(
      text: playable.title,
      detailText: detailText,
      image: image,
      accessoryImage: nil,
      accessoryType: accessoryType
    )
    listItem.userInfo = [
      CarPlayListUserInfoKeys.playableDownloadID.rawValue: playable.uniqueID,
      CarPlayListUserInfoKeys.artworkDownloadID.rawValue: playable.artwork?.uniqueID as Any,
      CarPlayListUserInfoKeys.artworkOwnerObjectID.rawValue: playable.objectID,
      CarPlayListUserInfoKeys.artworkOwnerType.rawValue: playable.isSong ? ArtworkType
        .song : ArtworkType.podcastEpisode,
      CarPlayListUserInfoKeys.isTrackDisplayed.rawValue: isTrackDisplayed,
    ]
    listItem.handler = { [weak self] item, completion in
      guard let self = self else { completion(); return }
      appDelegate.player.play(context: playContext)
      displayNowPlaying {
        completion()
      }
    }
    return listItem
  }
}
