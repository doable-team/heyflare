import * as React from "react"

const MOBILE_BREAKPOINT = 768

/**
 * Answered synchronously on the first render. Starting from `undefined` and deciding in an effect
 * meant every phone mounted the desktop tree — and fired its queries — before swapping to mobile.
 */
export function useIsMobile() {
  const [isMobile, setIsMobile] = React.useState(() => typeof window !== "undefined" && window.innerWidth < MOBILE_BREAKPOINT)

  React.useEffect(() => {
    const mql = window.matchMedia(`(max-width: ${MOBILE_BREAKPOINT - 1}px)`)
    const onChange = () => setIsMobile(window.innerWidth < MOBILE_BREAKPOINT)
    mql.addEventListener("change", onChange)
    onChange()
    return () => mql.removeEventListener("change", onChange)
  }, [])

  return isMobile
}
