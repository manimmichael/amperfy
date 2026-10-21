//
//  CassetteWebPageVC.swift
//  Amperfy
//
//  Cassette (founder, 2026-10-21): the site's own pages, inside the app. A record the radio
//  is playing opens here (the founder: "there should be a way to remain on Cassette while
//  browsing"), and later other catalog pages can too, without a second copy of each page
//  in Swift: whatever the site's pages become, this screen shows.
//
//  - Our screen, our back button: the page is Apple's web engine (WKWebView) inside an
//    ordinary pushed screen. The web view says "CassetteApp/1" in its user agent, and the
//    site then hides its own menus, footer and breadcrumb (apps/cassette/src/lib/
//    app-surface.ts) and turns its in-page song previews off, so the phone's player keeps
//    the sound.
//  - Signed in: the first request goes through the site's /api/app-session with the phone's
//    sign-in, which answers with a site session for this web view only (never Safari's) and
//    a redirect to the page. Until that route is deployed, the page opens signed out.
//  - Other sites (a station's home page, a store, checkout) open in Safari; pages on
//    cassette.digital stay here.
//
//  RecordOpener decides what a record tap shows: the person's own copy from their library
//  when they have it, else this page.
//

import AmperfyKit
import UIKit
import WebKit

// MARK: - CassetteWebPageVC

@MainActor
final class CassetteWebPageVC: UIViewController, WKNavigationDelegate, WKUIDelegate {
  static var base: String {
    #if DEBUG
      // A debug build can read a local web server: SIMCTL_CHILD_CASSETTE_RADIO_BASE=…
      if let base = ProcessInfo.processInfo.environment["CASSETTE_RADIO_BASE"], !base.isEmpty {
        return base
      }
    #endif
    // www: the bare domain redirects there, and a redirect would drop the sign-in header.
    return "https://www.cassette.digital"
  }

  private static let siteHosts: Set<String> = ["cassette.digital", "www.cassette.digital"]

  private let path: String
  private let placeholder: UIImage?
  private let webView: WKWebView
  private let cover = UIImageView()
  private let spinner = UIActivityIndicatorView(style: .medium)
  private var titleObservation: NSKeyValueObservation?
  private var triedSignedIn = false

  /// - Parameters:
  ///   - path: a page on the site ("/album/tim").
  ///   - title: what the bar says until the page names itself.
  ///   - placeholder: a picture to hold while the page loads (the record's cover).
  init(path: String, title: String?, placeholder: UIImage?) {
    self.path = path
    self.placeholder = placeholder
    let config = WKWebViewConfiguration()
    config.websiteDataStore = .default()
    config.applicationNameForUserAgent = "CassetteApp/1"
    config.allowsInlineMediaPlayback = true
    config.mediaTypesRequiringUserActionForPlayback = .all
    webView = WKWebView(frame: .zero, configuration: config)
    super.init(nibName: nil, bundle: nil)
    navigationItem.title = title
    navigationItem.largeTitleDisplayMode = .never
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    view.backgroundColor = .backgroundColor

    webView.navigationDelegate = self
    webView.uiDelegate = self
    webView.isOpaque = false
    webView.backgroundColor = .backgroundColor
    webView.scrollView.backgroundColor = .backgroundColor
    webView.allowsBackForwardNavigationGestures = true
    webView.alpha = 0
    #if DEBUG
      webView.isInspectable = true
    #endif
    webView.translatesAutoresizingMaskIntoConstraints = false
    view.addSubview(webView)

    cover.image = placeholder
    cover.contentMode = .scaleAspectFill
    cover.clipsToBounds = true
    cover.layer.cornerRadius = CassetteRadius.small
    cover.layer.cornerCurve = .continuous
    cover.isHidden = placeholder == nil
    spinner.color = .cassette(.textSecondary)
    spinner.startAnimating()
    for v in [cover, spinner] {
      v.translatesAutoresizingMaskIntoConstraints = false
      view.addSubview(v)
    }
    NSLayoutConstraint.activate([
      webView.topAnchor.constraint(equalTo: view.topAnchor),
      webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
      webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
      webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
      cover.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      cover.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 24),
      cover.widthAnchor.constraint(equalToConstant: 240),
      cover.heightAnchor.constraint(equalToConstant: 240),
      spinner.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      spinner.topAnchor.constraint(equalTo: cover.bottomAnchor, constant: 24),
    ])

    // The page names itself ("Tim — The Replacements — Cassette"); the bar shows its first part.
    titleObservation = webView.observe(\.title, options: [.new]) { [weak self] webView, _ in
      let name = webView.title?.components(separatedBy: " — ").first
      MainActor.assumeIsolated {
        if let name, !name.isEmpty { self?.navigationItem.title = name }
      }
    }

