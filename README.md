# Flick

A menu-bar app for macOS that fills, splits, moves or minimizes a window when you swipe or pinch two fingers on its title bar, and stays out of the way of Stage Manager. Hold ⌘ as you start a gesture to use it anywhere in the window.

| On a title bar, or with ⌘ anywhere in a window | Stage Manager off | Stage Manager on |
| --- | --- | --- |
| swipe ↑ | Window → Fill | fill the stage |
| swipe ← | Window → Move & Resize → Left | left half of the stage |
| swipe → | Window → Move & Resize → Right | right half of the stage |
| swipe ↓ | move to the next display, keeping its place on screen | same, within the stages |
| pinch in | minimize to the Dock | minimize to the strip |
| ⌘⇧ swipe ← / → | split the display with the window behind: this one on that side | split the stage with the window behind |

While ⌘ stays held, later ⌘ gestures keep going to the window the first one hit, wherever the pointer is, so you can split a window, send it to the next display and fill it there in one go. Releasing ⌘ lets go of it. Repeating a split in the same hold cycles the window through half, two thirds and one third of that side, as Rectangle does; with Stage Manager off, the thirds take the display's visible frame, since macOS's Window menu has none.

Adding ⇧ makes a split a pair: the window takes its side and the window behind it — the next one on the stage, or with Stage Manager off, on the display — takes the rest, both easing there together. Pairs cycle the same way, and turning a split into a pair keeps its size, so ⌘← ⌘← ⌘⇧← gives the window two thirds and the one behind it the last third. With Stage Manager on, only windows already sharing the stage pair up.

Displays are ordered left to right, wrapping around. A moved window keeps its position and size relative to the area windows are arranged in — the visible frame, or with Stage Manager on, the stage — so a filled window stays filled, a left half stays a left half, and a window in the top-right third stays there.

With Stage Manager off, Flick presses macOS's own Window-menu commands, so windows tile exactly as they would from the menu. With it on, those commands would cover the strip of recent apps, so Flick instead moves the window into the display's *stage*, the area beside the strip where macOS itself places new windows, and eases it there over 0.2 s the way native tiling animates.

The swipe is decided when your fingers lift, so you can still change direction or back out mid-swipe. Until then a frosted preview shows where the window will go, with a symbol for the action, and follows the swipe as it changes direction; a Force Touch trackpad ticks each time it does. A pinch likewise fires when the fingers lift, closed far enough. Every event of a gesture Flick takes, including a swipe's momentum, is swallowed, so the window never scrolls or zooms; with ⌘ held, that includes ⌘-scrolling and pinching within windows. Gestures that start elsewhere, and those with ⌥, ⌃ or ⇧ held, pass through untouched.

## Install

Requires macOS 14 or later and Xcode (or its command-line tools) for Swift 6.

```sh
./build.sh --install
```

