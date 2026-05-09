//
//  LoginVC.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 09.03.19.
//  Copyright (c) 2019 Maximilian Bauer. All rights reserved.
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
import AuthenticationServices
import UIKit

extension String {
  var isHyperTextProtocolProvided: Bool {
    hasPrefix("https://") || hasPrefix("http://")
  }
}

extension UITextField {
  func configuteForLogin(image: UIImage) {
    clipsToBounds = true
    layer.cornerRadius = 5
    layer.borderWidth = CGFloat(0.5)
    layer.borderColor = UIColor.label.cgColor

    borderStyle = .roundedRect
    font = .systemFont(ofSize: LoginVC.fontSize)

    let imageView = UIImageView(frame: CGRect(x: 5, y: 0, width: 25, height: 25))
    imageView.contentMode = .scaleAspectFit
    imageView.image = image.withRenderingMode(.alwaysTemplate)
    imageView.tintColor = .label

    let leftContainerView = UIView(frame: CGRect(x: 0, y: 0, width: 35, height: 25))
    leftContainerView.addSubview(imageView)

    leftView = leftContainerView
    leftViewMode = .always

    backgroundColor = .clear
  }
}

// MARK: - LoginVC

// MARK: - LoginVC

class LoginVC: UIViewController {
  var selectedApiType: BackenApiType = .notDetected

  // cassette Patch 013/014: Cassette account pairing
  // The "Sign in with Cassette" primary section is shown by default.
  // The existing manual login form is hidden behind "Use manual setup".
  private static let cassetteApiBase = "https://cassette.digital"
  private var webAuthSession: ASWebAuthenticationSession?

