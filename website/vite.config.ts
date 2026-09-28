import tailwindcss from '@tailwindcss/vite'
import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'

// Served by Vercel at https://ship.mili.today/
export default defineConfig({
  plugins: [react(), tailwindcss()],
})
