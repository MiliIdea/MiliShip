import { StrictMode } from 'react'
import { createRoot, hydrateRoot } from 'react-dom/client'
import './index.css'
import App from './App.tsx'

const root = document.getElementById('root')!
const app = (
  <StrictMode>
    <App />
  </StrictMode>
)

// The build pre-renders the page to static HTML (for search engines and a fast first paint); hydrate it.
if (root.firstElementChild) hydrateRoot(root, app) // dev serves an empty root with a placeholder comment
else createRoot(root).render(app)
