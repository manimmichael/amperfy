//
//  RadioStationVC.swift
//  Amperfy
//
//  Cassette (founder, 2026-10-21): a radio station's page. Tap a station on the dial or
//  in Home's Radio row and land here: Play and Save up top, then what's on air, what it
//  just played (where the station publishes its list), about, and stations like it.
//
//  The web's /radio/<slug> shows the same things from the same route
//  (GET /api/radio/station/<slug>, apps/cassette/src/lib/radio/station-page.ts). The page
//  opens at once from the registry copy the app carries (name, art, about, similar), and
//  the live parts fill in from the cloud, refreshed every 30 seconds while it is on
//  screen. Save is the web's save (RadioSaved). Lit like the record pages: the station's
//  mark (or its word picture) is the glow and the colour of the headings' answers.
//

import AmperfyKit
import UIKit

// MARK: - RadioStationPagePayload

/// The web route's shape, the parts the page shows.
struct RadioStationPagePayload: Decodable {
  struct Show: Decodable {
    let name: String
    let host: String?
    let tagline: String?
    let starts: String?
    let until: String?
    let image: String?
  }

  struct Track: Decodable {
    let artist: String
    let title: String
    let album: String?
    let coverUrl: String?
    let comment: String?
    let playedAt: String?
  }

  struct Live: Decodable {
    let show: Show?
    let track: Track?
    let next: [Show]?
    let nextTracks: [Track]?
  }

  let live: Live?
  let recent: [Track]?
  let similar: [RadioCatalogStation]?
}

// MARK: - RadioStationVC

@MainActor
final class RadioStationVC: UIViewController, UIScrollViewDelegate {
  private static let artSide: CGFloat = 240
  private static let gutter = CassetteHeading.sideInset
  private static let refreshEvery: TimeInterval = 30

  private static var base: String {
    #if DEBUG
      // A debug build can read a local web server before the route ships:
      // SIMCTL_CHILD_CASSETTE_RADIO_BASE=http://localhost:3000 xcrun simctl launch …
      if let base = ProcessInfo.processInfo.environment["CASSETTE_RADIO_BASE"], !base.isEmpty {
        return base
      }
    #endif
    return "https://cassette.digital"
  }

  private let account: Account
  private let station: RadioCatalogStation
  /// The hub's copy of this station (what Play plays); nil when the hub does not hold it.
  private var radio: Radio?

  private let scrollView = UIScrollView()
  private let stack = UIStackView()
  private let glow = CoverGlowView(recipe: .page)
  private let lighter = DetailCoverLighter()
  private var tint: CoverTint = .neutral

  private let art = UIImageView()
  private let nameLabel = UILabel()
  private let kickerLabel = UILabel()
  private let playPill = LibraryElementDetailTableHeaderView.makePlayPill()
  private let savePill = UIButton(configuration: .plain())

  private let onAirBlock = UIStackView()
  private let recentBlock = UIStackView()
  private let similarBlock = UIStackView()
  private var headings: [(label: UILabel, shout: String, answer: String?)] = []
  private var similar: [RadioCatalogStation] = []
  private lazy var similarCollection: UICollectionView = {
    let layout = UICollectionViewFlowLayout()
    layout.scrollDirection = .horizontal
    layout.itemSize = CGSize(width: AlbumCarousel.mockItemWidth, height: AlbumCarousel.mockItemWidth + 52)
    layout.minimumLineSpacing = 14
    layout.sectionInset = UIEdgeInsets(top: 0, left: Self.gutter, bottom: 0, right: Self.gutter)
    let view = UICollectionView(frame: .zero, collectionViewLayout: layout)
    view.backgroundColor = .clear
    view.showsHorizontalScrollIndicator = false
    view.register(RadioShelfCell.self, forCellWithReuseIdentifier: RadioShelfCell.typeName)
    view.dataSource = self
    view.delegate = self
    return view
  }()

  private var refreshTimer: Timer?
  private var loadedOnce = false

