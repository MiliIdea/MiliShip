import { Check, Minus, Plus } from 'lucide-react'
import { useState } from 'react'
import { faqs } from '../content'
import { asset, site } from '../site'
import { DownloadButtons } from './DownloadButtons'
import { GitHubMark } from './GitHubMark'
import { Reveal } from './Reveal'
import { SectionHeading } from './Sections'

export function ProductShot() {
  return (
    <section aria-labelledby="shot-title" className="overflow-x-clip py-12 md:py-20">
      <div className="container-page">
        <SectionHeading id="shot-title" eyebrow="The app" title="Every tag, every build, one window">
          See your release tags, their versions and how each deployment went. Deploy any tag with one click, or let new
          tags ship themselves.
        </SectionHeading>
        <Reveal>
          <div className="relative">
            <div aria-hidden className="absolute -inset-x-10 -top-10 bottom-0 bg-[radial-gradient(50%_50%_at_50%_30%,rgb(109_130_255/0.22),transparent)] blur-2xl" />
            <img
              src={asset('screenshot.webp')}
              alt="Mili Ship showing an app's release and patch tags, each with its version, commit, date and a Succeeded deployment status"
              width={2000}
              height={890}
              loading="lazy"
              decoding="async"
              className="relative w-full rounded-2xl border border-line-strong shadow-2xl shadow-black/60"
            />
          </div>
        </Reveal>
      </div>
    </section>
  )
}

type Cell = string | boolean
const comparison: { label: string; ship: Cell; hosted: Cell; scripts: Cell }[] = [
  { label: 'Where builds run', ship: 'Your Mac', hosted: 'The provider’s Macs', scripts: 'Wherever you set it up' },
  { label: 'Cost', ship: 'Free, open source', hosted: 'Per build minute or plan', scripts: 'Free + your CI costs' },
  { label: 'Setup', ship: 'Guided wizard that reads your repo', hosted: 'YAML + uploaded secrets', scripts: 'Ruby, Fastfile, plugins' },
  { label: 'Signing keys stay with you', ship: true, hosted: false, scripts: true },
  { label: 'Flutter, Shorebird, React Native, Expo', ship: true, hosted: true, scripts: 'Via plugins' },
  { label: 'Runs visible in GitHub Actions', ship: true, hosted: 'Some providers', scripts: 'If you wire it up' },
  { label: 'Many builds in parallel', ship: 'One Mac, one at a time', hosted: true, scripts: 'Depends on your CI' },
]

function Value({ value, highlight }: { value: Cell; highlight?: boolean }) {
  if (value === true) return <Check className={`mx-auto size-5 ${highlight ? 'text-ok' : 'text-muted'}`} strokeWidth={2.5} aria-label="Yes" />
  if (value === false) return <Minus className="mx-auto size-5 text-subtle" aria-label="No" />
  return <span className={highlight ? 'text-fg' : 'text-muted'}>{value}</span>
}

export function Comparison() {
  return (
    <section aria-labelledby="compare-title" className="py-24 md:py-32">
      <div className="container-page">
        <SectionHeading id="compare-title" eyebrow="Compare" title="A fastlane and hosted-CI alternative for small teams">
          If you ship from one Mac anyway, you don’t need to rent another one — or maintain a Fastfile.
        </SectionHeading>
        <Reveal>
          <p className="mb-3 text-center text-sm text-subtle md:hidden">Swipe the table sideways to compare →</p>
          <div className="overflow-x-auto rounded-2xl border border-line">
            <table className="w-full min-w-[40rem] border-collapse text-left text-[15px]">
              <caption className="sr-only">Mili Ship compared with hosted mobile CI and hand-written fastlane scripts</caption>
              <thead>
                <tr className="border-b border-line bg-surface">
                  <th scope="col" className="w-1/4 px-5 py-4 font-medium text-subtle" />
                  <th scope="col" className="bg-brand/10 px-5 py-4 text-center font-semibold text-fg">Mili Ship</th>
                  <th scope="col" className="px-5 py-4 text-center font-semibold text-muted">Hosted mobile CI</th>
                  <th scope="col" className="px-5 py-4 text-center font-semibold text-muted">fastlane scripts</th>
                </tr>
              </thead>
              <tbody>
                {comparison.map((row) => (
                  <tr key={row.label} className="border-b border-line last:border-0">
                    <th scope="row" className="px-5 py-4 font-medium text-fg">{row.label}</th>
                    <td className="bg-brand/[0.06] px-5 py-4 text-center"><Value value={row.ship} highlight /></td>
                    <td className="px-5 py-4 text-center"><Value value={row.hosted} /></td>
                    <td className="px-5 py-4 text-center"><Value value={row.scripts} /></td>
                  </tr>
                ))}
              </tbody>
            </table>
          </div>
        </Reveal>
      </div>
    </section>
  )
}

