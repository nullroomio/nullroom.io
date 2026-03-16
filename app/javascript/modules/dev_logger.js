const root = document.documentElement
const env = root && root.dataset ? root.dataset.env : null
const isDevelopment = env === "development" || env === "test"

export function devLog(...args) {
  if (isDevelopment && window.console && typeof window.console.log === "function") {
    window.console.log(...args)
  }
}

export function devInfo(...args) {
  if (isDevelopment && window.console && typeof window.console.info === "function") {
    window.console.info(...args)
  }
}
