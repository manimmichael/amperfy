//
//  RadiosVC.swift
//  Amperfy
//
//  Created by Maximilian Bauer on 27.12.24.
//  Copyright (c) 2024 Maximilian Bauer. All rights reserved.
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
//  cassette 2026-10-12: rebuilt as Cassette's radio dial. The hub still hands
//  the phone a plain station list (name, stream, home page); this screen
//  dresses it from the SAME registry the web uses (docs/reference/
//  CASSETTE_RADIO.md): the station's own name, its network and city, what it
//  sounds like, a logo, and a section (Live radio, then one mood or era per
//  channel). The registry rides along as a bundled JSON fallback and refreshes
//  from the cloud catalog route when that is reachable. Stations the registry
//  does not know (hand-added ones) still list, by name, under "Other stations".
//

import AmperfyKit
import CoreData
import UIKit

// MARK: - RadioCatalogStation

struct RadioCatalogStation: Decodable, Sendable {
  let slug: String
  let name: String
  let sourceLabel: String
  let kind: String // "channel" | "station"
  let streamUrl: String
  let homepage: String?
  let supportUrl: String?
  let description: String
  let image: String?
  let accent: String
  let moods: [String]
  let eras: [String]
  let genres: [String]
  let cityLabels: [String]
  let section: String
  let hasNowPlaying: Bool
  /// cassette 2026-10-21, the station page. Optional so a cached older catalog still
  /// decodes. The stations most like this one (registry slugs, best first), worked out
  /// from the registry's tags on the web (lib/radio/similar.ts).
  let similar: [String]?
  /// The station publishes its running list, so its page shows recent plays.
  let hasRecentPlays: Bool?
  /// Longer text from outside, with its credit; nil until a station has some.
  let about: RadioCatalogAbout?

  var isLive: Bool { kind == "station" }

  /// "SomaFM · San Francisco" / "KEXP · Seattle · Live"
  var kicker: String {
    [sourceLabel, cityLabels.first, isLive ? "Live" : nil].compactMap { $0 }
      .joined(separator: " · ")
  }

  /// Everything a person might type to find this station.
  var searchText: String {
    ([name, sourceLabel, description, section] + moods + eras + genres + cityLabels)
      .joined(separator: " ")
      .lowercased()
  }
}

// MARK: - RadioCatalogAbout

struct RadioCatalogAbout: Decodable, Sendable {
  let text: String
  let source: String
  let url: String
  let license: String?
}

// MARK: - RadioCatalogLane

struct RadioCatalogLane: Decodable, Sendable {
  let id: String
  let label: String
}

// MARK: - RadioCatalogPayload

struct RadioCatalogPayload: Decodable, Sendable {
  struct Lanes: Decodable, Sendable {
    let moods: [RadioCatalogLane]
    let eras: [RadioCatalogLane]
  }

  let version: Int
  let lanes: Lanes
  /// Section titles in display order (live regions, moods, eras). Older
  /// payloads lack it; the decoder then derives the order from the lanes.
  let sectionOrder: [String]?
  let stations: [RadioCatalogStation]
}

// MARK: - RadioCatalog

@MainActor
final class RadioCatalog {
  static let shared = RadioCatalog()

  /// Same host CassetteSyncAPI talks to; the catalog route is public.
  private static let cloudURL = URL(string: "https://cassette.digital/api/radio/catalog")!
  private static let cacheKey = "cassette.radio.catalog.v1"

  private(set) var byStreamUrl: [String: RadioCatalogStation] = [:]
  private(set) var bySlug: [String: RadioCatalogStation] = [:]
  /// Section titles in display order: Live radio, the moods, the eras.
  private(set) var sectionOrder: [String] = []
  private var refreshedThisLaunch = false

  private init() {
    if let cached = UserDefaults.standard.data(forKey: Self.cacheKey),
       adopt(data: cached) { return }
    _ = adopt(data: Data(Self.bundledJSON.utf8))
  }