export function FAQ() {
  const [open, setOpen] = useState<number | null>(0)
  return (
    <section aria-labelledby="faq-title" id="faq" className="scroll-mt-20 py-24 md:py-32">
      <div className="container-page max-w-3xl">
        <SectionHeading id="faq-title" eyebrow="FAQ" title="Questions, answered" />
        <div className="divide-y divide-line rounded-2xl border border-line bg-surface">
          {faqs.map((faq, i) => {
            const expanded = open === i
            return (
              <div key={faq.q}>
                <h3>
                  <button
                    type="button"
                    aria-expanded={expanded}
                    aria-controls={`faq-${i}`}
                    onClick={() => setOpen(expanded ? null : i)}
                    className="flex w-full cursor-pointer items-center justify-between gap-6 px-6 py-5 text-left text-[17px] font-medium transition-colors duration-200 hover:text-white"
                  >
                    {faq.q}
                    <Plus className={`size-5 shrink-0 text-muted transition-transform duration-300 ${expanded ? 'rotate-45' : ''}`} aria-hidden />
                  </button>
                </h3>
                {/* Kept in the DOM (hidden) so the answers are part of the static HTML. */}
                <div
                  id={`faq-${i}`}
                  role="region"
                  hidden={!expanded}
                  className="px-6 pb-6 leading-relaxed text-muted"
                >
                  {faq.a}
                </div>
              </div>
            )
          })}
        </div>
      </div>
    </section>
  )
}

export function FinalCTA() {
  return (
    <section aria-labelledby="cta-title" className="pb-24 md:pb-32">
      <div className="container-page">
        <Reveal>
          <div className="relative overflow-hidden rounded-3xl border border-line-strong bg-surface px-6 py-16 text-center md:px-16 md:py-20">
            <div aria-hidden className="absolute inset-0 bg-[radial-gradient(60%_80%_at_50%_0%,rgb(109_130_255/0.28),transparent),radial-gradient(40%_60%_at_80%_100%,rgb(52_211_153/0.12),transparent)]" />
            <div className="relative">
              <img src={asset('icon.png')} alt="" width={80} height={80} loading="lazy" className="mx-auto mb-7 size-20" />
              <h2 id="cta-title" className="text-3xl font-semibold tracking-[-0.03em] text-balance sm:text-5xl">
                Ship your next release with a git tag
              </h2>
              <p className="mx-auto mt-5 max-w-xl text-lg text-muted">
                Free and open source. Your Mac, your keys, your pipeline.
              </p>
              <div className="mt-9">
                <DownloadButtons align="center" />
              </div>
            </div>
          </div>
        </Reveal>
      </div>
    </section>
  )
}

export function Footer() {
  return (
    <footer className="border-t border-line py-10">
      <div className="container-page flex flex-col items-center justify-between gap-5 text-sm text-subtle md:flex-row">
        <p className="flex items-center gap-2.5">
          <img src={asset('icon.png')} alt="" width={20} height={20} loading="lazy" className="size-5" />
          {site.name} · Mobile CI/CD for Flutter and React Native on macOS
        </p>
        <nav aria-label="Footer" className="flex items-center gap-6">
          <a href={site.repo} className="inline-flex cursor-pointer items-center gap-2 py-2.5 transition-colors hover:text-fg">
            <GitHubMark className="size-4" /> GitHub
          </a>
          <a href={`${site.repo}/releases`} className="inline-block cursor-pointer py-2.5 transition-colors hover:text-fg">Releases</a>
          <a href={`${site.repo}/blob/main/LICENSE`} className="inline-block cursor-pointer py-2.5 transition-colors hover:text-fg">MIT License</a>
        </nav>
      </div>
    </footer>
  )
}