This builds `build/Flick.app`, copies it to `~/Applications`, and launches it. On first launch, grant Flick **Accessibility** under System Settings → Privacy & Security; it starts watching the trackpad as soon as the permission arrives. Turn on **Launch at Login** from its menu-bar icon, or with `launch-at-login on` (see [Command line](#command-line)).

The bundle is signed with `flick-local`, a self-signed code-signing certificate `build.sh` creates in your login keychain on first run. macOS ties the Accessibility grant to that signature rather than to a specific build, so rebuilding keeps the permission; an ad-hoc signature would lose it on every build.

## Settings

**Settings…** in the menu-bar menu (⌘,) opens a window for all of them; the menu also toggles the first two directly:

- **Show previews** (on): the frosted preview while a gesture is in progress.
- **Keep pointer on title bar** (on): after a swipe moves a window, the pointer follows to the middle of its title bar if it ended up outside it, so the next swipe can start right away. ⌘ gestures leave the pointer where it is, since they work anywhere in the window.
- **Swipe distance** (50 pt): the finger travel a swipe needs.
- **Animation** (0.2 s): how long a window eases into place; 0 jumps. The command line uses it too, unless given `--duration`.
- **Ignored apps**: apps whose windows gestures pass through untouched, for apps with gestures of their own.

They live in `~/.config/flick/config.toml` (or under `$XDG_CONFIG_HOME`), so they can be synced and versioned with your dotfiles. Flick reloads the file whenever it changes — after a `git pull`, say. When you change a setting in the app, it rewrites only that key's line, keeping your comments and layout; a new file starts as a commented template. Keys left out take their defaults:

```toml
swipe_threshold = 50          # finger travel a swipe needs, in points (10–200)
animation_duration = 0.2      # seconds; 0 jumps
show_previews = true
keep_pointer_on_title_bar = true
excluded_apps = [
  "com.apple.finder",
]
```

Flick reads the flat subset of TOML these settings need: bare keys, numbers, booleans, strings and arrays of strings, with comments. If the file has an error, Flick keeps its current settings, logs the line, and beeps rather than save over it.

Two settings stay with each Mac instead: **Enabled**, the menu's quick on/off switch, and **Launch at Login**, which macOS keeps.

## Command line

The app's executable also arranges the frontmost window once and exits, which helps for testing or for binding keyboard shortcuts:

```sh
FLICK=~/Applications/Flick.app/Contents/MacOS/Flick
$FLICK fill [--dry-run] [--duration SECONDS]
$FLICK tile [--dry-run] [--duration SECONDS] left|right|top|bottom
$FLICK pair [--dry-run] [--duration SECONDS] left|right
$FLICK display [--dry-run] previous|next
$FLICK minimize [--dry-run]
$FLICK probe X Y    # is there a title bar at this point (global, top-left origin)?
$FLICK launch-at-login [on|off]    # show or set Launch at Login, e.g. from a setup script
```

These need Accessibility permission for whatever runs them, such as your terminal or a keyboard remapper. `--dry-run` prints what it would do instead of doing it. A command that can't do its job also plays the alert sound, since remappers usually drop its error message.

## Troubleshooting

```sh
log stream --info --predicate 'subsystem == "info.junz.flick"'
```

shows each recognized swipe, the arrangement it chose, and any failure. Failures also beep.

## How it works

- **Gestures.** A session event tap sees every scroll event before apps do. Trackpad scrolls carry gesture phases (may-begin, began, changed, ended, cancelled, then momentum). `SwipeRecognizer` decides on a gesture's first event whether it started on a title bar (or with ⌘ held, on a window), then swallows it through its momentum and classifies the total finger travel when the fingers lift.
- **Pinches.** The same tap sees pinches as gesture events whose HID type is zoom, the ones AppKit turns into magnify events. `PinchRecognizer` picks the window the same way and fires when the fingers lift, having closed by enough.
- **Title bars.** An Accessibility hit test finds the topmost window under the pointer, which must be a standard, non-full-screen window; for a ⌘ swipe that is enough. Its title-bar band runs from the window's top edge to twice the close button's depth, because the traffic lights sit centred in whatever the window has there: a plain title bar, a unified toolbar or a tab strip.
- **Pairs.** The window behind is the frontmost other standard window, in the window server's front-to-back order, that lies mostly inside the stage or visible frame, which leaves out Stage Manager's thumbnails. It is matched to its Accessibility window through `_AXUIElementGetWindow`, the private call window managers use to get a window's ID.
- **Displays.** Rather than pressing Window → Move to <display>, Flick moves the window itself, mapping its frame between the two displays' usable areas in proportion, and jumps there as that command does.
- **Stages.** Stage Manager's stage frames come from `WMClientWindowManager` in the private WindowManagement framework, the same source AppKit uses to place new windows. The app keeps one client connected, so it always has the current stages. If a macOS update changes that framework, Flick beeps instead of moving the window.

## Development

```sh
swift build
swift test
Tests/test-cli.zsh
```

The gesture recognizer and geometry live in `FlickCore` and are unit-tested; `Tests/test-cli.zsh` checks the command line's argument handling. The event tap, Accessibility and window movement need a real session; use the `probe` and `--dry-run` commands above to check them.
