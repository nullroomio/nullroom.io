import { Controller } from "@hotwired/stimulus"
import { createBlindedPayload, unblindSignature, verifySignature } from "utils/blind_crypto"
import { saveBlindToken, loadBlindToken, clearBlindToken } from "utils/blind_token_storage"

// Handles donation receipt payment polling and blind-signature token issuance UX.
export default class extends Controller {
  static targets = ["stateText", "address", "confirmations", "actionButton", "clearButton", "copyButton", "walletLink", "qrImage", "amountText"]

  connect() {
    this.publicKey = null
    this.paymentSessionId = null
    this.pollTimer = null
    this.pendingBlindPayload = null
    this.currentSubaddress = null
    this.currentMoneroUri = null

    const existing = loadBlindToken()
    if (existing) {
      this.renderTokenState()
    } else {
      this.renderIdleState()
    }
  }

  disconnect() {
    this.stopPolling()
  }

  async begin() {
    try {
      this.setActionDisabled(true, "Preparing payment…")

      if (!this.publicKey) await this.fetchPublicKey()

      const response = await fetch("/blind_tokens/session", {
        method: "POST",
        headers: this.defaultHeaders()
      })

      if (!response.ok) throw new Error("Unable to create payment session")
      const data = await response.json()

      this.paymentSessionId = data.payment_session_id
      this.currentSubaddress = data.subaddress
      this.currentMoneroUri = this.buildMoneroUri(data.subaddress, data.amount_piconero)
      this.addressTarget.textContent = data.subaddress
      this.amountTextTarget.textContent = `${this.formatXmrAmount(data.amount_piconero)} XMR`
      this.walletLinkTarget.href = this.currentMoneroUri
      this.walletLinkTarget.classList.remove("hidden")
      this.copyButtonTarget.disabled = false
      this.qrImageTarget.src = `/blind_tokens/qr?payload=${encodeURIComponent(this.currentMoneroUri)}`
      this.qrImageTarget.classList.remove("hidden")
      this.confirmationsTarget.textContent = `0 / ${data.required_confirmations}`
      this.stateTextTarget.textContent = "Waiting for payment"
      this.actionButtonTarget.textContent = "Waiting for confirmations…"
      this.actionButtonTarget.disabled = true

      this.startPolling()
    } catch (error) {
      console.error("Donation flow begin error:", error)
      this.setActionDisabled(false, "Donate with Monero")
      this.stateTextTarget.textContent = "Failed to start payment session"
    }
  }

  async clearToken() {
    clearBlindToken()
    this.renderIdleState()
  }

  async copyAddress() {
    if (!this.currentSubaddress) return

    try {
      await navigator.clipboard.writeText(this.currentSubaddress)
      this.copyButtonTarget.textContent = "Copied"
      setTimeout(() => {
        if (this.hasCopyButtonTarget) this.copyButtonTarget.textContent = "Copy"
      }, 1200)
    } catch (_) {
      this.copyButtonTarget.textContent = "Copy failed"
      setTimeout(() => {
        if (this.hasCopyButtonTarget) this.copyButtonTarget.textContent = "Copy"
      }, 1200)
    }
  }

  async fetchPublicKey() {
    const response = await fetch("/blind_tokens/public_key", {
      headers: { "Accept": "application/json" }
    })

    if (!response.ok) throw new Error("Unable to fetch public key")
    this.publicKey = await response.json()
  }

  startPolling() {
    this.stopPolling()
    this.pollTimer = setInterval(() => this.pollStatus(), 30000)
    this.pollStatus()
  }

  stopPolling() {
    if (!this.pollTimer) return
    clearInterval(this.pollTimer)
    this.pollTimer = null
  }

  async pollStatus() {
    if (!this.paymentSessionId) return

    try {
      const url = `/blind_tokens/status?payment_session_id=${encodeURIComponent(this.paymentSessionId)}`
      const response = await fetch(url, { headers: { "Accept": "application/json" } })
      if (!response.ok) throw new Error("Status poll failed")

      const data = await response.json()
      this.confirmationsTarget.textContent = `${data.confirmations} / ${data.required_confirmations}`

      if (data.status === "waiting") {
        this.stateTextTarget.textContent = "Waiting for payment"
      } else if (data.status === "detected") {
        this.stateTextTarget.textContent = "Payment detected"
      } else if (data.status === "confirming") {
        this.stateTextTarget.textContent = "Confirming on-chain payment"
      } else if (data.status === "ready") {
        this.stateTextTarget.textContent = "Payment confirmed, issuing receipt"
        this.stopPolling()
        await this.issueToken()
      }
    } catch (error) {
      console.error("Donation flow status error:", error)
      this.stateTextTarget.textContent = "Status check failed"
      this.setActionDisabled(false, "Retry")
    }
  }

