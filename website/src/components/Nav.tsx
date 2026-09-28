import { useEffect, useState } from 'react'
import { asset, site } from '../site'
import { GitHubMark } from './GitHubMark'

const links = [
  { href: '#features', label: 'Features' },
  { href: '#how-it-works', label: 'How it works' },
  { href: '#github-actions', label: 'GitHub Actions' },
  { href: '#faq', label: 'FAQ' },
]

export function Nav() {
  const [scrolled, setScrolled] = useState(false)

  useEffect(() => {
    const onScroll = () => setScrolled(window.scrollY > 8)
    onScroll()
    window.addEventListener('scroll', onScroll, { passive: true })
    return () => window.removeEventListener('scroll', onScroll)
  }, [])

  return (
    <header
      className={`fixed inset-x-0 top-0 z-50 transition-colors duration-300 ${
        scrolled ? 'border-b border-line bg-bg/75 backdrop-blur-xl' : 'border-b border-transparent'
      }`}
    >
      <nav aria-label="Main" className="container-page flex h-16 items-center justify-between gap-6">
        <a href="#top" className="flex cursor-pointer items-center gap-2.5 font-semibold tracking-tight">
          <img src={asset('icon.png')} alt="" width={32} height={32} className="size-8" />
          <span>{site.name}</span>
        </a>
        <ul className="hidden items-center gap-7 text-sm text-muted md:flex">
          {links.map((link) => (
            <li key={link.href}>
              <a href={link.href} className="inline-block cursor-pointer py-2.5 transition-colors duration-200 hover:text-fg">
                {link.label}
              </a>
            </li>
          ))}
        </ul>
        <div className="flex items-center gap-2">
          <a
            href={site.repo}
            aria-label="Mili Ship on GitHub"
            className="grid size-10 cursor-pointer place-items-center rounded-lg text-muted transition-colors duration-200 hover:bg-white/5 hover:text-fg"
          >
            <GitHubMark />
          </a>
          <a
            href={site.download}
            className="inline-flex h-10 cursor-pointer items-center rounded-lg bg-fg px-4 text-sm font-semibold text-bg transition-colors duration-200 hover:bg-white"
          >
            Download
          </a>
        </div>
      </nav>
    </header>
  )
}
