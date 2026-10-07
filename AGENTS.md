# AGENTS.md

Notes for AI agents and contributors working on MacPaper Engine. Read this before changing code.
User-facing docs are in [README.md](README.md); the package format is specified in [FORMAT.md](FORMAT.md).

## Build and run

```sh
./scripts/bundle.sh                  # release build → build/MacPaper.app, screen saver included
./scripts/bundle.sh debug            # debug build, faster to compile
swift build -c release               # app binary only — quick compile check, no bundle
```

- macOS 26, Swift 6.2+. Command Line Tools are enough; there is no Xcode project.
- SwiftPM from the Command Line Tools ships without the SwiftUI macro plugins: don't use `@Entry`
  or `#Preview` (write `FocusedValueKey` / `EnvironmentKey` conformances by hand). `@Observable` works.
- The app icon is generated from `Assets/AppIcon.png` by `scripts/make-icon.swift`; `bundle.sh`
  rebuilds it when either file changes.
- To run a fresh build: quit the running app (`osascript -e 'quit app "MacPaper"'`), then
  `open build/MacPaper.app`. The binary is replaced in place, so a running copy keeps the old code.
- **Running the binary with no arguments launches a second GUI instance**, which fights the first
  over the desktop. Only call it with a CLI command (`validate`, `render`, …).
- The screen saver is loaded by `legacyScreenSaver`, which caches bundles. After rebuilding, install it
  from the app's Screen Saver page (or copy `build/MacPaper.app/Contents/Resources/MacPaper.saver`
  to `~/Library/Screen Savers/` and `killall legacyScreenSaver`).

## Verifying changes

There is no test target. Verify with the real thing:

| Change | How to check |
|---|---|
| Format, resolver, validator | `MacPaper validate <pkg>` on `Samples/*` and a package that exercises the change |
| Rendering | `MacPaper render <pkg> --out f.png --time 3` and look at the image; `MacPaper bench` for cost |
| App behavior | Rebuild, relaunch, and exercise it; read `~/Library/Application Support/MacPaper` state if needed |
| Energy / performance | `top -pid $(pgrep -x MacPaper)`, `sample <pid> 3`, `footprint <pid>` — compare before and after |
| Screen saver | Reinstall it, then run it from System Settings; never assume the cached bundle is current |

Take screenshots of MacPaper's own windows only (`screencapture -l <windowID>`), never the full screen.

## Architecture

```
Format/   manifest → ResolvedScene. Pure value types; no AppKit, no Metal.
Library/  packages on disk (LibraryStore), AppState (per-wallpaper settings), Preferences, Paths.
Render/   SceneSession (one per wallpaper, shared by every surface), SceneEncoder (one frame),
          WallpaperView (poster → live content), MetalSceneView, VideoLayerView, PosterCache.
Desktop/  DesktopManager: one desktop-level window per NSScreen, pause policy, pointer tracking.
Create/   Creator (drafts → packages), MediaTools (AVFoundation, Vision, ffmpeg), EffectCatalog.
UI/       SwiftUI views. App/ holds AppModel (the single source of truth), CLI and URL commands.
MacPaperSaver/  the .saver; compiled from Format + Library + Render + MacPaperSaver only.
```

Rules that keep this working:

- **Format, Library and Render must not depend on App, UI, Desktop (except `DesktopWindow.swift`) or
  Create** — the screen saver compiles without them (see the source list in `scripts/bundle.sh`).
- **Packages are read-only.** User choices live in `AppState`, never in the package. Generated
  posters go to `Paths.generatedPosters` / `Paths.personalPosters`, not into the package.
- **Paths from a manifest go through `Wallpaper.file(_:)`**, which refuses anything outside the package.
- **One `SceneSession` per wallpaper**, shared by every display, the inspector preview and posters.
  Decoders, textures and compiled shaders live there. Get one from `SessionStore.shared`.
- Each surface reports its own state to the session: `setPlaying(_:consumer:)` and
  `setAudio(volume:audible:consumer:)`. The session plays while any surface plays and is muted only
  when no surface wants sound.
- **AVPlayer shows video in only the most recently created `AVPlayerLayer`.** One surface per session
  owns the direct video path (`claimDirectVideo`); every other surface draws the same frames through
  Metal. Don't attach a second `AVPlayerLayer` to a session's player.
- `SceneSession.notify()` calls every listener synchronously, including the caller. Update your own
  state before triggering it (see `WallpaperView.rebuildContent`).
- Window occlusion is unreliable for desktop-level windows and never reports visible inside
  `legacyScreenSaver` on macOS 26. Coverage is measured from the window list; the saver pauses on
  start/stop and display sleep instead.
- Automatic changes (rotation, shuffle) must stay cheap: no poster renders or desktop-picture writes
  per clip. Only user edits re-render the personal poster.
- Everything in `Format`/`Render` is `@MainActor` unless it is pure. Heavy file or image work goes in
  `Task.detached`; the main thread never waits on a full-size encode or a recursive directory walk.
- Converting a `Double` from a manifest to an integer must clamp first (`JSONValue.int(in:)`);
  `Int(1e19)` traps.

## Changing the format

A format change touches, in order:

1. `Format/Scene.swift` (decoding, `ResolvedScene`) and `Format/Manifest.swift` if it's a top-level field.
2. `PropertyPath` in `Scene.swift` if controls may target it.
3. `Format/Validator.swift` — type, range, and file checks with a clear message.
4. The renderer.
5. **[FORMAT.md](FORMAT.md)** — it is the contract, and the text the app's *Copy AI Guide* hands to
   other models. Keep examples valid: run them through `MacPaper validate`.

Keep `format: 1` backward compatible: new fields are optional with defaults that preserve old behavior.

## Code style

- Swift 5 language mode, Swift 6 toolchain. Match the surrounding file's idioms.
- Comments only for what the code can't say: a non-obvious invariant, an OS quirk, an ordering
  constraint. No comments that restate the line, label sections, or narrate a change. A doc comment
  states what something is for in one sentence.
- Names say what things are (`effectiveFPSCap`, `canApply`); avoid abbreviations and `Manager`/`Helper` soup.
- No third-party dependencies.
- User-facing text: US English, plain words, no developer jargon in the main UI (developer tools live
  under Info › Develop). Destructive actions are undoable (`AppModel.registerUndo`, the toast) rather
  than guarded by confirmation dialogs.
- Every icon-only control gets an accessibility label; sliders get a label and a formatted value.
  Honor Reduce Motion.

## Where things are

| Need | Look at |
|---|---|
| Apply / per-display targeting / undo | `AppModel.apply(_:to:)`, `commitAssignments` |
| Pause policy | `DesktopManager.pauseReason`, `evaluatePolicy` |
| Settings that affect rendering | `AppModel.renderSettings` → `RenderSettings` |
| Control value → layer property | `SceneResolver`, `PropertyPath` |
| Rotation of choice controls | `WallpaperSettings.cycles(for:)`, `AppModel.rescheduleCycles`, `clipEnded` |
| Captions | `SceneSession.say`, `CaptionLayer` |
| Import / delete / restore | `LibraryStore.importPackage`, `remove`, `restore` |
| CLI | `App/CLI.swift` · URL scheme: `AppModel.handle(_:)` |
| Screen saver | `MacPaperSaver/MacPaperSaverView.swift`, `App/ScreenSaverInstaller.swift` |