  async issueToken() {
    try {
      this.pendingBlindPayload = createBlindedPayload({
        modulusHex: this.publicKey.modulus_hex,
        exponentHex: this.publicKey.exponent_hex
      })

      const response = await fetch("/blind_tokens/sign", {
        method: "POST",
        headers: this.defaultHeaders(),
        body: JSON.stringify({
          payment_session_id: this.paymentSessionId,
          blinded_message: this.pendingBlindPayload.blindedMessageHex
        })
      })

      if (!response.ok) throw new Error("Sign request failed")
      const data = await response.json()

      const signatureHex = unblindSignature({
        signedBlindedHex: data.signed_message,
        blindingFactorHex: this.pendingBlindPayload.blindingFactorHex,
        modulusHex: this.publicKey.modulus_hex
      })

      const isValid = verifySignature({
        messageHex: this.pendingBlindPayload.messageHex,
        signatureHex,
        exponentHex: this.publicKey.exponent_hex,
        modulusHex: this.publicKey.modulus_hex
      })

      if (!isValid) throw new Error("Local signature verification failed")

      saveBlindToken({
        messageHex: this.pendingBlindPayload.messageHex,
        signatureHex
      })

      this.renderTokenState()
    } catch (error) {
      console.error("Donation flow token issuance error:", error)
      this.stateTextTarget.textContent = "Token issuance failed"
      this.setActionDisabled(false, "Retry")
    }
  }

  renderIdleState() {
    this.currentSubaddress = null
    this.currentMoneroUri = null
    this.stateTextTarget.textContent = "No donation receipt"
    this.addressTarget.textContent = "—"
    this.amountTextTarget.textContent = "0 XMR"
    this.confirmationsTarget.textContent = "0 / 0"
    this.setActionDisabled(false, "Donate with Monero")
    this.clearButtonTarget.disabled = true
    this.copyButtonTarget.disabled = true
    this.copyButtonTarget.textContent = "Copy"
    this.walletLinkTarget.href = "#"
    this.walletLinkTarget.classList.add("hidden")
    this.qrImageTarget.src = ""
    this.qrImageTarget.classList.add("hidden")
  }

  renderTokenState() {
    this.currentSubaddress = null
    this.currentMoneroUri = null
    this.stateTextTarget.textContent = "Receipt Issued"
    this.addressTarget.textContent = "Stored in vault"
    this.amountTextTarget.textContent = "Paid"
    this.confirmationsTarget.textContent = "Ready"
    this.setActionDisabled(true, "Receipt Active")
    this.clearButtonTarget.disabled = false
    this.copyButtonTarget.disabled = true
    this.copyButtonTarget.textContent = "Copy"
    this.walletLinkTarget.href = "#"
    this.walletLinkTarget.classList.add("hidden")
    this.qrImageTarget.src = ""
    this.qrImageTarget.classList.add("hidden")
  }

  buildMoneroUri(address, amountPiconero) {
    return `monero:${address}?tx_amount=${this.formatXmrAmount(amountPiconero)}`
  }

  formatXmrAmount(amountPiconero) {
    const piconero = BigInt(String(amountPiconero || 0))
    const base = 1_000_000_000_000n
    const whole = piconero / base
    const fraction = piconero % base

    if (fraction === 0n) return whole.toString()

    const fractionStr = fraction.toString().padStart(12, "0").replace(/0+$/, "")
    return `${whole.toString()}.${fractionStr}`
  }

  setActionDisabled(disabled, text) {
    this.actionButtonTarget.disabled = disabled
    this.actionButtonTarget.textContent = text
  }

  defaultHeaders() {
    return {
      "Accept": "application/json",
      "Content-Type": "application/json",
      "X-CSRF-Token": this.csrfToken()
    }
  }

  csrfToken() {
    return document.querySelector('meta[name="csrf-token"]')?.getAttribute("content") || ""
  }
}
