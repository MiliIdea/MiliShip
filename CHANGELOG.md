# Changelog

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
