import { site } from '../site'
import { DownloadButtons } from './DownloadButtons'
import { PipelineDemo } from './PipelineDemo'

const facts = ['Free & open source', `${site.minimumMacOS}+`, 'Flutter · React Native · Expo', 'No fastlane']

export function Hero() {
  return (
    <section id="top" className="relative overflow-hidden pt-32 pb-20 md:pt-40 md:pb-28">
      <Backdrop />
      <div className="container-page relative grid items-center gap-14 lg:grid-cols-[1.05fr_1fr] [&>*]:min-w-0">
        <div>
          <p className="fade-up mb-6 inline-flex items-center gap-2 rounded-full border border-line-strong bg-white/[0.03] px-3.5 py-1.5 text-sm text-muted">
            <span className="size-1.5 rounded-full bg-ok shadow-[0_0_10px_var(--color-ok)]" />
            Mobile CI/CD that runs on your Mac
          </p>

          {/* The headline isn't faded in: it's the page's largest paint and must show immediately. */}
          <h1 className="text-5xl leading-[1.04] font-semibold tracking-[-0.035em] text-balance sm:text-6xl lg:text-7xl">
            Push a tag.
            <br />
            <span className="text-gradient">Your app ships.</span>
          </h1>

          <p style={{ animationDelay: '0.1s' }} className="fade-up mt-6 max-w-xl text-lg leading-relaxed text-muted text-pretty">
            Mili Ship builds, signs and publishes your <strong className="font-medium text-fg">Flutter</strong> and{' '}
            <strong className="font-medium text-fg">React Native</strong> apps to{' '}
            <strong className="font-medium text-fg">Google Play</strong> and{' '}
            <strong className="font-medium text-fg">TestFlight</strong> — on the Mac you already have. No build server,
            no YAML, no paid CI minutes.
          </p>

          <div style={{ animationDelay: '0.2s' }} className="fade-up mt-9">
            <DownloadButtons />
          </div>

          <ul style={{ animationDelay: '0.35s' }} className="fade-up mt-8 flex flex-wrap gap-x-5 gap-y-2 text-sm text-subtle">
            {facts.map((fact) => (
              <li key={fact} className="flex items-center gap-2">
                <span className="size-1 rounded-full bg-subtle" aria-hidden />
                {fact}
              </li>
            ))}
          </ul>
        </div>

        <div style={{ animationDelay: '0.15s' }} className="fade-up">
          <PipelineDemo />
        </div>
      </div>
    </section>
  )
}

function Backdrop() {
  return (
    <div aria-hidden className="pointer-events-none absolute inset-0">
      <div className="absolute inset-x-0 top-0 h-[42rem] bg-[radial-gradient(50%_60%_at_70%_0%,rgb(69_194_245/0.16),transparent),radial-gradient(45%_55%_at_20%_10%,rgb(109_130_255/0.2),transparent)]" />
      <div className="absolute inset-0 bg-[linear-gradient(to_right,rgb(148_163_184/0.06)_1px,transparent_1px),linear-gradient(to_bottom,rgb(148_163_184/0.06)_1px,transparent_1px)] bg-[size:56px_56px] [mask-image:radial-gradient(60%_50%_at_50%_0%,black,transparent)]" />
    </div>
  )
}
