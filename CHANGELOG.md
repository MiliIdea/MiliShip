# Changelog

## 0.3.0 — 2026-09-29

- **Pre-flight check.** *Check Project* (in the wizard's Review step and in each app's ⋯ menu) inspects Mili Ship's clean clone of the default branch — what a build sees — and lists problems with one-click fixes: git-ignored files the build needs (adds a copy-from-example pre-build command), tools your Terminal finds but builds don't (adds them to the build PATH), cache locations like `PUB_CACHE` from your shell, development dart-define files, Shorebird setup and whether this app's API key can access its Shorebird app, keystore password and alias, Gradle reading `key.properties`, CocoaPods, and an outdated GitHub Actions workflow.
- **One Shorebird account per app.** The per-app field is now a Shorebird API key (`sb_api_…` from Shorebird Console), which builds use instead of the Mac's `shorebird login`.
- Settings can pass extra environment variables to every build; `$PUB_CACHE/bin` is added to the build PATH automatically.
- Only one copy of Mili Ship runs at a time: a second copy hands over to the running one, so two copies can no longer overwrite each other's settings or compete for GitHub Actions jobs.
- Settings changed on disk while Mili Ship runs are loaded instead of being overwritten.
- The build log starts at the left edge and step and error highlights span its full width.

## 0.2.0 — 2026-09-29

- GitHub Actions setup without creating a token: **Use GitHub CLI Login** fills in the token of the GitHub CLI you're signed in to, and **Connect Runner** tries the typed token, the saved one and the GitHub CLI login in turn, keeping whichever can access the repository. Fine-grained tokens that can't see an organization's repository no longer stop the setup.
- Keychain: Mili Ship tells secrets that are missing apart from ones it isn't allowed to read yet, and offers **Allow Access…** — approve once and it saves them again itself, so they never prompt again.
- Fixed secrets showing as "not saved" after a failed Keychain read until the app was saved again; the check is now refreshed every few seconds.
- Opening an app's configuration never triggers a Keychain prompt.

## 0.1.0 — 2026-09-28

First public version.

- GitHub Actions: Mili Ship installs and manages GitHub's self-hosted runner, adds a workflow to the repository, and runs tag deployments as GitHub Actions jobs with live logs, step groups, annotations, a job summary and cancellation — free, on your Mac.
- Background mode: closing the window keeps Mili Ship in the menu bar (no Dock icon); it starts there quietly at login, and asks before quitting during a deployment.
- Add any number of Flutter applications with a step-by-step setup wizard (repository, project, prepare, build & versioning, Google Play, App Store, review).
- Auto-detection of Flutter apps in single-app repos and melos / pub-workspace monorepos (package name, bundle ID, team ID, Shorebird, FVM, entry points, dart-define files).
- Builds with Flutter (`flutter build appbundle` / `ipa`) or Shorebird (`release` / `patch`).
- React Native support: detection of bare and Expo apps (npm / yarn / pnpm / bun, CocoaPods, workspace and scheme), Gradle and `xcodebuild archive` builds, versions set in `build.gradle` and passed to Xcode, signing through Gradle's injected signing properties.
- Android signing choice: Google Play App Signing with an upload key (with a key generator), your own app signing key, or the project's Gradle config.
- Publishing through the Google Play Developer API and App Store Connect (xcodebuild upload) — no fastlane required.
- Four versioning strategies, including build numbers auto-incremented from the stores.
- Tag watching, sequential build queue, live logs with masked secrets, history, notifications, menu bar extra, open at login.
