import { Controller } from "@hotwired/stimulus"

// Runs a DOM-only integrity check on connect and displays the result.
// Zero network calls — compares the embedded Propshaft manifest
// against the importmap already in the page.
export default class extends Controller {
  static targets = ["dot", "dotIcon", "panel", "statusIcon", "statusText"]

  async connect() {
    const { runIntegrityCheck } = await import("utils/verifier")
    const result = runIntegrityCheck()

    if (result.isConsistent) {
      this.dotIconTarget.classList.replace("bg-secure-gray", "bg-signal-green")
      this.statusIconTarget.classList.replace("text-secure-gray", "text-signal-green")
      this.statusTextTarget.textContent = `${result.matches}/${result.total} modules match local manifest`
      this.statusTextTarget.classList.replace("text-secure-gray", "text-signal-green")
    } else {
      this.dotIconTarget.classList.replace("bg-secure-gray", "bg-red-400")
      this.statusIconTarget.classList.replace("text-secure-gray", "text-red-400")
      this.statusTextTarget.textContent = result.error
        ? "Manifest unavailable"
        : `Mismatch: ${result.matches}/${result.total} modules verified`
      this.statusTextTarget.classList.replace("text-secure-gray", "text-red-400")
    }
  }

  toggle() {
    this.panelTarget.classList.toggle("hidden")
  }
}
