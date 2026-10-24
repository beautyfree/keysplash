# KeySplash

A small macOS app that turns keyboard cleaning mode into colorful handprint play. Opening the app covers every display and filters keyboard input. Tapping an ANSI key paints a bright, fading child-hand print at the matching relative position on each display. The keyboard's left half selects left-facing hand shapes and its right half selects right-facing shapes; every mark gets a random silhouette, color, size, and tilt.

## Build and run

Requires macOS 14 or later and Xcode Command Line Tools.

```sh
./build-app.sh
open dist/KeySplash.app
```

GitHub Actions builds the macOS app for pushes and pull requests. Pushing a version tag such as `v1.0.0` also creates a GitHub Release with the app archive. CI uses an ad-hoc signature; Developer ID signing and notarization are not configured, so public downloads may require additional Gatekeeper steps.

The first launch asks you to allow KeySplash under **System Settings → Privacy & Security → Accessibility**. After enabling it, open the app again. If the keyboard event filter cannot be installed, KeySplash exits without showing the overlay or blocking input.

Click **Unlock** with the mouse, or press **Escape five times**. Holding Escape does not count as five presses; another key resets progress. Unlocking closes KeySplash.

Key positions are normalized across the full keyboard rectangle and projected across the full display. QWERTY, QWERTZ, and AZERTY input sources use physical key positions; the event's physical keyboard type selects ANSI, ISO, or JIS spacing. Special brightness and media keys map to their positions in the function row. Multi-display setups mirror the same projected key position on every display.

## Source

The keyboard lock, Escape unlock gesture, and mouse-unlock behavior are adapted from [Vorssaint](https://github.com/vorssaint/vorssaint-utils)'s Cleaning Mode and distributed under GPL-3.0-or-later. See [LICENSE](LICENSE).
