// Renders the landing page to static HTML after `vite build`, so search engines and link previews get the
// full content and visitors see it before JavaScript loads. The client bundle then hydrates it.
import { readFile, rm, writeFile } from 'node:fs/promises'
import { fileURLToPath } from 'node:url'

const root = fileURLToPath(new URL('..', import.meta.url))
const server = await import(new URL('../dist-ssr/entry-server.js', import.meta.url).href)
const htmlPath = `${root}dist/index.html`

const appHtml = server.render()
const structuredData = [
  {
    '@context': 'https://schema.org',
    '@type': 'SoftwareApplication',
    name: 'Mili Ship',
    description:
      'Mobile CI/CD for Flutter and React Native that runs on your Mac: builds, signs and publishes apps to Google Play and App Store Connect / TestFlight when you push a git tag.',
    applicationCategory: 'DeveloperApplication',
    operatingSystem: 'macOS 13 or later',
    url: server.site.url,
    downloadUrl: server.site.download,
    image: `${server.site.url}og.png`,
    license: 'https://opensource.org/licenses/MIT',
    isAccessibleForFree: true,
    offers: { '@type': 'Offer', price: '0', priceCurrency: 'USD' },
    author: { '@type': 'Organization', name: 'MiliIdea', url: 'https://github.com/MiliIdea' },
    sameAs: [server.site.repo],
  },
  {
    '@context': 'https://schema.org',
    '@type': 'FAQPage',
    mainEntity: server.faqs.map((faq) => ({
      '@type': 'Question',
      name: faq.q,
      acceptedAnswer: { '@type': 'Answer', text: faq.a },
    })),
  },
]
const scripts = structuredData
  .map((data) => `<script type="application/ld+json">${JSON.stringify(data).replace(/</g, '\\u003c')}</script>`)
  .join('\n    ')

const template = await readFile(htmlPath, 'utf8')
if (!template.includes('<!--app-html-->')) throw new Error('dist/index.html has no <!--app-html--> placeholder')
await writeFile(htmlPath, template.replace('<!--app-html-->', appHtml).replace('<!--structured-data-->', scripts))
await rm(`${root}dist-ssr`, { recursive: true, force: true })
console.log(`Pre-rendered dist/index.html (${Math.round(appHtml.length / 1024)} KB of HTML)`)
