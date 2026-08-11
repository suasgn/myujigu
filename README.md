<p align="center">
  <img src="Resources/AppIcon.png" width="144" alt="Myujigu app icon">
</p>

# Myujigu

![Swift](https://img.shields.io/badge/Swift-F54A2A?logo=swift&logoColor=white) ![macOS](https://img.shields.io/badge/macOS-000000?logo=apple&logoColor=F0F0F0)

A native menu-bar app that keeps synced Spotify and Apple Music lyrics visible while you listen.

```sh
open Myujigu.xcodeproj
```

- Keeps the active lyric in the macOS menu bar
- Shows album artwork from Spotify and Apple Music in the player panel
- Scrolls long lyric lines automatically
- Shows full, synchronized lyrics in a compact popover
- Includes previous, play/pause, and next controls
- Supports Spotify Desktop and Apple Music
- Uses camera-safe lyric lanes on MacBooks with a notch
- Reads cached lyrics first and keeps Spotify credentials in Keychain
- Written in Swift and SwiftUI
- macOS 13+

## How it works

Myujigu follows the current track and playback position through macOS Automation. It reads synchronized lyrics already cached by Spotify Desktop or Apple Music, then highlights the active line as the song plays.

For Spotify cache misses, open the music-note menu-bar item, select the gear, and choose **Sign In with Spotify**. The login runs in a temporary isolated web view; Myujigu stores only the resulting `sp_dc` session cookie in macOS Keychain and sends it only to Spotify.

For a new Apple Music track that has not been cached yet, open the track's Lyrics view in Music. Myujigu checks the local cache again every three seconds.

## Permissions

- **Automation** — required to read playback state and control Spotify or Music.
- **Accessibility** — optional; used to measure the available menu-bar space beside the camera housing. Without it, Myujigu safely uses the right lyric lane only.

Permissions can be changed in **System Settings → Privacy & Security**.

## Development

Requirements: macOS 13 or newer and Xcode.

Open `Myujigu.xcodeproj`, select the **Myujigu → My Mac** scheme, and press Run. Use
**Product → Test** for the `MyujiguCoreTests` suite and **Product → Archive** to
create an Xcode archive.

The Swift package remains available for command-line development:

```sh
make run
make test
```

Myujigu is an agent-style app, so it does not create a Dock icon or a normal app window.

Local builds and archives use **Sign to Run Locally** and are not notarized. Select
your Apple Developer team under **Signing & Capabilities** before distribution.

## Contributions

Contributions are welcome. For focused fixes or improvements, open a pull request with the smallest practical change. Please open an issue before starting work that changes the user experience or expands the app's scope.
