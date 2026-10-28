# Viu Live TV

# The project is unofficial & strictly a hobby project 

A clean, native **Live TV** app for iPhone and iPad, built entirely with **SwiftUI** for **iOS 17+**, with a native **Liquid Glass** interface on iOS 26, native **Light / Dark Mode**, and a custom app icon.

It is a ground-up iOS counterpart of the Viu Android TV app (`com.viu.viuapp` v1.12), using the same backend at `api.viu.rs` — **Live TV only**: no movies, no series, no video-on-demand. An **active VIP subscription is required** to use the app (see below).

Generated with the help of Claude (via claude.ai), then packaged as a standard Xcode project, published under the MIT License, and built into an unsigned IPA by GitHub Actions on a macOS runner.

![Platform](https://img.shields.io/badge/platform-iOS%2017%2B-black)
![Swift](https://img.shields.io/badge/Swift-5.0-orange)
![SwiftUI](https://img.shields.io/badge/UI-SwiftUI-blue)
![License](https://img.shields.io/badge/license-MIT-green)

**Latest release: [v1.3.0](https://github.com/c12n/viu-live-tv/releases/tag/v1.3.0)** — download `ViuLiveTV.ipa` from the release and sideload it with AltStore, SideStore, Sideloadly or a similar tool using your own Apple ID.

## Features

- **First-boot Viu login** — the first time you open the app it asks for your Viu username and password and signs in against `POST /api/4/authenticate`. The session token is stored in the **Keychain** (never in plain text files); only your username is remembered for the form. You can also paste a session token directly.
- **VIP subscription gate** — after sign-in and on every launch, the app checks the account's premium status (`/api/4/accountinfo`). Accounts without an active subscription are stopped at a **"Non-VIP Found"** screen with a **Renew or Purchase** button that opens the official member website ([viu.to](https://viu.to)), an "I've Renewed — Check Again" re-check, and a sign-out option. A network hiccup during the check never locks a subscriber out — the gate only triggers on a definite non-active status.
- **Channels + Favorites first** — after setup, the first thing you see is the channel list, with a **YouTube-style floating tab bar** (Channels / Favorites / Settings). Search, pull-to-refresh, channel logos, and **now / next** programme info with a progress bar from the EPG.
- **Live TV categories** — a scrollable chip row with the categories from your account (Hot Right Now, Hockey, Canada, USA, UK, News, Kids, Sports, ESPN Plus, TSN Plus, and 60+ more). Tap one to filter the channel list instantly, or **swipe left / right across the list** to move between categories. Categories can be hidden in Settings and reordered by long-press dragging a chip.
- **Fast loading, cached guide** — the guide loads from a single all-channels feed (one request; categories are read from each channel's own tags, with a parallel per-category merge as fallback) and is **cached on disk**, so later launches show your channels instantly while refreshing in the background. The cache is cleared on sign-out.
- **Video-only native player** — `AVPlayer` in `AVPlayerViewController`. The player screen is *only the video*: no channel name, no badges, no permanent buttons. A single auto-hiding **Guide** button (tap to reveal) opens the **channel guide** over the video in portrait and landscape — pick a channel and playback switches in place.
  - **Gestures** — **double-tap** the video to pause / resume; **swipe right from the left edge** to go back to the channel list.
  - **Picture in Picture** — including auto-PiP when you leave the app mid-stream.
  - **Background play** — audio keeps playing with the screen locked or the app backgrounded, with **Now Playing** info and lock-screen / Control Centre play-pause (the app declares the `audio` background mode). Background Play and PiP each have a Settings toggle, and the Guide button sits clear of the player's native controls (AirPlay, PiP, volume, play/pause stay visible).
  - **Chromecast** — cast any channel to a Chromecast or Android TV on the same Wi-Fi from the cast button next to Guide in the player (the app speaks the CASTV2 protocol directly to the TV's default media receiver — discovery, connect, channel loading and play/pause/stop remote control — with no third-party SDK). While casting, the player screen becomes the remote, and Guide picks are sent to the TV. AirPlay remains available from the native player's controls.
  - **AirPlay** — from the player's own controls (`allowsExternalPlayback`).
  - **Visible errors, self-healing** — if a stream fails, the player retries once with a fresh stream link, then shows the actual error with Try Again / Open in External Player instead of a black screen.
  - **Rotation-safe** — the layout is chosen by device (iPhone stack / iPad split), never by the current size class, so rotating mid-stream never rebuilds or restarts playback.
- **External players** — open any channel in **VLC**, **Infuse**, **OutPlayer**, **nPlayer** and more from the channel's menu, or pick your default player in Settings. If the chosen app isn't installed you get a clear message and the share-sheet fallback.
- **Favorites** — heart channels locally (persisted on device) and synced to the Viu account with the same `save/stream/favorite` / `remove/stream/favorite` endpoints the Android app uses. **Swipe right** on a channel and tap the heart button to favorite / unfavorite it, tap the heart on the row, or use the long-press menu.
- **Haptics** — light tactile feedback on channel taps, category chips and player taps; a firmer tap on favorite changes and double-tap pause. Can be turned off in Settings → Appearance.
- **Parental controls** — a Settings section (off by default): a 4-digit PIN (stored in the Keychain; factory default **0000** — you're asked to set your own when you turn the controls on) and per-channel locks — locked channels show a lock icon next to their name in the channel list, Favorites and search, and ask for the PIN before playing (in the app, from the channel guide, or in an external player). The PIN screen is styled after the iOS passcode screen (black background, round glass keys), with a **Forgot PIN?** button that emails a 6-digit reset code to the Viu account email; entering it resets the PIN to 0000. Turning the controls off asks for the PIN; signing out and back in — or reinstalling the app — also resets the PIN to 0000. **Kids Mode** (same section) limits the whole app to the Kids category, Favorites included — the PIN is only needed to turn Kids Mode off.
- **Sports Mode** — a Settings toggle (off by default, no PIN): only sports categories are shown (anything with "Sport" in the name, plus Hockey, ESPN+, TSN+ and similar), and the All view becomes all sports channels.
- **Accent color** — Settings → Appearance: red (default), blue, purple, pink, orange, green or teal, each with Light/Dark variants chosen to stay visible in both modes. The color applies across the app (tab bar, category chips, LIVE badge, progress bars, buttons) and switches the app icon to a matching alternate (see below).
- **Settings data tools** — Clear Cache shows how much data the app has used before clearing; Clear Favorites removes every favorite on the device and on the website; Restore Defaults resets category visibility and order.
- **Native Liquid Glass on iOS 26+** — channel cards, toolbars and player chrome use SwiftUI's native `glassEffect`, with a graceful Material fallback on iOS 17–25.
- **Dynamic Light / Dark Mode** — follows the system by default, with a System / Light / Dark override in Settings.
- **Portrait + landscape, iPhone + iPad** — iPad gets a two-column split view (channel list sidebar, player detail); iPhone uses a navigation stack.
- **Diagnostics** — Settings → Channel Loading Diagnostics probes every endpoint live and produces a shareable, token-free report.
- **Account in Settings** — account info (premium status, expiry, created date) and **Sign Out**, which calls `/api/4/logout/{token}`, clears the Keychain token and the cached guide.
- **Custom app icon** — a 1024×1024 VIU icon (red block letters with a Liquid Glass effect on black) with dedicated Dark and Tinted appearance variants for iOS 18+/26 home screens. Matching alternate icons in blue, purple, pink, orange, green and teal are bundled and applied automatically when the accent color changes.

## How it talks to Viu

All requests use the Android app's user agent, `viutvapp/1.12 LH` (the stream player sends it too, via `AVURLAsset` header fields).

| Purpose | Request |
|---|---|
| Login | `POST https://api.viu.rs/api/4/authenticate` — JSON `{"user": "…", "password": "…"}` → `{"token": "…", "error": 0, "message": "…"}` |
| Channel categories | `GET https://api.viu.rs/epg_tags.php?token={token}` → `[{"displayname": "…", "parameter_name": "…"}]` |
| Channels + EPG | `GET https://api.viu.rs/epgjson.php?token={token}&tag={tag}` — the app fetches the single `ALL` feed first (1,145 channels) and falls back to a parallel per-tag merge → array of channels with `stream_id`, `name`, `stream_icon`, `tags`, `category_id` and a `schedule` (`name`, `description`, `timestart`, `timeend`, `timezone`) |
| Play a channel | `GET https://api.viu.rs/api/4/live-tv/links/{stream_id}/{token}` → `{"live_link": "…", "stream_display_name": "…", "is_favorite": …}` — a standard HLS playlist (H.264 + AAC in MPEG-TS segments), which `AVPlayer` plays natively |
| Favorite / unfavorite | `POST …/api/4/save/stream/favorite/{token}` / `POST …/api/4/remove/stream/favorite/{token}` — JSON `{"stream_id": …, "title_id": …, "title_type": …}` |
| Account | `GET …/api/4/accountinfo/{token}` — includes `Your_Premium_Status` / `Premium_Expires_on`, which drive the VIP gate |
| Service status | `GET …/api/4/checkservice/{token}` |
| Logout | `GET …/api/4/logout/{token}` |

Stream URLs can be plain HTTP on some channels, so the app allows arbitrary loads in its `Info.plist` (`NSAllowsArbitraryLoads`) — the same streams the Android app plays would otherwise be blocked by App Transport Security.

## Requirements

- iOS 17.0 or later (Liquid Glass requires iOS 26.0 or later)
- Xcode 26 or later to build the Liquid Glass code paths (Xcode 15/16 cannot compile the iOS 26 glass APIs used here); the GitHub Actions workflow uses a `macos-26` runner for this reason
- Swift 5.0
- No third-party dependencies
- A Viu account for `viu.rs` **with an active VIP subscription** to watch live channels

## Project Structure

```
viu-live-tv/
├── ViuLiveTV.xcodeproj/            # Xcode project + shared ViuLiveTV scheme
├── ViuLiveTV/
│   ├── ViuLiveTVApp.swift          # @main app entry point, appearance, audio session
│   ├── ContentView.swift           # Root: login gate -> subscription gate -> Channels/Favorites, iPad split view
│   ├── Models.swift                # Channel/EPG, LiveLinks, Login, Account models (exact API shapes, Codable for the guide cache)
│   ├── APIClient.swift             # api.viu.rs client (async/await, token-in-path, UA header)
│   ├── Keychain.swift              # Keychain wrapper for the session token
│   ├── AuthViewModel.swift         # Signed-in state, subscription state, login/logout, persisted username
│   ├── LoginView.swift             # First-boot Viu login (+ use-a-token option) and the subscription gate screens
│   ├── ChannelListView.swift       # Channels + Favorites list, category chips, search, pull-to-refresh, swipe actions
│   ├── ChannelRowView.swift        # Logo, name, now/next EPG + progress, favorite star
│   ├── PlayerView.swift            # AVPlayerViewController: video-only UI, guide sheet, gestures, PiP, background play, Now Playing
│   ├── EPGDateParser.swift         # Parses the EPG's "yyyy-MM-dd HH:mm:ss" schedule times
│   ├── AppSettings.swift           # Appearance, external-player and quality preferences
│   ├── ExternalPlayer.swift        # VLC / Infuse / OutPlayer / nPlayer URL schemes + fallback
│   ├── FavoritesStore.swift        # Local favorites persistence + server sync
│   ├── EPGStore.swift              # Loads the ALL feed (parallel per-tag fallback), disk cache, now/next lookup
│   ├── SettingsView.swift          # Account, player choice, appearance, diagnostics, About, logout
│   ├── GlassHelpers.swift          # Liquid Glass (iOS 26) with Material fallback (iOS 17-25), haptics
│   ├── Info.plist                  # Orientations, background audio, ATS, external-player schemes
│   └── Assets.xcassets/            # App icon (Dark + Tinted variants), accent colour
├── .github/workflows/
│   ├── build-ipa.yml               # GitHub Actions: builds an unsigned IPA on macOS
│   └── simulator-test.yml          # GitHub Actions: boots a virtual iPhone on iOS 26, installs + launches the app, screenshots; with a VIU_TEST_TOKEN secret it also runs a live end-to-end playback test
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

4. On first launch, sign in with your Viu account. After that you'll land straight on the channel list every time — as long as the account's subscription is active.

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

Every push to `main` runs the **Build IPA** workflow on a `macos-26` runner and uploads `ViuLiveTV.ipa` as a build artifact. Tagged releases attach the IPA to the release. The **Simulator Test** workflow boots a virtual iPhone on iOS 26, installs and launches the app, and captures Light/Dark screenshots; when a `VIU_TEST_TOKEN` repository secret is provided, it additionally signs in with that account, loads the real guide, and verifies native playback of a live channel end to end (this is how v1.2.0's playback was proven: the test played the NHL / Edmonton Oilers channel in `AVPlayer` on the simulator and captured the decoded stream).

## Notes

- This is an unofficial, personal-use client for an account you own. It only implements Live TV; movies and series endpoints from the Android app are intentionally not used.
- The member website is [viu.to](https://viu.to) (it serves the account avatars and the member login where subscriptions are renewed/purchased). `vid.to` as typed in a browser currently redirects to a different service (viu.com) — this app follows the APK, whose backend is `api.viu.rs`, and that is the account the login screen expects.
- Channel availability, logos and EPG data come straight from Viu's feeds and can change on their side; the app decodes them flexibly and never shows a hard-coded channel list as a substitute for live data, except for clearly-labelled sample channels when the feed can't be reached at all (for example before/without a valid token).

## License

MIT — see [LICENSE](LICENSE). Copyright (c) 2026 c12n Apps.
