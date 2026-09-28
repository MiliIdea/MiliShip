import { motion, useInView, useReducedMotion } from 'motion/react'
import { Check, ChevronRight } from 'lucide-react'
import { useRef } from 'react'
import { Reveal } from './Reveal'

const groups = [
  { name: 'Checkout release/1.4.0+52', time: '3s' },
  { name: 'Resolve version', time: '1s' },
  { name: 'Install dependencies', time: '38s' },
  { name: 'Android · shorebird release', time: '4m 12s' },
  { name: 'Android · publish to Google Play (internal)', time: '21s' },
  { name: 'iOS · archive', time: '5m 48s' },
  { name: 'iOS · upload to App Store Connect', time: '52s' },
]

const points = [
  'Free on your own Mac — no GitHub Actions minutes, even for private repos',
  'Starts the moment a tag is pushed; Deploy buttons in Mili Ship start runs too',
  'Every step as a collapsible group, failures as annotations, a summary at the end',
  'Cancel in GitHub stops the build; jobs wait while your Mac sleeps',
]

export function ActionsSection() {
  const ref = useRef<HTMLDivElement>(null)
  const inView = useInView(ref, { once: true, margin: '-15%' })
  const reduced = useReducedMotion()

  return (
    <section aria-labelledby="actions-title" id="github-actions" className="scroll-mt-20 py-24 md:py-32">
      <div className="container-page grid items-center gap-14 lg:grid-cols-2 [&>*]:min-w-0">
        <Reveal>
          <p className="mb-3 font-mono text-xs font-medium tracking-[0.2em] text-brand-2 uppercase">GitHub Actions</p>
          <h2 id="actions-title" className="text-3xl font-semibold tracking-[-0.03em] text-balance sm:text-4xl md:text-5xl">
            Your whole team sees every release — in GitHub
          </h2>
          <p className="mt-5 text-lg leading-relaxed text-muted text-pretty">
            Mili Ship installs GitHub’s official self-hosted runner, adds one small workflow to your repository and
            streams each build into GitHub Actions. Your teammates push a tag and watch it ship — no Mac access needed.
          </p>
          <ul className="mt-8 space-y-3.5">
            {points.map((point) => (
              <li key={point} className="flex gap-3 text-[15px] leading-relaxed text-muted">
                <span className="mt-0.5 grid size-5 shrink-0 place-items-center rounded-full bg-ok/15 text-ok">
                  <Check className="size-3.5" strokeWidth={3} aria-hidden />
                </span>
                {point}
              </li>
            ))}
          </ul>
        </Reveal>

        <div ref={ref}>
          <Reveal delay={0.1}>
            <figure
              aria-label="A Mili Ship deployment shown as a GitHub Actions run"
              className="overflow-hidden rounded-2xl border border-line-strong bg-[#0d1117] shadow-2xl shadow-black/50"
            >
              <div className="flex items-center justify-between gap-4 border-b border-white/10 px-5 py-4">
                <div className="min-w-0">
                  <p className="truncate text-sm font-semibold text-fg">Deploy release/1.4.0+52</p>
                  <p className="truncate text-xs text-subtle">Mili Ship · push by a teammate · self-hosted</p>
                </div>
                <span className="inline-flex shrink-0 items-center gap-1.5 rounded-full bg-ok/12 px-2.5 py-1 text-xs font-medium text-ok ring-1 ring-ok/30">
                  <Check className="size-3.5" strokeWidth={3} aria-hidden /> Success
                </span>
              </div>
              <ol className="p-2 font-mono text-[13px]">
                {groups.map((group, i) => (
                  <motion.li
                    key={group.name}
                    initial={reduced ? false : { opacity: 0, x: -8 }}
                    animate={inView || reduced ? { opacity: 1, x: 0 } : undefined}
                    transition={{ delay: 0.15 + i * 0.12, duration: 0.35 }}
                    className="flex items-center gap-2.5 rounded-md px-3 py-2 text-[#c9d1d9] hover:bg-white/[0.04]"
                  >
                    <ChevronRight className="size-3.5 text-subtle" aria-hidden />
                    <Check className="size-4 shrink-0 text-ok" aria-hidden />
                    <span className="flex-1 truncate">{group.name}</span>
                    <span className="text-xs text-subtle">{group.time}</span>
                  </motion.li>
                ))}
              </ol>
              <div className="border-t border-white/10 px-5 py-4 text-sm">
                <p className="flex items-center gap-2 font-semibold text-fg">
                  <Check className="size-4 text-ok" strokeWidth={3} aria-hidden /> Shipped 1.4.0 (52)
                </p>
                <p className="mt-1 text-subtle">Google Play: versionCode 52 → internal · App Store Connect: in TestFlight</p>
              </div>
            </figure>
          </Reveal>
        </div>
      </div>
    </section>
  )
}
