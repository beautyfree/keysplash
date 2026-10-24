# KeySplash

KeySplash turns keyboard cleaning mode into colorful handprint play. It covers every display, blocks normal keyboard input, and paints a fading child-sized handprint where each key is mapped on the keyboard. Press **Escape five times** or click **Unlock** to close it.

## Download and use

Download the latest ready-to-run macOS app from [GitHub Releases](https://github.com/beautyfree/keysplash/releases/latest). Open `KeySplash-macOS.zip`, then move `KeySplash.app` to Applications and launch it.

On first launch, allow KeySplash in **System Settings → Privacy & Security → Accessibility**, then open the app again. KeySplash stays transparent and filters input only while its keyboard event tap is active. If setup fails, it exits without showing the overlay, leaving the keyboard usable.

## What it does

- Maps physical key positions across the full keyboard and display, including ANSI, ISO, and JIS layouts.
- Uses randomized, colorful left- and right-hand prints with varied sizes, angles, and a larger splash for repeated keys.
- Plays a short sound on key presses; the speaker button mutes it.
- Keeps mouse interaction limited to the centered Unlock and sound controls. macOS Force Quit remains available as an emergency exit.

## Development

KeySplash is a native Swift app for macOS 14 or later. To build locally, install Xcode Command Line Tools and run:

```sh
./build-app.sh
open dist/KeySplash.app
```

The app bundle is assembled with its app icon and handprint artwork by `build-app.sh`. GitHub Actions builds it for pushes and pull requests. A `v*` tag publishes a GitHub Release after signing with a Developer ID certificate and notarizing the app with Apple. Repository Actions secrets required for release publishing:

- `DEVELOPER_ID_CERTIFICATE_P12_BASE64`
- `DEVELOPER_ID_CERTIFICATE_PASSWORD`
- `APP_STORE_CONNECT_API_KEY_BASE64`
- `APP_STORE_CONNECT_API_KEY_ID`
- `APP_STORE_CONNECT_ISSUER_ID`

The key lock, Escape unlock gesture, and mouse-unlock behavior are adapted from [Vorssaint](https://github.com/vorssaint/vorssaint-utils)'s Cleaning Mode and distributed under GPL-3.0-or-later. See [LICENSE](LICENSE).
