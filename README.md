# Viu Live TV

A clean, native **Live TV** app for iPhone and iPad, built entirely with **SwiftUI** for **iOS 17+**, with a native **Liquid Glass** interface on iOS 26, native **Light / Dark Mode**, and a custom app icon.

It is a ground-up iOS counterpart of the Viu Android TV app (`com.viu.viuapp` v1.12), using the same backend at `api.viu.rs` — **Live TV only**: no movies, no series, no video-on-demand.

Generated with the help of Claude (via claude.ai), then packaged as a standard Xcode project, published under the MIT License, and built into an unsigned IPA by GitHub Actions on a macOS runner.

![Platform](https://img.shields.io/badge/platform-iOS%2017%2B-black)
![Swift](https://img.shields.io/badge/Swift-5.0-orange)
![SwiftUI](https://img.shields.io/badge/UI-SwiftUI-blue)
![License](https://img.shields.io/badge/license-MIT-green)

## Features

- **First-boot Viu login** — the first time you open the app it asks for your Viu username and password and signs in against `POST /api/4/authenticate`. The session token is stored in the **Keychain** (never in plain text files); only your username is remembered for the form. You can also paste a session token directly.
- **Channels + Favorites first** — after setup, the first thing you see is the channel list with a **Favorites** filter. Search, pull-to-refresh, channel logos, and **now / next** programme info with a progress bar from the EPG.
- **Live TV only** — channels come from the Viu EPG feeds (`epg_tags.php` + `epgjson.php` / `epgjsonV2.php`, the same feeds the Android app uses). Tapping a channel resolves its stream with `GET /api/4/live-tv/links/{stream_id}/{token}`.
- **Native Apple video player** — `AVPlayer` in `AVPlayerViewController`, with:
  - **Picture in Picture** (including auto-PiP from inline playback)
  - **AirPlay** — route picker in the player, `allowsExternalPlayback`
  - Live playback with the system playback controls, and a **LIVE** badge
- **External players** — open any channel in **VLC**, **Infuse**, **OutPlayer**, **nPlayer** and more, or pick your default player in Settings. If the chosen app isn't installed you get a clear message and the share-sheet fallback.
- **Favorites** — star channels locally (persisted on device) and synced to the Viu account with the same `save/stream/favorite` / `remove/stream/favorite` endpoints the Android app uses.
- **Native Liquid Glass on iOS 26+** — channel cards, toolbars and the player overlay use SwiftUI's native `glassEffect` in a `GlassEffectContainer`.
- **Graceful fallback on iOS 17–25** — the same UI uses adaptive materials, so the app still runs on iOS 17.
- **Dynamic Light / Dark Mode** — follows the system by default, with a System / Light / Dark override in Settings.
- **Portrait + landscape, iPhone + iPad** — iPad gets a two-column split view (channel list sidebar, player detail); iPhone uses a navigation stack and the player expands in landscape.
- **Account in Settings** — account info (`/api/4/accountinfo/{token}`: premium status, expiry, created date) and **Log out**, which calls `/api/4/logout/{token}` and clears the Keychain token.
- **Custom app icon** — a 1024×1024 VIU icon (red on black, matching the Android app's branding) with dedicated Dark and Tinted appearance variants for iOS 18+/26 home screens.

## How it talks to Viu

All requests use the Android app's user agent, `viutvapp/1.12 LH`.

| Purpose | Request |
|---|---|
| Login | `POST https://api.viu.rs/api/4/authenticate` — JSON `{"user": "…", "password": "…"}` → `{"token": "…", "error": 0, "message": "…"}` |
| Channel categories | `GET https://api.viu.rs/epg_tags.php?token={token}` → `[{"displayname": "…", "parameter_name": "…"}]` |
| Channels + EPG | `GET https://api.viu.rs/epgjson.php?token={token}&tag={tag}` and `GET https://api.viu.rs/epgjsonV2.php` → array of channels with `stream_id`, `name`, `stream_icon`, `current_show` and a `schedule` (`name`, `timestart`, `timeend`, `timezone`) |
| Play a channel | `GET https://api.viu.rs/api/4/live-tv/links/{stream_id}/{token}` → `{"live_link": "…", "stream_display_name": "…", "is_favorite": …}` |
| Favorite / unfavorite | `POST …/api/4/save/stream/favorite/{token}` / `POST …/api/4/remove/stream/favorite/{token}` — JSON `{"stream_id": …, "title_id": …, "title_type": …}` |
| Account | `GET …/api/4/accountinfo/{token}` |
| Service status | `GET …/api/4/checkservice/{token}` |
| Logout | `GET …/api/4/logout/{token}` |

Stream URLs can be plain HTTP on some channels, so the app allows arbitrary loads in its `Info.plist` (`NSAllowsArbitraryLoads`) — the same streams the Android app plays would otherwise be blocked by App Transport Security.

## Requirements

- iOS 17.0 or later (Liquid Glass requires iOS 26.0 or later)
- Xcode 26 or later to build the Liquid Glass code paths (Xcode 15/16 cannot compile the iOS 26 glass APIs used here); the GitHub Actions workflow uses a `macos-26` runner for this reason
- Swift 5.0
- No third-party dependencies
- A Viu account for `viu.rs` to watch live channels

## Project Structure

```
viu-live-tv/
├── ViuLiveTV.xcodeproj/            # Xcode project + shared ViuLiveTV scheme
├── ViuLiveTV/
│   ├── ViuLiveTVApp.swift          # @main app entry point, appearance, audio session
│   ├── ContentView.swift           # Root: login gate -> Channels/Favorites, iPad split view
│   ├── Models.swift                # Channel/EPG, LiveLinks, Login, Account models (exact API shapes)
│   ├── APIClient.swift             # api.viu.rs client (async/await, token-in-path, UA header)
│   ├── Keychain.swift              # Keychain wrapper for the session token
│   ├── AuthViewModel.swift         # Signed-in state, login/logout, persisted username
│   ├── LoginView.swift             # First-boot Viu login (+ use-a-token option)
│   ├── ChannelListView.swift       # Channels + Favorites list, search, pull-to-refresh
│   ├── ChannelRowView.swift        # Logo, name, now/next EPG + progress, favorite star
│   ├── PlayerView.swift            # AVPlayerViewController: PiP, AirPlay, external playback
│   ├── EPGDateParser.swift         # Parses the EPG's "yyyy-MM-dd HH:mm:ss" schedule times
│   ├── AppSettings.swift           # Appearance, external-player and quality preferences
│   ├── ExternalPlayer.swift        # VLC / Infuse / OutPlayer / nPlayer URL schemes + fallback
│   ├── FavoritesStore.swift        # Local favorites persistence + server sync
│   ├── EPGStore.swift              # Loads tags + EPG, merges channels, now/next lookup
│   ├── SettingsView.swift          # Account, player choice, appearance, About, logout
│   ├── GlassHelpers.swift          # Liquid Glass (iOS 26) with Material fallback (iOS 17-25)
│   ├── Info.plist                  # Orientations, background audio, ATS, external-player schemes
│   └── Assets.xcassets/            # App icon (Dark + Tinted variants), accent colour
├── .github/workflows/
│   ├── build-ipa.yml               # GitHub Actions: builds an unsigned IPA on macOS
│   └── simulator-test.yml          # GitHub Actions: boots a virtual iPhone on iOS 26, installs + launches the app, screenshots Light/Dark
├── LICENSE                         # MIT License
└── README.md
```

## Getting Started

### Run in Xcode

1. Clone the repo:

   ```bash
   git clone https://github.com/c12n/viu-live-tv.git
   cd viu-live-tv
   ```

2. Open the project:

   ```bash
   open ViuLiveTV.xcodeproj
   ```

3. Select an iPhone or iPad simulator (iOS 17+) or a connected device, then Run (`Cmd+R`).

To run on a physical device, select your own Development Team in **Signing & Capabilities** for the `ViuLiveTV` target — Apple requires a team to sign apps for devices.

4. On first launch, sign in with your Viu account. After that you'll land straight on the channel list every time.

### Build an IPA locally (Mac only)

On a Mac with Xcode:

```bash
xcodebuild \
  -project ViuLiveTV.xcodeproj \
  -scheme ViuLiveTV \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath build/ViuLiveTV.xcarchive \
  archive \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" DEVELOPMENT_TEAM=""
mkdir -p Payload
cp -R build/ViuLiveTV.xcarchive/Products/Applications/ViuLiveTV.app Payload/
zip -r ViuLiveTV.ipa Payload
```

The unsigned IPA can be sideloaded with AltStore, SideStore, Sideloadly or a similar tool using your own Apple ID.

### GitHub Actions

Every push to `main` runs the **Build IPA** workflow on a `macos-26` runner and uploads `ViuLiveTV.ipa` as a build artifact. Tagged releases attach the IPA to the release.

## Notes

- This is an unofficial, personal-use client for an account you own. It only implements Live TV; movies and series endpoints from the Android app are intentionally not used.
- `vid.to` as typed in a browser currently redirects to a different service (viu.com) — this app follows the APK, whose backend is `api.viu.rs`, and that is the account the login screen expects.
- Channel availability, logos and EPG data come straight from Viu's feeds and can change on their side; the app decodes them flexibly and never shows a hard-coded channel list as a substitute for live data, except for clearly-labelled sample channels when the feed can't be reached at all (for example before/without a valid token).

## License

MIT — see [LICENSE](LICENSE). Copyright (c) 2026 c12n Apps.