  init(account: Account, station: RadioCatalogStation) {
    self.account = account
    self.station = station
    super.init(nibName: nil, bundle: nil)
    navigationItem.largeTitleDisplayMode = .never
    // The glow runs up under a clear bar, as on the record pages; the name joins the bar
    // only once the hero's own name has scrolled under it.
    let clearBar = UINavigationBarAppearance()
    clearBar.configureWithTransparentBackground()
    navigationItem.standardAppearance = clearBar
    navigationItem.compactAppearance = clearBar
    navigationItem.scrollEdgeAppearance = clearBar
    navigationItem.compactScrollEdgeAppearance = clearBar
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: Lifecycle

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .backgroundColor
    radio = hubRadio(for: station)

    glow.isUserInteractionEnabled = false
    view.addSubview(glow)

    scrollView.delegate = self
    scrollView.alwaysBounceVertical = true
    scrollView.backgroundColor = .clear
    scrollView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(scrollView)

    stack.axis = .vertical
    stack.alignment = .fill
    stack.spacing = 0
    stack.translatesAutoresizingMaskIntoConstraints = false
    scrollView.addSubview(stack)
    NSLayoutConstraint.activate([
      scrollView.topAnchor.constraint(equalTo: view.topAnchor),
      scrollView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      scrollView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      scrollView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      stack.topAnchor.constraint(equalTo: scrollView.contentLayoutGuide.topAnchor),
      stack.leadingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.leadingAnchor),
      stack.trailingAnchor.constraint(equalTo: scrollView.contentLayoutGuide.trailingAnchor),
      stack.bottomAnchor.constraint(equalTo: scrollView.contentLayoutGuide.bottomAnchor, constant: -32),
      stack.widthAnchor.constraint(equalTo: scrollView.frameLayoutGuide.widthAnchor),
    ])

    buildHero()
    for block in [onAirBlock, recentBlock] {
      block.axis = .vertical
      block.spacing = 12
      block.isHidden = true
    }
    stack.addArrangedSubview(onAirBlock)
    stack.addArrangedSubview(recentBlock)
    stack.addArrangedSubview(buildAbout())
    similarBlock.axis = .vertical
    stack.addArrangedSubview(similarBlock)

