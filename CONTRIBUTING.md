# Contributing to Mili Ship

Thanks for helping! Bug reports, docs fixes and pull requests are all welcome.

## Development setup

You need macOS 13+ and Xcode 16 or newer.

```bash
git clone https://github.com/MiliIdea/MiliShip.git
cd MiliShip
open MiliShip.xcodeproj    # ⌘R builds and runs
```

The project uses Xcode's folder-synchronized groups. Any file you add under `MiliShip/` in Finder or Xcode
is compiled automatically, so there's no project file to edit.

**Signing while developing:** the project signs to run locally, with no team required. macOS ties Keychain access
to the signature, so every rebuild may ask again for the stored passwords. To stop this, pick your own team in
*Signing & Capabilities*, and don't commit that change.

## Project layout

```
MiliShip.xcodeproj
MiliShip/
  App/        MiliShipApp (scenes, menus, menu bar), AppModel (state, polling, build queue)
  Core/       Models, Storage (JSON + Keychain), Shell, Logging, Git, ProjectScanner, Pipeline
  Stores/     GooglePlay (Developer API), AppStoreConnect (API)
  Views/      Sidebar, AppDetailView, DeploymentViews, Wizard, AppSummaryView, WelcomeView,
              PreferencesView, Components
  Assets.xcassets   AppIcon, AccentColor
scripts/
  build_app.sh      xcodebuild → .app / .zip / .dmg, optional signing + notarization
  generate_icon.py  renders the app icon into the asset catalog (needs Pillow)
```

## Guidelines

- Keep Mili Ship dependency-free, using Apple frameworks only.
- New `AppConfig` fields need a default value. Saved configurations are merged over the defaults, so older configs keep loading.
- Never log secrets. Keep them in the Keychain and let `LogSink` mask them.
- Views with private state and parameters get an explicit `init`, so they can be used from other files.
- Please describe how you tested a change: which Flutter project, which store, Flutter or Shorebird.

## Changing the icon

Edit `scripts/generate_icon.py`, then run `python3 scripts/generate_icon.py`. It rewrites
`MiliShip/Assets.xcassets/AppIcon.appiconset` and `docs/images/icon.png`.

## Releasing

Push a tag like `v0.2.0`. The Release workflow builds a universal app, signs and notarizes it when the
Developer ID secrets are configured, and attaches `MiliShip-0.2.0.dmg` and `.zip` to a GitHub release.
