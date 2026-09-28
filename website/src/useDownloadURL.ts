import { useEffect, useState } from 'react'
import { site } from './site'

// The pre-rendered page links to the releases page; once JavaScript runs, the link points at the latest
// release's DMG itself so a click downloads it right away. One request is shared by every button.
let latest: Promise<string | undefined> | undefined

function latestDMG() {
  latest ??= fetch(`https://api.github.com/repos/${site.repoPath}/releases/latest`, {
    headers: { Accept: 'application/vnd.github+json' },
  })
    .then((response) => (response.ok ? response.json() : undefined))
    .then((release?: { assets?: { name: string; browser_download_url: string }[] }) =>
      release?.assets?.find((file) => file.name.endsWith('.dmg'))?.browser_download_url,
    )
    .catch(() => undefined)
  return latest
}

export function useDownloadURL() {
  const [url, setURL] = useState<string>(site.download)
  useEffect(() => {
    let active = true
    latestDMG().then((dmg) => active && dmg && setURL(dmg))
    return () => {
      active = false
    }
  }, [])
  return url
}
