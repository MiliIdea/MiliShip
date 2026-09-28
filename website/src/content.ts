/** FAQ copy: rendered on the page and published as FAQPage structured data for search engines. */
export const faqs = [
  {
    q: 'What is Mili Ship?',
    a: 'Mili Ship is a free, open-source mobile CI/CD app for macOS. When you push a git tag, it checks out your Flutter or React Native app, builds it, signs it and publishes it to Google Play and App Store Connect / TestFlight — on your own Mac.',
  },
  {
    q: 'Is Mili Ship a fastlane alternative?',
    a: 'For building and publishing, yes. Mili Ship talks to the Google Play Developer API and App Store Connect directly, so there is no Ruby, no Fastfile and no plugins to maintain. It also handles code signing, version numbers and TestFlight uploads for you.',
  },
  {
    q: 'How is it different from hosted mobile CI like Codemagic or Bitrise?',
    a: 'Hosted services run your builds on their Macs and charge for build minutes. Mili Ship runs on a Mac you already own, so builds cost nothing and your keystores and API keys never leave it. Hosted CI is the better fit if you need many builds in parallel or don’t have a Mac.',
  },
  {
    q: 'Can my team see builds in GitHub Actions?',
    a: 'Yes. Mili Ship installs GitHub’s official self-hosted runner on your Mac and adds a small workflow to your repository. Every pushed tag appears as a GitHub Actions run with the full, step-by-step log and a summary — without using any GitHub Actions minutes.',
  },
  {
    q: 'Does it support Flutter flavors, Shorebird, Expo and monorepos?',
    a: 'Yes. Flutter builds support flavors, entry points, dart-define files, FVM and melos, plus Shorebird releases and over-the-air patches. React Native builds work for bare apps and Expo (with prebuild), with npm, yarn, pnpm or bun, including monorepos.',
  },
  {
    q: 'What happens when my Mac is asleep?',
    a: 'Nothing is lost. Mili Ship picks up new tags as soon as the Mac wakes. With GitHub Actions connected, GitHub keeps the job queued for up to 24 hours and it starts the moment Mili Ship is running again. For builds within minutes of every push, keep the Mac awake and plugged in.',
  },
  {
    q: 'Is Mili Ship free?',
    a: 'Yes — Mili Ship is free and open source under the MIT license. You only need the developer accounts you already have: a Google Play Console account and an Apple Developer Program membership.',
  },
]
