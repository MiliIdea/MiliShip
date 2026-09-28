import { FolderGit2, KeyRound, Layers, MonitorSmartphone, Hash, ShieldCheck, Tag, Workflow, Zap, Store } from 'lucide-react'
import type { ReactNode } from 'react'
import { Reveal } from './Reveal'

export function SectionHeading({ eyebrow, title, children, id }: { eyebrow: string; title: ReactNode; children?: ReactNode; id?: string }) {
  return (
    <Reveal className="mx-auto mb-14 max-w-2xl text-center">
      <p className="mb-3 font-mono text-xs font-medium tracking-[0.2em] text-brand-2 uppercase">{eyebrow}</p>
      <h2 id={id} className="text-3xl font-semibold tracking-[-0.03em] text-balance sm:text-4xl md:text-5xl">
        {title}
      </h2>
      {children && <p className="mt-5 text-lg leading-relaxed text-muted text-pretty">{children}</p>}
    </Reveal>
  )
}

const stack = ['Flutter', 'React Native', 'Expo', 'Shorebird', 'Google Play', 'App Store Connect', 'TestFlight', 'GitHub Actions']

export function WorksWith() {
  return (
    <section aria-label="Works with" className="border-y border-line bg-surface/40 py-8">
      <div className="container-page flex flex-col items-center gap-5 md:flex-row md:justify-between">
        <p className="shrink-0 text-sm text-subtle">Works with the tools you already ship with</p>
        <ul className="flex flex-wrap justify-center gap-x-7 gap-y-3 md:justify-end">
          {stack.map((name) => (
            <li key={name} className="text-[15px] font-medium tracking-tight text-muted">
              {name}
            </li>
          ))}
        </ul>
      </div>
    </section>
  )
}

const steps = [
  {
    icon: FolderGit2,
    title: 'Point it at your repo',
    body: 'Paste a Git URL. Mili Ship clones it, finds your Flutter or React Native app — even deep in a monorepo — and fills in the package name, bundle ID, team ID and flavors.',
  },
  {
    icon: KeyRound,
    title: 'Connect the stores once',
    body: 'Add a Google Play service account and an App Store Connect API key. Test each connection with one click. Passwords stay in the macOS Keychain.',
  },
  {
    icon: Tag,
    title: 'Push a tag',
    body: 'git tag release/1.4.0+52 && git push --tags. Mili Ship checks it out, builds, signs and publishes both platforms — and tells you when it lands.',
  },
]

export function HowItWorks() {
  return (
    <section aria-labelledby="how-title" id="how-it-works" className="scroll-mt-20 py-24 md:py-32">
      <div className="container-page">
        <SectionHeading id="how-title" eyebrow="How it works" title="From git tag to TestFlight in three steps">
          Set it up in minutes with a guided wizard. After that, releasing is a git command.
        </SectionHeading>
        <ol className="grid gap-5 md:grid-cols-3">
          {steps.map((step, i) => (
            <Reveal key={step.title} delay={i * 0.08} className="h-full">
              <li className="relative h-full rounded-2xl border border-line bg-surface p-7">
                <span className="absolute top-7 right-7 font-mono text-sm text-subtle">0{i + 1}</span>
                <span className="mb-6 grid size-12 place-items-center rounded-xl bg-gradient-to-br from-brand/25 to-brand-2/10 text-brand-2 ring-1 ring-brand/30">
                  <step.icon className="size-6" aria-hidden />
                </span>
                <h3 className="mb-3 text-xl font-semibold tracking-tight">{step.title}</h3>
                <p className="leading-relaxed text-muted">{step.body}</p>
              </li>
            </Reveal>
          ))}
        </ol>
      </div>
    </section>
  )
}

const features = [
  {
    icon: Layers,
    title: 'Flutter and React Native',
    body: 'Flutter with flutter or Shorebird, React Native with Gradle and xcodebuild — bare or Expo. npm, yarn, pnpm, bun, melos and FVM all work.',
    wide: true,
  },
  {
    icon: Zap,
    title: 'Shorebird code push',
    body: 'release/… tags go to the stores; patch/… tags ship an over-the-air Shorebird patch.',
  },
  {
    icon: KeyRound,
    title: 'Signing, handled',
    body: 'Google Play App Signing with an upload key Mili Ship can generate for you. Automatic iOS signing with your App Store Connect API key.',
  },
  {
    icon: Hash,
    title: 'Versions your way',
    body: 'Require the tag to match pubspec.yaml or build.gradle, take the version from the tag, or auto-increment the build number from the stores.',
  },
  {
    icon: Workflow,
    title: 'Live in GitHub Actions',
    body: 'One click installs GitHub’s runner on your Mac. Every tag becomes a GitHub Actions run with the full log — free, no Actions minutes.',
    wide: true,
  },
  {
    icon: MonitorSmartphone,
    title: 'Lives in your menu bar',
    body: 'Close the window and it keeps watching tags and running the build queue. Notifications tell you when a release lands.',
  },
  {
    icon: ShieldCheck,
    title: 'Private by design',
    body: 'Your code, keystores and API keys never leave your Mac. Secrets are masked in every log.',
  },
  {
    icon: Store,
    title: 'Straight to the stores',
    body: 'Talks to the Google Play Developer API and App Store Connect directly: tracks, staged rollouts, release notes, TestFlight.',
  },
]

export function Features() {
  return (
    <section aria-labelledby="features-title" id="features" className="scroll-mt-20 py-24 md:py-32">
      <div className="container-page">
        <SectionHeading id="features-title" eyebrow="Features" title={<>Everything a mobile release needs.<br className="hidden sm:block" /> Nothing it doesn’t.</>}>
          The whole release pipeline — checkout, dependencies, build, signing, versioning and store upload — in one native Mac app.
        </SectionHeading>
        <ul className="grid gap-4 sm:grid-cols-2 lg:grid-cols-4">
          {features.map((feature, i) => (
            <Reveal key={feature.title} delay={(i % 4) * 0.06} className={`h-full ${feature.wide ? 'lg:col-span-2' : ''}`}>
              <li className="group h-full rounded-2xl border border-line bg-surface p-6 transition-colors duration-300 hover:border-line-strong hover:bg-raised">
                <feature.icon className="mb-5 size-6 text-brand-2 transition-transform duration-300 group-hover:-translate-y-0.5" aria-hidden />
                <h3 className="mb-2 text-lg font-semibold tracking-tight">{feature.title}</h3>
                <p className="text-[15px] leading-relaxed text-muted">{feature.body}</p>
              </li>
            </Reveal>
          ))}
        </ul>
      </div>
    </section>
  )
}