  // "Sign in with Cassette" primary button (Patch 013)
  fileprivate lazy var cassetteSignInButton: UIButton = {
    var config = UIButton.Configuration.prominentGlass()
    config.imagePadding = 14
    let button = UIButton(configuration: config)
    button.setTitle("Sign in with Cassette", for: .normal)
    button.tintColor = appDelegate.storage.settings.accounts.getSetting(nil).read.themePreference
      .asColor
    button.addTarget(self, action: #selector(Self.cassetteSignInPressed), for: .touchUpInside)
    button.preferredBehavioralStyle = .pad
    return button
  }()

  // Onboarding copy label shown above the Cassette sign-in button
  fileprivate lazy var cassetteOnboardingLabel: UILabel = {
    let label = UILabel()
    label.text =
      "Sit down at your computer with your phone nearby. We'll connect them automatically. " +
      "Your phone needs to be on the same Wi-Fi as your computer for this to work."
    label.font = UIFont.cassetteDisplay(size: 15, weight: .regular)
    label.textColor = .secondaryLabel
    label.numberOfLines = 0
    label.textAlignment = .center
    return label
  }()

  // Activity indicator while fetching credentials from Cassette
  fileprivate lazy var cassetteActivityIndicator: UIActivityIndicatorView = {
    let indicator = UIActivityIndicatorView(style: .medium)
    indicator.hidesWhenStopped = true
    return indicator
  }()

  // "Use manual setup" link — reveals existing form (Patch 013)
  fileprivate lazy var manualSetupButton: UIButton = {
    var config = UIButton.Configuration.plain()
    config.baseForegroundColor = .tertiaryLabel
    config.contentInsets = .zero
    let button = UIButton(configuration: config)
    button.setTitle("Having trouble? Use manual setup →", for: .normal)
    button.titleLabel?.font = UIFont.cassetteDisplay(size: 13, weight: .regular)
    button.addTarget(self, action: #selector(Self.manualSetupPressed), for: .touchUpInside)
    return button
  }()

  // Container that wraps the Cassette sign-in section (hidden when manual mode active)
  fileprivate lazy var cassetteSignInContainer: UIView = UIView()

  @IBAction
  func cassetteSignInPressed() {
    guard let callbackScheme = URL(string: "cassette://")?.scheme else { return }
    let redirectURI = "cassette://auth/callback"
    let authURLString =
      "\(Self.cassetteApiBase)/auth/player" +
      "?redirect_uri=\(redirectURI.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? "")" +
      "&client=cassette-ios"
    guard let authURL = URL(string: authURLString) else { return }

    cassetteSignInButton.isEnabled = false
    cassetteActivityIndicator.startAnimating()

    let session = ASWebAuthenticationSession(
      url: authURL,
      callbackURLScheme: callbackScheme
    ) { [weak self] callbackURL, error in
      guard let self else { return }
      DispatchQueue.main.async {
        self.cassetteSignInButton.isEnabled = true
        self.cassetteActivityIndicator.stopAnimating()
      }
      if let error {
        if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin { return }
        DispatchQueue.main.async {
          self.showErrorMsg(message: "Sign-in was cancelled or failed. Try again.")
        }
        return
      }
      guard
        let url = callbackURL,
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
        let tokenItem = components.queryItems?.first(where: { $0.name == "token" }),
        let token = tokenItem.value, !token.isEmpty
      else {
        DispatchQueue.main.async {
          self.showErrorMsg(message: "Couldn't get credentials from Cassette. Try again.")
        }
        return
      }
      self.fetchAndLoginWithCassetteToken(token)
    }

    session.presentationContextProvider = self
    session.prefersEphemeralWebBrowserSession = false
    webAuthSession = session
    session.start()
  }

  /// Patch 014 — fetch /api/player/me and auto-configure Amperfy account.
  private func fetchAndLoginWithCassetteToken(_ token: String) {
    guard let url = URL(string: "\(Self.cassetteApiBase)/api/player/me") else { return }
    var request = URLRequest(url: url)
    request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
    request.timeoutInterval = 15

    URLSession.shared.dataTask(with: request) { [weak self] data, response, error in
      guard let self else { return }

      if let error {
        DispatchQueue.main.async {
          self.showErrorMsg(message: "Couldn't reach Cassette. Check your connection and try again.")
        }
        return
      }
      guard
        let httpResponse = response as? HTTPURLResponse,
        let data,
        httpResponse.statusCode == 200
      else {
        let code = (response as? HTTPURLResponse)?.statusCode ?? 0
        let msg: String
        if code == 404 {
          msg =
            "No Cassette Player found on your account. " +
            "Open Cassette Player on your computer and complete setup first."
        } else {
          msg = "Couldn't fetch your Cassette Player info. Try again."
        }
        DispatchQueue.main.async { self.showErrorMsg(message: msg) }
        return
      }

      guard
        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
        let lanHostname = json["lanHostname"] as? String,
        let lanPort = json["lanPort"] as? Int,
        let subsonicUsername = json["subsonicUsername"] as? String,
        let subsonicPassword = json["subsonicPassword"] as? String
      else {
        DispatchQueue.main.async {
          self.showErrorMsg(message: "Unexpected response from Cassette. Try again.")
        }
        return
      }

      // 3-param init computes passwordHash via SHA-256 internally
      let serverUrl = "http://\(lanHostname):\(lanPort)"
      let credentials = LoginCredentials(
        serverUrl: serverUrl,
        username: subsonicUsername,
        password: subsonicPassword,
        backendApi: .subsonic
      )

      DispatchQueue.main.async {
        self.loginWithCredentials(credentials)
      }
    }.resume()
  }

  /// Patch 014 — programmatically authenticate and navigate into the app.
  /// Mirrors the core of login() but starts from pre-built credentials
  /// returned by /api/player/me instead of the manual form fields.
  private func loginWithCredentials(_ credentials: LoginCredentials) {
    var mutableCredentials = credentials
    var accountInfo = Account.createInfo(credentials: credentials)

    Task { @MainActor in
      do {
        let meta = self.appDelegate.getMeta(accountInfo)
        let authenticatedApiType = try await meta.backendApi.login(
          apiType: .subsonic,
          credentials: mutableCredentials
        )
        mutableCredentials.backendApi = authenticatedApiType
        accountInfo = Account.createInfo(credentials: mutableCredentials)
        meta.backendApi.selectedApi = authenticatedApiType
        meta.account.assignInfo(info: accountInfo)
        self.appDelegate.storage.main.saveContext()
        self.appDelegate.storage.settings.accounts.login(mutableCredentials)
        meta.backendApi.provideCredentials(credentials: mutableCredentials)

        self.appDelegate.notificationHandler.post(name: .accountAdded, object: nil, userInfo: nil)
        self.appDelegate.notificationHandler.post(
          name: .accountActiveChanged,
          object: nil,
          userInfo: nil
        )
        AmperfyAppShortcuts.updateAppShortcutParameters()

        let syncVC = AppStoryboard.Main.segueToSync(account: meta.account)
        if let rootVC = self.presentingViewController {
          syncVC.modalPresentationStyle = self.modalPresentationStyle
          rootVC.dismiss(animated: false) {
            rootVC.present(syncVC, animated: false)
          }
        } else {
          guard let mainScene = AppDelegate.mainSceneDelegate else { return }
          mainScene.replaceMainRootViewController(vc: syncVC)
        }
      } catch {
        let msg = "Couldn't connect to your Cassette Player. Make sure your phone and computer " +
          "are on the same Wi-Fi, then try again."
        self.showErrorMsg(message: msg)
      }
    }
  }

  @IBAction
  func manualSetupPressed() {
    cassetteSignInContainer.isHidden = true
    formGlassContainer.isHidden = false
    loginGlassContainer.isHidden = false
    navidromeHelpButton.isHidden = false
    serverDescriptionLabel.text =
      "Cassette plays music from your own Navidrome server. Enter its address to get started."
  }

  #if targetEnvironment(macCatalyst)
    static let fontSize: CGFloat = 14
  #else
    static let fontSize: CGFloat = 16
  #endif

  fileprivate lazy var iconView: UIImageView = {
    let imageView = UIImageView()
    imageView.contentMode = .scaleAspectFit
    imageView.image = .appIconTemplate
    imageView.tintColor = appDelegate.storage.settings.accounts.getSetting(nil).read.themePreference
      .asColor
    return imageView
  }()

  fileprivate lazy var amperfyLabel: UILabel = {
    let label = UILabel()
    label.text = "Cassette"
    label.font = UIFont.cassetteDisplay(size: 50, weight: .bold)
    label.textColor = .tintColor
    label.tintColor = appDelegate.storage.settings.accounts.getSetting(nil).read.themePreference
      .asColor
    return label
  }()

  fileprivate lazy var apiLabel: UILabel = {
    let label = UILabel()
    label.text = "API:"
    label.font = .systemFont(ofSize: Self.fontSize)
    label.textColor = .hardLabelColor
    return label
  }()

  fileprivate lazy var serverUrlTF: UITextField = {
    let textField = UITextField()
    textField.configuteForLogin(image: .serverUrl)
    textField.placeholder = "https://your-navidrome.local:4533"
    textField.textContentType = .URL
    textField.keyboardType = .URL
    textField.autocorrectionType = .no
    textField.autocapitalizationType = .none
    textField.addTarget(
      self,
      action: #selector(Self.serverUrlActionPressed),
      for: .primaryActionTriggered
    )
    return textField
  }()

  @IBAction
  func serverUrlActionPressed() {
    serverUrlTF.resignFirstResponder()
    login()
  }

  fileprivate lazy var usernameTF: UITextField = {
    let textField = UITextField()
    textField.configuteForLogin(image: .userPerson)
    textField.placeholder = "Username"
    textField.textContentType = .username
    textField.keyboardType = .default
    textField.autocorrectionType = .no
    textField.autocapitalizationType = .none
    textField.addTarget(
      self,
      action: #selector(Self.usernameActionPressed),
      for: .primaryActionTriggered
    )
    return textField
  }()

  @IBAction
  func usernameActionPressed() {
    usernameTF.resignFirstResponder()
    login()
  }

  fileprivate lazy var passwordTF: UITextField = {
    let textField = UITextField()
    textField.configuteForLogin(image: .password)
    textField.placeholder = "Password"
    textField.textContentType = .password
    textField.keyboardType = .default
    textField.isSecureTextEntry = true
    textField.autocorrectionType = .no
    textField.autocapitalizationType = .none
    textField.addTarget(
      self,
      action: #selector(Self.passwordActionPressed),
      for: .primaryActionTriggered
    )
    return textField
  }()

  @IBAction
  func passwordActionPressed() {
    passwordTF.resignFirstResponder()
    login()
  }

  fileprivate lazy var apiSelectorButton: UIButton = {
    var config = UIButton.Configuration.glass()
    let button = UIButton(configuration: config)
    button.setTitle("API", for: .normal)
    button.preferredBehavioralStyle = .pad
    button.tintColor = appDelegate.storage.settings.accounts.getSetting(nil).read.themePreference
      .asColor
    return button
  }()

  fileprivate lazy var loginButton: UIButton = {
    var config = UIButton.Configuration.prominentGlass()
    config.image = .login
    config.imagePadding = 20.0
    let button = UIButton(configuration: config)
    button.setTitle("Login", for: .normal)
    button.accessibilityLabel = "Login"
    button.addTarget(self, action: #selector(Self.loginPressed), for: .touchUpInside)
    button.preferredBehavioralStyle = .pad
    button.tintColor = appDelegate.storage.settings.accounts.getSetting(nil).read.themePreference
      .asColor
    return button
  }()

  // Close button shown when presented as a sheet/modal
  fileprivate lazy var closeButton: UIButton = {
    var config = UIButton.Configuration.prominentGlass()
    config.image = .xmark
    config.imagePadding = 20.0
    let button = UIButton(configuration: config)
    button.accessibilityLabel = "Close"
    button.addTarget(self, action: #selector(Self.closePressed), for: .touchUpInside)
    button.preferredBehavioralStyle = .pad
    button.isHidden = true
    return button
  }()

  // Explanatory subtitle between the app title and the login form.
  fileprivate lazy var serverDescriptionLabel: UILabel = {
    let label = UILabel()
    label.text =
      "Cassette plays music from your own Navidrome server. Enter its address to get started."
    label.font = UIFont.cassetteDisplay(size: 16, weight: .regular)
    label.textColor = .secondaryLabel
    label.numberOfLines = 0
    label.textAlignment = .center
    return label
  }()

  // Help link shown below the Login button.
  fileprivate lazy var navidromeHelpButton: UIButton = {
    var config = UIButton.Configuration.plain()
    config.baseForegroundColor = .secondaryLabel
    config.contentInsets = .zero
    let button = UIButton(configuration: config)
    button.setTitle("New to Navidrome? Set it up first →", for: .normal)
    button.titleLabel?.font = UIFont.cassetteDisplay(size: 14, weight: .regular)
    button.addTarget(self, action: #selector(Self.navidromeHelpPressed), for: .touchUpInside)
    return button
  }()

  @IBAction
  func navidromeHelpPressed() {
    guard let url = URL(string: "https://www.navidrome.org/docs/installation/") else { return }
    UIApplication.shared.open(url)
  }

  @IBAction
  func closePressed() {
    // Dismiss when presented modally (e.g., as a sheet)
    if presentingViewController != nil || navigationController?.presentingViewController != nil {
      dismiss(animated: true)
    }
  }

  @IBAction
  func loginPressed() {
    serverUrlTF.resignFirstResponder()
    usernameTF.resignFirstResponder()
    passwordTF.resignFirstResponder()
    login()
  }

  public lazy var formView: UIView = {
    self.serverUrlTF.translatesAutoresizingMaskIntoConstraints = false
    self.usernameTF.translatesAutoresizingMaskIntoConstraints = false
    self.passwordTF.translatesAutoresizingMaskIntoConstraints = false
    apiLabel.translatesAutoresizingMaskIntoConstraints = false
    self.apiSelectorButton.translatesAutoresizingMaskIntoConstraints = false

    let view = UIView()
    view.addSubview(serverUrlTF)
    view.addSubview(usernameTF)
    view.addSubview(passwordTF)
    view.addSubview(apiLabel)
    view.addSubview(apiSelectorButton)

    let padding: CGFloat = 0
    let elementHeight: CGFloat = 40
    let spaceInBetween: CGFloat = 15

    NSLayoutConstraint.activate([
      serverUrlTF.safeAreaLayoutGuide.topAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.topAnchor,
        constant: padding
      ),
      serverUrlTF.safeAreaLayoutGuide.leadingAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.leadingAnchor,
        constant: padding
      ),
      serverUrlTF.safeAreaLayoutGuide.trailingAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.trailingAnchor,
        constant: -padding
      ),
      serverUrlTF.heightAnchor.constraint(equalToConstant: elementHeight),

      usernameTF.safeAreaLayoutGuide.topAnchor.constraint(
        equalTo: serverUrlTF.bottomAnchor,
        constant: spaceInBetween
      ),
      usernameTF.safeAreaLayoutGuide.leadingAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.leadingAnchor,
        constant: padding
      ),
      usernameTF.safeAreaLayoutGuide.trailingAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.trailingAnchor,
        constant: -padding
      ),
      usernameTF.heightAnchor.constraint(equalToConstant: elementHeight),

      passwordTF.safeAreaLayoutGuide.topAnchor.constraint(
        equalTo: usernameTF.bottomAnchor,
        constant: spaceInBetween
      ),
      passwordTF.safeAreaLayoutGuide.leadingAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.leadingAnchor,
        constant: padding
      ),
      passwordTF.safeAreaLayoutGuide.trailingAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.trailingAnchor,
        constant: -padding
      ),
      passwordTF.heightAnchor.constraint(equalToConstant: elementHeight),

      apiLabel.safeAreaLayoutGuide.topAnchor.constraint(
        equalTo: passwordTF.bottomAnchor,
        constant: spaceInBetween
      ),
      apiLabel.safeAreaLayoutGuide.leadingAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.leadingAnchor,
        constant: padding
      ),
      apiLabel.heightAnchor.constraint(equalToConstant: elementHeight),