    loadSignedIn()
  }

  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    extendSafeAreaToAccountForMiniPlayer()
  }

  private var pageURL: URL? { URL(string: Self.base + path) }

  /// Through the sign-in pass when the phone is signed in, else the page itself.
  private func loadSignedIn() {
    guard let pageURL else { return }
    guard let token = CassetteSyncAPI.bearerToken,
          var pass = URLComponents(string: Self.base + "/api/app-session") else {
      webView.load(URLRequest(url: pageURL))
      return
    }
    pass.queryItems = [URLQueryItem(name: "next", value: path)]
    guard let passURL = pass.url else { return }
    triedSignedIn = true
    var request = URLRequest(url: passURL)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    webView.load(request)
  }

  private static func isSite(_ url: URL?) -> Bool {
    guard let url, let host = url.host()?.lowercased() else { return false }
    #if DEBUG
      if let base = URL(string: Self.base)?.host()?.lowercased(), host == base { return true }
    #endif
    return siteHosts.contains(host)
  }

  // MARK: WKNavigationDelegate

  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationAction: WKNavigationAction
  ) async
    -> WKNavigationActionPolicy {
    let url = navigationAction.request.url
    if url?.scheme == "about" || Self.isSite(url) { return .allow }
    // Another site (a station's home page, a store, checkout): Safari.
    if let url, ["http", "https", "mailto", "tel"].contains(url.scheme ?? "") {
      await UIApplication.shared.open(url)
    }
    return .cancel
  }

  func webView(
    _ webView: WKWebView,
    decidePolicyFor navigationResponse: WKNavigationResponse
  ) async
    -> WKNavigationResponsePolicy {
    // A sign-in pass the server refused or does not have yet (401, 404): open the page
    // signed out rather than showing an error.
    if triedSignedIn, navigationResponse.isForMainFrame,
       let http = navigationResponse.response as? HTTPURLResponse,
       http.url?.path == "/api/app-session", http.statusCode >= 400 {
      triedSignedIn = false
      if let pageURL { webView.load(URLRequest(url: pageURL)) }
      return .cancel
    }
    return .allow
  }

  func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
    reveal()
  }

  func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
    reveal()
  }

  func webView(
    _ webView: WKWebView,
    didFailProvisionalNavigation navigation: WKNavigation!,
    withError error: Error
  ) {
    // A load the policy above stopped (a refused sign-in pass, a link sent to Safari)
    // is not a failure: the page it chose instead is on its way.
    let e = error as NSError
    if e.code == NSURLErrorCancelled { return }
    if e.domain == "WebKitErrorDomain", e.code == 102 { return } // frame load interrupted by policy
    spinner.stopAnimating()
    var config = UIContentUnavailableConfiguration.cassetteEmpty(
      image: CassetteIcon.album.uiImage,
      title: "Couldn't open this page",
      body: "Check your connection and try again."
    )
    var retry = UIButton.Configuration.plain()
    retry.title = "Try Again"
    config.button = retry
    config.buttonProperties.primaryAction = UIAction { [weak self] _ in
      self?.contentUnavailableConfiguration = nil
      self?.spinner.startAnimating()
      self?.loadSignedIn()
    }
    contentUnavailableConfiguration = config
  }

  private func reveal() {
    contentUnavailableConfiguration = nil
    guard webView.alpha < 1 else { return }
    spinner.stopAnimating()
    UIView.animate(withDuration: 0.25) {
      self.webView.alpha = 1
      self.cover.alpha = 0
    }
  }

  // MARK: WKUIDelegate

  /// A link that asks for a new window: on the site it opens here, elsewhere in Safari.
  func webView(
    _ webView: WKWebView,
    createWebViewWith configuration: WKWebViewConfiguration,
    for navigationAction: WKNavigationAction,
    windowFeatures: WKWindowFeatures
  )
    -> WKWebView? {
    if let url = navigationAction.request.url {
      if Self.isSite(url) {
        webView.load(URLRequest(url: url))
      } else {
        UIApplication.shared.open(url)
      }
    }
    return nil
  }
}

// MARK: - RecordOpener

/// cassette 2026-10-21: what a tap on a record the radio is playing shows. The person's own
/// copy when their library has it (the site knows which of the record's songs they own, by
/// the hub's song ids, which are this phone's ids too), else the record's page from the
/// site, inside the app. `show` puts the chosen screen on screen (pushed from a page, or
/// shown in the Library tab after closing the player).
@MainActor
enum RecordOpener {
  static func open(
    albumSlug: String,
    title: String?,
    placeholder: UIImage?,
    account: Account,
    show: @escaping (UIViewController) -> ()
  ) {
    Task { @MainActor in
      if let (album, song) = await ownedAlbum(slug: albumSlug, account: account) {
        show(AppStoryboard.Main.segueToAlbumDetail(account: account, album: album, songToScrollTo: song))
        return
      }
      let slug = albumSlug.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? albumSlug
      show(CassetteWebPageVC(path: "/album/\(slug)", title: title, placeholder: placeholder))
    }
  }

  private static func ownedAlbum(slug: String, account: Account) async -> (Album, Song)? {
    guard CassetteSyncAPI.bearerToken != nil,
          let ids = try? await CassetteSyncAPI.shared.getOwnedSongIds(albumSlug: slug) else { return nil }
    guard let app = UIApplication.shared.delegate as? AppDelegate else { return nil }
    let library = app.storage.main.library
    for id in ids {
      if let song = library.getSong(for: account, id: id), let album = song.album {
        return (album, song)
      }
    }
    return nil
  }
}
