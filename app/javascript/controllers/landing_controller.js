import { Controller } from "@hotwired/stimulus"
import { generateKey } from "modules/encryption"

// Handles room creation and client-side key generation on the landing page.
export default class extends Controller {
  static targets = ["buttonText", "errorContainer", "errorMessage"]

  connect() {
    // The create-room button is disabled via JS and the redirect on success
    // bypasses Turbo (raw window.location.assign), so bfcache can restore this
    // page with the button still disabled after the user navigates back.
    this.resetButton = this.resetButton.bind(this)
    window.addEventListener("pageshow", this.resetButton)
  }

  disconnect() {
    window.removeEventListener("pageshow", this.resetButton)
  }

  // Restore the button's idle state when the page is served from bfcache.
  resetButton(event) {
    if (!event.persisted) return

    const button = this.element.querySelector('[data-action="landing#createRoom"]')
    if (button) button.disabled = false
    this.buttonTextTarget.textContent = "Create Secure Room"
  }

  // Create a room on the server, generate the client key, and redirect with hash.
  createRoom(event) {
    event.preventDefault()

    const button = event.currentTarget
    button.disabled = true

    // Show loading state
    this.buttonTextTarget.textContent = "Creating room..."

    // POST to /rooms to create a new room (returns JSON, not redirect)
    fetch("/rooms", {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        "X-CSRF-Token": this.getCSRFToken()
      }
    })
      .then(response => {
        if (!response.ok) throw new Error("Failed to create room")
        return response.json()
      })
      .then(async (data) => {
        const { room_id, turn_servers } = data

        // Generate encryption key client-side
        const encryptionKey = await generateKey()

        // Browser-side redirect: key is born in browser and never touches HTTP
        window.location.assign(`/rooms/${room_id}#${encryptionKey}`)
      })
      .catch((error) => {
        console.error("Room creation error:", error)

        // Show error message
        this.showError("Failed to create room. Please try again.")

        // Reset button
        button.disabled = false
        this.buttonTextTarget.textContent = "Create Room"
      })
  }

  // Display an error message with auto-hide.
  showError(message) {
    this.errorMessageTarget.textContent = message
    this.errorContainerTarget.classList.remove("hidden")

    // Auto-hide after 5 seconds
    setTimeout(() => {
      this.errorContainerTarget.classList.add("hidden")
    }, 5000)
  }

  // Read CSRF token from the page for POST requests.
  getCSRFToken() {
    return document.querySelector('meta[name="csrf-token"]')?.getAttribute("content") || ""
  }
}