      apiSelectorButton.safeAreaLayoutGuide.topAnchor.constraint(
        equalTo: passwordTF.bottomAnchor,
        constant: spaceInBetween
      ),
      apiSelectorButton.safeAreaLayoutGuide.trailingAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.trailingAnchor,
        constant: -padding
      ),
      apiSelectorButton.heightAnchor.constraint(equalToConstant: elementHeight),

      view.heightAnchor
        .constraint(equalToConstant: (4 * elementHeight) + (3 * spaceInBetween) + (2 * padding)),
    ])

    return view
  }()

  var mainContainerPaddingLeadingConstraint: NSLayoutConstraint?
  var mainContainerPaddingTrailingConstraint: NSLayoutConstraint?
  var mainContainerPaddingTopConstraint: NSLayoutConstraint?
  var mainContainerPaddingBottomConstraint: NSLayoutConstraint?
  var formLeadingConstraing: NSLayoutConstraint?
  var formTrailingConstraing: NSLayoutConstraint?
  var formWitdhConstraing: NSLayoutConstraint?

  public lazy var mainContainerView: UIView = {
    self.formView.translatesAutoresizingMaskIntoConstraints = false

    let view = UIView()
    view.addSubview(formView)

    let outerInset: CGFloat = 25

    mainContainerPaddingLeadingConstraint = formView.safeAreaLayoutGuide.leadingAnchor.constraint(
      equalTo: view.safeAreaLayoutGuide.leadingAnchor,
      constant: outerInset
    )
    mainContainerPaddingTrailingConstraint = formView.safeAreaLayoutGuide.trailingAnchor.constraint(
      equalTo: view.safeAreaLayoutGuide.trailingAnchor,
      constant: -outerInset
    )
    mainContainerPaddingTopConstraint = formView.safeAreaLayoutGuide.topAnchor.constraint(
      equalTo: view.safeAreaLayoutGuide.topAnchor,
      constant: outerInset
    )
    mainContainerPaddingBottomConstraint = formView.safeAreaLayoutGuide.bottomAnchor.constraint(
      equalTo: view.safeAreaLayoutGuide.bottomAnchor,
      constant: -outerInset
    )

    NSLayoutConstraint.activate([
      mainContainerPaddingLeadingConstraint!,
      mainContainerPaddingTrailingConstraint!,
      mainContainerPaddingTopConstraint!,
      mainContainerPaddingBottomConstraint!,
    ])

    return view
  }()

  public lazy var formGlassContainer: UIVisualEffectView = {
    let container = UIVisualEffectView()
    let glassEffect = UIGlassEffect(style: .regular)
    glassEffect.isInteractive = false
    glassEffect.tintColor = appDelegate.storage.settings.accounts.getSetting(nil).read
      .themePreference.asColor
      .withAlphaComponent(0.1)
    container.effect = glassEffect
    container.cornerConfiguration = .corners(radius: 20)
    mainContainerView.translatesAutoresizingMaskIntoConstraints = false
    container.contentView.addSubview(mainContainerView)

    NSLayoutConstraint.activate([
      container.safeAreaLayoutGuide.topAnchor
        .constraint(equalTo: mainContainerView.safeAreaLayoutGuide.topAnchor),
      container.safeAreaLayoutGuide.leadingAnchor
        .constraint(equalTo: mainContainerView.safeAreaLayoutGuide.leadingAnchor),
      container.safeAreaLayoutGuide.trailingAnchor
        .constraint(equalTo: mainContainerView.safeAreaLayoutGuide.trailingAnchor),
      container.safeAreaLayoutGuide.bottomAnchor
        .constraint(equalTo: mainContainerView.safeAreaLayoutGuide.bottomAnchor),
    ])

    return container
  }()

  public lazy var loginGlassContainer: UIView = {
    loginButton
  }()

  func login() {
    guard let serverUrl = serverUrlTF.text?.trimmingCharacters(in: .whitespacesAndNewlines),
          !serverUrl.isEmpty else {
      showErrorMsg(message: "No server URL given!")
      return
    }
    guard serverUrl.isHyperTextProtocolProvided else {
      showErrorMsg(message: "Please provide either 'https://' or 'http://' in your server URL.")
      return
    }
    guard let username = usernameTF.text, !username.isEmpty else {
      showErrorMsg(message: "No username given!")
      return
    }
    guard let password = passwordTF.text, !password.isEmpty else {
      showErrorMsg(message: "No password given!")
      return
    }

    var credentials = LoginCredentials(serverUrl: serverUrl, username: username, password: password)
    var accountInfo = Account.createInfo(credentials: credentials)

    guard !appDelegate.storage.settings.accounts.allAccounts.contains(where: { $0 == accountInfo })
    else {
      showErrorMsg(message: "Account already added!")
      return
    }

    Task { @MainActor in
      do {
        let meta = self.appDelegate.getMeta(accountInfo)
        let authenticatedApiType = try await meta.backendApi.login(
          apiType: selectedApiType,
          credentials: credentials
        )
        credentials.backendApi = authenticatedApiType
        accountInfo = Account.createInfo(credentials: credentials)
        meta.backendApi.selectedApi = authenticatedApiType
        meta.account.assignInfo(info: accountInfo)
        self.appDelegate.storage.main.saveContext()
        self.appDelegate.storage.settings.accounts.login(credentials)
        meta.backendApi.provideCredentials(credentials: credentials)

        self.appDelegate.notificationHandler.post(name: .accountAdded, object: nil, userInfo: nil)
        self.appDelegate.notificationHandler.post(
          name: .accountActiveChanged,
          object: nil,
          userInfo: nil
        )
        AmperfyAppShortcuts.updateAppShortcutParameters()

        let syncVC = AppStoryboard.Main.segueToSync(account: meta.account)
        if let rootVC = presentingViewController {
          syncVC.modalPresentationStyle = self.modalPresentationStyle
          rootVC.dismiss(animated: false) {
            rootVC.present(syncVC, animated: false)
          }
        } else {
          guard let mainScene = AppDelegate.mainSceneDelegate else { return }
          mainScene
            .replaceMainRootViewController(vc: syncVC)
        }
      } catch {
        if error is AuthenticationError {
          self.showErrorMsg(message: error.localizedDescription)
        } else {
          self.showErrorMsg(message: "Not able to login!")
        }
        self.appDelegate.resetMeta(accountInfo)
      }
    }
  }

  func showErrorMsg(message: String) {
    let alert = UIAlertController(title: "Login failed", message: message, preferredStyle: .alert)
    alert.addAction(UIAlertAction(title: "OK", style: .default))
    present(alert, animated: true, completion: nil)
  }

  override func viewDidLoad() {
    super.viewDidLoad()
    updateApiSelectorText()

    apiSelectorButton.showsMenuAsPrimaryAction = true
    // cassette Patch 012: Ampache hidden from picker (self-host-first = Subsonic-only).
    // BackenApiType.ampache remains in the enum so existing data and upstream merges are unaffected.
    apiSelectorButton.menu = UIMenu(title: "Select API", children: [
      UIAction(title: BackenApiType.notDetected.selectorDescription, handler: { _ in
        self.selectedApiType = .notDetected
        self.updateApiSelectorText()
      }),
      UIAction(title: BackenApiType.subsonic.selectorDescription, handler: { _ in
        self.selectedApiType = .subsonic
        self.updateApiSelectorText()
      }),
      UIAction(title: BackenApiType.subsonic_legacy.selectorDescription, handler: { _ in
        self.selectedApiType = .subsonic_legacy
        self.updateApiSelectorText()
      }),
    ])

    view.backgroundColor = .systemBackground

    amperfyLabel.translatesAutoresizingMaskIntoConstraints = false
    iconView.translatesAutoresizingMaskIntoConstraints = false
    serverDescriptionLabel.translatesAutoresizingMaskIntoConstraints = false
    formGlassContainer.translatesAutoresizingMaskIntoConstraints = false
    loginGlassContainer.translatesAutoresizingMaskIntoConstraints = false
    navidromeHelpButton.translatesAutoresizingMaskIntoConstraints = false
    closeButton.translatesAutoresizingMaskIntoConstraints = false

    // cassette Patch 013: Cassette sign-in section
    cassetteSignInContainer.translatesAutoresizingMaskIntoConstraints = false
    cassetteOnboardingLabel.translatesAutoresizingMaskIntoConstraints = false
    cassetteSignInButton.translatesAutoresizingMaskIntoConstraints = false
    cassetteActivityIndicator.translatesAutoresizingMaskIntoConstraints = false
    manualSetupButton.translatesAutoresizingMaskIntoConstraints = false

    cassetteSignInContainer.addSubview(cassetteOnboardingLabel)
    cassetteSignInContainer.addSubview(cassetteSignInButton)
    cassetteSignInContainer.addSubview(cassetteActivityIndicator)
    cassetteSignInContainer.addSubview(manualSetupButton)
    NSLayoutConstraint.activate([
      cassetteOnboardingLabel.topAnchor.constraint(equalTo: cassetteSignInContainer.topAnchor),
      cassetteOnboardingLabel.leadingAnchor.constraint(equalTo: cassetteSignInContainer.leadingAnchor),
      cassetteOnboardingLabel.trailingAnchor.constraint(equalTo: cassetteSignInContainer.trailingAnchor),

      cassetteSignInButton.topAnchor.constraint(equalTo: cassetteOnboardingLabel.bottomAnchor, constant: 24),
      cassetteSignInButton.centerXAnchor.constraint(equalTo: cassetteSignInContainer.centerXAnchor),
      cassetteSignInButton.widthAnchor.constraint(equalToConstant: 240),
      cassetteSignInButton.heightAnchor.constraint(equalToConstant: 48),

      cassetteActivityIndicator.centerXAnchor.constraint(equalTo: cassetteSignInContainer.centerXAnchor),
      cassetteActivityIndicator.topAnchor.constraint(equalTo: cassetteSignInButton.bottomAnchor, constant: 12),

      manualSetupButton.centerXAnchor.constraint(equalTo: cassetteSignInContainer.centerXAnchor),
      manualSetupButton.topAnchor.constraint(equalTo: cassetteActivityIndicator.bottomAnchor, constant: 12),
      manualSetupButton.bottomAnchor.constraint(equalTo: cassetteSignInContainer.bottomAnchor),
    ])

    view.addSubview(iconView)
    view.addSubview(amperfyLabel)
    view.addSubview(serverDescriptionLabel)
    view.addSubview(cassetteSignInContainer)  // Patch 013: primary sign-in section
    view.addSubview(formGlassContainer)
    view.addSubview(loginGlassContainer)
    view.addSubview(navidromeHelpButton)
    view.addSubview(closeButton)

    // cassette Patch 013: hide manual form behind "Use manual setup" link by default
    formGlassContainer.isHidden = true
    loginGlassContainer.isHidden = true
    navidromeHelpButton.isHidden = true

    formLeadingConstraing = formGlassContainer.leadingAnchor.constraint(
      equalTo: view.leadingAnchor,
      constant: 12
    )
    formLeadingConstraing?.priority = .defaultHigh
    formTrailingConstraing = formGlassContainer.trailingAnchor.constraint(
      equalTo: view.trailingAnchor,
      constant: -12
    )
    formTrailingConstraing?.priority = .defaultHigh
    formWitdhConstraing = formGlassContainer.widthAnchor.constraint(lessThanOrEqualToConstant: 600)
    formWitdhConstraing?.priority = .required

    iconView.addConstraint(NSLayoutConstraint(
      item: iconView,
      attribute: .height,
      relatedBy: .equal,
      toItem: iconView,
      attribute: .width,
      multiplier: 1.0,
      constant: 0
    ))
    NSLayoutConstraint.activate([
      // App title
      amperfyLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      amperfyLabel.bottomAnchor.constraint(
        equalTo: serverDescriptionLabel.topAnchor,
        constant: -8
      ),
      amperfyLabel.heightAnchor.constraint(equalToConstant: 60),

      // Onboarding subtitle — sits between title and form glass
      serverDescriptionLabel.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      serverDescriptionLabel.leadingAnchor.constraint(
        greaterThanOrEqualTo: view.leadingAnchor,
        constant: 24
      ),
      serverDescriptionLabel.trailingAnchor.constraint(
        lessThanOrEqualTo: view.trailingAnchor,
        constant: -24
      ),
      serverDescriptionLabel.widthAnchor.constraint(lessThanOrEqualToConstant: 400),
      serverDescriptionLabel.bottomAnchor.constraint(
        equalTo: formGlassContainer.topAnchor,
        constant: -14
      ),

      // Login form
      formGlassContainer.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      formGlassContainer.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: 20),
      formWitdhConstraing!,
      formLeadingConstraing!,
      formTrailingConstraing!,

      // Login button
      loginGlassContainer.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      loginGlassContainer.topAnchor.constraint(
        equalTo: formGlassContainer.bottomAnchor,
        constant: 30
      ),
      loginGlassContainer.widthAnchor.constraint(equalToConstant: 140),
      loginGlassContainer.heightAnchor.constraint(equalToConstant: 40),

      // Navidrome help link below login button
      navidromeHelpButton.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      navidromeHelpButton.topAnchor.constraint(
        equalTo: loginGlassContainer.bottomAnchor,
        constant: 16
      ),

      // cassette Patch 013: Cassette sign-in section — centered at same Y as form
      cassetteSignInContainer.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      cassetteSignInContainer.centerYAnchor.constraint(equalTo: view.centerYAnchor, constant: 20),
      cassetteSignInContainer.leadingAnchor.constraint(
        greaterThanOrEqualTo: view.leadingAnchor, constant: 32
      ),
      cassetteSignInContainer.trailingAnchor.constraint(
        lessThanOrEqualTo: view.trailingAnchor, constant: -32
      ),
      cassetteSignInContainer.widthAnchor.constraint(lessThanOrEqualToConstant: 400),

      // Background watermark icon
      iconView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
      iconView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
      iconView.heightAnchor.constraint(equalTo: formGlassContainer.heightAnchor, constant: 40),

      // Close button top-right
      closeButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
      closeButton.trailingAnchor.constraint(
        equalTo: view.safeAreaLayoutGuide.trailingAnchor,
        constant: -16
      ),
    ])

    // Show close button only when presented as a sheet/modal
    let isModal = presentingViewController != nil || navigationController?
      .presentingViewController != nil
    closeButton.isHidden = !isModal
  }

  override func updateProperties() {
    super.updateProperties()

    var outerInset: CGFloat = 25
    if traitCollection.horizontalSizeClass == .compact {
      outerInset = 20
    } else {
      outerInset = 40
    }

    mainContainerPaddingLeadingConstraint?.constant = outerInset
    mainContainerPaddingTrailingConstraint?.constant = -outerInset
    mainContainerPaddingTopConstraint?.constant = outerInset
    mainContainerPaddingBottomConstraint?.constant = -outerInset + 6
  }

  override func viewWillLayoutSubviews() {
    let glassEffect = UIGlassEffect(style: .regular)
    glassEffect.isInteractive = false
    glassEffect.tintColor = appDelegate.storage.settings.accounts.getSetting(nil).read
      .themePreference.asColor
      .withAlphaComponent(0.1)
    formGlassContainer.effect = glassEffect

    if formGlassContainer.frame.width < 600 {
      formLeadingConstraing?.priority = .required
      formTrailingConstraing?.priority = .required
      formWitdhConstraing?.priority = .defaultHigh
    } else {
      formLeadingConstraing?.priority = .defaultHigh
      formTrailingConstraing?.priority = .defaultHigh
      formWitdhConstraing?.priority = .required
    }
  }

  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    if let credentials = appDelegate.storage.settings.accounts.getSetting(nil).read
      .loginCredentials {
      serverUrlTF.text = credentials.serverUrl
      usernameTF.text = credentials.username
    }
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    let isModal = presentingViewController != nil || navigationController?
      .presentingViewController != nil
    closeButton.isHidden = !isModal
  }

  func updateApiSelectorText() {
    apiSelectorButton.setTitle("\(selectedApiType.selectorDescription)", for: .normal)
  }
}

// cassette Patch 013: ASWebAuthenticationSession needs a presentation context
extension LoginVC: ASWebAuthenticationPresentationContextProviding {
  func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
    view.window ?? UIWindow()
  }
}
