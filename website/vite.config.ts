import tailwindcss from '@tailwindcss/vite'
import react from '@vitejs/plugin-react'
import { defineConfig } from 'vite'

// Served from GitHub Pages at https://miliidea.github.io/MiliShip/
export default defineConfig({
  base: '/MiliShip/',
  plugins: [react(), tailwindcss()],
})