  static func normalize(_ url: String?) -> String {
    (url ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      .replacingOccurrences(of: #"/+$"#, with: "", options: .regularExpression)
  }

  func station(forStreamUrl url: String?) -> RadioCatalogStation? {
    byStreamUrl[Self.normalize(url)]
  }

  func station(slug: String) -> RadioCatalogStation? {
    bySlug[slug]
  }

  /// The stations most like `station`. A catalog from a deploy that predates the lists (a
  /// cloud or cached copy) has none, so the copy bundled with this build fills in.
  func similarSlugs(for station: RadioCatalogStation) -> [String] {
    station.similar ?? bundledSimilar[station.slug] ?? []
  }

  private lazy var bundledSimilar: [String: [String]] = {
    guard let payload = try? JSONDecoder().decode(
      RadioCatalogPayload.self,
      from: Data(Self.bundledJSON.utf8)
    ) else { return [:] }
    var out: [String: [String]] = [:]
    for s in payload.stations { if let similar = s.similar { out[s.slug] = similar } }
    return out
  }()

  @discardableResult
  private func adopt(data: Data) -> Bool {
    guard let payload = try? JSONDecoder().decode(RadioCatalogPayload.self, from: data),
          payload.version == 1, !payload.stations.isEmpty else { return false }
    var map: [String: RadioCatalogStation] = [:]
    for s in payload.stations { map[Self.normalize(s.streamUrl)] = s }
    byStreamUrl = map
    bySlug = Dictionary(payload.stations.map { ($0.slug, $0) }, uniquingKeysWith: { a, _ in a })
    sectionOrder = payload.sectionOrder
      ?? (["Live radio"] + payload.lanes.moods.map(\.label) + payload.lanes.eras.map(\.label))
    return true
  }

  /// Once per launch: the cloud copy, when the route exists and answers. A
  /// miss (today: the route is not deployed yet) keeps the bundled registry.
  func refreshFromCloud() async {
    guard !refreshedThisLaunch else { return }
    refreshedThisLaunch = true
    var request = URLRequest(url: Self.cloudURL)
    request.timeoutInterval = 8
    guard let (data, response) = try? await URLSession.shared.data(for: request),
          (response as? HTTPURLResponse)?.statusCode == 200,
          adopt(data: data) else { return }
    UserDefaults.standard.set(data, forKey: Self.cacheKey)
  }

  // BEGIN GENERATED CATALOG (scripts/export-radio-catalog.ts) — do not edit by hand
  static let bundledJSON = #"""
{"version":1,"generatedAt":"registry","lanes":{"moods":[{"id":"chill","label":"Chill","blurb":"Downtempo, mellow vocals, nothing in a hurry."},{"id":"focus","label":"Focus","blurb":"Beatless and steady. Music for holding your attention still."},{"id":"late-night","label":"Late night","blurb":"Lights down. Deep house, dark ambient, spy jazz."},{"id":"sunny","label":"Sunny","blurb":"Reggae, Balearic, folk, and 70s album rock with the windows down."},{"id":"heavy","label":"Heavy","blurb":"Metal, sludge, bass that moves the furniture."},{"id":"dance","label":"Dance","blurb":"House, techno, electro-pop, and party music from everywhere."},{"id":"dreamy","label":"Dreamy","blurb":"Hazy, glowing, half-remembered."},{"id":"vintage","label":"Vintage","blurb":"Soul on 45s, exotica, tiki, bachelor-pad lounge."},{"id":"cosmic","label":"Cosmic","blurb":"Space music, drones, and the view from orbit."}],"eras":[{"id":"1940s","label":"1940s","blurb":"Big bands and the Home Service."},{"id":"1950s","label":"1950s","blurb":"Rock 'n' roll, doo-wop, rockabilly, exotica."},{"id":"1960s","label":"1960s","blurb":"Soul 45s, garage, psychedelia, Euro pop."},{"id":"1970s","label":"1970s","blurb":"Album rock, funk, and the yacht."},{"id":"1980s","label":"1980s","blurb":"Synthpop, new wave, the underground side."},{"id":"1990s","label":"1990s","blurb":"Classic rock's last decade on the dial."}],"cities":[{"id":"san-francisco","label":"San Francisco","blurb":"SomaFM's home."},{"id":"london","label":"London","blurb":"NTS 1."},{"id":"los-angeles","label":"Los Angeles","blurb":"NTS 2 and dublab."},{"id":"seattle","label":"Seattle","blurb":"KEXP."},{"id":"new-york","label":"New York","blurb":"WFMU across the river, WFUV in the Bronx."},{"id":"philadelphia","label":"Philadelphia","blurb":"WXPN."},{"id":"new-orleans","label":"New Orleans","blurb":"WWOZ."},{"id":"chicago","label":"Chicago","blurb":"WFMT."},{"id":"minneapolis","label":"Minneapolis","blurb":"The Current."},{"id":"boston","label":"Boston","blurb":"WMBR, across the river in Cambridge."},{"id":"paris","label":"Paris","blurb":"FIP, Radio Nova, TSF Jazz."},{"id":"brussels","label":"Brussels","blurb":"Kiosk Radio."},{"id":"milan","label":"Milan","blurb":"Radio Raheem."},{"id":"oslo","label":"Oslo","blurb":"NRK P13."},{"id":"stockholm","label":"Stockholm","blurb":"Sveriges Radio P3."},{"id":"copenhagen","label":"Copenhagen","blurb":"DR P6 Beat."}]},"sectionOrder":["Live · United States","Live · London","Live · Europe","Live radio","Chill","Focus","Late night","Sunny","Heavy","Dance","Dreamy","Vintage","Cosmic","1940s","1950s","1960s","1970s","1980s","1990s"],"stations":[{"slug":"kexp","name":"KEXP","source":"kexp","sourceLabel":"KEXP","kind":"station","streamUrl":"https://kexp-mp3-128.streamguys1.com/kexp128.mp3","homepage":"https://www.kexp.org/","supportUrl":"https://www.kexp.org/donate/","description":"Seattle's listener-powered station. Real DJs, real shows, and the record named on every play.","image":"https://cassette.digital/radio-art/kexp.jpg","accent":"#f26522","moods":[],"eras":[],"genres":["indie","rock","hip-hop","electronic","eclectic"],"cities":["seattle"],"cityLabels":["Seattle"],"section":"Live · United States","hasNowPlaying":true,"hasRecentPlays":true,"similar":["kcrw","radio-nova","kcrw-eclectic24","dr-p6-beat","nrk-p13","the-current"],"about":{"text":"KEXP is a non-commercial radio station in Seattle, Washington, United States, specializing in indie music programmed by its disc jockeys. The station is operated by the non-profit entity Friends of KEXP, an affiliate of the University of Washington.","source":"Wikipedia","url":"https://en.wikipedia.org/wiki/KEXP","license":"CC BY-SA 4.0, shortened"}},{"slug":"nts-1","name":"NTS 1","source":"nts","sourceLabel":"NTS","kind":"station","streamUrl":"https://stream-relay-geo.ntslive.net/stream","homepage":"https://www.nts.live/1","supportUrl":"https://www.nts.live/supporters","description":"NTS's first channel, live from London. A different show and a different host every hour or two.","image":"https://cassette.digital/radio-art/nts.png","accent":"#d7263d","moods":[],"eras":[],"genres":["eclectic","electronic","jazz","experimental"],"cities":["london"],"cityLabels":["London"],"section":"Live · London","hasNowPlaying":true,"hasRecentPlays":false,"similar":["kiosk-radio","soho-radio","fip","radio-nova","kcrw","nts-2"],"about":{"text":"NTS Radio is a music radio platform founded in 2011 in Hackney, London by Femi Adeyemi \"for an international community of music lovers\". The platform prioritises showcasing niche artists in its radio programming and live events. NTS Radio's tagline is \"Don't Assume\".","source":"Wikipedia","url":"https://en.wikipedia.org/wiki/NTS_Radio","license":"CC BY-SA 4.0"}},{"slug":"nts-2","name":"NTS 2","source":"nts","sourceLabel":"NTS","kind":"station","streamUrl":"https://stream-relay-geo.ntslive.net/stream2","homepage":"https://www.nts.live/2","supportUrl":"https://www.nts.live/supporters","description":"NTS's second channel, live from Los Angeles. Funk, boogie, ambient, whatever the host brought.","image":"https://cassette.digital/radio-art/nts.png","accent":"#1b998b","moods":[],"eras":[],"genres":["eclectic","funk","electronic","soul"],"cities":["los-angeles"],"cityLabels":["Los Angeles"],"section":"Live · United States","hasNowPlaying":true,"hasRecentPlays":false,"similar":["soho-radio","radio-nova","dublab","fip","kexp","kiosk-radio"],"about":null},{"slug":"wfmu","name":"WFMU","source":"wfmu","sourceLabel":"WFMU","kind":"station","streamUrl":"https://stream0.wfmu.org/freeform-128k","homepage":"https://wfmu.org/","supportUrl":"https://wfmu.org/pledge","description":"Freeform radio from Jersey City since 1958. The DJs play whatever they want, and it is never the same twice.","image":"https://cassette.digital/radio-art/wfmu.jpg","accent":"#e63946","moods":["late-night"],"eras":[],"genres":["eclectic","experimental","garage"],"cities":["new-york"],"cityLabels":["New York"],"section":"Live · United States","hasNowPlaying":false,"hasRecentPlays":false,"similar":["kalx","wprb","kcrw-eclectic24","new-sounds","nts-1","wkcr"],"about":{"text":"WFMU is a non-commercial, listener-supported, independent community radio station licensed to East Orange, New Jersey, with studios in Jersey City. It is owned by Auricle Communications, broadcasting a free-form radio format.","source":"Wikipedia","url":"https://en.wikipedia.org/wiki/WFMU","license":"CC BY-SA 4.0, shortened"}},{"slug":"dublab","name":"dublab","source":"dublab","sourceLabel":"dublab","kind":"station","streamUrl":"https://dublab.out.airtime.pro/dublab_a","homepage":"https://www.dublab.com/","supportUrl":"https://www.dublab.com/donate","description":"Los Angeles' non-profit radio collective. Future roots since 1999.","image":"https://cassette.digital/radio-art/dublab.jpg","accent":"#ffb703","moods":["chill"],"eras":[],"genres":["electronic","eclectic","beats"],"cities":["los-angeles"],"cityLabels":["Los Angeles"],"section":"Live · United States","hasNowPlaying":true,"hasRecentPlays":false,"similar":["fip","kcrw-eclectic24","nts-2","kiosk-radio","kexp","radio-nova"],"about":null},{"slug":"wfuv","name":"WFUV","source":"wfuv","sourceLabel":"WFUV","kind":"station","streamUrl":"https://onair.wfuv.org/onair-hi","homepage":"https://wfuv.org/","supportUrl":null,"description":"Fordham's public radio in the Bronx. Singer-songwriters, adult alternative, and the live sessions New York musicians stop by for.","image":"https://cassette.digital/radio-art/wfuv.jpg","accent":"#8d99ae","moods":[],"eras":[],"genres":["indie","folk","rock","americana"],"cities":["new-york"],"cityLabels":["New York"],"section":"Live · United States","hasNowPlaying":false,"hasRecentPlays":false,"similar":["the-current","wxpn","kexp","dr-p6-beat","nrk-p13","fip-rock"],"about":{"text":"WFUV is a non-commercial radio station licensed to New York, New York. The station is owned by Fordham University, with studios on its Bronx campus. WFUV first went on the air in 1947. It became a professional public radio station in 1990 and is one of three NPR member stations in New York City. Its on-air staff has included Dennis Elsas, Vin Scelsa, Pete Fornatale, and Rita Houston.","source":"Wikipedia","url":"https://en.wikipedia.org/wiki/WFUV","license":"CC BY-SA 4.0, shortened"}},{"slug":"wxpn","name":"WXPN","source":"wxpn","sourceLabel":"WXPN","kind":"station","streamUrl":"https://wxpnhi.xpn.org/xpnhi","homepage":"https://xpn.org/","supportUrl":null,"description":"Philadelphia's public radio for music lovers, home of World Cafe.","image":"https://cassette.digital/radio-art/wxpn.jpg","accent":"#1d3557","moods":[],"eras":[],"genres":["indie","rock","folk","soul"],"cities":["philadelphia"],"cityLabels":["Philadelphia"],"section":"Live · United States","hasNowPlaying":true,"hasRecentPlays":true,"similar":["the-current","wfuv","kexp","dr-p6-beat","nrk-p13","fip-rock"],"about":{"text":"WXPN is a non-commercial radio station licensed to the Trustees of the University of Pennsylvania in Philadelphia, Pennsylvania, that airs an adult album alternative (AAA) format. WXPN produces World Cafe, a music program distributed by NPR to non-commercial stations in the United States. The station's call sign, which is often abbreviated to XPN, stands for \"Experimental Pennsylvania Network\".","source":"Wikipedia","url":"https://en.wikipedia.org/wiki/WXPN","license":"CC BY-SA 4.0, shortened"}},{"slug":"radioparadise-main","name":"Radio Paradise","source":"radioparadise","sourceLabel":"Radio Paradise","kind":"channel","streamUrl":"https://stream.radioparadise.com/aac-320","homepage":"https://radioparadise.com/","supportUrl":"https://radioparadise.com/support","description":"Eclectic, hand-picked rock and beyond, mixed by two people in Paradise, California since 2000. No ads.","image":"https://cassette.digital/radio-art/radioparadise-main.jpg","accent":"#3a6ea5","moods":[],"eras":[],"genres":["eclectic","rock","folk","world"],"cities":[],"cityLabels":[],"section":"Eclectic","hasNowPlaying":true,"hasRecentPlays":false,"similar":["kexp","fip","kcrw","the-current","wfuv","wxpn"],"about":null},{"slug":"radioparadise-mellow","name":"Radio Paradise Mellow Mix","source":"radioparadise","sourceLabel":"Radio Paradise","kind":"channel","streamUrl":"https://stream.radioparadise.com/mellow-320","homepage":"https://radioparadise.com/","supportUrl":"https://radioparadise.com/support","description":"The same hands, the volume down: the quieter end of the Radio Paradise library.","image":"https://cassette.digital/radio-art/radioparadise-mellow.jpg","accent":"#6b8e9f","moods":["chill","late-night"],"eras":[],"genres":["eclectic","folk","ambient"],"cities":[],"cityLabels":[],"section":"Chill","hasNowPlaying":true,"hasRecentPlays":false,"similar":["kcrw-eclectic24","somafm-dronezone","somafm-folkfwd","nts-slow-focus","dublab","fip"],"about":null},{"slug":"radioparadise-rock","name":"Radio Paradise Rock Mix","source":"radioparadise","sourceLabel":"Radio Paradise","kind":"channel","streamUrl":"https://stream.radioparadise.com/rock-320","homepage":"https://radioparadise.com/","supportUrl":"https://radioparadise.com/support","description":"Radio Paradise with the guitars turned up.","image":"https://cassette.digital/radio-art/radioparadise-rock.jpg","accent":"#b23a48","moods":[],"eras":[],"genres":["rock"],"cities":[],"cityLabels":[],"section":"Rock","hasNowPlaying":true,"hasRecentPlays":false,"similar":["fip-rock","somafm-seventies","radioparadise-main","rdmix-classic-rock","dr-p6-beat","kexp"],"about":null},{"slug":"radioparadise-global","name":"Radio Paradise Global Mix","source":"radioparadise","sourceLabel":"Radio Paradise","kind":"channel","streamUrl":"https://stream.radioparadise.com/global-320","homepage":"https://radioparadise.com/","supportUrl":"https://radioparadise.com/support","description":"Radio Paradise's passport: music from everywhere, mixed by hand.","image":"https://cassette.digital/radio-art/radioparadise-global.jpg","accent":"#2a9d8f","moods":["sunny"],"eras":[],"genres":["world","eclectic"],"cities":[],"cityLabels":[],"section":"Sunny","hasNowPlaying":true,"hasRecentPlays":false,"similar":["radio-nova","radioparadise-main","fip","kcrw","somafm-bossa","fip-monde"],"about":null},{"slug":"somafm-groovesalad","name":"Groove Salad","source":"somafm","sourceLabel":"SomaFM","kind":"channel","streamUrl":"https://ice6.somafm.com/groovesalad-256-mp3","homepage":"https://somafm.com/groovesalad/","supportUrl":"https://somafm.com/support/","description":"A nicely chilled plate of ambient and downtempo beats and grooves.","image":"https://api.somafm.com/logos/256/groovesalad256.png","accent":"#7fb069","moods":["chill","focus"],"eras":[],"genres":["ambient","electronic","downtempo"],"cities":["san-francisco"],"cityLabels":["San Francisco"],"section":"Chill","hasNowPlaying":true,"hasRecentPlays":true,"similar":["somafm-spacestation","somafm-synphaera","nts-slow-focus","ambient-sleeping-pill","nts-field-recordings","radioparadise-mellow"],"about":null},{"slug":"somafm-dronezone","name":"Drone Zone","source":"somafm","sourceLabel":"SomaFM","kind":"channel","streamUrl":"https://ice6.somafm.com/dronezone-256-mp3","homepage":"https://somafm.com/dronezone/","supportUrl":"https://somafm.com/support/","description":"Atmospheric textures with minimal beats. Served best chilled.","image":null,"accent":"#4a6fa5","moods":["focus","late-night","cosmic"],"eras":[],"genres":["ambient","drone"],"cities":["san-francisco"],"cityLabels":["San Francisco"],"section":"Focus","hasNowPlaying":true,"hasRecentPlays":true,"similar":["somafm-deepspaceone","nts-slow-focus","somafm-synphaera","ambient-sleeping-pill","nts-field-recordings","new-sounds"],"about":null},{"slug":"somafm-deepspaceone","name":"Deep Space One","source":"somafm","sourceLabel":"SomaFM","kind":"channel","streamUrl":"https://ice6.somafm.com/deepspaceone-128-mp3","homepage":"https://somafm.com/deepspaceone/","supportUrl":"https://somafm.com/support/","description":"Deep ambient electronic, experimental and space music.","image":null,"accent":"#3b4a7a","moods":["cosmic","focus"],"eras":[],"genres":["ambient","space music"],"cities":["san-francisco"],"cityLabels":["San Francisco"],"section":"Cosmic","hasNowPlaying":true,"hasRecentPlays":true,"similar":["somafm-synphaera","somafm-dronezone","ambient-sleeping-pill","nts-field-recordings","nts-slow-focus","new-sounds"],"about":null},{"slug":"somafm-spacestation","name":"Space Station Soma","source":"somafm","sourceLabel":"SomaFM","kind":"channel","streamUrl":"https://ice6.somafm.com/spacestation-320-mp3","homepage":"https://somafm.com/spacestation/","supportUrl":"https://somafm.com/support/","description":"Tune in, turn on, space out. Spaced-out ambient and mid-tempo electronica.","image":"https://api.somafm.com/logos/256/spacestation256.png","accent":"#5a7fb5","moods":["cosmic","chill"],"eras":[],"genres":["ambient","electronic"],"cities":["san-francisco"],"cityLabels":["San Francisco"],"section":"Cosmic","hasNowPlaying":true,"hasRecentPlays":true,"similar":["somafm-groovesalad","somafm-missioncontrol","ambient-sleeping-pill","kcrw-eclectic24","nts-field-recordings","nts-labyrinth"],"about":null},{"slug":"somafm-secretagent","name":"Secret Agent","source":"somafm","sourceLabel":"SomaFM","kind":"channel","streamUrl":"https://ice6.somafm.com/secretagent-128-mp3","homepage":"https://somafm.com/secretagent/","supportUrl":"https://somafm.com/support/","description":"The soundtrack for your stylish, mysterious, dangerous life. For spies and PIs too.","image":"https://api.somafm.com/logos/256/secretagent256.png","accent":"#b5533c","moods":["vintage","late-night"],"eras":["1960s"],"genres":["lounge","jazz","soundtrack"],"cities":["san-francisco"],"cityLabels":["San Francisco"],"section":"Vintage","hasNowPlaying":true,"hasRecentPlays":true,"similar":["somafm-illstreet","somafm-insound","kcsm","fip-jazz","nts-expansions","radio-swiss-jazz"],"about":null},{"slug":"somafm-illstreet","name":"Illinois Street Lounge","source":"somafm","sourceLabel":"SomaFM","kind":"channel","streamUrl":"https://ice6.somafm.com/illstreet-128-mp3","homepage":"https://somafm.com/illstreet/","supportUrl":"https://somafm.com/support/","description":"Classic bachelor pad, playful exotica and vintage music of tomorrow.","image":"https://api.somafm.com/logos/256/illstreet256.jpg","accent":"#c97b3a","moods":["vintage"],"eras":["1950s","1960s"],"genres":["lounge","exotica"],"cities":["san-francisco"],"cityLabels":["San Francisco"],"section":"Vintage","hasNowPlaying":true,"hasRecentPlays":true,"similar":["somafm-tikitime","somafm-secretagent","nts-feelings","soul-radio-classics","fifties-sixties-retro-hits","nts-memory-lane"],"about":null},{"slug":"somafm-lush","name":"Lush","source":"somafm","sourceLabel":"SomaFM","kind":"channel","streamUrl":"https://ice6.somafm.com/lush-128-mp3","homepage":"https://somafm.com/lush/","supportUrl":"https://somafm.com/support/","description":"Sensuous and mellow vocals, many with an electronic influence.","image":"https://api.somafm.com/logos/256/lush256.png","accent":"#a35c8f","moods":["chill","dreamy"],"eras":[],"genres":["electronic","trip-hop","dream pop"],"cities":["san-francisco"],"cityLabels":["San Francisco"],"section":"Chill","hasNowPlaying":true,"hasRecentPlays":true,"similar":["kcrw-eclectic24","somafm-beatblender","somafm-digitalis","nightride-fm","nightwave-plaza","fip"],"about":null},{"slug":"somafm-beatblender","name":"Beat Blender","source":"somafm","sourceLabel":"SomaFM","kind":"channel","streamUrl":"https://ice6.somafm.com/beatblender-128-mp3","homepage":"https://somafm.com/beatblender/","supportUrl":"https://somafm.com/support/","description":"A late night blend of deep-house and downtempo chill.","image":null,"accent":"#4f7f9f","moods":["late-night","dance","chill"],"eras":[],"genres":["house","downtempo","electronic"],"cities":["san-francisco"],"cityLabels":["San Francisco"],"section":"Late night","hasNowPlaying":true,"hasRecentPlays":true,"similar":["netil-radio","somafm-groovesalad","fip-electro","kcrw-eclectic24","somafm-fluid","kiosk-radio"],"about":null},{"slug":"somafm-bootliquor","name":"Boot Liquor","source":"somafm","sourceLabel":"SomaFM","kind":"channel","streamUrl":"https://ice6.somafm.com/bootliquor-320-mp3","homepage":"https://somafm.com/bootliquor/","supportUrl":"https://somafm.com/support/","description":"Americana roots music for cowhands, cowpokes and cowtippers.","image":"https://api.somafm.com/logos/256/bootliquor256.png","accent":"#a0522d","moods":["sunny"],"eras":[],"genres":["americana","country","roots"],"cities":["san-francisco"],"cityLabels":["San Francisco"],"section":"Sunny","hasNowPlaying":true,"hasRecentPlays":true,"similar":["somafm-folkfwd","wfuv","somafm-bossa","wwoz","wkcr"],"about":null},{"slug":"somafm-folkfwd","name":"Folk Forward","source":"somafm","sourceLabel":"SomaFM","kind":"channel","streamUrl":"https://ice6.somafm.com/folkfwd-128-mp3","homepage":"https://somafm.com/folkfwd/","supportUrl":"https://somafm.com/support/","description":"Indie folk, alt-folk and the occasional folk classic.","image":"https://api.somafm.com/logos/256/folkfwd256.png","accent":"#8a9a5b","moods":["sunny","chill"],"eras":[],"genres":["folk","indie folk","singer-songwriter"],"cities":["san-francisco"],"cityLabels":["San Francisco"],"section":"Sunny","hasNowPlaying":true,"hasRecentPlays":true,"similar":["radioparadise-mellow","somafm-thistle","somafm-bossa","nts-memory-lane","nts-poolside","the-current"],"about":null},{"slug":"somafm-indiepop","name":"Indie Pop Rocks!","source":"somafm","sourceLabel":"SomaFM","kind":"channel","streamUrl":"https://ice6.somafm.com/indiepop-128-mp3","homepage":"https://somafm.com/indiepop/","supportUrl":"https://somafm.com/support/","description":"New and classic favorite indie pop tracks.","image":null,"accent":"#d94f70","moods":["sunny"],"eras":[],"genres":["indie pop","indie rock","pop"],"cities":["san-francisco"],"cityLabels":["San Francisco"],"section":"Sunny","hasNowPlaying":true,"hasRecentPlays":true,"similar":["fip-pop","nts-poolside","radio-swiss-pop","somafm-insound","somafm-digitalis","sr-p3"],"about":null},{"slug":"somafm-poptron","name":"PopTron","source":"somafm","sourceLabel":"SomaFM","kind":"channel","streamUrl":"https://ice6.somafm.com/poptron-128-mp3","homepage":"https://somafm.com/poptron/","supportUrl":"https://somafm.com/support/","description":"Electropop and indie dance rock with sparkle and pop.","image":"https://api.somafm.com/logos/256/poptron256.png","accent":"#e0558c","moods":["dance"],"eras":[],"genres":["electropop","indie dance","synthpop"],"cities":["san-francisco"],"cityLabels":["San Francisco"],"section":"Dance","hasNowPlaying":true,"hasRecentPlays":true,"similar":["somafm-u80s","somafm-beatblender","nightride-datawave","fip-electro","nts-4-to-the-floor","kcrw-eclectic24"],"about":null},{"slug":"somafm-u80s","name":"Underground 80s","source":"somafm","sourceLabel":"SomaFM","kind":"channel","streamUrl":"https://ice6.somafm.com/u80s-256-mp3","homepage":"https://somafm.com/u80s/","supportUrl":"https://somafm.com/support/","description":"Early 80s UK synthpop and a bit of new wave.","image":"https://api.somafm.com/logos/256/u80s256.png","accent":"#7b5ea7","moods":["dance"],"eras":["1980s"],"genres":["synthpop","new wave","electronic"],"cities":["san-francisco"],"cityLabels":["San Francisco"],"section":"Dance","hasNowPlaying":true,"hasRecentPlays":true,"similar":["somafm-beatblender","somafm-poptron","fip-electro","nightride-fm","kiosk-radio","netil-radio"],"about":null},{"slug":"somafm-seventies","name":"Left Coast 70s","source":"somafm","sourceLabel":"SomaFM","kind":"channel","streamUrl":"https://ice6.somafm.com/seventies-320-mp3","homepage":"https://somafm.com/seventies/","supportUrl":"https://somafm.com/support/","description":"Mellow album rock from the seventies. Yacht not required.","image":"https://api.somafm.com/logos/256/seventies256.jpg","accent":"#d9a441","moods":["sunny"],"eras":["1970s"],"genres":["rock","soft rock","yacht rock"],"cities":["san-francisco"],"cityLabels":["San Francisco"],"section":"Sunny","hasNowPlaying":true,"hasRecentPlays":true,"similar":["rdmix-classic-rock","somafm-reggae","radio-swiss-pop","somafm-insound","fip-rock","radioparadise-main"],"about":null},{"slug":"somafm-7soul","name":"Seven Inch Soul","source":"somafm","sourceLabel":"SomaFM","kind":"channel","streamUrl":"https://ice6.somafm.com/7soul-128-mp3","homepage":"https://somafm.com/7soul/","supportUrl":"https://somafm.com/support/","description":"Vintage soul tracks from the original 45 RPM vinyl.","image":"https://api.somafm.com/logos/256/7soul256.png","accent":"#c4552d","moods":["vintage"],"eras":["1960s","1970s"],"genres":["soul","r&b","funk"],"cities":["san-francisco"],"cityLabels":["San Francisco"],"section":"Vintage","hasNowPlaying":true,"hasRecentPlays":true,"similar":["funky-radio","soul-radio-classics","nts-feelings","nts-memory-lane","fip-groove","somafm-insound"],"about":null},{"slug":"somafm-insound","name":"The In-Sound","source":"somafm","sourceLabel":"SomaFM","kind":"channel","streamUrl":"https://ice6.somafm.com/insound-256-mp3","homepage":"https://somafm.com/insound/","supportUrl":"https://somafm.com/support/","description":"60s and 70s hipster Euro pop, where psychedelic melodies meet groovy vibes.","image":"https://api.somafm.com/logos/256/insound256.jpg","accent":"#e07a3f","moods":["vintage","sunny"],"eras":["1960s","1970s"],"genres":["psychedelic","pop","lounge"],"cities":["san-francisco"],"cityLabels":["San Francisco"],"section":"Vintage","hasNowPlaying":true,"hasRecentPlays":true,"similar":["somafm-tikitime","nts-memory-lane","somafm-illstreet","0n-60s","funky-radio","nts-feelings"],"about":null},{"slug":"somafm-metal","name":"Metal Detector","source":"somafm","sourceLabel":"SomaFM","kind":"channel","streamUrl":"https://ice6.somafm.com/metal-128-mp3","homepage":"https://somafm.com/metal/","supportUrl":"https://somafm.com/support/","description":"From black to doom, prog to sludge, thrash to post, stoner to crossover, punk to industrial.","image":null,"accent":"#8b1e1e","moods":["heavy"],"eras":[],"genres":["metal","doom","thrash"],"cities":["san-francisco"],"cityLabels":["San Francisco"],"section":"Heavy","hasNowPlaying":true,"hasRecentPlays":true,"similar":["nts-the-pit","fip-metal","wsou","somafm-doomed","nightride-darksynth","somafm-dubstep"],"about":null},{"slug":"somafm-reggae","name":"Heavyweight Reggae","source":"somafm","sourceLabel":"SomaFM","kind":"channel","streamUrl":"https://ice6.somafm.com/reggae-256-mp3","homepage":"https://somafm.com/reggae/","supportUrl":"https://somafm.com/support/","description":"Reggae, ska, rocksteady: classic and deep tracks.","image":"https://api.somafm.com/logos/256/reggae256.png","accent":"#2e8b57","moods":["sunny"],"eras":["1970s"],"genres":["reggae","ska","rocksteady","dub"],"cities":["san-francisco"],"cityLabels":["San Francisco"],"section":"Sunny","hasNowPlaying":true,"hasRecentPlays":true,"similar":["fip-reggae","nts-island-time","somafm-seventies","somafm-insound"],"about":null},{"slug":"somafm-sonicuniverse","name":"Sonic Universe","source":"somafm","sourceLabel":"SomaFM","kind":"channel","streamUrl":"https://ice6.somafm.com/sonicuniverse-256-mp3","homepage":"https://somafm.com/sonicuniverse/","supportUrl":"https://somafm.com/support/","description":"Transcending the world of jazz with eclectic, avant-garde takes on tradition.","image":null,"accent":"#3f6b8e","moods":["late-night"],"eras":[],"genres":["jazz","nu jazz","avant-garde"],"cities":["san-francisco"],"cityLabels":["San Francisco"],"section":"Late night","hasNowPlaying":true,"hasRecentPlays":true,"similar":["somafm-secretagent","kcsm","fip-jazz","nts-expansions","radio-swiss-jazz","jazz-groove-mix1"],"about":null},{"slug":"somafm-fluid","name":"Fluid","source":"somafm","sourceLabel":"SomaFM","kind":"channel","streamUrl":"https://ice6.somafm.com/fluid-128-mp3","homepage":"https://somafm.com/fluid/","supportUrl":"https://somafm.com/support/","description":"Drown in the electronic sound of instrumental hip-hop, future soul and liquid trap.","image":null,"accent":"#3a8f8f","moods":["chill","late-night"],"eras":[],"genres":["hip-hop","instrumental hip-hop","future soul","electronic"],"cities":["san-francisco"],"cityLabels":["San Francisco"],"section":"Chill","hasNowPlaying":true,"hasRecentPlays":true,"similar":["nts-100-percent-hip-hop","somafm-beatblender","kcrw-eclectic24","kexp","radio-nova","fip-hiphop"],"about":null},{"slug":"somafm-thetrip","name":"The Trip","source":"somafm","sourceLabel":"SomaFM","kind":"channel","streamUrl":"https://ice6.somafm.com/thetrip-128-mp3","homepage":"https://somafm.com/thetrip/","supportUrl":"https://somafm.com/support/","description":"Progressive house and trance. Tip top tunes.","image":"https://api.somafm.com/logos/256/thetrip256.jpg","accent":"#4b6ccc","moods":["dance"],"eras":[],"genres":["progressive house","trance","electronic"],"cities":["san-francisco"],"cityLabels":["San Francisco"],"section":"Dance","hasNowPlaying":true,"hasRecentPlays":true,"similar":["somafm-beatblender","somafm-u80s","fip-electro","kiosk-radio","netil-radio","kcrw-eclectic24"],"about":null},{"slug":"somafm-cliqhop","name":"cliqhop idm","source":"somafm","sourceLabel":"SomaFM","kind":"channel","streamUrl":"https://ice6.somafm.com/cliqhop-256-mp3","homepage":"https://somafm.com/cliqhop/","supportUrl":"https://somafm.com/support/","description":"Blips and beeps backed mostly with beats. Intelligent dance music.","image":null,"accent":"#5b8c5a","moods":["focus"],"eras":[],"genres":["idm","electronic","glitch"],"cities":["san-francisco"],"cityLabels":["San Francisco"],"section":"Focus","hasNowPlaying":true,"hasRecentPlays":true,"similar":["somafm-groovesalad","somafm-synphaera","fip-electro","kcrw-eclectic24","nightride-fm","nightwave-plaza"],"about":null},{"slug":"somafm-suburbsofgoa","name":"Suburbs of Goa","source":"somafm","sourceLabel":"SomaFM","kind":"channel","streamUrl":"https://ice6.somafm.com/suburbsofgoa-128-mp3","homepage":"https://somafm.com/suburbsofgoa/","supportUrl":"https://somafm.com/support/","description":"Desi-influenced Asian world beats and beyond.","image":"https://api.somafm.com/logos/256/suburbsofgoa256.png","accent":"#c0392b","moods":["sunny"],"eras":[],"genres":["world","asian underground","electronic"],"cities":["san-francisco"],"cityLabels":["San Francisco"],"section":"Sunny","hasNowPlaying":true,"hasRecentPlays":true,"similar":["radio-nova","somafm-bossa","fip","kcrw","fip-monde","nts-sweat"],"about":null},{"slug":"somafm-bossa","name":"Bossa Beyond","source":"somafm","sourceLabel":"SomaFM","kind":"channel","streamUrl":"https://ice6.somafm.com/bossa-256-mp3","homepage":"https://somafm.com/bossa/","supportUrl":"https://somafm.com/support/","description":"Silky, laid-back Brazilian rhythms: bossa nova, samba and beyond.","image":"https://api.somafm.com/logos/256/bossa256.jpg","accent":"#2a9d8f","moods":["sunny","chill"],"eras":[],"genres":["bossa nova","brazilian","jazz","world"],"cities":["san-francisco"],"cityLabels":["San Francisco"],"section":"Sunny","hasNowPlaying":true,"hasRecentPlays":true,"similar":["fip","radio-nova","wmbr","radio-swiss-jazz","jazz-groove-mix1","jazz-groove-mix2"],"about":null},{"slug":"somafm-covers","name":"Covers","source":"somafm","sourceLabel":"SomaFM","kind":"channel","streamUrl":"https://ice6.somafm.com/covers-128-mp3","homepage":"https://somafm.com/covers/","supportUrl":"https://somafm.com/support/","description":"Just covers. Songs you know by artists you don't.","image":"https://api.somafm.com/logos/256/covers256.png","accent":"#6c757d","moods":[],"eras":[],"genres":["eclectic","covers"],"cities":["san-francisco"],"cityLabels":["San Francisco"],"section":"Eclectic","hasNowPlaying":true,"hasRecentPlays":true,"similar":["fip-nouveautes","kcrw-eclectic24","radioparadise-main","fip","kcrw","kexp"],"about":null},{"slug":"somafm-digitalis","name":"Digitalis","source":"somafm","sourceLabel":"SomaFM","kind":"channel","streamUrl":"https://ice6.somafm.com/digitalis-256-mp3","homepage":"https://somafm.com/digitalis/","supportUrl":"https://somafm.com/support/","description":"Digitally affected analog rock to calm the agitated heart.","image":"https://api.somafm.com/logos/256/digitalis256.png","accent":"#556b2f","moods":["dreamy"],"eras":[],"genres":["rock","indie rock","electronic"],"cities":["san-francisco"],"cityLabels":["San Francisco"],"section":"Dreamy","hasNowPlaying":true,"hasRecentPlays":true,"similar":["somafm-lush","kexp","somafm-vaporwaves","nightride-fm","nightwave-plaza","nts-otaku"],"about":null},{"slug":"somafm-doomed","name":"Doomed","source":"somafm","sourceLabel":"SomaFM","kind":"channel","streamUrl":"https://ice6.somafm.com/doomed-256-mp3","homepage":"https://somafm.com/doomed/","supportUrl":"https://somafm.com/support/","description":"Where every day is Halloween: dark industrial and ambient music for tortured souls.","image":null,"accent":"#3d2b3d","moods":["heavy","late-night"],"eras":[],"genres":["industrial","dark ambient"],"cities":["san-francisco"],"cityLabels":["San Francisco"],"section":"Heavy","hasNowPlaying":true,"hasRecentPlays":true,"similar":["nightride-darksynth","nts-the-tube","somafm-darkzone","somafm-metal","kalx","kfjc"],"about":null},{"slug":"somafm-darkzone","name":"The Dark Zone","source":"somafm","sourceLabel":"SomaFM","kind":"channel","streamUrl":"https://ice6.somafm.com/darkzone-256-mp3","homepage":"https://somafm.com/darkzone/","supportUrl":"https://somafm.com/support/","description":"The darker side of deep ambient. Music for staring into the abyss.","image":null,"accent":"#2f2f3f","moods":["late-night","cosmic"],"eras":[],"genres":["dark ambient","ambient"],"cities":["san-francisco"],"cityLabels":["San Francisco"],"section":"Late night","hasNowPlaying":true,"hasRecentPlays":true,"similar":["somafm-dronezone","somafm-deepspaceone","ambient-sleeping-pill","nts-field-recordings","radioparadise-mellow","new-sounds"],"about":null},{"slug":"somafm-tikitime","name":"Tiki Time","source":"somafm","sourceLabel":"SomaFM","kind":"channel","streamUrl":"https://ice6.somafm.com/tikitime-256-mp3","homepage":"https://somafm.com/tikitime/","supportUrl":"https://somafm.com/support/","description":"Classic tiki music and vintage island rhythms to sip cocktails by.","image":"https://api.somafm.com/logos/256/tikitime256.jpg","accent":"#e76f51","moods":["vintage","sunny"],"eras":["1950s","1960s"],"genres":["exotica","lounge","hawaiian"],"cities":["san-francisco"],"cityLabels":["San Francisco"],"section":"Vintage","hasNowPlaying":true,"hasRecentPlays":true,"similar":["somafm-illstreet","somafm-insound","fifties-sixties-retro-hits","nts-feelings","soul-radio-classics","nts-memory-lane"],"about":null},{"slug":"somafm-thistle","name":"ThistleRadio","source":"somafm","sourceLabel":"SomaFM","kind":"channel","streamUrl":"https://ice6.somafm.com/thistle-128-mp3","homepage":"https://somafm.com/thistle/","supportUrl":"https://somafm.com/support/","description":"Exploring music from Celtic roots and branches, with Fiona Ritchie.","image":"https://api.somafm.com/logos/256/thistle256.jpg","accent":"#2d6a4f","moods":[],"eras":[],"genres":["celtic","folk","world"],"cities":["san-francisco"],"cityLabels":["San Francisco"],"section":"Celtic","hasNowPlaying":true,"hasRecentPlays":true,"similar":["radioparadise-main","somafm-folkfwd","nts-memory-lane","radioparadise-mellow","somafm-bossa","the-current"],"about":null},{"slug":"somafm-vaporwaves","name":"Vaporwaves","source":"somafm","sourceLabel":"SomaFM","kind":"channel","streamUrl":"https://ice6.somafm.com/vaporwaves-128-mp3","homepage":"https://somafm.com/vaporwaves/","supportUrl":"https://somafm.com/support/","description":"All vaporwave. All the time.","image":"https://api.somafm.com/logos/256/vaporwaves256.png","accent":"#c77dff","moods":["dreamy"],"eras":[],"genres":["vaporwave","electronic"],"cities":["san-francisco"],"cityLabels":["San Francisco"],"section":"Dreamy","hasNowPlaying":true,"hasRecentPlays":true,"similar":["nightwave-plaza","somafm-lush","nightride-fm","somafm-digitalis","nts-otaku","fip-electro"],"about":null},{"slug":"somafm-dubstep","name":"Dub Step Beyond","source":"somafm","sourceLabel":"SomaFM","kind":"channel","streamUrl":"https://ice6.somafm.com/dubstep-256-mp3","homepage":"https://somafm.com/dubstep/","supportUrl":"https://somafm.com/support/","description":"Dubstep, dub and deep bass. May damage speakers at high volume.","image":null,"accent":"#1f4e79","moods":["heavy","dance"],"eras":[],"genres":["dubstep","dub","bass","electronic"],"cities":["san-francisco"],"cityLabels":["San Francisco"],"section":"Heavy","hasNowPlaying":true,"hasRecentPlays":true,"similar":["somafm-beatblender","somafm-thetrip","fip-electro","kiosk-radio","netil-radio","fip-reggae"],"about":null},{"slug":"somafm-synphaera","name":"Synphaera Radio","source":"somafm","sourceLabel":"SomaFM","kind":"channel","streamUrl":"https://ice6.somafm.com/synphaera-256-mp3","homepage":"https://somafm.com/synphaera/","supportUrl":"https://somafm.com/support/","description":"An independent label's catalog of modern electronic ambient and space music.","image":"https://api.somafm.com/logos/256/synphaera256.jpg","accent":"#4361ee","moods":["cosmic","focus"],"eras":[],"genres":["ambient","electronic","space music"],"cities":["san-francisco"],"cityLabels":["San Francisco"],"section":"Cosmic","hasNowPlaying":true,"hasRecentPlays":true,"similar":["somafm-deepspaceone","somafm-groovesalad","ambient-sleeping-pill","nts-field-recordings","nts-slow-focus","new-sounds"],"about":null},{"slug":"somafm-missioncontrol","name":"Mission Control","source":"somafm","sourceLabel":"SomaFM","kind":"channel","streamUrl":"https://ice6.somafm.com/missioncontrol-128-mp3","homepage":"https://somafm.com/missioncontrol/","supportUrl":"https://somafm.com/support/","description":"Ambient music mixed with the voices of NASA and space explorers everywhere.","image":"https://api.somafm.com/logos/256/missioncontrol256.png","accent":"#495057","moods":["cosmic"],"eras":[],"genres":["ambient","electronic"],"cities":["san-francisco"],"cityLabels":["San Francisco"],"section":"Cosmic","hasNowPlaying":true,"hasRecentPlays":true,"similar":["somafm-spacestation","somafm-synphaera","ambient-sleeping-pill","nts-field-recordings","nts-labyrinth","radioparadise-mellow"],"about":null},{"slug":"nts-poolside","name":"NTS Poolside","source":"nts","sourceLabel":"NTS","kind":"channel","streamUrl":"https://stream-mixtape-geo.ntslive.net/mixtape4","homepage":"https://www.nts.live/infinite-mixtapes/poolside","supportUrl":"https://www.nts.live/supporters","description":"Balearic, boogie, and sophisti-pop for poolsides, beaches and car stereos.","image":"https://media.ntslive.co.uk/resize/400x400/cf5afb01-5a68-4fa0-a1c6-415b35d09ed6_1542931200.jpeg","accent":"#f4a261","moods":["sunny","chill"],"eras":[],"genres":["balearic","boogie","pop"],"cities":[],"cityLabels":[],"section":"Sunny","hasNowPlaying":false,"hasRecentPlays":false,"similar":["fip-pop","somafm-indiepop","radio-swiss-pop","somafm-insound","sr-p3","kcrw-eclectic24"],"about":null},{"slug":"nts-slow-focus","name":"NTS Slow Focus","source":"nts","sourceLabel":"NTS","kind":"channel","streamUrl":"https://stream-mixtape-geo.ntslive.net/mixtape","homepage":"https://www.nts.live/infinite-mixtapes/slow-focus","supportUrl":"https://www.nts.live/supporters","description":"Meditative, relaxing and beatless: ambient, drone and ragas.","image":"https://media.ntslive.co.uk/resize/400x400/01f7cbe6-235f-4e33-8f2f-70152c91edf1_1542931200.jpeg","accent":"#5e81ac","moods":["focus","chill"],"eras":[],"genres":["ambient","drone","classical"],"cities":[],"cityLabels":[],"section":"Focus","hasNowPlaying":false,"hasRecentPlays":false,"similar":["somafm-dronezone","somafm-groovesalad","ambient-sleeping-pill","nts-field-recordings","nts-sheet-music","sr-p2-musik"],"about":null},{"slug":"nts-100-percent-hip-hop","name":"NTS Low Key","source":"nts","sourceLabel":"NTS","kind":"channel","streamUrl":"https://stream-mixtape-geo.ntslive.net/mixtape2","homepage":"https://www.nts.live/infinite-mixtapes/100-percent-hip-hop","supportUrl":"https://www.nts.live/supporters","description":"Keeping it simple with lo-fi hip-hop and smooth R&B.","image":"https://media.ntslive.co.uk/resize/400x400/b667c612-1ef6-4bfd-ae87-0cec0a19629d_1626307200.jpeg","accent":"#8d6e63","moods":["chill","late-night"],"eras":[],"genres":["hip-hop","r&b","lo-fi"],"cities":[],"cityLabels":[],"section":"Chill","hasNowPlaying":false,"hasRecentPlays":false,"similar":["somafm-fluid","fip-hiphop","nts-rap-house","somafm-beatblender","kcrw-eclectic24","kexp"],"about":null},{"slug":"nts-memory-lane","name":"NTS Memory Lane","source":"nts","sourceLabel":"NTS","kind":"channel","streamUrl":"https://stream-mixtape-geo.ntslive.net/mixtape6","homepage":"https://www.nts.live/infinite-mixtapes/memory-lane","supportUrl":"https://www.nts.live/supporters","description":"Counter-cultural folk, LSD-laced psychedelia, sweet soul and raw garage rock.","image":"https://media.ntslive.co.uk/resize/400x400/f889399d-6277-46e2-9be9-840bbdd25cc5_1560470400.jpeg","accent":"#b5838d","moods":["vintage"],"eras":["1960s","1970s"],"genres":["psychedelic","folk","soul","garage"],"cities":[],"cityLabels":[],"section":"Vintage","hasNowPlaying":false,"hasRecentPlays":false,"similar":["funky-radio","nts-feelings","somafm-7soul","soul-radio-classics","somafm-insound","wxpn"],"about":null},{"slug":"nts-4-to-the-floor","name":"NTS 4 To The Floor","source":"nts","sourceLabel":"NTS","kind":"channel","streamUrl":"https://stream-mixtape-geo.ntslive.net/mixtape5","homepage":"https://www.nts.live/infinite-mixtapes/4-to-the-floor","supportUrl":"https://www.nts.live/supporters","description":"House and techno from past to present. Chicago, Detroit, NYC disco.","image":"https://media.ntslive.co.uk/resize/400x400/c3bad52d-418b-4bf6-aff5-eea3b9ff1186_1542931200.jpeg","accent":"#ff5d8f","moods":["dance"],"eras":[],"genres":["house","techno","disco"],"cities":[],"cityLabels":[],"section":"Dance","hasNowPlaying":false,"hasRecentPlays":false,"similar":["somafm-beatblender","netil-radio","radio-raheem","fip-groove","nts-labyrinth","nightride-datawave"],"about":null},{"slug":"nts-island-time","name":"NTS Island Time","source":"nts","sourceLabel":"NTS","kind":"channel","streamUrl":"https://stream-mixtape-geo.ntslive.net/mixtape21","homepage":"https://www.nts.live/infinite-mixtapes/island-time","supportUrl":"https://www.nts.live/supporters","description":"Roots reggae, sweet lovers rock and vintage dub. Easy skanking.","image":"https://media.ntslive.co.uk/resize/400x400/68541b02-903c-4caf-bba2-538d0b9bfedc_1590451200.jpeg","accent":"#43aa8b","moods":["sunny"],"eras":["1970s"],"genres":["reggae","dub","lovers rock"],"cities":[],"cityLabels":[],"section":"Sunny","hasNowPlaying":false,"hasRecentPlays":false,"similar":["fip-reggae","somafm-reggae","somafm-seventies"],"about":null},{"slug":"nts-the-tube","name":"NTS The Tube","source":"nts","sourceLabel":"NTS","kind":"channel","streamUrl":"https://stream-mixtape-geo.ntslive.net/mixtape26","homepage":"https://www.nts.live/infinite-mixtapes/the-tube","supportUrl":"https://www.nts.live/supporters","description":"Oddball post-punk, industrial provocation, and minimal wave.","image":"https://media.ntslive.co.uk/resize/400x400/f3657c6b-aa6b-4ad9-9c12-d9e9cbe7f68d_1626220800.jpeg","accent":"#6d597a","moods":["late-night"],"eras":["1980s"],"genres":["post-punk","industrial","minimal wave"],"cities":[],"cityLabels":[],"section":"Late night","hasNowPlaying":false,"hasRecentPlays":false,"similar":["nightride-darksynth","somafm-doomed","nightride-fm","kfjc","somafm-beatblender","fip-electro"],"about":null},{"slug":"nts-sheet-music","name":"NTS Sheet Music","source":"nts","sourceLabel":"NTS","kind":"channel","streamUrl":"https://stream-mixtape-geo.ntslive.net/mixtape35","homepage":"https://www.nts.live/infinite-mixtapes/sheet-music","supportUrl":"https://www.nts.live/supporters","description":"The best of classical and contemporary composition, baroque to post-modern.","image":"https://media.ntslive.co.uk/resize/400x400/fe3dc346-2549-44cc-96c7-c3117056aa74_1668038400.jpeg","accent":"#9c6644","moods":["focus"],"eras":[],"genres":["classical","contemporary classical"],"cities":[],"cityLabels":[],"section":"Focus","hasNowPlaying":false,"hasRecentPlays":false,"similar":["nts-slow-focus","sr-p2-musik","radio-swiss-classic","kusc","new-sounds","wfmt"],"about":null},{"slug":"nts-feelings","name":"NTS Feelings","source":"nts","sourceLabel":"NTS","kind":"channel","streamUrl":"https://stream-mixtape-geo.ntslive.net/mixtape27","homepage":"https://www.nts.live/infinite-mixtapes/feelings","supportUrl":"https://www.nts.live/supporters","description":"Sweet soul, gospel, boogie, and beyond. Doo-wop to disco.","image":"https://media.ntslive.co.uk/resize/400x400/53026366-cf7c-4a57-af5c-c894d2375dc6_1626220800.jpeg","accent":"#e07a5f","moods":["vintage"],"eras":["1950s","1960s","1970s"],"genres":["soul","gospel","boogie","doo-wop"],"cities":[],"cityLabels":[],"section":"Vintage","hasNowPlaying":false,"hasRecentPlays":false,"similar":["soul-radio-classics","funky-radio","somafm-7soul","nts-memory-lane","somafm-illstreet","fip-groove"],"about":null},{"slug":"nts-expansions","name":"NTS Expansions","source":"nts","sourceLabel":"NTS","kind":"channel","streamUrl":"https://stream-mixtape-geo.ntslive.net/mixtape3","homepage":"https://www.nts.live/infinite-mixtapes/expansions","supportUrl":"https://www.nts.live/supporters","description":"Jazz and its many mind-expanding variations: Sun Ra to George Duke, spiritual jazz to Ethiopiques.","image":"https://media.ntslive.co.uk/resize/400x400/acc3ad65-05bd-495d-90cb-f5d81221464b_1542931200.jpeg","accent":"#3d5a80","moods":["late-night"],"eras":[],"genres":["jazz","spiritual jazz","fusion"],"cities":[],"cityLabels":[],"section":"Late night","hasNowPlaying":false,"hasRecentPlays":false,"similar":["fip-jazz","radio-swiss-jazz","somafm-secretagent","somafm-sonicuniverse","jazz-groove-mix1","jazz-groove-mix2"],"about":null},{"slug":"nts-rap-house","name":"NTS Rap House","source":"nts","sourceLabel":"NTS","kind":"channel","streamUrl":"https://stream-mixtape-geo.ntslive.net/mixtape22","homepage":"https://www.nts.live/infinite-mixtapes/rap-house","supportUrl":"https://www.nts.live/supporters","description":"Non-stop rap, trap, and drill from both sides of the Atlantic. 808s and champagne.","image":"https://media.ntslive.co.uk/resize/400x400/916a2aa3-dcc5-4eb6-abea-b2f1914fb49a_1590451200.jpeg","accent":"#9d4edd","moods":["dance"],"eras":[],"genres":["hip-hop","rap","trap","drill"],"cities":[],"cityLabels":[],"section":"Dance","hasNowPlaying":false,"hasRecentPlays":false,"similar":["fip-hiphop","somafm-fluid","nts-100-percent-hip-hop","kexp","radio-nova","rinse-fm"],"about":null},{"slug":"nts-labyrinth","name":"NTS Labyrinth","source":"nts","sourceLabel":"NTS","kind":"channel","streamUrl":"https://stream-mixtape-geo.ntslive.net/mixtape31","homepage":"https://www.nts.live/infinite-mixtapes/labyrinth","supportUrl":"https://www.nts.live/supporters","description":"Atmospheric breaks, tripped-out techno, and cerebral electronics. Enter the void.","image":"https://media.ntslive.co.uk/resize/400x400/4ce92a36-4942-4f35-9cc4-1d3e6c2be746_1638230400.jpeg","accent":"#1b263b","moods":["late-night","cosmic"],"eras":[],"genres":["techno","breaks","electronic"],"cities":[],"cityLabels":[],"section":"Late night","hasNowPlaying":false,"hasRecentPlays":false,"similar":["somafm-beatblender","fip-electro","kcrw-eclectic24","nightride-fm","somafm-spacestation","netil-radio"],"about":null},{"slug":"nts-sweat","name":"NTS Sweat","source":"nts","sourceLabel":"NTS","kind":"channel","streamUrl":"https://stream-mixtape-geo.ntslive.net/mixtape24","homepage":"https://www.nts.live/infinite-mixtapes/sweat","supportUrl":"https://www.nts.live/supporters","description":"A new wave of international party music: soundsystems, block parties, carnivals.","image":"https://media.ntslive.co.uk/resize/400x400/f0c77a19-670b-4979-ac6e-e93f6089b5bc_1622592000.png","accent":"#ff7b00","moods":["dance","sunny"],"eras":[],"genres":["world","club","dancehall"],"cities":[],"cityLabels":[],"section":"Dance","hasNowPlaying":false,"hasRecentPlays":false,"similar":["somafm-bossa","fip-monde","radioparadise-global","somafm-suburbsofgoa","radio-nova","fip-groove"],"about":null},{"slug":"nts-otaku","name":"NTS Otaku","source":"nts","sourceLabel":"NTS","kind":"channel","streamUrl":"https://stream-mixtape-geo.ntslive.net/mixtape36","homepage":"https://www.nts.live/infinite-mixtapes/otaku","supportUrl":"https://www.nts.live/supporters","description":"Video game and anime soundtracks, from childlike wonder to tech futurism.","image":"https://media.ntslive.co.uk/resize/400x400/0c693fdb-544c-4b85-9679-3268afa3a273_1668038400.jpeg","accent":"#48cae4","moods":["dreamy"],"eras":[],"genres":["soundtrack","video game music","electronic"],"cities":[],"cityLabels":[],"section":"Dreamy","hasNowPlaying":false,"hasRecentPlays":false,"similar":["rainwave-game","somafm-digitalis","somafm-lush","nightride-fm","nightwave-plaza","fip-electro"],"about":null},{"slug":"nts-the-pit","name":"NTS The Pit","source":"nts","sourceLabel":"NTS","kind":"channel","streamUrl":"https://stream-mixtape-geo.ntslive.net/mixtape34","homepage":"https://www.nts.live/infinite-mixtapes/the-pit","supportUrl":"https://www.nts.live/supporters","description":"Heavy sludge dirges, black metal, frenetic thrash and everything in between.","image":"https://cassette.digital/radio-art/nts-the-pit.jpg","accent":"#540b0e","moods":["heavy"],"eras":[],"genres":["metal","sludge","black metal","thrash"],"cities":[],"cityLabels":[],"section":"Heavy","hasNowPlaying":false,"hasRecentPlays":false,"similar":["somafm-metal","fip-metal","wsou","nightride-darksynth","somafm-doomed","kxlu"],"about":null},{"slug":"nts-field-recordings","name":"NTS Field Recordings","source":"nts","sourceLabel":"NTS","kind":"channel","streamUrl":"https://stream-mixtape-geo.ntslive.net/mixtape23","homepage":"https://www.nts.live/infinite-mixtapes/field-recordings","supportUrl":"https://www.nts.live/supporters","description":"Natural ambience recorded by NTS listeners around the world.","image":"https://cassette.digital/radio-art/nts-field-recordings.jpg","accent":"#588157","moods":["focus","cosmic"],"eras":[],"genres":["ambient","field recordings"],"cities":[],"cityLabels":[],"section":"Focus","hasNowPlaying":false,"hasRecentPlays":false,"similar":["ambient-sleeping-pill","somafm-deepspaceone","somafm-dronezone","nts-slow-focus","new-sounds","radioparadise-mellow"],"about":null},{"slug":"fifties-sixties-retro-hits","name":"50s 60s Retro Hits","source":"independent","sourceLabel":"Independent","kind":"channel","streamUrl":"https://stream.zeno.fm/pxzwykxbluitv","homepage":null,"supportUrl":null,"description":"Rock 'n' roll and classic hits from the fifties and sixties, all day.","image":null,"accent":"#e76f51","moods":["vintage"],"eras":["1950s","1960s"],"genres":["rock 'n' roll","classic hits","oldies"],"cities":[],"cityLabels":[],"section":"Vintage","hasNowPlaying":false,"hasRecentPlays":false,"similar":["0n-50s","0n-60s","somafm-illstreet","nts-feelings","somafm-tikitime","nts-memory-lane"],"about":null},{"slug":"0n-50s","name":"0N 50s on Radio","source":"independent","sourceLabel":"Independent","kind":"channel","streamUrl":"https://0n-50s.radionetz.de/0n-50s.mp3","homepage":null,"supportUrl":null,"description":"The fifties, start to finish: rock 'n' roll, crooners, early rhythm and blues.","image":null,"accent":"#bc6c25","moods":["vintage"],"eras":["1950s"],"genres":["rock 'n' roll","oldies"],"cities":[],"cityLabels":[],"section":"Vintage","hasNowPlaying":false,"hasRecentPlays":false,"similar":["fifties-sixties-retro-hits","1940s-radio","somafm-illstreet","nts-feelings","somafm-tikitime"],"about":null},{"slug":"0n-60s","name":"0N 60s on Radio","source":"independent","sourceLabel":"Independent","kind":"channel","streamUrl":"https://0n-60s.radionetz.de/0n-60s.mp3","homepage":null,"supportUrl":null,"description":"The sixties on a loop: beat groups, Motown, and the summer of love.","image":null,"accent":"#dda15e","moods":["vintage"],"eras":["1960s"],"genres":["pop","soul","oldies"],"cities":[],"cityLabels":[],"section":"Vintage","hasNowPlaying":false,"hasRecentPlays":false,"similar":["fifties-sixties-retro-hits","funky-radio","nts-feelings","nts-memory-lane","somafm-7soul","somafm-insound"],"about":null},{"slug":"1940s-radio","name":"1940s Radio","source":"independent","sourceLabel":"Independent","kind":"channel","streamUrl":"https://cast2.asurahosting.com/proxy/1940sradio/stream","homepage":null,"supportUrl":null,"description":"Big bands, crooners and the wireless as it sounded in the forties and early fifties.","image":null,"accent":"#8a5a44","moods":["vintage"],"eras":["1940s","1950s"],"genres":["big band","swing","oldies"],"cities":[],"cityLabels":[],"section":"Vintage","hasNowPlaying":false,"hasRecentPlays":false,"similar":["0n-50s","fifties-sixties-retro-hits","somafm-illstreet","nts-feelings","somafm-tikitime"],"about":null},{"slug":"soul-radio-classics","name":"SOUL RADIO Classics","source":"independent","sourceLabel":"Independent","kind":"channel","streamUrl":"https://listen.soulradio.uk/uk","homepage":null,"supportUrl":null,"description":"Only classic soul, from the fifties through the seventies.","image":null,"accent":"#9b2226","moods":["vintage"],"eras":["1950s","1960s","1970s"],"genres":["soul","r&b","motown"],"cities":[],"cityLabels":[],"section":"Vintage","hasNowPlaying":false,"hasRecentPlays":false,"similar":["somafm-7soul","nts-feelings","funky-radio","nts-memory-lane","somafm-illstreet","0n-60s"],"about":null},{"slug":"dagnys-jukebox","name":"Dagnys Jukebox","source":"independent","sourceLabel":"Independent","kind":"channel","streamUrl":"https://stream.dagnysjukebox.se/dagny","homepage":null,"supportUrl":null,"description":"Rockabilly, rock 'n' roll and jukebox hits of the fifties.","image":null,"accent":"#d62828","moods":["vintage"],"eras":["1950s"],"genres":["rockabilly","rock 'n' roll"],"cities":[],"cityLabels":[],"section":"Vintage","hasNowPlaying":false,"hasRecentPlays":false,"similar":["0n-50s","fifties-sixties-retro-hits","somafm-illstreet","nts-feelings","somafm-tikitime"],"about":null},{"slug":"funky-radio","name":"FUNKY RADIO","source":"independent","sourceLabel":"Independent","kind":"channel","streamUrl":"https://funkyradio.streamingmedia.it/play.mp3","homepage":null,"supportUrl":null,"description":"Only funk music, sixties and seventies.","image":null,"accent":"#f77f00","moods":["dance","vintage"],"eras":["1960s","1970s"],"genres":["funk","soul"],"cities":[],"cityLabels":[],"section":"Dance","hasNowPlaying":false,"hasRecentPlays":false,"similar":["somafm-7soul","nts-feelings","soul-radio-classics","fip-groove","nts-memory-lane","0n-60s"],"about":null},{"slug":"rdmix-classic-rock","name":"RdMix Classic Rock","source":"independent","sourceLabel":"Independent","kind":"channel","streamUrl":"https://cast1.torontocast.com:4610/stream","homepage":null,"supportUrl":null,"description":"Classic rock from the seventies, eighties and nineties.","image":null,"accent":"#6a040f","moods":[],"eras":["1970s","1980s","1990s"],"genres":["classic rock","rock"],"cities":[],"cityLabels":[],"section":"1970s","hasNowPlaying":false,"hasRecentPlays":false,"similar":["somafm-seventies","fip-rock","radioparadise-main","radioparadise-rock","dr-p6-beat","kexp"],"about":null},{"slug":"wwoz","name":"WWOZ","source":"public","sourceLabel":"WWOZ 90.7","kind":"station","streamUrl":"https://wwoz-sc.streamguys1.com/wwoz-hi.mp3","homepage":"https://www.wwoz.org/","supportUrl":"https://www.wwoz.org/support","description":"New Orleans' listener-supported jazz and heritage station: brass bands, blues, R&B, zydeco, and the city's own DJs.","image":"https://www.wwoz.org/sites/default/files/favicons-bw/apple-touch-icon-120x120.png","accent":"#8e44ad","moods":["sunny"],"eras":[],"genres":["jazz","blues","r&b","brass band","zydeco"],"cities":["new-orleans"],"cityLabels":["New Orleans"],"section":"Live · United States","hasNowPlaying":false,"hasRecentPlays":false,"similar":["radio-nova","soho-radio","somafm-bossa","fip","kcsm","kiosk-radio"],"about":{"text":"WWOZ is a non-profit community-supported radio station in New Orleans. It is owned by the New Orleans Jazz & Heritage Foundation. The station specializes in music from or relating to the cultural heritage of New Orleans and the surrounding region of Louisiana. The playlist includes jazz, blues, local, regional and world music.","source":"Wikipedia","url":"https://en.wikipedia.org/wiki/WWOZ","license":"CC BY-SA 4.0"}},{"slug":"wqxr","name":"WQXR","source":"public","sourceLabel":"WQXR 105.9","kind":"station","streamUrl":"https://stream.wqxr.org/wqxr","homepage":"https://www.wqxr.org/","supportUrl":"https://www.wqxr.org/support","description":"New York's classical station, hosted all day, from the morning show to live concerts.","image":"https://media.wnyc.org/i/500/500/c/80/1/wqxr_1_1.png","accent":"#1f4e79","moods":["focus"],"eras":[],"genres":["classical"],"cities":["new-york"],"cityLabels":["New York"],"section":"Live · United States","hasNowPlaying":false,"hasRecentPlays":false,"similar":["kusc","wfmt","nts-sheet-music","nts-slow-focus","sr-p2-musik","radio-swiss-classic"],"about":null},{"slug":"new-sounds","name":"New Sounds","source":"public","sourceLabel":"WNYC","kind":"station","streamUrl":"https://stream.wqxr.org/q2","homepage":"https://www.newsounds.org/","supportUrl":"https://www.newsounds.org/support","description":"John Schaefer's New Sounds: new music from everywhere, ambient to avant-garde, chosen by hand in New York.","image":"https://media.wnyc.org/i/600/600/l/80/1/ns_showcard-newsounds-radio-1.jpg","accent":"#3a506b","moods":["focus","late-night"],"eras":[],"genres":["contemporary classical","ambient","experimental","world"],"cities":["new-york"],"cityLabels":["New York"],"section":"Live · United States","hasNowPlaying":false,"hasRecentPlays":false,"similar":["somafm-dronezone","resonance-fm","ambient-sleeping-pill","somafm-deepspaceone","nts-field-recordings","nts-sheet-music"],"about":null},{"slug":"kcsm","name":"KCSM Jazz 91","source":"public","sourceLabel":"KCSM 91.1","kind":"station","streamUrl":"https://ice5.securenetsystems.net/KCSM","homepage":"https://kcsm.org/","supportUrl":"https://kcsm.org/support","description":"The Bay Area's jazz station, listener-supported and hosted around the clock.","image":"https://cassette.digital/radio-art/kcsm.jpg","accent":"#2c6e91","moods":["late-night"],"eras":[],"genres":["jazz"],"cities":["san-francisco"],"cityLabels":["San Francisco"],"section":"Live · United States","hasNowPlaying":false,"hasRecentPlays":false,"similar":["somafm-secretagent","somafm-sonicuniverse","tsf-jazz","wkcr","wmbr","fip-jazz"],"about":null},{"slug":"wfmt","name":"WFMT","source":"public","sourceLabel":"WFMT 98.7","kind":"station","streamUrl":"https://wfmt.streamguys1.com/main-mp3","homepage":"https://www.wfmt.com/","supportUrl":"https://www.wfmt.com/support/","description":"Chicago's classical and fine-arts station since 1951, hosted live.","image":"https://cassette.digital/radio-art/wfmt.jpg","accent":"#8b1e3f","moods":["focus"],"eras":[],"genres":["classical"],"cities":["chicago"],"cityLabels":["Chicago"],"section":"Live · United States","hasNowPlaying":false,"hasRecentPlays":false,"similar":["kusc","wqxr","nts-sheet-music","nts-slow-focus","sr-p2-musik","radio-swiss-classic"],"about":null},{"slug":"kcrw","name":"KCRW","source":"kcrw","sourceLabel":"KCRW","kind":"station","streamUrl":"https://streams.kcrw.com/kcrw_mp3","homepage":"https://www.kcrw.com/","supportUrl":"https://www.kcrw.com/join","description":"Santa Monica's public station: Morning Becomes Eclectic and DJs whose playlists name every record.","image":"https://cassette.digital/radio-art/kcrw.jpg","accent":"#e63946","moods":[],"eras":[],"genres":["eclectic","indie","electronic","world"],"cities":["los-angeles"],"cityLabels":["Los Angeles"],"section":"Live · United States","hasNowPlaying":true,"hasRecentPlays":true,"similar":["kcrw-eclectic24","fip","kexp","radio-nova","kiosk-radio","netil-radio"],"about":{"text":"KCRW is an NPR member station in Santa Monica, California. KCRW airs original news and music programming in addition to programming from NPR and other affiliates.","source":"Wikipedia","url":"https://en.wikipedia.org/wiki/KCRW","license":"CC BY-SA 4.0, shortened"}},{"slug":"kcrw-eclectic24","name":"KCRW Eclectic 24","source":"kcrw","sourceLabel":"KCRW","kind":"channel","streamUrl":"https://streams.kcrw.com/e24_mp3","homepage":"https://www.kcrw.com/music/shows/eclectic24","supportUrl":"https://www.kcrw.com/join","description":"KCRW's all-music stream, around the clock: the Morning Becomes Eclectic sound without the talk.","image":"https://cassette.digital/radio-art/kcrw.jpg","accent":"#c1121f","moods":["chill","late-night"],"eras":[],"genres":["eclectic","indie","electronic"],"cities":["los-angeles"],"cityLabels":["Los Angeles"],"section":"Chill","hasNowPlaying":true,"hasRecentPlays":true,"similar":["kcrw","kexp","fip","kiosk-radio","netil-radio","somafm-beatblender"],"about":null},{"slug":"the-current","name":"The Current","source":"public","sourceLabel":"Minnesota Public Radio","kind":"station","streamUrl":"https://current.stream.publicradio.org/current.mp3","homepage":"https://www.thecurrent.org/","supportUrl":"https://www.thecurrent.org/support","description":"Minnesota Public Radio's music station: indie, local bands, live sessions, hosted all day.","image":"https://cassette.digital/radio-art/the-current.png","accent":"#00a3e0","moods":[],"eras":[],"genres":["indie","rock","folk"],"cities":["minneapolis"],"cityLabels":["Minneapolis"],"section":"Live · United States","hasNowPlaying":true,"hasRecentPlays":true,"similar":["wfuv","wxpn","kexp","dr-p6-beat","nrk-p13","fip-rock"],"about":{"text":"KCMP is a radio station owned by Minnesota Public Radio (MPR) that airs an adult album alternative (AAA) music format, including a significant rotation of songs by local artists.","source":"Wikipedia","url":"https://en.wikipedia.org/wiki/KCMP","license":"CC BY-SA 4.0, shortened"}},{"slug":"kusc","name":"Classical KUSC","source":"public","sourceLabel":"KUSC 91.5","kind":"station","streamUrl":"https://playerservices.streamtheworld.com/api/livestream-redirect/KUSCMP128.mp3","homepage":"https://www.kusc.org/","supportUrl":"https://www.kusc.org/support/","description":"Los Angeles' classical station, the largest in the country, hosted live.","image":"https://upload.wikimedia.org/wikipedia/commons/e/e2/KUSC_Logo.jpg","accent":"#1d3557","moods":["focus"],"eras":[],"genres":["classical"],"cities":["los-angeles"],"cityLabels":["Los Angeles"],"section":"Live · United States","hasNowPlaying":false,"hasRecentPlays":false,"similar":["wfmt","wqxr","nts-sheet-music","nts-slow-focus","sr-p2-musik","radio-swiss-classic"],"about":null},{"slug":"wkcr","name":"WKCR","source":"public","sourceLabel":"WKCR 89.9 · Columbia","kind":"station","streamUrl":"https://wkcr.streamguys1.com/live","homepage":"https://www.cc-seas.columbia.edu/wkcr/","supportUrl":null,"description":"Columbia University's station since 1941: deep jazz, classical, American roots and new music, programmed by students who know their archives.","image":null,"accent":"#4a6fa5","moods":["late-night"],"eras":[],"genres":["jazz","classical","roots","experimental"],"cities":["new-york"],"cityLabels":["New York"],"section":"Live · United States","hasNowPlaying":false,"hasRecentPlays":false,"similar":["wprb","fip","nts-1","kcsm","tsf-jazz","wmbr"],"about":null},{"slug":"wprb","name":"WPRB","source":"public","sourceLabel":"WPRB 103.3 · Princeton","kind":"station","streamUrl":"https://wprb.streamguys1.com/live","homepage":"https://wprb.com/","supportUrl":"https://wprb.com/support/","description":"Princeton's freeform college station: indie, experimental, jazz, whatever the DJ carried in.","image":"https://cassette.digital/radio-art/wprb.jpg","accent":"#ff6b35","moods":["late-night"],"eras":[],"genres":["indie","experimental","jazz","freeform"],"cities":[],"cityLabels":[],"section":"Live radio","hasNowPlaying":false,"hasRecentPlays":false,"similar":["kalx","wmbr","kfjc","wkcr","kxlu","wfmu"],"about":null},{"slug":"kalx","name":"KALX","source":"public","sourceLabel":"KALX 90.7 · Berkeley","kind":"station","streamUrl":"https://stream.kalx.berkeley.edu:8443/kalx-128.mp3","homepage":"https://kalx.berkeley.edu/","supportUrl":null,"description":"Berkeley's student-and-community station: freeform, deep, and allergic to playlists.","image":"https://kalx.berkeley.edu/wp-content/uploads/2023/07/kalx-logo.png","accent":"#003262","moods":["late-night"],"eras":[],"genres":["indie","freeform","punk","experimental"],"cities":["san-francisco"],"cityLabels":["San Francisco"],"section":"Live · United States","hasNowPlaying":false,"hasRecentPlays":false,"similar":["kfjc","wprb","kxlu","wmbr","wfmu","kcrw-eclectic24"],"about":null},{"slug":"kfjc","name":"KFJC","source":"public","sourceLabel":"KFJC 89.7","kind":"station","streamUrl":"https://netcast.kfjc.org/kfjc-128k-mp3","homepage":"https://kfjc.org/","supportUrl":"https://kfjc.org/support","description":"Foothill College's freeform station in the hills above Silicon Valley, strange and beloved since 1959.","image":"https://cassette.digital/radio-art/kfjc.jpg","accent":"#6a994e","moods":["late-night"],"eras":[],"genres":["freeform","experimental","rock","punk"],"cities":["san-francisco"],"cityLabels":["San Francisco"],"section":"Live · United States","hasNowPlaying":false,"hasRecentPlays":false,"similar":["kalx","wprb","kxlu","new-sounds","resonance-fm","wfmu"],"about":null},{"slug":"kxlu","name":"KXLU","source":"public","sourceLabel":"KXLU 88.9","kind":"station","streamUrl":"https://kxlu.streamguys1.com/kxlu-hi","homepage":"https://kxlu.com/","supportUrl":null,"description":"Loyola Marymount's station: LA's underground, punk to Latin to noise, since 1957.","image":"https://kxlu.com/wp-content/uploads/2019/02/kxlusplatblack-125x125.png","accent":"#c9184a","moods":["heavy"],"eras":[],"genres":["punk","indie","latin","experimental"],"cities":["los-angeles"],"cityLabels":["Los Angeles"],"section":"Live · United States","hasNowPlaying":false,"hasRecentPlays":false,"similar":["kalx","kfjc","wprb","kcrw","kcrw-eclectic24","dr-p6-beat"],"about":null},{"slug":"wmbr","name":"WMBR","source":"public","sourceLabel":"WMBR 88.1 · MIT","kind":"station","streamUrl":"https://wmbr.org:8002/hi","homepage":"https://wmbr.org/","supportUrl":null,"description":"MIT's station in Cambridge: freeform, deep genre shows, a schedule you can set your week by.","image":"https://cassette.digital/radio-art/wmbr.jpg","accent":"#a31f34","moods":["late-night"],"eras":[],"genres":["freeform","indie","jazz","world"],"cities":["boston"],"cityLabels":["Boston"],"section":"Live · United States","hasNowPlaying":false,"hasRecentPlays":false,"similar":["wprb","kalx","fip","kcrw","radio-nova","somafm-bossa"],"about":null},{"slug":"wsou","name":"WSOU","source":"public","sourceLabel":"WSOU 89.5 · Seton Hall","kind":"station","streamUrl":"https://crystalout.surfernetwork.com:8001/WSOU_MP3","homepage":"https://www.wsou.net/","supportUrl":null,"description":"Seton Hall's Pirate Radio: hard rock and metal, student-run since 1986.","image":"https://cassette.digital/radio-art/wsou.jpg","accent":"#b22222","moods":["heavy"],"eras":[],"genres":["metal","hard rock"],"cities":["new-york"],"cityLabels":["New York"],"section":"Live · United States","hasNowPlaying":false,"hasRecentPlays":false,"similar":["fip-metal","somafm-metal","nts-the-pit","kxlu","nightride-darksynth","somafm-doomed"],"about":null},{"slug":"rinse-fm","name":"Rinse FM","source":"community","sourceLabel":"Community radio","kind":"station","streamUrl":"https://admin.stream.rinse.fm/proxy/rinse_uk/stream","homepage":"https://www.rinse.fm/","supportUrl":null,"description":"London's pirate turned institution: grime, garage, drum and bass, and whatever the city invents next.","image":"https://cassette.digital/radio-art/rinse-fm.jpg","accent":"#e5383b","moods":["dance","late-night"],"eras":[],"genres":["grime","garage","drum and bass","electronic"],"cities":["london"],"cityLabels":["London"],"section":"Live · London","hasNowPlaying":true,"hasRecentPlays":false,"similar":["netil-radio","somafm-beatblender","fip-electro","kiosk-radio","somafm-fluid","kcrw-eclectic24"],"about":{"text":"Rinse FM is a London-based community radio station, licensed for \"young people living and/or working within the central, east and south London areas\". It plays garage, grime, dubstep, house, jungle, UK funky and other dance music genres popular in the United Kingdom.","source":"Wikipedia","url":"https://en.wikipedia.org/wiki/Rinse_FM","license":"CC BY-SA 4.0"}},{"slug":"soho-radio","name":"Soho Radio","source":"community","sourceLabel":"Community radio","kind":"station","streamUrl":"https://sohoradiomusic.doughunt.co.uk:8010/320mp3","homepage":"https://sohoradiolondon.com/","supportUrl":null,"description":"A shopfront studio in Soho, London: DJs, musicians and record collectors passing through all day.","image":"https://sohoradiolondon.com/wp-content/themes/sohoradio-jan-2023/build/images/favicons/sohoradio-192x192.jpg","accent":"#f4a261","moods":["sunny"],"eras":[],"genres":["eclectic","soul","jazz","electronic"],"cities":["london"],"cityLabels":["London"],"section":"Live · London","hasNowPlaying":false,"hasRecentPlays":false,"similar":["radio-nova","fip","nts-1","kiosk-radio","nts-2","kcrw"],"about":null},{"slug":"resonance-fm","name":"Resonance FM","source":"community","sourceLabel":"Community radio","kind":"station","streamUrl":"https://stream.resonance.fm/resonance","homepage":"https://www.resonancefm.com/","supportUrl":"https://www.resonancefm.com/support","description":"London's art radio since 2002: sound art, improvised music, radio made by artists.","image":"https://cassette.digital/radio-art/resonance-fm.jpg","accent":"#6d597a","moods":["cosmic","late-night"],"eras":[],"genres":["experimental","sound art","improvised"],"cities":["london"],"cityLabels":["London"],"section":"Live · London","hasNowPlaying":false,"hasRecentPlays":false,"similar":["new-sounds","somafm-dronezone","kalx","kfjc","somafm-darkzone","wfmu"],"about":null},{"slug":"netil-radio","name":"Netil Radio","source":"community","sourceLabel":"Community radio","kind":"station","streamUrl":"https://netilradio.out.airtime.pro/netilradio_a","homepage":"https://netilradio.com/","supportUrl":null,"description":"A shipping-container studio on a rooftop in Hackney, with East London's DJs on rotation.","image":"https://cassette.digital/radio-art/netil-radio.png","accent":"#9d4edd","moods":["dance","late-night"],"eras":[],"genres":["electronic","eclectic","house"],"cities":["london"],"cityLabels":["London"],"section":"Live · London","hasNowPlaying":true,"hasRecentPlays":false,"similar":["somafm-beatblender","kiosk-radio","radio-raheem","kcrw-eclectic24","nts-1","fip-electro"],"about":null},{"slug":"kiosk-radio","name":"Kiosk Radio","source":"community","sourceLabel":"Community radio","kind":"station","streamUrl":"https://kioskradiobxl.out.airtime.pro/kioskradiobxl_a","homepage":"https://kioskradio.com/","supportUrl":null,"description":"A wooden kiosk in a Brussels park, broadcasting the city's DJs every day.","image":"https://kioskradio.com/favicon.png","accent":"#2a9d8f","moods":["chill","dance"],"eras":[],"genres":["electronic","eclectic","jazz"],"cities":["brussels"],"cityLabels":["Brussels"],"section":"Live · Europe","hasNowPlaying":true,"hasRecentPlays":false,"similar":["fip","nts-1","radio-nova","soho-radio","netil-radio","kcrw-eclectic24"],"about":null},{"slug":"radio-raheem","name":"Radio Raheem","source":"community","sourceLabel":"Community radio","kind":"station","streamUrl":"https://radioraheem.out.airtime.pro/radioraheem_a","homepage":"https://www.radioraheem.it/","supportUrl":null,"description":"Milan's community station: DJs from the city's clubs, labels and record shops.","image":"https://cassette.digital/radio-art/radio-raheem.jpg","accent":"#ff5d8f","moods":["dance"],"eras":[],"genres":["electronic","eclectic","disco"],"cities":["milan"],"cityLabels":["Milan"],"section":"Live · Europe","hasNowPlaying":true,"hasRecentPlays":false,"similar":["kiosk-radio","netil-radio","kcrw","nts-1","kcrw-eclectic24","somafm-beatblender"],"about":null},{"slug":"fip","name":"FIP","source":"radiofrance","sourceLabel":"FIP · Radio France","kind":"station","streamUrl":"https://icecast.radiofrance.fr/fip-midfi.mp3","homepage":"https://www.radiofrance.fr/fip","supportUrl":null,"description":"Radio France's FIP: jazz into Afrobeat into Debussy, with hosts who never tell you what's next.","image":"https://cdn.radiofrance.fr/s3/cruiser-production/2019/06/f5b944ca-9a21-4970-8eed-e711dac8ac15/200x200_fip-rock_ok.jpg","accent":"#e4007c","moods":["chill"],"eras":[],"genres":["eclectic","jazz","world","electronic","classical"],"cities":["paris"],"cityLabels":["Paris"],"section":"Live · Europe","hasNowPlaying":false,"hasRecentPlays":false,"similar":["radio-nova","kiosk-radio","soho-radio","kcrw","nts-1","dublab"],"about":{"text":"FIP is a French radio network founded in 1971. It is part of the Radio France group.","source":"Wikipedia","url":"https://en.wikipedia.org/wiki/FIP_(radio_station)","license":"CC BY-SA 4.0"}},{"slug":"fip-rock","name":"FIP Rock","source":"radiofrance","sourceLabel":"FIP · Radio France","kind":"channel","streamUrl":"https://icecast.radiofrance.fr/fiprock-midfi.mp3","homepage":"https://www.radiofrance.fr/fip/radio-rock","supportUrl":null,"description":"FIP's rock stream: garage, psych, post-punk, and the records between.","image":"https://cdn.radiofrance.fr/s3/cruiser-production/2019/06/f5b944ca-9a21-4970-8eed-e711dac8ac15/200x200_fip-rock_ok.jpg","accent":"#c1121f","moods":[],"eras":[],"genres":["rock","indie","psychedelic"],"cities":[],"cityLabels":[],"section":"Rock","hasNowPlaying":false,"hasRecentPlays":false,"similar":["dr-p6-beat","kexp","nrk-p13","the-current","wfuv","wxpn"],"about":null},{"slug":"fip-jazz","name":"FIP Jazz","source":"radiofrance","sourceLabel":"FIP · Radio France","kind":"channel","streamUrl":"https://icecast.radiofrance.fr/fipjazz-midfi.mp3","homepage":"https://www.radiofrance.fr/fip/radio-jazz","supportUrl":null,"description":"FIP's jazz stream, hard bop to spiritual, all day.","image":"https://www.radiofrance.fr/s3/cruiser-production/2019/06/840a4431-0db0-4a94-aa28-53f8de011ab6/300x300_fip-jazz-01.jpg","accent":"#3d5a80","moods":["late-night"],"eras":[],"genres":["jazz"],"cities":[],"cityLabels":[],"section":"Late night","hasNowPlaying":false,"hasRecentPlays":false,"similar":["nts-expansions","radio-swiss-jazz","somafm-secretagent","somafm-sonicuniverse","jazz-groove-mix1","jazz-groove-mix2"],"about":null},{"slug":"fip-groove","name":"FIP Groove","source":"radiofrance","sourceLabel":"FIP · Radio France","kind":"channel","streamUrl":"https://icecast.radiofrance.fr/fipgroove-midfi.mp3","homepage":"https://www.radiofrance.fr/fip/radio-groove","supportUrl":null,"description":"FIP's groove stream: funk, soul, disco, boogie.","image":"https://cdn.radiofrance.fr/s3/cruiser-production/2019/06/f5b944ca-9a21-4970-8eed-e711dac8ac15/200x200_fip-rock_ok.jpg","accent":"#f77f00","moods":["dance","sunny"],"eras":[],"genres":["funk","soul","disco"],"cities":[],"cityLabels":[],"section":"Dance","hasNowPlaying":false,"hasRecentPlays":false,"similar":["funky-radio","somafm-7soul","nts-2","soho-radio","nts-4-to-the-floor","radio-raheem"],"about":null},{"slug":"fip-monde","name":"FIP Monde","source":"radiofrance","sourceLabel":"FIP · Radio France","kind":"channel","streamUrl":"https://icecast.radiofrance.fr/fipworld-midfi.mp3","homepage":"https://www.radiofrance.fr/fip/radio-monde","supportUrl":null,"description":"FIP's world stream: music from every continent, curated in Paris.","image":"https://cdn.radiofrance.fr/s3/cruiser-production/2019/06/f5b944ca-9a21-4970-8eed-e711dac8ac15/200x200_fip-rock_ok.jpg","accent":"#2a9d8f","moods":["sunny"],"eras":[],"genres":["world"],"cities":[],"cityLabels":[],"section":"Sunny","hasNowPlaying":false,"hasRecentPlays":false,"similar":["somafm-bossa","nts-sweat","radioparadise-global","somafm-suburbsofgoa","radio-nova","radioparadise-main"],"about":null},{"slug":"fip-nouveautes","name":"FIP Nouveautés","source":"radiofrance","sourceLabel":"FIP · Radio France","kind":"channel","streamUrl":"https://icecast.radiofrance.fr/fipnouveautes-midfi.mp3","homepage":"https://www.radiofrance.fr/fip/radio-nouveautes","supportUrl":null,"description":"FIP's new-releases stream: this month's records across every genre FIP plays.","image":"https://cdn.radiofrance.fr/s3/cruiser-production/2019/06/f5b944ca-9a21-4970-8eed-e711dac8ac15/200x200_fip-rock_ok.jpg","accent":"#e4007c","moods":[],"eras":[],"genres":["eclectic","new releases"],"cities":[],"cityLabels":[],"section":"Eclectic","hasNowPlaying":false,"hasRecentPlays":false,"similar":["somafm-covers","kcrw-eclectic24","radioparadise-main","fip","kcrw","kexp"],"about":null},{"slug":"fip-reggae","name":"FIP Reggae","source":"radiofrance","sourceLabel":"FIP · Radio France","kind":"channel","streamUrl":"https://icecast.radiofrance.fr/fipreggae-midfi.mp3","homepage":"https://www.radiofrance.fr/fip/radio-reggae","supportUrl":null,"description":"FIP's reggae stream: roots, dub, rocksteady.","image":"https://www.radiofrance.fr/pikapi/images/a242c7c5-bf1e-468b-9cb9-2154550f8be7/2048","accent":"#43aa8b","moods":["sunny"],"eras":["1970s"],"genres":["reggae","dub"],"cities":[],"cityLabels":[],"section":"Sunny","hasNowPlaying":false,"hasRecentPlays":false,"similar":["somafm-reggae","nts-island-time","somafm-seventies"],"about":null},{"slug":"fip-electro","name":"FIP Electro","source":"radiofrance","sourceLabel":"FIP · Radio France","kind":"channel","streamUrl":"https://icecast.radiofrance.fr/fipelectro-midfi.mp3","homepage":"https://www.radiofrance.fr/fip/radio-electro","supportUrl":null,"description":"FIP's electronic stream, from ambient to club.","image":"https://cdn.radiofrance.fr/s3/cruiser-production/2019/06/f5b944ca-9a21-4970-8eed-e711dac8ac15/200x200_fip-rock_ok.jpg","accent":"#4361ee","moods":["dance","late-night"],"eras":[],"genres":["electronic"],"cities":[],"cityLabels":[],"section":"Dance","hasNowPlaying":false,"hasRecentPlays":false,"similar":["somafm-beatblender","netil-radio","rinse-fm","kcrw-eclectic24","nightride-fm","nts-labyrinth"],"about":null},{"slug":"fip-metal","name":"FIP Metal","source":"radiofrance","sourceLabel":"FIP · Radio France","kind":"channel","streamUrl":"https://icecast.radiofrance.fr/fipmetal-midfi.mp3","homepage":"https://www.radiofrance.fr/fip/radio-metal","supportUrl":null,"description":"FIP's metal stream: a public broadcaster that takes doom seriously.","image":"https://www.radiofrance.fr/s3/cruiser-production/2022/07/160994f8-296b-4cd8-97a0-34c9111cdd9d/400x400_fip-metal-20222x_2.webp","accent":"#540b0e","moods":["heavy"],"eras":[],"genres":["metal"],"cities":[],"cityLabels":[],"section":"Heavy","hasNowPlaying":false,"hasRecentPlays":false,"similar":["somafm-metal","nts-the-pit","wsou","nightride-darksynth","somafm-doomed","kxlu"],"about":null},{"slug":"fip-pop","name":"FIP Pop","source":"radiofrance","sourceLabel":"FIP · Radio France","kind":"channel","streamUrl":"https://icecast.radiofrance.fr/fippop-midfi.mp3","homepage":"https://www.radiofrance.fr/fip/radio-pop","supportUrl":null,"description":"FIP's pop stream: the elegant end of pop, French and otherwise.","image":"https://cdn.radiofrance.fr/s3/cruiser-production/2020/06/14f16d25-960c-4cf4-8e39-682268b1a0c1/200x200_fip-pop_ok.jpg","accent":"#ff5d8f","moods":["sunny"],"eras":[],"genres":["pop","indie pop","chanson"],"cities":[],"cityLabels":[],"section":"Sunny","hasNowPlaying":false,"hasRecentPlays":false,"similar":["somafm-indiepop","nts-poolside","radio-swiss-pop","somafm-insound","sr-p3","0n-60s"],"about":null},{"slug":"fip-hiphop","name":"FIP Hip-Hop","source":"radiofrance","sourceLabel":"FIP · Radio France","kind":"channel","streamUrl":"https://icecast.radiofrance.fr/fiphiphop-midfi.mp3","homepage":"https://www.radiofrance.fr/fip/radio-hip-hop","supportUrl":null,"description":"FIP's hip-hop stream: boom bap to abstract, both sides of the Atlantic.","image":"https://cdn.radiofrance.fr/s3/cruiser-production/2019/06/f5b944ca-9a21-4970-8eed-e711dac8ac15/200x200_fip-rock_ok.jpg","accent":"#9d4edd","moods":["late-night"],"eras":[],"genres":["hip-hop"],"cities":[],"cityLabels":[],"section":"Late night","hasNowPlaying":false,"hasRecentPlays":false,"similar":["somafm-fluid","nts-100-percent-hip-hop","nts-rap-house","kexp","radio-nova","rinse-fm"],"about":null},{"slug":"radio-nova","name":"Radio Nova","source":"independent","sourceLabel":"Radio Nova","kind":"station","streamUrl":"https://novazz.ice.infomaniak.ch/novazz-128.mp3","homepage":"https://www.nova.fr/","supportUrl":null,"description":"Paris' Grand Mix since 1981: hip-hop, world, electronic and jazz in one breath, with hosts who collect.","image":"https://www.nova.fr/wp-content/uploads/sites/2/2021/02/cropped-favicon.png","accent":"#ff8500","moods":["sunny"],"eras":[],"genres":["eclectic","hip-hop","world","electronic","jazz"],"cities":["paris"],"cityLabels":["Paris"],"section":"Live · Europe","hasNowPlaying":false,"hasRecentPlays":false,"similar":["fip","soho-radio","kexp","kiosk-radio","nts-1","somafm-bossa"],"about":null},{"slug":"tsf-jazz","name":"TSF Jazz","source":"independent","sourceLabel":"TSF Jazz","kind":"station","streamUrl":"https://tsfjazz.ice.infomaniak.ch/tsfjazz-high.mp3","homepage":"https://www.tsfjazz.com/","supportUrl":null,"description":"Paris' all-jazz station: live hosts, live sessions, since 1999.","image":"https://cassette.digital/radio-art/tsf-jazz.png","accent":"#003049","moods":["late-night"],"eras":[],"genres":["jazz"],"cities":["paris"],"cityLabels":["Paris"],"section":"Live · Europe","hasNowPlaying":false,"hasRecentPlays":false,"similar":["kcsm","wkcr","wmbr","fip-jazz","nts-expansions","radio-swiss-jazz"],"about":null},{"slug":"radio-swiss-jazz","name":"Radio Swiss Jazz","source":"srg","sourceLabel":"Radio Swiss","kind":"channel","streamUrl":"https://stream.srg-ssr.ch/m/rsj/mp3_128","homepage":"https://www.radioswissjazz.ch/","supportUrl":null,"description":"Swiss public radio's jazz channel: no ads, no talk, a title on every song.","image":"https://cassette.digital/radio-art/radio-swiss-jazz.jpg","accent":"#c1121f","moods":["late-night","chill"],"eras":[],"genres":["jazz"],"cities":[],"cityLabels":[],"section":"Late night","hasNowPlaying":false,"hasRecentPlays":false,"similar":["jazz-groove-mix1","jazz-groove-mix2","somafm-bossa","fip-jazz","nts-expansions","somafm-secretagent"],"about":null},{"slug":"radio-swiss-classic","name":"Radio Swiss Classic","source":"srg","sourceLabel":"Radio Swiss","kind":"channel","streamUrl":"https://stream.srg-ssr.ch/m/rsc_de/mp3_128","homepage":"https://www.radioswissclassic.ch/","supportUrl":null,"description":"Swiss public radio's classical channel: no ads, no talk.","image":"https://cassette.digital/radio-art/radio-swiss-classic.jpg","accent":"#1d3557","moods":["focus"],"eras":[],"genres":["classical"],"cities":[],"cityLabels":[],"section":"Focus","hasNowPlaying":false,"hasRecentPlays":false,"similar":["nts-sheet-music","nts-slow-focus","sr-p2-musik","kusc","wfmt","wqxr"],"about":null},{"slug":"radio-swiss-pop","name":"Radio Swiss Pop","source":"srg","sourceLabel":"Radio Swiss","kind":"channel","streamUrl":"https://stream.srg-ssr.ch/m/rsp/mp3_128","homepage":"https://www.radioswisspop.ch/","supportUrl":null,"description":"Swiss public radio's pop channel: melodic pop and soft rock, no ads.","image":"https://cassette.digital/radio-art/radio-swiss-pop.jpg","accent":"#f4a261","moods":["sunny"],"eras":[],"genres":["pop","soft rock"],"cities":[],"cityLabels":[],"section":"Sunny","hasNowPlaying":false,"hasRecentPlays":false,"similar":["fip-pop","somafm-indiepop","nts-poolside","somafm-seventies","sr-p3","0n-60s"],"about":null},{"slug":"nrk-p13","name":"NRK P13","source":"broadcaster","sourceLabel":"NRK","kind":"station","streamUrl":"https://lyd.nrk.no/nrk_radio_p13_mp3_h","homepage":"https://radio.nrk.no/direkte/p13","supportUrl":null,"description":"Norway's public rock and alternative channel, hosted from Oslo.","image":"https://cassette.digital/radio-art/nrk-p13.png","accent":"#0a4c8c","moods":[],"eras":[],"genres":["rock","indie","alternative"],"cities":["oslo"],"cityLabels":["Oslo"],"section":"Live · Europe","hasNowPlaying":false,"hasRecentPlays":false,"similar":["dr-p6-beat","kexp","fip-rock","the-current","wfuv","wxpn"],"about":null},{"slug":"sr-p3","name":"Sveriges Radio P3","source":"broadcaster","sourceLabel":"Sveriges Radio","kind":"station","streamUrl":"https://live1.sr.se/p3-aac-320","homepage":"https://sverigesradio.se/p3","supportUrl":null,"description":"Sweden's public channel for the young: new Swedish music, hosted all day.","image":"https://cassette.digital/radio-art/sr-p3.jpg","accent":"#0066cc","moods":[],"eras":[],"genres":["pop","indie","hip-hop"],"cities":["stockholm"],"cityLabels":["Stockholm"],"section":"Live · Europe","hasNowPlaying":true,"hasRecentPlays":false,"similar":["kexp","dr-p6-beat","kalx","kcrw","kxlu","nrk-p13"],"about":null},{"slug":"sr-p2-musik","name":"P2 Musik","source":"broadcaster","sourceLabel":"Sveriges Radio","kind":"channel","streamUrl":"https://live1.sr.se/p2musik-aac-320","homepage":"https://sverigesradio.se/p2","supportUrl":null,"description":"Sweden's public classical and jazz music stream, around the clock.","image":"https://cassette.digital/radio-art/sr-p2-musik.jpg","accent":"#3a506b","moods":["focus"],"eras":[],"genres":["classical","jazz"],"cities":[],"cityLabels":[],"section":"Focus","hasNowPlaying":true,"hasRecentPlays":false,"similar":["fip","nts-sheet-music","nts-slow-focus","radio-swiss-classic","kusc","wfmt"],"about":null},{"slug":"dr-p6-beat","name":"DR P6 Beat","source":"broadcaster","sourceLabel":"DR","kind":"station","streamUrl":"https://live-icy.dr.dk/A/A29H.mp3","homepage":"https://www.dr.dk/lyd/p6beat","supportUrl":null,"description":"Denmark's public rock and alternative channel, hosted from Copenhagen.","image":"https://www.dr.dk/nyhedsbrev/images/drlyd.png","accent":"#d62828","moods":[],"eras":[],"genres":["rock","indie","alternative"],"cities":["copenhagen"],"cityLabels":["Copenhagen"],"section":"Live · Europe","hasNowPlaying":false,"hasRecentPlays":false,"similar":["nrk-p13","kexp","fip-rock","the-current","wfuv","wxpn"],"about":null},{"slug":"nightride-fm","name":"Nightride FM","source":"nightride","sourceLabel":"Nightride FM","kind":"channel","streamUrl":"https://stream.nightride.fm/nightride.mp3","homepage":"https://nightride.fm/","supportUrl":null,"description":"Synthwave, around the clock, from the network that made it a radio format.","image":"https://nightride.fm/apple-touch-icon.png","accent":"#ff2a6d","moods":["late-night","dreamy"],"eras":["1980s"],"genres":["synthwave","retrowave","electronic"],"cities":[],"cityLabels":[],"section":"Late night","hasNowPlaying":false,"hasRecentPlays":false,"similar":["somafm-beatblender","nightride-chillsynth","nightride-datawave","fip-electro","kcrw-eclectic24","somafm-lush"],"about":null},{"slug":"nightride-chillsynth","name":"Chillsynth","source":"nightride","sourceLabel":"Nightride FM","kind":"channel","streamUrl":"https://stream.nightride.fm/chillsynth.mp3","homepage":"https://nightride.fm/?station=chillsynth","supportUrl":null,"description":"Nightride's slow lane: chillsynth and dreamwave for late drives.","image":"https://nightride.fm/apple-touch-icon.png","accent":"#05d9e8","moods":["chill","dreamy"],"eras":[],"genres":["chillsynth","synthwave"],"cities":[],"cityLabels":[],"section":"Chill","hasNowPlaying":false,"hasRecentPlays":false,"similar":["nightride-fm","somafm-lush","somafm-spacestation","nightride-datawave","kcrw-eclectic24","nightwave-plaza"],"about":null},{"slug":"nightride-datawave","name":"Datawave","source":"nightride","sourceLabel":"Nightride FM","kind":"channel","streamUrl":"https://stream.nightride.fm/datawave.mp3","homepage":"https://nightride.fm/?station=datawave","supportUrl":null,"description":"Nightride's cyberpunk stream: darker, faster, more neon.","image":"https://nightride.fm/apple-touch-icon.png","accent":"#7b2cbf","moods":["late-night","dance"],"eras":[],"genres":["synthwave","cyberpunk"],"cities":[],"cityLabels":[],"section":"Late night","hasNowPlaying":false,"hasRecentPlays":false,"similar":["nightride-fm","somafm-beatblender","fip-electro","netil-radio","rinse-fm","nightride-chillsynth"],"about":null},{"slug":"nightride-darksynth","name":"Darksynth","source":"nightride","sourceLabel":"Nightride FM","kind":"channel","streamUrl":"https://stream.nightride.fm/darksynth.mp3","homepage":"https://nightride.fm/?station=darksynth","supportUrl":null,"description":"Nightride's heavy end: darksynth and industrial synth.","image":"https://nightride.fm/apple-touch-icon.png","accent":"#3a0ca3","moods":["heavy","late-night"],"eras":[],"genres":["darksynth","industrial"],"cities":[],"cityLabels":[],"section":"Heavy","hasNowPlaying":false,"hasRecentPlays":false,"similar":["somafm-doomed","nts-the-tube","kfjc","somafm-beatblender","nightride-datawave","fip-electro"],"about":null},{"slug":"ambient-sleeping-pill","name":"Ambient Sleeping Pill","source":"independent","sourceLabel":"Ambient Sleeping Pill","kind":"channel","streamUrl":"https://radio.stereoscenic.com/asp-h","homepage":"https://ambientsleepingpill.com/","supportUrl":null,"description":"Ambient for sleeping and not-quite-sleeping. Listener-supported, no beats, no ads.","image":"https://ambientsleepingpill.com/wp-content/uploads/cropped-asp-small-logo-512-trans-192x192.png","accent":"#5e81ac","moods":["focus","cosmic"],"eras":[],"genres":["ambient"],"cities":[],"cityLabels":[],"section":"Focus","hasNowPlaying":false,"hasRecentPlays":false,"similar":["somafm-deepspaceone","somafm-dronezone","nts-field-recordings","nts-slow-focus","new-sounds","radioparadise-mellow"],"about":null},{"slug":"nightwave-plaza","name":"Nightwave Plaza","source":"independent","sourceLabel":"Nightwave Plaza","kind":"channel","streamUrl":"https://radio.plaza.one/mp3","homepage":"https://plaza.one/","supportUrl":null,"description":"Vaporwave around the clock, with a playlist you can read.","image":"https://plaza.one/icons/apple-touch-icon.png","accent":"#c77dff","moods":["dreamy"],"eras":[],"genres":["vaporwave","electronic"],"cities":[],"cityLabels":[],"section":"Dreamy","hasNowPlaying":false,"hasRecentPlays":false,"similar":["somafm-vaporwaves","somafm-lush","nightride-fm","nts-otaku","fip-electro","kcrw-eclectic24"],"about":null},{"slug":"rainwave-game","name":"Rainwave Game Music","source":"independent","sourceLabel":"Rainwave","kind":"channel","streamUrl":"https://relay.rainwave.cc/game.mp3","homepage":"https://rainwave.cc/","supportUrl":null,"description":"Video game soundtracks chosen by the listeners, around the clock.","image":"https://cassette.digital/radio-art/rainwave-game.png","accent":"#48cae4","moods":["dreamy","focus"],"eras":[],"genres":["video game music","soundtrack"],"cities":[],"cityLabels":[],"section":"Dreamy","hasNowPlaying":false,"hasRecentPlays":false,"similar":["nts-otaku","somafm-secretagent"],"about":null},{"slug":"jazz-groove-mix1","name":"The Jazz Groove","source":"independent","sourceLabel":"The Jazz Groove","kind":"channel","streamUrl":"https://west-mp3-128.streamthejazzgroove.com/stream","homepage":"https://jazzgroove.org/","supportUrl":"https://jazzgroove.org/support/","description":"Laid-back jazz, listener-supported and ad-free, for late nights and long mornings.","image":"https://assets.jazzgroove.org/logo-circle-white1-no-org.png","accent":"#2b2d42","moods":["chill","late-night"],"eras":[],"genres":["jazz"],"cities":[],"cityLabels":[],"section":"Chill","hasNowPlaying":false,"hasRecentPlays":false,"similar":["radio-swiss-jazz","jazz-groove-mix2","somafm-bossa","fip-jazz","nts-expansions","somafm-secretagent"],"about":null},{"slug":"jazz-groove-mix2","name":"The Jazz Groove Mix 2","source":"independent","sourceLabel":"The Jazz Groove","kind":"channel","streamUrl":"https://east-mp3-128.streamthejazzgroove.com/stream","homepage":"https://jazzgroove.org/","supportUrl":"https://jazzgroove.org/support/","description":"The Jazz Groove's second mix: the same calm, a different hour.","image":"https://assets.jazzgroove.org/logo-circle-white1-no-org.png","accent":"#8d99ae","moods":["chill","late-night"],"eras":[],"genres":["jazz"],"cities":[],"cityLabels":[],"section":"Chill","hasNowPlaying":false,"hasRecentPlays":false,"similar":["radio-swiss-jazz","jazz-groove-mix1","somafm-bossa","fip-jazz","nts-expansions","somafm-secretagent"],"about":null}]}
"""#
  // END GENERATED CATALOG
}

// MARK: - RadioSaved

/// cassette 2026-10-21: the stations this person saved: ONE save, the web's (the follow
/// list behind "Your stations" on /radio). The phone reads it with its sign-in and writes
/// through the same route the web's Save key uses, so a save on either side is the same
/// save. Kept on the phone too (latest save first), so the dial and Home order by it
/// offline and a tap answers at once; a write that fails puts the old state back.
@MainActor
final class RadioSaved {
  static let shared = RadioSaved()
  static let didChange = Notification.Name("cassette.radioSaved.didChange")
  private static let key = "cassette.radio.saved.v1"
  /// Don't ask the cloud more than this often (the dial and Home both ask on appear).
  private static let refreshEvery: TimeInterval = 30

  /// Saved slugs, the latest save first.
  private(set) var slugs: [String]
  private var lastRefresh: Date?
  /// Slugs with a write in flight: a refresh that lands meanwhile keeps their local state.
  private var pending: Set<String> = []

  private init() {
    slugs = UserDefaults.standard.stringArray(forKey: Self.key) ?? []
  }

  func isSaved(_ slug: String) -> Bool { slugs.contains(slug) }

  private func set(_ next: [String]) {
    guard next != slugs else { return }
    slugs = next
    UserDefaults.standard.set(next, forKey: Self.key)
    NotificationCenter.default.post(name: Self.didChange, object: nil)
  }

  private func applying(_ slug: String, saved: Bool, to list: [String]) -> [String] {
    var out = list.filter { $0 != slug }
    if saved { out.insert(slug, at: 0) }
    return out
  }

  /// Save or unsave; the dial and Home reorder at once, the cloud follows.
  func setSaved(_ slug: String, _ saved: Bool) {
    let before = slugs
    set(applying(slug, saved: saved, to: slugs))
    if let app = UIApplication.shared.delegate as? AppDelegate {
      Haptics.light.vibrate(isHapticsEnabled: app.storage.settings.user.isHapticsEnabled)
    }
    pending.insert(slug)
    Task { @MainActor in
      defer { self.pending.remove(slug) }
      do {
        try await CassetteSyncAPI.shared.setRadioStationSaved(slug: slug, saved: saved)
      } catch {
        // Not signed in, offline, or the server said no: back to how it was.
        if self.isSaved(slug) == saved {
          self.set(self.applying(slug, saved: before.contains(slug), to: self.slugs))
        }
      }
    }
  }

  func toggle(_ slug: String) { setSaved(slug, !isSaved(slug)) }

  /// The account's list from the cloud (at most every 30 seconds unless `force`).
  func refresh(force: Bool = false) async {
    if !force, let last = lastRefresh, Date().timeIntervalSince(last) < Self.refreshEvery { return }
    guard CassetteSyncAPI.bearerToken != nil else { return }
    lastRefresh = Date()
    guard let remote = try? await CassetteSyncAPI.shared.getSavedRadioStations() else { return }
    var next = remote
    for slug in pending { next = applying(slug, saved: isSaved(slug), to: next) }
    set(next)
  }
}

// MARK: - RadioArtLoader

@MainActor
final class RadioArtLoader {
  static let shared = RadioArtLoader()
  private let cache = NSCache<NSString, UIImage>()
  private init() { cache.countLimit = 200 }

  /// The logo when it is already in memory, with no fetch: a rebuilt CarPlay row shows it at
  /// once instead of flashing the word picture first.
  func cachedImage(for urlString: String) -> UIImage? {
    cache.object(forKey: urlString as NSString)
  }

  func image(for urlString: String) async -> UIImage? {
    if let hit = cache.object(forKey: urlString as NSString) { return hit }
    guard let url = URL(string: urlString) else { return nil }
    var request = URLRequest(url: url)
    request.timeoutInterval = 12
    guard let (data, response) = try? await URLSession.shared.data(for: request),
          (response as? HTTPURLResponse)?.statusCode == 200,
          let image = UIImage(data: data) else { return nil }
    cache.setObject(image, forKey: urlString as NSString)
    return image
  }
}

// MARK: - RadioLiveFeed

/// cassette 2026-10-21: what's on, from the cloud. While a registry station
/// whose feed we read is playing, asks cassette.digital's now-playing route (the
/// one the web dock polls) every 30 seconds for the song or show, the show's
/// picture, when it ends and what comes next, and hands it to the player, which
/// carries it to the player screen, the lock screen and CarPlay. Stops the
/// moment the radio does. A miss changes nothing: the in-stream title stays.
@MainActor
final class RadioLiveFeed: MusicPlayable {
  static let shared = RadioLiveFeed()

  private static var route: String {
    #if DEBUG
      // A debug build can read a local web server before the route ships:
      // SIMCTL_CHILD_CASSETTE_RADIO_BASE=http://localhost:3200 xcrun simctl launch …
      if let base = ProcessInfo.processInfo.environment["CASSETTE_RADIO_BASE"], !base.isEmpty {
        return base + "/api/radio/now-playing?station="
      }
    #endif
    return "https://cassette.digital/api/radio/now-playing?station="
  }
  private static let every: TimeInterval = 30

  private var player: PlayerFacade?
  private var timer: Timer?
  private var slug: String?
  private var streamUrl: String?

  private init() {}

  /// Idempotent; the app calls it once the player is up.
  func start(player: PlayerFacade) {
    guard self.player == nil else { return }
    self.player = player
    player.addNotifier(notifier: self)
    evaluate()
  }

  private func evaluate() {
    guard let player, player.isPlaying,
          let radio = player.currentlyPlaying?.asRadio,
          let station = RadioCatalog.shared.station(forStreamUrl: radio.url),
          station.hasNowPlaying
    else {
      stop()
      return
    }
    if slug == station.slug, timer != nil {
      // Same station, still polling; refill at once if the player dropped it
      // (a stream reconnect clears the live info).
      if player.currentRadioLive == nil { tick() }
      return
    }
    stop()
    slug = station.slug
    streamUrl = radio.url
    tick()
    timer = Timer.scheduledTimer(withTimeInterval: Self.every, repeats: true) { [weak self] _ in
      Task { @MainActor in self?.tick() }
    }
  }

  private func stop() {
    timer?.invalidate()
    timer = nil
    if slug != nil { player?.setRadioLive(nil, artwork: nil, forStreamUrl: streamUrl) }
    slug = nil
    streamUrl = nil
  }

  private func tick() {
    guard let slug, let url = URL(string: Self.route + slug) else { return }
    let streamUrl = streamUrl
    Task { @MainActor in
      var request = URLRequest(url: url)
      request.timeoutInterval = 10
      guard let (data, response) = try? await URLSession.shared.data(for: request),
            (response as? HTTPURLResponse)?.statusCode == 200,
            let payload = try? JSONDecoder().decode(Payload.self, from: data),
            payload.station == slug
      else { return }
      let info = payload.liveInfo
      var art: UIImage?
      if let src = info.artworkURL { art = await RadioArtLoader.shared.image(for: src) }
      // Still the same station by the time the answer and its picture landed?
      guard self.slug == slug else { return }
      self.player?.setRadioLive(info, artwork: art, forStreamUrl: streamUrl)
    }
  }

  /// The web route's shape (apps/cassette/src/lib/radio/types.ts), the parts we use.
  private struct Payload: Decodable {
    struct Show: Decodable {
      let name: String
      let host: String?
      let starts: String?
      let until: String?
      let image: String?
    }

    struct Track: Decodable {
      let artist: String
      let title: String
      let coverUrl: String?
    }

    let station: String
    let show: Show?
    let track: Track?
    let next: [Show]?
    let nextTracks: [Track]?

    var liveInfo: RadioLiveInfo {
      let upNext = next?.first
      let nextSong = nextTracks?.first
      return RadioLiveInfo(
        songTitle: track?.title,
        songArtist: track?.artist,
        show: show?.name,
        host: show?.host,
        until: Self.date(show?.until),
        next: upNext?.name ?? nextSong.map { "\($0.title) · \($0.artist)" },
        nextStarts: Self.date(upNext?.starts),
        artworkURL: track?.coverUrl ?? show?.image
      )
    }

    private static func date(_ s: String?) -> Date? {
      guard let s else { return nil }
      let withFraction = ISO8601DateFormatter()
      withFraction.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
      return withFraction.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }
  }

  // MusicPlayable
  func didStartPlayingFromBeginning() { evaluate() }
  func didStartPlaying() { evaluate() }
  func didPause() { evaluate() }
  func didStopPlaying() { evaluate() }
  func didElapsedTimeChange() {}
  func didPlaylistChange() {}
  func didArtworkChange() {}
  func didShuffleChange() {}
  func didRepeatChange() {}
  func didPlaybackRateChange() {}
}

// MARK: - RadioRow

struct RadioRow {
  let radio: Radio
  let info: RadioCatalogStation?

  var displayName: String { info?.name ?? radio.title }
  var section: String { info?.section ?? "Other stations" }
}

// MARK: - RadioStationCell

final class RadioStationCell: UITableViewCell {
  static let reuseId = "RadioStationCell"

  private let art = UIImageView()
  private let initials = UILabel()
  private let nameLabel = UILabel()
  private let kickerLabel = UILabel()
  private let descLabel = UILabel()
  private let playingMark = UIImageView()
  /// cassette 2026-10-21: the row opens the station's page; this disc tunes in at once
  /// (the same one-tap play disc the record tiles wear).
  private let playButton = AlbumCollectionCell.makePlayOverlayButton()
  var onPlayTapped: (() -> ())?
  private var representedImage: String?
  private var loadTask: Task<(), Never>?

  override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
    super.init(style: style, reuseIdentifier: reuseIdentifier)
    backgroundColor = .clear
    contentView.backgroundColor = .clear
    let selected = UIView()
    selected.backgroundColor = CassetteTheme.UIColors.bg3
    selectedBackgroundView = selected

    art.contentMode = .scaleAspectFill
    art.clipsToBounds = true
    art.layer.cornerRadius = CassetteTheme.Radius.md
    art.backgroundColor = CassetteTheme.UIColors.bg3
    art.layer.borderWidth = 1
    art.layer.borderColor = CassetteTheme.UIColors.ink4.cgColor

    initials.font = UIFont.cassette(.rowTitle)
    initials.textColor = CassetteTheme.UIColors.ink
    initials.textAlignment = .center

    nameLabel.font = UIFont.cassette(.rowTitle)
    nameLabel.textColor = CassetteTheme.UIColors.ink
    nameLabel.numberOfLines = 1

    kickerLabel.font = UIFont.cassette(.metadata)
    kickerLabel.textColor = CassetteTheme.UIColors.ink2
    kickerLabel.numberOfLines = 1

    descLabel.font = UIFont.systemFont(ofSize: 13)
    descLabel.textColor = CassetteTheme.UIColors.ink3
    descLabel.numberOfLines = 2

    playingMark.image = UIImage(systemName: "waveform")
    playingMark.tintColor = CassetteTheme.UIColors.orange
    playingMark.contentMode = .scaleAspectFit
    playingMark.isHidden = true

    let text = UIStackView(arrangedSubviews: [nameLabel, kickerLabel, descLabel])
    text.axis = .vertical
    text.spacing = 3
    text.alignment = .leading

    playButton.addAction(UIAction { [weak self] _ in self?.onPlayTapped?() }, for: .touchUpInside)

    for v in [art, initials, text, playingMark, playButton] {
      v.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview(v)
    }
    let m = CassetteTheme.Spacing.lg
    NSLayoutConstraint.activate([
      art.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: m),
      art.topAnchor.constraint(equalTo: contentView.topAnchor, constant: CassetteTheme.Spacing.md),
      art.bottomAnchor.constraint(
        lessThanOrEqualTo: contentView.bottomAnchor,
        constant: -CassetteTheme.Spacing.md
      ),
      art.widthAnchor.constraint(equalToConstant: 56),
      art.heightAnchor.constraint(equalToConstant: 56),
      initials.centerXAnchor.constraint(equalTo: art.centerXAnchor),
      initials.centerYAnchor.constraint(equalTo: art.centerYAnchor),
      initials.widthAnchor.constraint(equalTo: art.widthAnchor),

      playButton.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -m),
      playButton.centerYAnchor.constraint(equalTo: art.centerYAnchor),
      playButton.widthAnchor.constraint(equalToConstant: AlbumCollectionCell.playOverlayDiameter),
      playButton.heightAnchor.constraint(equalToConstant: AlbumCollectionCell.playOverlayDiameter),
      playingMark.centerXAnchor.constraint(equalTo: playButton.centerXAnchor),
      playingMark.centerYAnchor.constraint(equalTo: playButton.centerYAnchor),
      playingMark.widthAnchor.constraint(equalToConstant: 18),
      playingMark.heightAnchor.constraint(equalToConstant: 18),

      text.leadingAnchor.constraint(
        equalTo: art.trailingAnchor,
        constant: CassetteTheme.Spacing.md
      ),
      text.trailingAnchor.constraint(
        equalTo: playButton.leadingAnchor,
        constant: -CassetteTheme.Spacing.md
      ),
      text.topAnchor.constraint(equalTo: contentView.topAnchor, constant: CassetteTheme.Spacing.md),
      text.bottomAnchor.constraint(
        equalTo: contentView.bottomAnchor,
        constant: -CassetteTheme.Spacing.md
      ),
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func prepareForReuse() {
    super.prepareForReuse()
    loadTask?.cancel()
    loadTask = nil
    representedImage = nil
    art.image = nil
    onPlayTapped = nil
  }

  func configure(row: RadioRow, playing: Bool) {
    nameLabel.text = row.displayName
    if let info = row.info {
      kickerLabel.text = info.kicker
      descLabel.text = info.description
      kickerLabel.isHidden = false
      descLabel.isHidden = false
    } else {
      kickerLabel.text = row.radio.siteURL?.host ?? ""
      kickerLabel.isHidden = (row.radio.siteURL?.host ?? "").isEmpty
      descLabel.text = nil
      descLabel.isHidden = true
    }
    playingMark.isHidden = !playing
    playButton.isHidden = playing
    playButton.accessibilityLabel = "Play \(row.displayName)"
    nameLabel.textColor = playing ? CassetteTheme.UIColors.orange : CassetteTheme.UIColors.ink

    initials.text = Self.initials(of: row.displayName)
    initials.isHidden = false
    art.image = nil
    art.backgroundColor = RadioTile.fill(accent: row.info?.accent)
    if let image = row.info?.image, !image.isEmpty {
      representedImage = image
      loadTask = Task { @MainActor [weak self] in
        let loaded = await RadioArtLoader.shared.image(for: image)
        guard let self, representedImage == image, let loaded else { return }
        art.image = loaded
        initials.isHidden = true
      }
    }
  }

  private static func initials(of name: String) -> String {
    let parts = name.split(separator: " ").filter { !$0.isEmpty }
    let first = parts.first?.prefix(1) ?? ""
    let second = parts.dropFirst().first?.prefix(1) ?? ""
    let s = (first + second).uppercased()
    return s.isEmpty ? String(name.prefix(2)).uppercased() : s
  }
}

// MARK: - RadiosVC

class RadiosVC: UITableViewController, UISearchResultsUpdating {
  override var sceneTitle: String? { "Radios" }
  static let savedSectionTitle = "Your stations"

  private let account: Account
  private var radios: [Radio] = []
  private var sections: [(title: String, rows: [RadioRow])] = []
  private var query = ""
  private var playingTimer: Timer?
  private var lastPlayingKey = ""
  private let searchController = UISearchController(searchResultsController: nil)

  init(account: Account) {
    self.account = account
    super.init(style: .grouped)
  }

  required init?(coder: NSCoder) {
    fatalError("init(coder:) has not been implemented")
  }

  // MARK: Lifecycle

  override func viewDidLoad() {
    super.viewDidLoad()
    appDelegate.userStatistics.visited(.radios)
    setNavBarTitle(title: sceneTitle ?? "")

    tableView.register(RadioStationCell.self, forCellReuseIdentifier: RadioStationCell.reuseId)
    tableView.rowHeight = UITableView.automaticDimension
    tableView.estimatedRowHeight = 92
    tableView.separatorStyle = .none
    tableView.backgroundColor = .backgroundColor
    tableView.sectionHeaderTopPadding = CassetteTheme.Spacing.sm
    tableView.sectionFooterHeight = 0
    tableView.estimatedSectionFooterHeight = 0

    #if !targetEnvironment(macCatalyst)
      refreshControl = UIRefreshControl()
      refreshControl?.addTarget(self, action: #selector(Self.handleRefresh), for: .valueChanged)
    #endif

    // In-list search over names, networks, moods, eras, genres and cities —
    // "late night", "50s", "Seattle" — which the global Search tab cannot do.
    searchController.searchResultsUpdater = self
    searchController.obscuresBackgroundDuringPresentation = false
    searchController.searchBar.placeholder = "Mood, era, city, or station"
    navigationItem.searchController = searchController
    navigationItem.hidesSearchBarWhenScrolling = true
    definesPresentationContext = true

    NotificationCenter.default.addObserver(
      self,
      selector: #selector(Self.savedDidChange),
      name: RadioSaved.didChange,
      object: nil
    )

    reloadFromLibrary()
  }

  @objc
  private func savedDidChange() {
    rebuildRows()
  }

  override func viewWillAppear(_ animated: Bool) {
    super.viewWillAppear(animated)
    navigationController?.navigationBar.prefersLargeTitles = true
    startPlayingWatch()
  }

  override func viewIsAppearing(_ animated: Bool) {
    super.viewIsAppearing(animated)
    extendSafeAreaToAccountForMiniPlayer()
    updateFromRemote()
  }

  override func viewWillDisappear(_ animated: Bool) {
    super.viewWillDisappear(animated)
    playingTimer?.invalidate()
    playingTimer = nil
  }

  // MARK: Data

  private func reloadFromLibrary() {
    radios = appDelegate.storage.main.library.getRadios(for: account)
    rebuildRows()
  }

  private func rebuildRows() {
    let catalog = RadioCatalog.shared
    var rows = radios.map { RadioRow(radio: $0, info: catalog.station(forStreamUrl: $0.url)) }
    let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    if !q.isEmpty {
      rows = rows.filter { row in
        (row.info?.searchText ?? row.displayName.lowercased()).contains(q)
      }
    }
    var grouped: [String: [RadioRow]] = [:]
    for row in rows { grouped[row.section, default: []].append(row) }
    // cassette 2026-10-21: the stations this person saved lead the dial, latest save
    // first, and stay in their own sections below too.
    let rowsByURL = Dictionary(
      rows.map { (RadioCatalog.normalize($0.radio.url), $0) },
      uniquingKeysWith: { a, _ in a }
    )
    let savedRows = RadioSaved.shared.slugs.compactMap { slug in
      catalog.station(slug: slug).flatMap { rowsByURL[RadioCatalog.normalize($0.streamUrl)] }
    }
    let order = catalog.sectionOrder
    func rank(_ title: String) -> (Int, String) {
      if title == "Other stations" { return (order.count + 1, title) }
      if let i = order.firstIndex(of: title) { return (i, title) }
      return (order.count, title)
    }
    sections = grouped.keys
      .sorted { rank($0) < rank($1) }
      .map { title in
        (
          title,
          grouped[title]!
            .sorted {
              $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending
            }
        )
      }
    if !savedRows.isEmpty {
      sections.insert((Self.savedSectionTitle, savedRows), at: 0)
    }
    tableView.reloadData()
    updateContentUnavailable()
  }

  private func updateContentUnavailable() {
    if sections.isEmpty {
      contentUnavailableConfiguration = query
        .isEmpty ? emptyContentConfig : UIContentUnavailableConfiguration.search()
    } else {
      contentUnavailableConfiguration = nil
    }
  }

  private lazy var emptyContentConfig: UIContentUnavailableConfiguration = {
    var config = UIContentUnavailableConfiguration.empty()
    config.image = .radio
    config.text = "No stations yet"
    config
      .secondaryText =
      "Stations saved on the web arrive here through your Cassette Player. Pull down to refresh."
    return config
  }()

  private func updateFromRemote() {
    guard appDelegate.storage.settings.user.isOnlineMode else { return }
    Task { @MainActor in
      async let cloud: () = RadioCatalog.shared.refreshFromCloud()
      async let saved: () = RadioSaved.shared.refresh()
      do {
        try await self.appDelegate.getMeta(self.account.info).librarySyncer.syncRadios()
      } catch {
        // cassette Patch 040: tab-appear background sync.
        self.appDelegate.eventLogger.report(topic: "Radios Sync", error: error, isBackground: true)
      }
      await cloud
      await saved
      self.reloadFromLibrary()
    }
  }

  @objc
  private func handleRefresh(refreshControl: UIRefreshControl) {
    guard appDelegate.storage.settings.user.isOnlineMode else {
      refreshControl.endRefreshing()
      return
    }
    Task { @MainActor in
      async let cloud: () = RadioCatalog.shared.refreshFromCloud()
      async let saved: () = RadioSaved.shared.refresh(force: true)
      do {
        try await self.appDelegate.getMeta(self.account.info).librarySyncer.syncRadios()
      } catch {
        // cassette Patch 040: pull-to-refresh sync — silent.
        self.appDelegate.eventLogger.report(topic: "Radios Sync", error: error, isBackground: true)
      }
      await cloud
      await saved
      self.reloadFromLibrary()
      refreshControl.endRefreshing()
    }
  }

  // MARK: Playing indicator

  private var playingKey: String {
    guard appDelegate.player.isPlaying,
          let current = appDelegate.player.currentlyPlaying as? Radio else { return "" }
    return current.id
  }

  private func isPlaying(_ row: RadioRow) -> Bool {
    let key = playingKey
    return !key.isEmpty && row.radio.id == key
  }

  private func startPlayingWatch() {
    playingTimer?.invalidate()
    lastPlayingKey = playingKey
    playingTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self else { return }
        let key = self.playingKey
        guard key != self.lastPlayingKey else { return }
        self.lastPlayingKey = key
        self.tableView.reloadData()
      }
    }
  }

  // MARK: Search

  func updateSearchResults(for searchController: UISearchController) {
    let next = searchController.searchBar.text ?? ""
    guard next != query else { return }
    query = next
    rebuildRows()
  }

  // MARK: Table

  override func numberOfSections(in tableView: UITableView) -> Int { sections.count }

  override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
    sections[section].rows.count
  }

  override func tableView(
    _ tableView: UITableView,
    viewForHeaderInSection section: Int
  )
    -> UIView? {
    let container = UIView()
    let label = UILabel()
    label.attributedText = NSAttributedString(
      string: sections[section].title.uppercased(),
      attributes: [
        .kern: 1.4,
        .font: UIFont.cassette(.sectionLabel),
        .foregroundColor: CassetteTheme.UIColors.ink3,
      ]
    )
    label.translatesAutoresizingMaskIntoConstraints = false
    container.addSubview(label)
    NSLayoutConstraint.activate([
      label.leadingAnchor.constraint(
        equalTo: container.leadingAnchor,
        constant: CassetteTheme.Spacing.lg
      ),
      label.trailingAnchor.constraint(
        lessThanOrEqualTo: container.trailingAnchor,
        constant: -CassetteTheme.Spacing.lg
      ),
      label.topAnchor.constraint(equalTo: container.topAnchor, constant: CassetteTheme.Spacing.md),
      label.bottomAnchor.constraint(
        equalTo: container.bottomAnchor,
        constant: -CassetteTheme.Spacing.xs
      ),
    ])
    return container
  }

  override func tableView(
    _ tableView: UITableView,
    cellForRowAt indexPath: IndexPath
  )
    -> UITableViewCell {
    let cell = tableView.dequeueReusableCell(
      withIdentifier: RadioStationCell.reuseId,
      for: indexPath
    ) as! RadioStationCell
    let row = sections[indexPath.section].rows[indexPath.row]
    cell.configure(row: row, playing: isPlaying(row))
    cell.onPlayTapped = { [weak self] in self?.play(row.radio) }
    return cell
  }

  /// cassette 2026-10-21: a station opens its page (what's on, what it just played, about,
  /// similar stations, Save); the row's disc tunes in. A hub station the registry does not
  /// know has no page, so its tap still tunes in.
  override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
    tableView.deselectRow(at: indexPath, animated: true)
    let row = sections[indexPath.section].rows[indexPath.row]
    guard let info = row.info else {
      play(row.radio)
      return
    }
    navigationController?.pushViewController(
      RadioStationVC(account: account, station: info),
      animated: true
    )
  }

  /// The whole dial in display order is the context (each station once), so Next /
  /// Previous on the player move between stations the way a tuner would.
  private func play(_ radio: Radio) {
    var seen = Set<String>()
    let all = sections.flatMap(\.rows).map(\.radio).filter { seen.insert($0.id).inserted }
    guard let index = all.firstIndex(where: { $0.id == radio.id }) else { return }
    appDelegate.player.play(context: PlayContext(
      name: sceneTitle ?? "Radio",
      index: index,
      playables: all
    ))
    lastPlayingKey = radio.id
    tableView.reloadData()
  }

  override func tableView(
    _ tableView: UITableView,
    contextMenuConfigurationForRowAt indexPath: IndexPath,
    point: CGPoint
  )
    -> UIContextMenuConfiguration? {
    let row = sections[indexPath.section].rows[indexPath.row]
    return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { [weak self] _ in
      var actions: [UIMenuElement] = [
        UIAction(title: "Play", image: CassetteIcon.play.symbolImage) { _ in
          MainActor.assumeIsolated { self?.play(row.radio) }
        },
      ]
      if let slug = row.info?.slug {
        let saved = RadioSaved.shared.isSaved(slug)
        actions.append(UIAction(
          title: saved ? "Remove from Your Stations" : "Save",
          image: (saved ? CassetteIcon.check : CassetteIcon.plus).symbolImage
        ) { _ in
          MainActor.assumeIsolated { RadioSaved.shared.toggle(slug) }
        })
      }
      return UIMenu(children: actions)
    }
  }
}

// MARK: - RadioTile

/// A station without a logo gets a label, not a blank: its accent blended into
/// the chassis with its initials in ink. Consistent across the dial, the Home
/// shelf and the web, so the dial reads as one product rather than a directory
/// of other people's artwork.
enum RadioTile {
  static func fill(accent: String?) -> UIColor {
    guard let accent, let color = UIColor(cassetteHexString: accent) else {
      return CassetteTheme.UIColors.bg3
    }
    return color.radioMixed(with: CassetteTheme.UIColors.bg3, fraction: 0.5)
  }
}

extension UIColor {
  /// "#rrggbb" → color; nil for anything else.
  convenience init?(cassetteHexString: String) {
    var hex = cassetteHexString.trimmingCharacters(in: .whitespacesAndNewlines)
    if hex.hasPrefix("#") { hex.removeFirst() }
    guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
    self.init(
      red: CGFloat((value >> 16) & 0xFF) / 255,
      green: CGFloat((value >> 8) & 0xFF) / 255,
      blue: CGFloat(value & 0xFF) / 255,
      alpha: 1
    )
  }

  /// Linear blend toward `other` (0 = self, 1 = other).
  func radioMixed(with other: UIColor, fraction: CGFloat) -> UIColor {
    var r1: CGFloat = 0, g1: CGFloat = 0, b1: CGFloat = 0, a1: CGFloat = 0
    var r2: CGFloat = 0, g2: CGFloat = 0, b2: CGFloat = 0, a2: CGFloat = 0
    getRed(&r1, green: &g1, blue: &b1, alpha: &a1)
    other.getRed(&r2, green: &g2, blue: &b2, alpha: &a2)
    let f = max(0, min(1, fraction))
    return UIColor(
      red: r1 + (r2 - r1) * f,
      green: g1 + (g2 - g1) * f,
      blue: b1 + (b2 - b1) * f,
      alpha: 1
    )
  }
}

// MARK: - RadioShelf

/// The order behind the Home "Radios" shelf. What this person tunes to comes
/// first (recency and play count on the station itself), then stations whose
/// genres match what they have been PLAYING lately (the last 30 days, recent plays
/// weighted up), with the genres they own as a smaller background signal, then live
/// stations for breadth. Capped per network so SomaFM or NTS cannot fill the row.
/// No network, no model.
///
/// cassette 2026-10-21: the stations this person saved come first, latest save first,
/// ahead of everything scored and outside the per-network cap.
///
/// cassette 2026-10-20: genre affinity follows recent listening (founder ask). Station
/// moods (late-night, sunny, chill, ...) are a separate nine-word vocabulary from the
/// song moods, so they are not matched against the listening profile.
enum RadioShelf {
  static func normalize(_ s: String) -> String {
    s.lowercased()
      .replacingOccurrences(of: "&", with: " and ")
      .replacingOccurrences(of: #"[^a-z0-9]+"#, with: " ", options: .regularExpression)
      .trimmingCharacters(in: .whitespaces)
  }

  private struct Scored {
    let radio: Radio
    let score: Double
    let network: String
    let name: String
  }

  @MainActor
  static func rank(
    radios: [Radio],
    libraryGenres: [String: Int],
    recentGenres: [String: Double] = [:],
    savedSlugs: [String] = [],
    now: Date = Date(),
    perNetworkCap: Int = 3
  )
    -> [Radio] {
    let catalog = RadioCatalog.shared
    let genreWeight = blendedGenreWeights(library: libraryGenres, recent: recentGenres)
    let knownGenres = genreWeight.keys.filter { !$0.isEmpty }

    var savedRank: [String: Int] = [:]
    for (i, slug) in savedSlugs.enumerated() where savedRank[slug] == nil { savedRank[slug] = i }
    var saved: [(rank: Int, radio: Radio)] = []
    var scored: [Scored] = []
    for radio in radios {
      let info = catalog.station(forStreamUrl: radio.url)
      if let slug = info?.slug, let rank = savedRank[slug] {
        saved.append((rank, radio))
        continue
      }
      var score = 0.0
      // What you tune to.
      if let last = radio.lastTimePlayed {
        let days = now.timeIntervalSince(last) / 86_400
        if days < 1 { score += 6 } else if days < 7 { score += 4 } else if days < 30 { score += 2 }
      }
      if radio.playCount > 0 { score += min(3, log2(Double(radio.playCount) + 1)) }
      // What you own: a station genre that matches a genre in the library.
      if let info {
        var affinity = 0.0
        for genre in info.genres.map(normalize) where !genre.isEmpty {
          let hit = knownGenres.first { $0 == genre || $0.contains(genre) || genre.contains($0) }
          if let hit, let weight = genreWeight[hit] {
            affinity += 2 * weight
          }
        }
        score += min(3, affinity)
        if info.isLive { score += 0.25 }
        if info.hasNowPlaying { score += 0.25 }
      }
      scored.append(Scored(
        radio: radio, score: score,
        network: info?.sourceLabel ?? "Other", name: (info?.name ?? radio.title).lowercased()
      ))
    }
    scored.sort { ($0.score, $1.name) > ($1.score, $0.name) }

    // Variety: at most `perNetworkCap` per network on the first pass; a second
    // pass fills from the leftovers so the shelf is never short.
    var out: [Radio] = saved.sorted { $0.rank < $1.rank }.map(\.radio)
    var perNetwork: [String: Int] = [:]
    var leftovers: [Scored] = []
    for s in scored {
      if perNetwork[s.network, default: 0] < perNetworkCap {
        perNetwork[s.network, default: 0] += 1
        out.append(s.radio)
      } else {
        leftovers.append(s)
      }
    }
    out.append(contentsOf: leftovers.map(\.radio))
    return out
  }

  /// Share of recent listening vs the library in a station's genre affinity.
  static let recentGenreShare = 0.7

  /// Each genre's weight in [0, 1]: 70% how much of the last month's listening it is,
  /// 30% how much of the library. With no recent plays the library alone decides, as
  /// before; with no library genres, recent listening alone.
  static func blendedGenreWeights(library: [String: Int], recent: [String: Double]) -> [String: Double] {
    let maxLibrary = Double(library.values.max() ?? 0)
    let maxRecent = recent.values.max() ?? 0
    let recentShare = maxRecent > 0 ? (maxLibrary > 0 ? recentGenreShare : 1) : 0
    var out: [String: Double] = [:]
    if maxLibrary > 0 {
      for (genre, n) in library { out[genre, default: 0] += (1 - recentShare) * Double(n) / maxLibrary }
    }
    if maxRecent > 0 {
      for (genre, w) in recent { out[genre, default: 0] += recentShare * w / maxRecent }
    }
    return out
  }
}

// MARK: - RadioShelfCell

/// A station card for the Home carousel: the logo or the tile, the station's
/// name, and the network line. Same width as the album cards beside it.
///
/// Founder, 2026-10-21: a station with no logo showed two initials on its colour mixed half
/// into the chassis ("the radio covers look gross"). It now gets the car's word picture, its
/// colour running into the dark with its name in our type (CarPlayStyle.phoneWordArt), and
/// the card takes the album tiles' shape (their corner, no outline), so the row reads like
/// the shelves around it.
final class RadioShelfCell: UICollectionViewCell {
  // `typeName` comes from the kit's NSObject extension ("RadioShelfCell").

  private let art = UIImageView()
  private let initials = UILabel()
  private let nameLabel = UILabel()
  private let kickerLabel = UILabel()
  /// cassette 2026-10-21: the tile opens the station's page; the disc tunes in, as on the
  /// record tiles beside it.
  private let playButton = AlbumCollectionCell.makePlayOverlayButton()
  var onPlayTapped: (() -> ())?
  private var representedImage: String?
  private var loadTask: Task<(), Never>?

  override init(frame: CGRect) {
    super.init(frame: frame)
    art.contentMode = .scaleAspectFill
    art.clipsToBounds = true
    art.layer.cornerRadius = CassetteRadius.artworkTile
    art.backgroundColor = CassetteTheme.UIColors.bg3

    initials.font = UIFont.cassette(.sectionTitle)
    initials.textColor = CassetteTheme.UIColors.ink
    initials.textAlignment = .center

    nameLabel.font = UIFont.cassette(.rowTitle)
    nameLabel.textColor = CassetteTheme.UIColors.ink
    nameLabel.numberOfLines = 1
    nameLabel.lineBreakMode = .byTruncatingTail

    kickerLabel.font = UIFont.cassette(.cardSubtitle)
    kickerLabel.textColor = CassetteTheme.UIColors.ink2
    kickerLabel.numberOfLines = 1
    kickerLabel.lineBreakMode = .byTruncatingTail

    playButton.addAction(UIAction { [weak self] _ in self?.onPlayTapped?() }, for: .touchUpInside)
    for v in [art, initials, nameLabel, kickerLabel, playButton] {
      v.translatesAutoresizingMaskIntoConstraints = false
      contentView.addSubview(v)
    }
    NSLayoutConstraint.activate([
      playButton.widthAnchor.constraint(equalToConstant: AlbumCollectionCell.playOverlayDiameter),
      playButton.heightAnchor.constraint(equalToConstant: AlbumCollectionCell.playOverlayDiameter),
      playButton.trailingAnchor.constraint(equalTo: art.trailingAnchor, constant: -8),
      playButton.bottomAnchor.constraint(equalTo: art.bottomAnchor, constant: -8),
      art.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      art.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      art.topAnchor.constraint(equalTo: contentView.topAnchor),
      art.heightAnchor.constraint(equalTo: art.widthAnchor),
      initials.centerXAnchor.constraint(equalTo: art.centerXAnchor),
      initials.centerYAnchor.constraint(equalTo: art.centerYAnchor),
      initials.widthAnchor.constraint(equalTo: art.widthAnchor),
      nameLabel.topAnchor.constraint(equalTo: art.bottomAnchor, constant: CassetteTheme.Spacing.sm),
      nameLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      nameLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      kickerLabel.topAnchor.constraint(equalTo: nameLabel.bottomAnchor, constant: 2),
      kickerLabel.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
      kickerLabel.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
      kickerLabel.bottomAnchor.constraint(lessThanOrEqualTo: contentView.bottomAnchor),
    ])
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

  override func prepareForReuse() {
    super.prepareForReuse()
    loadTask?.cancel()
    loadTask = nil
    representedImage = nil
    art.image = nil
    onPlayTapped = nil
    showsPlayButton = true
  }

  /// Off for a tile with nothing to play from (the station page's similar stations that
  /// are not on the hub).
  var showsPlayButton = true {
    didSet { playButton.isHidden = !showsPlayButton }
  }

  func display(radio: Radio, info: RadioCatalogStation?) {
    show(name: info?.name ?? radio.title, kicker: info?.kicker ?? (radio.siteURL?.host ?? ""), info: info)
  }

  /// A registry station, whether or not the hub holds it (the station page's similar row).
  func display(station: RadioCatalogStation) {
    show(name: station.name, kicker: station.kicker, info: station)
  }

  private func show(name: String, kicker: String, info: RadioCatalogStation?) {
    nameLabel.text = name
    kickerLabel.text = kicker
    initials.text = RadioShelfCell.initials(of: name)
    // The word picture until (unless) the station's logo lands; the initials stay hidden.
    initials.isHidden = true
    art.backgroundColor = RadioTile.fill(accent: info?.accent)
    let side = bounds.width > 0 ? bounds.width : AlbumCarousel.mockItemWidth
    let color = info.flatMap { UIColor(cassetteHexString: $0.accent) } ?? CassetteTheme.UIColors.bg3
    art.image = CarPlayStyle.phoneWordArt(
      word: name,
      color: color,
      side: side,
      scale: traitCollection.displayScale > 0 ? traitCollection.displayScale : 3
    )
    if let image = info?.image, !image.isEmpty {
      representedImage = image
      if let cached = RadioArtLoader.shared.cachedImage(for: image) {
        art.image = cached
        return
      }
      loadTask = Task { @MainActor [weak self] in
        let loaded = await RadioArtLoader.shared.image(for: image)
        guard let self, representedImage == image, let loaded else { return }
        art.image = loaded
      }
    }
  }

  private static func initials(of name: String) -> String {
    let parts = name.split(separator: " ").filter { !$0.isEmpty }
    let first = parts.first?.prefix(1) ?? ""
    let second = parts.dropFirst().first?.prefix(1) ?? ""
    let s = (first + second).uppercased()
    return s.isEmpty ? String(name.prefix(2)).uppercased() : s
  }
}
