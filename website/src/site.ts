/** Everything that changes between releases lives here. */
export const site = {
  name: 'Mili Ship',
  url: 'https://miliidea.github.io/MiliShip/',
  repo: 'https://github.com/MiliIdea/MiliShip',
  download: 'https://github.com/MiliIdea/MiliShip/releases/latest',
  /** Set once Mili Ship is listed; the official Mac App Store badge then appears next to Download. */
  appStoreURL: '',
  minimumMacOS: 'macOS 13',
} as const

export const asset = (path: string) => `${import.meta.env.BASE_URL}${path}`
