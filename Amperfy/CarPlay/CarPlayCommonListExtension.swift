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

/// cassette (BUG-337): which of the two browse tabs a list belongs to.
enum CarPlayBrowseKind: Sendable {
  case albums, artists

  var tabTitle: String { self == .albums ? "Albums" : "Artists" }

  func noun(_ n: Int) -> String {
    self == .albums ? (n == 1 ? "album" : "albums") : (n == 1 ? "artist" : "artists")
  }
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
  /// CarPlay raises an uncaught `NSInvalidArgumentException` when a pushed
  /// `CPListTemplate` exceeds the connected vehicle's item limit. Leaf detail
  /// lists prepend `reserved` action rows (Shuffle / All Songs), so clamp the
  /// content to leave room for them — within both that limit and our own
  /// `carPlayMaxElements` ceiling.
  func carPlayLeafItemLimit(reserved: Int) -> Int {
    max(0, min(LibraryStorage.carPlayMaxElements, CPListTemplate.maximumItemCount - reserved))
  }

  /// cassette (BUG-337): the row budget for the Albums and Artists tabs and every pushed
  /// range list. The car's reported `CPListTemplate.maximumItemCount` is NOT trusted above
  /// this ceiling: the reported symptom ("#, A, part of B") can only happen when the phone
  /// built the whole list and the head unit drew about 24 rows of it, so the first install
  /// never emits more than 24 browse rows. The leaf lists (album tracks, All Songs, playlist
  /// items) still use the raw report through `carPlayLeafItemLimit` and are the probe.
  /// Lift rule, from the "CarPlay budget" line of the first drive's diagnostics export:
  /// a 500 report and a long leaf list that scrolls to the end means the car honours what it
  /// reports, so raise this to `LibraryStorage.carPlayMaxElements`; a 500 report and a leaf
  /// list that stops near 24 means keep it; `Int.max` trusts the report fully.
  static let carPlayBrowseBudgetCeiling = 24

  /// `min(reported, ceiling)`, with a report under 4 treated as unreported. Read at every
  /// render, never cached at connect, so a value that arrives late is honoured. The `max(2, ...)`
  /// keeps one content row beside the paging row.
  var carPlayBrowseItemBudget: Int {
    let reported = CPListTemplate.maximumItemCount
    let trusted = reported >= 4 ? reported : Self.carPlayBrowseBudgetCeiling
    return max(2, min(trusted, Self.carPlayBrowseBudgetCeiling))
  }

  var carPlayBrowseSectionBudget: Int { max(1, CPListTemplate.maximumSectionCount) }

  // cassette (BUG-337): the single-level builders fill IN ORDER and stop at the browse
  // budget, instead of dividing the car's item count by the section count (which starved
  // every letter to a couple of rows). Index titles come from the FRC section key, which is
  // the one-character `sectionInitial`, so `&` and `?` sections index as on the phone. These
  // serve the favorites / newest / recent / cached lists (unreachable in the shipped IA);
  // the Albums and Artists tabs render through `renderBrowseList` and get bucketing.
  func createArtistItems(
    from fetchedController: ArtistFetchedResultsController?,
    onlyCached: Bool
  )
    -> [CPListSection] {
    var sections = [CPListSection]()
    guard let fetchedController = fetchedController,
          let fetchSections = fetchedController.sections else { return sections }
    let budget = carPlayBrowseItemBudget
    let isAlphabetic = fetchedController.sortType.asSectionIndexType == .alphabet
    var emitted = 0
    for fetchSection in fetchSections {
      if emitted >= budget { break }
      guard let fetchObjects = fetchSection.objects as? [ArtistMO] else { continue }
      var items = [CPListTemplateItem]()
      for fetchObject in fetchObjects {
        // cassette (LIST-2): cap BEFORE appending, so the total never passes the budget.
        if emitted >= budget { break }
        items.append(createDetailTemplate(
          for: Artist(managedObject: fetchObject),
          onlyCached: onlyCached
        ))
        emitted += 1
      }
      sections.append(CPListSection(
        items: items,
        header: nil,
        sectionIndexTitle: isAlphabetic ? String(fetchSection.name.prefix(1)) : nil
      ))
    }
    return sections
  }

