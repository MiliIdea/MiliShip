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

Add a `## 0.2.0` section to `CHANGELOG.md`, commit, then run `./scripts/release.sh 0.2.0` on a Mac with a
Developer ID Application certificate and a notarytool profile. It builds a universal app, signs, notarizes and
staples it, checks it with Gatekeeper, tags `v0.2.0` and publishes `MiliShip-0.2.0.dmg` and `.zip` as a GitHub
release with the changelog section as notes. (The Release workflow can do the same on CI for an existing tag
once Developer ID secrets are configured.)
