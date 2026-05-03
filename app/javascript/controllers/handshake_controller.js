import { Controller } from "@hotwired/stimulus"
import { createHandshake, computeIdentifier, decryptUrl } from "modules/handshake_crypto"

/**
 * Handles the Short-Code Handshake UI for both sender (room view) and receiver (homepage).
 */
export default class extends Controller {
  static targets = [
    "phraseDisplay", "phraseText", "shareButton",
    "toggleButton", "joinForm", "joinInput", "joinButton", "joinError"
  ]

  connect() {
    this.handlePeerConnected = () => this.hidePhraseDisplay()
    document.addEventListener("room:peer-connected", this.handlePeerConnected)
  }

  disconnect() {
    document.removeEventListener("room:peer-connected", this.handlePeerConnected)
  }

  hidePhraseDisplay() {
    if (this.hasPhraseDisplayTarget) {
      this.phraseDisplayTarget.classList.add("hidden")
    }
    if (this.hasShareButtonTarget) {
      this.shareButtonTarget.disabled = true
    }
  }

  // ── Sender: generate handshake and POST blob ──────────────────────

  async share(event) {
    event.preventDefault()
    const button = this.shareButtonTarget
    button.disabled = true

    try {
      const roomUrl = window.location.href
      const { phrase, identifier, encryptedBlob } = await createHandshake(roomUrl)

      const response = await fetch(`/handshakes/${identifier}`, {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          "X-CSRF-Token": this.csrfToken()
        },
        body: JSON.stringify({ blob: encryptedBlob })
      })

      if (!response.ok) {
        throw new Error("Failed to create handshake")
      }

      // Display the phrase to the user
      this.phraseTextTarget.textContent = phrase
      this.phraseDisplayTarget.classList.remove("hidden")
    } catch (error) {
      button.disabled = false
    }
  }

  // ── Receiver: toggle join form ────────────────────────────────────

  toggleJoin(event) {
    event.preventDefault()
    this.joinFormTarget.classList.toggle("hidden")
    if (!this.joinFormTarget.classList.contains("hidden")) {
      this.joinInputTarget.focus()
    }
  }

  // ── Receiver: fetch blob and decrypt ──────────────────────────────

  async join(event) {
    event.preventDefault()
    const input = this.joinInputTarget
    const phrase = input.value.trim().toLowerCase()

    this.hideJoinError()

    if (!this.validPhrase(phrase)) {
      this.showJoinError("Enter 4 words separated by dashes")
      return
    }

    const button = this.joinButtonTarget
    button.disabled = true

    try {
      const identifier = await computeIdentifier(phrase)
      const response = await fetch(`/handshakes/${identifier}`)

      if (response.status === 404) {
        this.showJoinError("Code not found or expired")
        button.disabled = false
        return
      }

      if (!response.ok) {
        throw new Error("Server error")
      }

      const { blob } = await response.json()
      const url = await decryptUrl(blob, phrase)

      window.location.href = url
    } catch (error) {
      this.showJoinError("Invalid code or decryption failed")
      button.disabled = false
    }
  }

  // ── Copy phrase to clipboard ──────────────────────────────────────

  copyPhrase(event) {
    event.preventDefault()
    const phrase = this.phraseTextTarget.textContent
    navigator.clipboard.writeText(phrase)
  }

  // ── Helpers ───────────────────────────────────────────────────────

  validPhrase(phrase) {
    const words = phrase.split("-")
    return words.length === 4 && words.every((w) => w.length > 0)
  }

  showJoinError(message) {
    if (this.hasJoinErrorTarget) {
      this.joinErrorTarget.textContent = message
      this.joinErrorTarget.classList.remove("hidden")
    }
  }

  hideJoinError() {
    if (this.hasJoinErrorTarget) {
      this.joinErrorTarget.classList.add("hidden")
    }
  }

  csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.getAttribute("content") || ""
  }
}