  func createAlbumItems(
    from fetchedController: AlbumFetchedResultsController?,
    onlyCached: Bool
  )
    -> [CPListSection] {
    var sections = [CPListSection]()
    guard let fetchedController = fetchedController,
          let fetchSections = fetchedController.sections else { return sections }
    let budget = carPlayBrowseItemBudget
    let isAlphabetic = fetchedController.sortType.asSectionIndexType == .alphabet
    var emitted = 0
    for fetchSection in fetchSections {
      if emitted >= budget { break }
      guard let fetchObjects = fetchSection.objects as? [AlbumMO] else { continue }
      var items = [CPListTemplateItem]()
      for fetchObject in fetchObjects {
        // cassette (LIST-2): cap BEFORE appending (see createArtistItems).
        if emitted >= budget { break }
        items.append(createDetailTemplate(
          for: Album(managedObject: fetchObject),
          onlyCached: onlyCached
        ))
        emitted += 1
      }
      sections.append(CPListSection(
        items: items,
        header: nil,
        sectionIndexTitle: isAlphabetic ? String(fetchSection.name.prefix(1)) : nil
      ))
    }
    return sections
  }

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
    let glyph: UIImage = kind == .albums ? UIImage.lucideAlbums : UIImage.lucideArtists
    let item = CPListItem(
      text: label,
      detailText: "\(bucket.itemCount) \(kind.noun(bucket.itemCount))",
      image: UIImage
        .carPlayGlyph(
          with: glyph,
          iconSizeType: .small,
          theme: getPreference(activeAccountInfo).theme,
          lightDarkMode: traits.userInterfaceStyle.asModeType,
          switchColors: true
        )
        .carPlayImage(carTraitCollection: traits),
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
          rows.append((key: entity.key, item: item))
        }
      }
      mode = pageCount > 1 ? "leafPaged" : "leaf"
    } else {
      let buckets = AlphabeticBucketPacker.pack(
        sections: counts,
        itemBudget: budget,
        sectionBudget: sectionBudget
      )
      if buckets.isEmpty {
        descriptor.page = 0
        for entity in browseEntities(kind: descriptor.kind, in: frcSections, sectionNames: nil) {
          if let item = browseRow(
            kind: descriptor.kind,
            object: entity.object,
            onlyCached: onlyCached
          ) {
            rows.append((key: entity.key, item: item))
          }
        }
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

  func createSongItems(from fetchedController: BasicFetchedResultsController<SongMO>?)
    -> [CPListTemplateItem] {
    var items = [CPListTemplateItem]()
    var playables = [AbstractPlayable]()
    guard let fetchedController = fetchedController else { return items }
    // cassette (LIST-3): iterate up to the item limit, not maximumSectionCount.
    for index in 0 ..< carPlayLeafItemLimit(reserved: 1) {
      guard let entity = fetchedController.getWrappedEntity(at: index) else { break }
      playables.append(entity)
    }
    if !playables.isEmpty {
      items.append(createPlayShuffledListItem(playContext: PlayContext(
        name: "Favorite Songs",
        playables: playables
      )))
    }
    for (index, playable) in playables.enumerated() {
      let detailTemplate = createDetailTemplate(
        for: playable,
        playContext: PlayContext(name: "Favorite Songs", index: index, playables: playables)
      )
      items.append(detailTemplate)
    }
    return items
  }

  func createPlaylistDetailItems(
    from fetchedController: PlaylistItemsFetchedResultsController
  )
    -> [CPListTemplateItem] {
    let playlist = fetchedController.playlist
    var items = [CPListItem]()

    guard let playables = fetchedController.getContextSongs(onlyCachedSongs: isOfflineMode)
    else { return items }

    items.append(createPlayShuffledListItem(playContext: PlayContext(
      containable: playlist,
      playables: playlist.playables.filterCached(dependigOn: isOfflineMode)
    )))
    // cassette (LIST-3): clamp by the ITEM limit, not maximumSectionCount (a section
    // ceiling), so a long playlist isn't silently cut to a handful of rows. reserved:1
    // leaves room for the Shuffle row prepended above.
    let displayedSongs = playables.prefix(carPlayLeafItemLimit(reserved: 1))
    for (index, song) in displayedSongs.enumerated() {
      let listItem = createDetailTemplate(
        for: song,
        playContext: PlayContext(containable: playlist, index: index, playables: playables)
      )
      items.append(listItem)
    }
    return items
  }

  func createPodcastDetailItems(
    from fetchedController: PodcastEpisodesFetchedResultsController
  )
    -> [CPListTemplateItem] {
    let podcast = fetchedController.podcast
    var items = [CPListItem]()

    var playables = [AbstractPlayable]()
    // cassette (LIST-3): iterate up to the item limit, not maximumSectionCount.
    for index in 0 ..< carPlayLeafItemLimit(reserved: 0) {
      guard let entity = fetchedController.getWrappedEntity(at: index) else { break }
      playables.append(entity)
    }
    for (index, song) in playables.enumerated() {
      let listItem = createDetailTemplate(
        for: song,
        playContext: PlayContext(containable: podcast, index: index, playables: playables)
      )
      items.append(listItem)
    }
    return items
  }

  /// cassette: produce a CarPlay bitmap for a library entity, cropping artists
  /// to a circle so they match the round artist artwork iOS renders (CarPlay
  /// list items / image-row elements can't apply a shape themselves). Albums,
  /// podcasts, playlists, etc. stay square.
  func carPlayEntityImage(_ image: UIImage, for entity: AbstractLibraryEntity?) -> UIImage {
    let shaped = (entity is Artist) ? image.croppedToCircle() : image
    return shaped.carPlayImage(carTraitCollection: traits)
  }

  func createDetailTemplate(for artist: Artist, onlyCached: Bool) -> CPListItem {
    let section = CPListItem(
      text: artist.name,
      detailText: artist.subtitle,
      image: carPlayEntityImage(
        LibraryEntityImage.getImageToDisplayImmediately(
          libraryEntity: artist,
          themePreference: getPreference(activeAccountInfo).theme,
          artworkDisplayPreference: getPreference(activeAccountInfo).artworkDisplayPreference,
          useCache: false
        ),
        for: artist
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

  // cassette (CarPlay open-a-view): the artist detail (shuffle + all-songs + albums)
  // as a REUSABLE template, shared by the library artist row and the Home artist tile.
  func makeArtistDetailTemplate(for artist: Artist, onlyCached: Bool) -> CPListTemplate? {
    guard let activeAccount else { return nil }
    var albumItems = [CPListItem]()
    albumItems.append(createPlayShuffledListItem(playContext: PlayContext(
      containable: artist,
      playables: artist.playables.filterCached(dependigOn: onlyCached || isOfflineMode)
    )))
    albumItems.append(createDetailAllSongsTemplate(for: artist, onlyCached: onlyCached))
    let artistAlbums = appDelegate.storage.main.library.getAlbums(
      for: activeAccount,
      whichContainsSongsWithArtist: artist,
      onlyCached: onlyCached || isOfflineMode
    ).prefix(carPlayLeafItemLimit(reserved: albumItems.count))
    for album in artistAlbums {
      let listItem = createDetailTemplate(for: album, onlyCached: onlyCached)
      albumItems.append(listItem)
    }
    return CPListTemplate(title: artist.name, sections: [
      CPListSection(items: albumItems),
    ])
  }

  func createDetailAllSongsTemplate(for artist: Artist, onlyCached: Bool) -> CPListItem {
    let section = CPListItem(
      text: "All Songs",
      detailText: nil,
      image: UIImage.carPlayGlyph(
        with: UIImage.lucideSongs,
        iconSizeType: .small,
        theme: getPreference(activeAccountInfo).theme,
        lightDarkMode: traits.userInterfaceStyle.asModeType,
        switchColors: true
      ).carPlayImage(carTraitCollection: traits),
      accessoryImage: nil,
      accessoryType: .disclosureIndicator
    )
    section.handler = { [weak self] item, completion in
      guard let self = self else { completion(); return }
      var songItems = [CPListItem]()
      songItems.append(createPlayShuffledListItem(playContext: PlayContext(
        containable: artist,
        playables: artist.playables.filterCached(dependigOn: onlyCached || isOfflineMode)
      )))
      let artistSongs = artist.playables.filterCached(dependigOn: onlyCached || isOfflineMode)
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
      image: LibraryEntityImage.getImageToDisplayImmediately(
        libraryEntity: album,
        themePreference: getPreference(activeAccountInfo).theme,
        artworkDisplayPreference: getPreference(activeAccountInfo).artworkDisplayPreference,
        useCache: false
      ).carPlayImage(carTraitCollection: traits),
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
        appDelegate.player.play(context: PlayContext(
          containable: album,
          playables: album.playables.filterCached(dependigOn: onlyCached || isOfflineMode)
        ))
        displayNowPlaying { completion() }
        return
      }
      completion()
    }
    return section
  }

  // cassette (CarPlay open-a-view): the album detail (shuffle row + track list) as a
  // REUSABLE template, so the library album row AND the Home album tile open the same
  // view instead of the Home tile auto-playing.
  func makeAlbumDetailTemplate(for album: Album, onlyCached: Bool) -> CPListTemplate {
    var songItems = [CPListItem]()
    songItems.append(createPlayShuffledListItem(playContext: PlayContext(
      containable: album,
      playables: album.playables.filterCached(dependigOn: onlyCached || isOfflineMode)
    )))
    let albumSongs = album.playables.filterCached(dependigOn: onlyCached || isOfflineMode)
      .prefix(carPlayLeafItemLimit(reserved: songItems.count))
    for (index, song) in albumSongs.enumerated() {
      let listItem = createDetailTemplate(
        for: song,
        playContext: PlayContext(containable: album, index: index, playables: Array(albumSongs)),
        isTrackDisplayed: true
      )
      songItems.append(listItem)
    }
    return CPListTemplate(title: album.name, sections: [
      CPListSection(items: songItems),
    ])
  }

  func createPlaylistsSections() -> [CPListSection] {
    var sections = [CPListSection]()
    var itemCount = 0
    guard let fetchedController = playlistFetchController,
          let fetchSections = fetchedController.sections else { return sections }
    for fetchSection in fetchSections {
      guard let fetchObjects = fetchSection.objects as? [PlaylistMO] else { continue }
      var items = [CPListTemplateItem]()

      var indexTitle: String?
      if fetchedController.sortType.asSectionIndexType == .alphabet {
        indexTitle = fetchObjects.first?.name?.prefix(1).uppercased()
        if let _ = Int(indexTitle ?? "-") {
          indexTitle = "#"
        }
      }

      for fetchObject in fetchObjects {
        // cassette (BUG-337): cap BEFORE building the row; the old post-append `>` let the
        // list overshoot the car's item count by one.
        if itemCount >= CPListTemplate.maximumItemCount { break }
        let playlist = Playlist(
          library: appDelegate.storage.main.library,
          managedObject: fetchObject
        )
        items.append(createPlaylistRow(playlist))
        itemCount += 1
      }
      let section = CPListSection(items: items, header: nil, sectionIndexTitle: indexTitle)
      sections.append(section)
      if itemCount >= CPListTemplate.maximumItemCount { break }
    }
    return sections
  }

  /// One playlist row (local cover, name, subtitle, disclosure; tap pushes the playlist
  /// detail). Shared by the Playlists tab and the Home shelf list (cassette, BUG-338).
  func createPlaylistRow(_ playlist: Playlist) -> CPListItem {
    // cassette (Wave 2b): playlists used to render blank in CarPlay (image: nil).
    // Resolve the LOCAL cover (a bundled preset, or a materialized pick), else a
    // generated playlist placeholder, so every playlist shows art in the car.
    let cover = CassetteCloudPlaylistBridge.localCoverImage(for: playlist.id)
      ?? UIImage.getGeneratedArtwork(
        theme: getPreference(activeAccountInfo).theme,
        artworkType: .playlist,
        name: playlist.name
      )
    let item = CPListItem(
      text: playlist.name,
      detailText: playlist.subtitle,
      image: carPlayEntityImage(cover, for: nil),
      accessoryImage: nil,
      accessoryType: .disclosureIndicator
    )
    item.handler = { [weak self] item, completion in
      guard let self = self else { completion(); return }
      pushPlaylistDetail(playlist)
      completion()
    }
    return item
  }

  // cassette (CarPlay open-a-view): push a playlist's detail (empty template + async
  // FRC populate), shared by the library playlist row and the Home playlist tile.
  func pushPlaylistDetail(_ playlist: Playlist) {
    let playlistDetailTemplate = CPListTemplate(title: playlist.name, sections: [
      CPListSection(items: [CPListTemplateItem]()),
    ])
    playlistDetailSection = playlistDetailTemplate
    createPlaylistDetailFetchController(playlist: playlist)
    pushTemplateIfAllowed(playlistDetailTemplate, animated: true)
  }

  func createPodcastsSections(
    from fetchedController: BasicFetchedResultsController<PodcastMO>?,
    onlyCached: Bool
  )
    -> [CPListSection] {
    var sections = [CPListSection]()
    var itemCount = 0
    guard let fetchedController,
          let fetchSections = fetchedController.sections else { return sections }
    for fetchSection in fetchSections {
      guard let fetchObjects = fetchSection.objects as? [PodcastMO] else { continue }
      var items = [CPListTemplateItem]()

      var indexTitle: String?
      indexTitle = fetchObjects.first?.title?.prefix(1).uppercased()
      if let _ = Int(indexTitle ?? "-") {
        indexTitle = "#"
      }

      for fetchObject in fetchObjects {
        // cassette (BUG-337): cap BEFORE building the row (see createPlaylistsSections).
        if itemCount >= CPListTemplate.maximumItemCount { break }
        let podcast = Podcast(managedObject: fetchObject)

        let item = CPListItem(
          text: podcast.title,
          detailText: podcast.subtitle,
          image: LibraryEntityImage.getImageToDisplayImmediately(
            libraryEntity: podcast,
            themePreference: getPreference(activeAccountInfo).theme,
            artworkDisplayPreference: getPreference(activeAccountInfo).artworkDisplayPreference,
            useCache: false
          ).carPlayImage(carTraitCollection: traits),
          accessoryImage: nil,
          accessoryType: .disclosureIndicator
        )
        if let artwork = podcast.artwork, let accountInfo = artwork.account?.info {
          appDelegate.getMeta(accountInfo).artworkDownloadManager.download(object: artwork)
        }
        item.userInfo = [
          CarPlayListUserInfoKeys.artworkDownloadID.rawValue: podcast.artwork?.uniqueID as Any,
          CarPlayListUserInfoKeys.artworkOwnerObjectID.rawValue: podcast.managedObject
            .objectID as Any,
          CarPlayListUserInfoKeys.artworkOwnerType.rawValue: ArtworkType.podcast as Any,
        ]
        item.handler = { [weak self] item, completion in
          guard let self = self else { completion(); return }
          let podcastDetailTemplate = CPListTemplate(title: podcast.name, sections: [
            CPListSection(items: [CPListTemplateItem]()),
          ])
          podcastDetailSection = podcastDetailTemplate
          createPodcastDetailFetchController(podcast: podcast, onlyCached: onlyCached)
          pushTemplateIfAllowed(podcastDetailTemplate, animated: true)
          completion()
        }
        items.append(item)
        itemCount += 1
      }
      let section = CPListSection(items: items, header: nil, sectionIndexTitle: indexTitle)
      sections.append(section)
      if itemCount >= CPListTemplate.maximumItemCount { break }
    }
    return sections
  }

  func createGenreSections(
    from fetchedController: BasicFetchedResultsController<GenreMO>?,
    onlyCached: Bool
  )
    -> [CPListSection] {
    var sections = [CPListSection]()
    var itemCount = 0
    guard let fetchedController = fetchedController,
          let fetchSections = fetchedController.sections,
          !fetchSections.isEmpty,
          let activeAccount = activeAccount else { return sections }

    for fetchSection in fetchSections {
      guard let fetchObjects = fetchSection.objects as? [GenreMO] else { continue }
      var items = [CPListTemplateItem]()

      var indexTitle: String?
      indexTitle = fetchObjects.first?.name?.prefix(1).uppercased()
      if let _ = Int(indexTitle ?? "-") {
        indexTitle = "#"
      }

      for fetchObject in fetchObjects {
        // cassette (BUG-337): cap BEFORE building the row (see createPlaylistsSections).
        if itemCount >= CPListTemplate.maximumItemCount { break }
        let genre = Genre(managedObject: fetchObject)
        let genreInfo = genre.info(
          for: activeAccount.apiType.asServerApiType,
          details: DetailInfoType(
            type: .short,
            settings: appDelegate.storage.settings
          )
        )
        let listItem = CPListItem(
          text: genre.name,
          detailText: genreInfo,
          image: LibraryEntityImage.getImageToDisplayImmediately(
            libraryEntity: genre,
            themePreference: getPreference(activeAccountInfo).theme,
            artworkDisplayPreference: getPreference(activeAccountInfo).artworkDisplayPreference,
            useCache: false
          ).carPlayImage(carTraitCollection: traits),
          accessoryImage: nil,
          accessoryType: .none
        )
        listItem.handler = { [weak self] item, completion in
          guard let self = self else { completion(); return }
          let songs = genre.playables.filterCached(dependigOn: onlyCached || isOfflineMode)
          let genrePlayContext = PlayContext(name: genre.name, playables: songs)
          appDelegate.player.play(context: genrePlayContext)
          displayNowPlaying {}
          completion()
        }
        items.append(listItem)
        itemCount += 1
      }
      let section = CPListSection(items: items, header: nil, sectionIndexTitle: indexTitle)
      sections.append(section)
      if itemCount >= CPListTemplate.maximumItemCount { break }
    }
    return sections
  }

  func createRadioSections(from fetchedController: BasicFetchedResultsController<RadioMO>?)
    -> [CPListSection] {
    var sections = [CPListSection]()
    guard let fetchedController = fetchedController,
          let fetchSections = fetchedController.sections,
          !fetchSections.isEmpty else { return sections }

    guard let fetchedRadios = fetchedController.fetchedObjects else { return sections }
    // cassette (BUG-337): the Random row prepended below already occupies one slot.
    let radios = fetchedRadios.prefix(max(0, CPListTemplate.maximumItemCount - 1))
      .compactMap { Radio(managedObject: $0) }

    let playRandomItem = createPlayRandomListItem(playContext: PlayContext(
      name: "Radios",
      playables: radios
    ))
    let randomSection = CPListSection(items: [playRandomItem], header: nil, sectionIndexTitle: nil)
    sections.append(randomSection)
    var itemCount = 1

    for fetchSection in fetchSections {
      guard let fetchObjects = fetchSection.objects as? [RadioMO] else { continue }
      var items = [CPListTemplateItem]()

      var indexTitle: String?
      indexTitle = fetchObjects.first?.title?.prefix(1).uppercased()
      if let _ = Int(indexTitle ?? "-") {
        indexTitle = "#"
      }

      for fetchObject in fetchObjects {
        // cassette (BUG-337): cap BEFORE building the row (see createPlaylistsSections).
        if itemCount >= CPListTemplate.maximumItemCount { break }
        let radio = Radio(managedObject: fetchObject)
        let listItem = createDetailTemplate(
          for: radio,
          playContext: PlayContext(name: "Radios", index: itemCount - 1, playables: Array(radios)),
          isTrackDisplayed: false
        )
        items.append(listItem)
        itemCount += 1
      }
      let section = CPListSection(items: items, header: nil, sectionIndexTitle: indexTitle)
      sections.append(section)
      if itemCount >= CPListTemplate.maximumItemCount { break }
    }
    return sections
  }

  func createPlayRandomListItem(
    playContext: PlayContext,
    text: String = "Random"
  )
    -> CPListItem {
    let img = UIImage.carPlayGlyph(
      with: UIImage.lucideShuffle,
      iconSizeType: .small,
      theme: getPreference(activeAccountInfo).theme,
      lightDarkMode: traits.userInterfaceStyle.asModeType,
      switchColors: true
    ).carPlayImage(carTraitCollection: traits)
    let listItem = CPListItem(text: text, detailText: nil, image: img)
    listItem.handler = { [weak self] item, completion in
      guard let self = self else { completion(); return }
      appDelegate.player.play(context: playContext.getWithShuffledIndex())
      displayNowPlaying {
        completion()
      }
    }
    return listItem
  }

  func createPlayShuffledListItem(
    playContext: PlayContext,
    text: String = "Shuffle"
  )
    -> CPListItem {
    let img = UIImage.carPlayGlyph(
      with: UIImage.lucideShuffle,
      iconSizeType: .small,
      theme: getPreference(activeAccountInfo).theme,
      lightDarkMode: traits.userInterfaceStyle.asModeType,
      switchColors: true
    ).carPlayImage(carTraitCollection: traits)
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

  func createDetailTemplate(for episode: PodcastEpisode) -> CPListItem {
    // Cassette CarPlay: cloud/"cached" badge gated to Server Mode — see the
    // song-row variant. Hidden in the default on-device-only experience.
    let accessoryType: CPListItemAccessoryType = CassetteLibraryFilterProvider.shared
      .isOnDeviceOnly ? .none : (episode.isCached ? .cloud : .none)
    let listItem = CPListItem(
      text: episode.title,
      detailText: nil,
      image: nil,
      accessoryImage: nil,
      accessoryType: accessoryType
    )
    listItem.handler = { [weak self] item, completion in
      guard let self = self else { completion(); return }
      appDelegate.player.play(context: PlayContext(containable: episode))
      displayNowPlaying {
        completion()
      }
    }
    return listItem
  }

  func createLibraryItem(
    text: String,
    subtitle: String? = nil,
    icon: UIImage,
    sectionToDisplay: CPListTemplate
  )
    -> CPListItem {
    let item = CPListItem(
      text: text,
      detailText: subtitle,
      image: UIImage
        .carPlayGlyph(
          with: icon,
          iconSizeType: .small,
          theme: getPreference(activeAccountInfo).theme,
          lightDarkMode: traits.userInterfaceStyle.asModeType,
          switchColors: true
        )
        .carPlayImage(carTraitCollection: traits),
      accessoryImage: nil,
      accessoryType: .disclosureIndicator
    )
    item.handler = { [weak self] item, completion in
      guard let self = self else { completion(); return }
      Task { @MainActor in
        self.pushTemplateIfAllowed(sectionToDisplay, animated: true)
        completion()
      }
    }
    return item
  }

  enum CarPlayListUserInfoKeys: String {
    case playableDownloadID
    case artworkDownloadID
    case artworkOwnerType
    case artworkOwnerObjectID
    case isTrackDisplayed
  }

  func createDetailTemplate(
    for playable: AbstractPlayable,
    playContext: PlayContext,
    isTrackDisplayed: Bool = false
  )
    -> CPListItem {
    // Cassette CarPlay: the cloud/"cached" badge is gated to Server Mode
    // (Navidrome native streaming). In the default on-device-only experience
    // everything browsable in-car is already local, so the badge is pure noise
    // — keep rows clean. In streaming mode it marks which rows are cached.
    let accessoryType: CPListItemAccessoryType = CassetteLibraryFilterProvider.shared
      .isOnDeviceOnly ? .none : (playable.isCached ? .cloud : .none)
    let image = getImage(for: playable, isTrackDisplayed: isTrackDisplayed)
    if let artwork = playable.artwork, let accountInfo = artwork.account?.info {
      appDelegate.getMeta(accountInfo).artworkDownloadManager.download(object: artwork)
    }
    let listItem = CPListItem(
      text: playable.title,
      detailText: playable.subtitle,
      image: image.carPlayImage(carTraitCollection: traits),
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

  func getImage(for playable: AbstractPlayable, isTrackDisplayed: Bool) -> UIImage {
    isTrackDisplayed ? UIImage.numberToImage(number: playable.track) :
      LibraryEntityImage.getImageToDisplayImmediately(
        libraryEntity: playable,
        themePreference: getPreference(activeAccountInfo).theme,
        artworkDisplayPreference: getPreference(activeAccountInfo).artworkDisplayPreference,
        useCache: false
      )
  }

  func triggerPlayRandomSongsItem(onlyCached: Bool) {
    let songs = appDelegate.storage.main.library
      .getRandomSongs(for: activeAccount, onlyCached: onlyCached || isOfflineMode)
    let playContext = PlayContext(
      name: "Random\(onlyCached ? " Cached" : "") Songs",
      playables: songs
    )
    appDelegate.player.playShuffled(context: playContext)
    displayNowPlaying {}
  }

  func triggerPlayRandomAlbums(onlyCached: Bool) {
    let randomAlbums = appDelegate.storage.main.library.getRandomAlbums(
      for: activeAccount,
      count: 5,
      onlyCached: onlyCached || isOfflineMode
    )
    var songs = [AbstractPlayable]()
    randomAlbums
      .forEach {
        songs
          .append(
            contentsOf: $0.playables
              .filterCached(dependigOn: onlyCached || self.isOfflineMode)
          )
      }
    let playContext = PlayContext(
      name: "Random\(onlyCached ? " Cached" : "") Albums",
      playables: songs
    )
    appDelegate.player.play(context: playContext)
    displayNowPlaying {}
  }
}