    lighter.apply = { [weak self] tint, image, key in
      guard let self else { return }
      self.tint = tint
      glow.show(image: image, key: key)
      recolourHeadings()
    }

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(Self.savedDidChange),
      name: RadioSaved.didChange,
      object: nil
    )

    showSimilar(station.similar?.compactMap { RadioCatalog.shared.station(slug: $0) } ?? [])
    loadArt()
  }

  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    extendSafeAreaToAccountForMiniPlayer()
    applySaveState()
    refreshLive()
    refreshTimer?.invalidate()
    refreshTimer = Timer.scheduledTimer(withTimeInterval: Self.refreshEvery, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated { self?.refreshLive() }
    }
    Task { await RadioSaved.shared.refresh() }
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    refreshTimer?.invalidate()
    refreshTimer = nil
  }

  override func viewDidLayoutSubviews() {
    super.viewDidLayoutSubviews()
    layoutGlow()
  }

  func scrollViewDidScroll(_ scrollView: UIScrollView) {
    layoutGlow()
    let nameBottom = nameLabel.convert(nameLabel.bounds, to: view).maxY
    let barBottom = view.safeAreaInsets.top
    let title = nameBottom < barBottom ? station.name : nil
    if navigationItem.title != title { navigationItem.title = title }
  }

  /// The glow sits behind the page, under the bar, and scrolls with the hero.
  private func layoutGlow() {
    let offset = scrollView.contentOffset.y + scrollView.adjustedContentInset.top
    let height: CGFloat = Self.artSide + 360
    glow.frame = CGRect(x: 0, y: -offset, width: view.bounds.width, height: height + max(0, -offset))
  }

  // MARK: Hub

  private func hubRadio(for station: RadioCatalogStation) -> Radio? {
    let key = RadioCatalog.normalize(station.streamUrl)
    return appDelegate.storage.main.library.getRadios(for: account)
      .first { RadioCatalog.normalize($0.url) == key }
  }

  // MARK: Hero

  private func buildHero() {
    let hero = UIView()
    art.contentMode = .scaleAspectFill
    art.clipsToBounds = true
    art.layer.cornerRadius = CassetteRadius.small
    art.layer.cornerCurve = .continuous
    art.backgroundColor = RadioTile.fill(accent: station.accent)
    art.accessibilityIgnoresInvertColors = true

    nameLabel.numberOfLines = 0
    nameLabel.textAlignment = .center
    nameLabel.attributedText = NSAttributedString.cassette(
      station.name.uppercased(),
      .pageTitle,
      color: .cassette(.textPrimary)
    )
    nameLabel.accessibilityTraits = .header

    kickerLabel.numberOfLines = 0
    kickerLabel.textAlignment = .center
    kickerLabel.attributedText = NSAttributedString.cassette(
      station.kicker.uppercased(),
      .meta,
      color: .cassette(.textSecondary)
    )

    playPill.addAction(UIAction { [weak self] _ in self?.play() }, for: .primaryActionTriggered)
    playPill.isEnabled = radio != nil
    if radio == nil {
      // The hub does not hold this station yet, so there is nothing to tune to here.
      playPill.configuration?.attributedTitle = AttributedString(NSAttributedString.cassette(
        "Not on your Mac",
        .pill,
        color: .cassette(.textOnFill)
      ))
      playPill.configuration?.image = nil
    }
    savePill.configuration?.background.backgroundColor = .clear
    savePill.configuration?.background.strokeColor = UIColor.cassette(.textPrimary).withAlphaComponent(0.35)
    savePill.configuration?.background.strokeWidth = 1.5
    savePill.configuration?.cornerStyle = .capsule
    savePill.configuration?.baseForegroundColor = UIColor.cassette(.textPrimary)
    savePill.configuration?.preferredSymbolConfigurationForImage = UIImage.SymbolConfiguration(pointSize: 16)
    savePill.configuration?.imagePlacement = .leading
    savePill.configuration?.imagePadding = 8
    savePill.addAction(UIAction { [weak self] _ in
      guard let self else { return }
      RadioSaved.shared.toggle(station.slug)
    }, for: .primaryActionTriggered)
    applySaveState()

    let pills = UIStackView(arrangedSubviews: [playPill, savePill])
    pills.axis = .horizontal
    pills.spacing = 10
    pills.distribution = .fillEqually

    for v in [art, nameLabel, kickerLabel, pills] {
      v.translatesAutoresizingMaskIntoConstraints = false
      hero.addSubview(v)
    }
    let g = Self.gutter
    NSLayoutConstraint.activate([
      art.topAnchor.constraint(equalTo: hero.topAnchor, constant: CassetteTheme.Spacing.md),
      art.centerXAnchor.constraint(equalTo: hero.centerXAnchor),
      art.widthAnchor.constraint(equalToConstant: Self.artSide),
      art.heightAnchor.constraint(equalToConstant: Self.artSide),
      nameLabel.topAnchor.constraint(equalTo: art.bottomAnchor, constant: 24),
      nameLabel.leadingAnchor.constraint(equalTo: hero.leadingAnchor, constant: g),
      nameLabel.trailingAnchor.constraint(equalTo: hero.trailingAnchor, constant: -g),
      kickerLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 8),
      kickerLabel.leadingAnchor.constraint(equalTo: hero.leadingAnchor, constant: g),
      kickerLabel.trailingAnchor.constraint(equalTo: hero.trailingAnchor, constant: -g),
      pills.topAnchor.constraint(equalTo: kickerLabel.bottomAnchor, constant: 18),
      pills.leadingAnchor.constraint(equalTo: hero.leadingAnchor, constant: g),
      pills.trailingAnchor.constraint(equalTo: hero.trailingAnchor, constant: -g),
      pills.heightAnchor.constraint(equalToConstant: 48),
      pills.bottomAnchor.constraint(equalTo: hero.bottomAnchor, constant: -8),
    ])
    stack.addArrangedSubview(hero)
  }

  private func loadArt() {
    let scale = traitCollection.displayScale > 0 ? traitCollection.displayScale : 3
    let color = UIColor(cassetteHexString: station.accent) ?? CassetteTheme.UIColors.bg3
    let wordArt = CarPlayStyle.phoneWordArt(word: station.name, color: color, side: Self.artSide, scale: scale)
    art.image = wordArt
    guard let src = station.image, !src.isEmpty else {
      lighter.lightUp(image: wordArt, key: "radio-word:\(station.slug)")
      return
    }
    if let cached = RadioArtLoader.shared.cachedImage(for: src) {
      art.image = cached
      lighter.lightUp(image: cached, key: "radio:\(src)")
      return
    }
    Task { @MainActor [weak self] in
      let loaded = await RadioArtLoader.shared.image(for: src)
      guard let self else { return }
      if let loaded {
        art.image = loaded
        lighter.lightUp(image: loaded, key: "radio:\(src)")
      } else {
        lighter.lightUp(image: wordArt, key: "radio-word:\(station.slug)")
      }
    }
  }

  @objc
  private func savedDidChange() {
    applySaveState()
  }

  /// `+ SAVE` / `✓ SAVED`, the one save mark.
  private func applySaveState() {
    let saved = RadioSaved.shared.isSaved(station.slug)
    savePill.configuration?.image = (saved ? CassetteIcon.check : CassetteIcon.plus).symbolImage
    savePill.configuration?.attributedTitle = AttributedString(NSAttributedString.cassette(
      saved ? "Saved" : "Save",
      .pill,
      color: .cassette(.textPrimary)
    ))
    savePill.accessibilityLabel = saved ? "Saved. Remove \(station.name) from your stations" : "Save \(station.name)"
  }

  // MARK: Playing

  /// This station, then the similar stations the hub holds, so Next moves to one like it.
  private func play() {
    guard let radio else { return }
    let neighbours = similar.compactMap { hubRadio(for: $0) }
    appDelegate.player.play(context: PlayContext(
      name: station.name,
      index: 0,
      playables: [radio] + neighbours.filter { $0.id != radio.id }
    ))
    Haptics.light.vibrate(isHapticsEnabled: appDelegate.storage.settings.user.isHapticsEnabled)
  }

  fileprivate func play(similar s: RadioCatalogStation) {
    guard let hub = hubRadio(for: s) else { return }
    appDelegate.player.play(context: PlayContext(name: s.name, index: 0, playables: [hub]))
  }

  // MARK: Headings

  private func heading(_ shout: String, answer: String? = nil) -> UIView {
    let label = CassetteHeading.makeLabel()
    label.attributedText = CassetteHeading.attributed(shout: shout, answer: answer, answerColor: tint.text)
    label.accessibilityLabel = CassetteHeading.accessibilityLabel(shout: shout, answer: answer)
    headings.append((label, shout, answer))
    let head = UIView()
    head.addSubview(label)
    NSLayoutConstraint.activate([
      label.topAnchor.constraint(equalTo: head.topAnchor, constant: CassetteHeading.topSpacing),
      label.bottomAnchor.constraint(equalTo: head.bottomAnchor, constant: -CassetteHeading.bottomSpacing),
      label.leadingAnchor.constraint(equalTo: head.leadingAnchor, constant: Self.gutter),
      label.trailingAnchor.constraint(lessThanOrEqualTo: head.trailingAnchor, constant: -Self.gutter),
    ])
    return head
  }

  private func recolourHeadings() {
    for h in headings {
      h.label.attributedText = CassetteHeading.attributed(shout: h.shout, answer: h.answer, answerColor: tint.text)
    }
  }

  /// A view inset by the page gutter.
  private func inset(_ content: UIView) -> UIView {
    let wrap = UIView()
    content.translatesAutoresizingMaskIntoConstraints = false
    wrap.addSubview(content)
    NSLayoutConstraint.activate([
      content.topAnchor.constraint(equalTo: wrap.topAnchor),
      content.bottomAnchor.constraint(equalTo: wrap.bottomAnchor),
      content.leadingAnchor.constraint(equalTo: wrap.leadingAnchor, constant: Self.gutter),
      content.trailingAnchor.constraint(equalTo: wrap.trailingAnchor, constant: -Self.gutter),
    ])
    return wrap
  }

  private static func label(_ text: String, font: UIFont, color: UIColor, lines: Int = 1) -> UILabel {
    let label = UILabel()
    label.text = text
    label.font = font
    label.textColor = color
    label.numberOfLines = lines
    return label
  }

  // MARK: About

  private func buildAbout() -> UIView {
    let block = UIStackView()
    block.axis = .vertical
    block.addArrangedSubview(heading("About"))

    let body = UIStackView()
    body.axis = .vertical
    body.spacing = 14
    body.addArrangedSubview(Self.label(
      station.description,
      font: .cassette(.body),
      color: .cassette(.textSecondary),
      lines: 0
    ))
    if let about = station.about {
      for paragraph in about.text.components(separatedBy: "\n\n") where !paragraph.isEmpty {
        body.addArrangedSubview(Self.label(paragraph, font: .cassette(.body), color: .cassette(.textSecondary), lines: 0))
      }
      let credit = UIButton(configuration: .plain())
      credit.configuration?.contentInsets = .zero
      credit.configuration?.attributedTitle = AttributedString(NSAttributedString.cassette(
        "From \(about.source)\(about.license.map { ", \($0)" } ?? "")",
        .caption,
        color: .cassette(.textTertiary)
      ))
      credit.contentHorizontalAlignment = .leading
      credit.addAction(UIAction { _ in Self.open(about.url) }, for: .primaryActionTriggered)
      body.addArrangedSubview(credit)
    }

    var facts: [(String, String)] = [("Network", station.sourceLabel)]
    if !station.cityLabels.isEmpty { facts.append(("From", station.cityLabels.joined(separator: ", "))) }
    facts.append(("On air", station.isLive ? "Real shows and hosts" : "One sound, around the clock"))
    if !station.genres.isEmpty { facts.append(("Plays", station.genres.joined(separator: ", "))) }
    for (key, value) in facts {
      let k = Self.label(key.uppercased(), font: .cassette(.metadata), color: .cassette(.textTertiary))
      k.setContentHuggingPriority(.required, for: .horizontal)
      k.widthAnchor.constraint(equalToConstant: 76).isActive = true
      let v = Self.label(value, font: .cassette(.body), color: .cassette(.textSecondary), lines: 0)
      let row = UIStackView(arrangedSubviews: [k, v])
      row.axis = .horizontal
      row.alignment = .firstBaseline
      row.spacing = 12
      body.addArrangedSubview(row)
    }

    var links: [UIView] = []
    if let home = station.homepage { links.append(linkButton("Website", url: home)) }
    if let support = station.supportUrl { links.append(linkButton("Support \(station.name)", url: support)) }
    if !links.isEmpty {
      let row = UIStackView(arrangedSubviews: links + [UIView()])
      row.axis = .horizontal
      row.spacing = 20
      body.addArrangedSubview(row)
    }
    block.addArrangedSubview(inset(body))
    return block
  }

  private func linkButton(_ title: String, url: String) -> UIButton {
    let button = UIButton(configuration: .plain())
    button.configuration?.contentInsets = .zero
    button.configuration?.image = CassetteIcon.openExternal.uiImage(size: .small)
    button.configuration?.imagePlacement = .trailing
    button.configuration?.imagePadding = 4
    button.configuration?.baseForegroundColor = .cassette(.textPrimary)
    button.configuration?.attributedTitle = AttributedString(NSAttributedString.cassette(
      title,
      .metadata,
      color: .cassette(.textPrimary)
    ))
    button.addAction(UIAction { _ in Self.open(url) }, for: .primaryActionTriggered)
    return button
  }

  private static func open(_ url: String) {
    guard let url = URL(string: url) else { return }
    UIApplication.shared.open(url)
  }

  // MARK: Similar

  private func showSimilar(_ list: [RadioCatalogStation]) {
    let list = list.filter { $0.slug != station.slug }
    guard list.map(\.slug) != similar.map(\.slug) || similarBlock.arrangedSubviews.isEmpty else { return }
    similar = list
    similarBlock.arrangedSubviews.forEach { $0.removeFromSuperview() }
    guard !list.isEmpty else { return }
    similarBlock.addArrangedSubview(heading("More like", answer: station.name))
    similarCollection.heightAnchor.constraint(equalToConstant: AlbumCarousel.mockItemWidth + 52).isActive = true
    similarBlock.addArrangedSubview(similarCollection)
    similarCollection.reloadData()
  }

  // MARK: Live

  private func refreshLive() {
    guard station.hasNowPlaying || station.hasRecentPlays == true || !loadedOnce else { return }
    guard let url = URL(string: Self.base + "/api/radio/station/" + station.slug) else { return }
    Task { @MainActor [weak self] in
      var request = URLRequest(url: url)
      request.timeoutInterval = 10
      if let (data, response) = try? await URLSession.shared.data(for: request),
         (response as? HTTPURLResponse)?.statusCode == 200,
         let payload = try? JSONDecoder().decode(RadioStationPagePayload.self, from: data) {
        guard let self else { return }
        loadedOnce = true
        showLive(payload.live)
        showRecent(payload.recent ?? [])
        if let server = payload.similar, !server.isEmpty { showSimilar(server) }
        return
      }
      // The station route is newer than the now-playing route; until it ships, what's
      // on still comes from the route the player already reads.
      await self?.refreshFromNowPlaying()
    }
  }

  private func refreshFromNowPlaying() async {
    guard station.hasNowPlaying,
          let url = URL(string: Self.base + "/api/radio/now-playing?station=" + station.slug)
    else { return }
    var request = URLRequest(url: url)
    request.timeoutInterval = 10
    guard let (data, response) = try? await URLSession.shared.data(for: request),
          (response as? HTTPURLResponse)?.statusCode == 200,
          let live = try? JSONDecoder().decode(RadioStationPagePayload.Live.self, from: data)
    else { return }
    showLive(live)
  }

  private func showLive(_ live: RadioStationPagePayload.Live?) {
    onAirBlock.arrangedSubviews.forEach { $0.removeFromSuperview() }
    headings.removeAll { $0.shout == "On air" }
    guard let live, live.show != nil || live.track != nil else {
      onAirBlock.isHidden = true
      return
    }
    onAirBlock.isHidden = false
    onAirBlock.addArrangedSubview(heading("On air"))

    let text = UIStackView()
    text.axis = .vertical
    text.spacing = 4
    if let show = live.show {
      let line = [show.name, show.host].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
      text.addArrangedSubview(Self.label(line, font: .cassette(.rowTitle), color: .cassette(.textPrimary), lines: 2))
      if let until = Self.clock(show.until) {
        text.addArrangedSubview(Self.label("Until \(until)", font: .cassette(.metadata), color: .cassette(.textTertiary)))
      }
    }
    if let track = live.track {
      let title = Self.label(track.title, font: .cassette(live.show == nil ? .rowTitle : .body), color: .cassette(.textPrimary), lines: 2)
      text.addArrangedSubview(title)
      text.addArrangedSubview(Self.label(
        [track.artist, track.album].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · "),
        font: .cassette(.cardSubtitle),
        color: .cassette(.textSecondary),
        lines: 2
      ))
    }
    if let next = live.next?.first {
      let at = Self.clock(next.starts).map { " at \($0)" } ?? ""
      let name = [next.name, next.host].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: " · ")
      text.addArrangedSubview(Self.label("Next\(at): \(name)", font: .cassette(.metadata), color: .cassette(.textTertiary), lines: 2))
    } else if let song = live.nextTracks?.first {
      text.addArrangedSubview(Self.label("Next: \(song.title) · \(song.artist)", font: .cassette(.metadata), color: .cassette(.textTertiary), lines: 2))
    }

    let dot = UIView()
    dot.backgroundColor = CassetteTheme.UIColors.orange
    dot.layer.cornerRadius = 4
    dot.translatesAutoresizingMaskIntoConstraints = false
    let picture = UIImageView()
    picture.contentMode = .scaleAspectFill
    picture.clipsToBounds = true
    picture.layer.cornerRadius = CassetteRadius.small
    picture.backgroundColor = .cassette(.surfaceElevated)
    picture.translatesAutoresizingMaskIntoConstraints = false
    picture.isHidden = true
    if let src = live.track?.coverUrl ?? live.show?.image {
      Task { @MainActor [weak picture] in
        guard let image = await RadioArtLoader.shared.image(for: src) else { return }
        picture?.image = image
        picture?.isHidden = false
      }
    }

    let row = UIView()
    text.translatesAutoresizingMaskIntoConstraints = false
    for v in [dot, picture, text] { row.addSubview(v) }
    NSLayoutConstraint.activate([
      dot.widthAnchor.constraint(equalToConstant: 8),
      dot.heightAnchor.constraint(equalToConstant: 8),
      dot.leadingAnchor.constraint(equalTo: row.leadingAnchor),
      dot.topAnchor.constraint(equalTo: row.topAnchor, constant: 8),
      text.leadingAnchor.constraint(equalTo: dot.trailingAnchor, constant: 10),
      text.topAnchor.constraint(equalTo: row.topAnchor),
      text.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor),
      text.trailingAnchor.constraint(equalTo: picture.leadingAnchor, constant: -12),
      picture.trailingAnchor.constraint(equalTo: row.trailingAnchor),
      picture.topAnchor.constraint(equalTo: row.topAnchor),
      picture.widthAnchor.constraint(equalToConstant: 72),
      picture.heightAnchor.constraint(equalToConstant: 72),
      picture.bottomAnchor.constraint(lessThanOrEqualTo: row.bottomAnchor),
    ])
    onAirBlock.addArrangedSubview(inset(row))
  }

  private func showRecent(_ plays: [RadioStationPagePayload.Track]) {
    recentBlock.arrangedSubviews.forEach { $0.removeFromSuperview() }
    headings.removeAll { $0.shout == "Recently played" }
    guard !plays.isEmpty else {
      recentBlock.isHidden = true
      return
    }
    recentBlock.isHidden = false
    recentBlock.addArrangedSubview(heading("Recently played"))
    let list = UIStackView()
    list.axis = .vertical
    list.spacing = 12
    let now = Date()
    for play in plays.prefix(10) {
      let cover = UIImageView()
      cover.contentMode = .scaleAspectFill
      cover.clipsToBounds = true
      cover.layer.cornerRadius = 3
      cover.backgroundColor = .cassette(.surfaceElevated)
      cover.translatesAutoresizingMaskIntoConstraints = false
      cover.widthAnchor.constraint(equalToConstant: 44).isActive = true
      cover.heightAnchor.constraint(equalToConstant: 44).isActive = true
      if let src = play.coverUrl, !src.isEmpty {
        Task { @MainActor [weak cover] in
          cover?.image = await RadioArtLoader.shared.image(for: src)
        }
      }
      let lines = UIStackView(arrangedSubviews: [
        Self.label(play.title, font: .cassette(.miniTitle), color: .cassette(.textPrimary)),
        Self.label(play.artist, font: .cassette(.cardSubtitle), color: .cassette(.textSecondary)),
      ])
      lines.axis = .vertical
      lines.spacing = 2
      let when = Self.label(Self.ago(play.playedAt, now: now) ?? "", font: .cassette(.caption), color: .cassette(.textTertiary))
      when.setContentHuggingPriority(.required, for: .horizontal)
      when.setContentCompressionResistancePriority(.required, for: .horizontal)
      let row = UIStackView(arrangedSubviews: [cover, lines, when])
      row.axis = .horizontal
      row.alignment = .center
      row.spacing = 12
      row.isAccessibilityElement = true
      row.accessibilityLabel = "\(play.title), \(play.artist)"
      list.addArrangedSubview(row)
    }
    recentBlock.addArrangedSubview(inset(list))
  }

  // MARK: Time

  private static func date(_ s: String?) -> Date? {
    guard let s else { return nil }
    let withFraction = ISO8601DateFormatter()
    withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return withFraction.date(from: s) ?? ISO8601DateFormatter().date(from: s)
  }

  private static func clock(_ s: String?) -> String? {
    guard let d = date(s), d > Date() else { return nil }
    return d.formatted(date: .omitted, time: .shortened)
  }

  private static func ago(_ s: String?, now: Date) -> String? {
    guard let d = date(s) else { return nil }
    let minutes = Int(now.timeIntervalSince(d) / 60)
    if minutes < 1 { return "now" }
    if minutes < 60 { return "\(minutes) min ago" }
    return d.formatted(date: .omitted, time: .shortened)
  }
}

// MARK: - Similar stations row

extension RadioStationVC: UICollectionViewDataSource, UICollectionViewDelegate {
  func collectionView(_ collectionView: UICollectionView, numberOfItemsInSection section: Int) -> Int {
    similar.count
  }

  func collectionView(_ collectionView: UICollectionView, cellForItemAt indexPath: IndexPath) -> UICollectionViewCell {
    let cell = collectionView.dequeueReusableCell(
      withReuseIdentifier: RadioShelfCell.typeName,
      for: indexPath
    ) as! RadioShelfCell
    let s = similar[indexPath.item]
    cell.display(station: s)
    cell.showsPlayButton = hubRadio(for: s) != nil
    cell.onPlayTapped = { [weak self] in self?.play(similar: s) }
    return cell
  }

  func collectionView(_ collectionView: UICollectionView, didSelectItemAt indexPath: IndexPath) {
    let s = similar[indexPath.item]
    navigationController?.pushViewController(RadioStationVC(account: account, station: s), animated: true)
  }
}
