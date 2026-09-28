import { MotionConfig } from 'motion/react'
import { ActionsSection } from './components/ActionsSection'
import { Comparison, FAQ, Developer, FinalCTA, Footer, ProductShot } from './components/Closing'
import { Hero } from './components/Hero'
import { Nav } from './components/Nav'
import { Features, HowItWorks, WorksWith } from './components/Sections'

export default function App() {
  return (
    <MotionConfig reducedMotion="user">
      <a href="#main" className="sr-only focus:not-sr-only focus:fixed focus:top-3 focus:left-3 focus:z-[60] focus:rounded-lg focus:bg-fg focus:px-4 focus:py-2 focus:text-bg">
        Skip to content
      </a>
      <Nav />
      <main id="main">
        <Hero />
        <WorksWith />
        <HowItWorks />
        <ProductShot />
        <Features />
        <ActionsSection />
        <Comparison />
        <FAQ />
        <FinalCTA />
        <Developer />
      </main>
      <Footer />
    </MotionConfig>
  )
}
