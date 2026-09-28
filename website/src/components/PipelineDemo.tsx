import { AnimatePresence, motion, useInView, useReducedMotion } from 'motion/react'
import { Check, LoaderCircle } from 'lucide-react'
import { useEffect, useRef, useState } from 'react'

const steps = [
  { name: 'Checkout release/1.4.0+52', detail: '0:03' },
  { name: 'Install dependencies', detail: 'flutter pub get' },
  { name: 'Android · shorebird release', detail: '.aab signed' },
  { name: 'Publish to Google Play', detail: 'internal track' },
  { name: 'iOS · archive & sign', detail: 'automatic signing' },
  { name: 'Upload to App Store Connect', detail: 'TestFlight' },
]

/**
 * A looping, illustrative deployment. Server-rendered in its finished state so the content is
 * readable without JavaScript; the animation starts once it scrolls into view.
 */
export function PipelineDemo() {
  const ref = useRef<HTMLDivElement>(null)
  const inView = useInView(ref, { margin: '-10%' })
  const reduced = useReducedMotion()
  const [active, setActive] = useState(steps.length)
  const done = active >= steps.length

  useEffect(() => {
    if (reduced || !inView) return
    const delay = active === steps.length ? 3200 : 950
    const timer = setTimeout(() => setActive((i) => (i >= steps.length ? 0 : i + 1)), delay)
    return () => clearTimeout(timer)
  }, [active, inView, reduced])

  return (
    <div ref={ref} className="relative">
      <div aria-hidden className="absolute -inset-6 rounded-[2rem] bg-[radial-gradient(60%_60%_at_50%_40%,rgb(109_130_255/0.35),transparent)] blur-2xl" />
      <figure
        aria-label="Example deployment: a release tag is built, signed and published to Google Play and TestFlight"
        className="relative overflow-hidden rounded-2xl border border-line-strong bg-surface/90 shadow-2xl shadow-black/50 backdrop-blur"
      >
        <div className="flex items-center gap-2 border-b border-line px-4 py-3">
          <span className="size-3 rounded-full bg-[#ff5f57]" />
          <span className="size-3 rounded-full bg-[#febc2e]" />
          <span className="size-3 rounded-full bg-[#28c840]" />
          <span className="ml-3 truncate font-mono text-xs text-subtle">Mili Ship — release/1.4.0+52</span>
        </div>

        <div className="border-b border-line bg-black/30 px-4 py-3 font-mono text-[13px] leading-relaxed break-words">
          <span className="text-ok">~/app</span> <span className="text-subtle">$</span>{' '}
          <span className="text-fg">git tag release/1.4.0+52 && git push --tags</span>
        </div>

        <ol className="space-y-1 p-3">
          {steps.map((step, i) => {
            const state = i < active ? 'done' : i === active ? 'running' : 'waiting'
            return (
              <li
                key={step.name}
                className={`flex items-center gap-3 rounded-lg px-3 py-2.5 transition-colors duration-300 ${
                  state === 'running' ? 'bg-brand/10' : ''
                }`}
              >
                <span className="grid size-6 shrink-0 place-items-center">
                  {state === 'done' && (
                    <motion.span
                      initial={{ scale: 0.4, opacity: 0 }}
                      animate={{ scale: 1, opacity: 1 }}
                      transition={{ type: 'spring', stiffness: 500, damping: 25 }}
                      className="grid size-5 place-items-center rounded-full bg-ok/15 text-ok"
                    >
                      <Check className="size-3.5" strokeWidth={3} aria-hidden />
                    </motion.span>
                  )}
                  {state === 'running' && <LoaderCircle className="size-5 animate-spin text-brand-2" aria-hidden />}
                  {state === 'waiting' && <span className="size-2 rounded-full bg-line-strong" />}
                </span>
                <span className={`flex-1 truncate text-sm ${state === 'waiting' ? 'text-subtle' : 'text-fg'}`}>{step.name}</span>
                <span className="hidden font-mono text-xs text-subtle sm:block">{step.detail}</span>
              </li>
            )
          })}
        </ol>

        <div className="relative h-14 border-t border-line">
          <AnimatePresence mode="wait">
            {done ? (
              <motion.p
                key="done"
                initial={{ opacity: 0, y: 6 }}
                animate={{ opacity: 1, y: 0 }}
                exit={{ opacity: 0, y: -6 }}
                transition={{ duration: 0.3 }}
                className="absolute inset-0 flex items-center gap-2 px-5 text-sm"
              >
                <span className="size-2 rounded-full bg-ok shadow-[0_0_12px_var(--color-ok)]" />
                <span className="font-medium text-fg">Shipped 1.4.0 (52)</span>
                <span className="text-muted">to Google Play and TestFlight</span>
              </motion.p>
            ) : (
              <motion.div
                key="progress"
                initial={{ opacity: 0 }}
                animate={{ opacity: 1 }}
                exit={{ opacity: 0 }}
                className="absolute inset-0 flex items-center px-5"
              >
                <div className="h-1.5 w-full overflow-hidden rounded-full bg-white/5">
                  <motion.div
                    className="h-full origin-left rounded-full bg-gradient-to-r from-brand to-brand-2"
                    initial={{ scaleX: 0 }}
                    animate={{ scaleX: active / steps.length }}
                    transition={{ duration: 0.5, ease: 'easeOut' }}
                  />
                </div>
              </motion.div>
            )}
          </AnimatePresence>
        </div>
      </figure>
    </div>
  )
}
