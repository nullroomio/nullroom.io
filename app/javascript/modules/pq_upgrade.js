/**
 * Post-Quantum Upgrade Module for nullroom
 *
 * Performs an ML-KEM-768 key exchange over the WebRTC data channel immediately
 * after it opens, then fuses the quantum shared secret with the classical URL
 * key via HKDF to produce a hybrid session key.
 *
 * Protocol (3 messages total):
 *   1. Initiator → Responder: {type: "pq-pubkey", data: "<base64-pk>"}
 *   2. Responder → Initiator: {type: "pq-encap", data: "<base64-ct>", confirm: "<base64-hmac>"}
 *   3. Initiator → Responder: {type: "pq-confirm", data: "<base64-hmac>"}
 *
 * Both sides switch to K_H only after mutual HMAC verification.
 */

import { deriveHybridKey } from "modules/encryption"
import { devLog } from "modules/dev_logger"

const PQ_TIMEOUT_MS = 10_000
const CONFIRM_LABEL_RESPONDER = "nullroom-pq-confirm-responder"
const CONFIRM_LABEL_INITIATOR = "nullroom-pq-confirm-initiator"

/**
 * Encode a Uint8Array to Base64 string.
 */
function toBase64(bytes) {
  return btoa(String.fromCharCode(...bytes))
}

/**
 * Decode a Base64 string to Uint8Array.
 */
function fromBase64(str) {
  return Uint8Array.from(atob(str), c => c.charCodeAt(0))
}

/**
 * Compute HMAC-SHA-256 for key confirmation.
 * @param {Uint8Array} sharedSecret The derived quantum secret
 * @param {string} label Role-specific label to prevent reflection attacks
 * @returns {Promise<Uint8Array>} 32-byte HMAC
 */
async function computeConfirmHmac(sharedSecret, label) {
  const key = await crypto.subtle.importKey(
    "raw", sharedSecret, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]
  )
  const sig = await crypto.subtle.sign(
    "HMAC", key, new TextEncoder().encode(label)
  )
  return new Uint8Array(sig)
}

/**
 * Verify an HMAC-SHA-256 confirmation.
 * @param {Uint8Array} sharedSecret The derived quantum secret
 * @param {string} label Role-specific label
 * @param {Uint8Array} received The HMAC bytes to verify
 * @returns {Promise<boolean>}
 */
async function verifyConfirmHmac(sharedSecret, label, received) {
  const key = await crypto.subtle.importKey(
    "raw", sharedSecret, { name: "HMAC", hash: "SHA-256" }, false, ["verify"]
  )
  return crypto.subtle.verify(
    "HMAC", key, received, new TextEncoder().encode(label)
  )
}

/**
 * Perform the post-quantum key upgrade over an open data channel.
 *
 * @param {object} peer The PeerConnection instance (must have send() and allow message interception)
 * @param {CryptoKey} classicalKey The AES-GCM key from the URL fragment
 * @param {boolean} isInitiator Whether this peer is the connection initiator
 * @param {Promise} mlkemReady A promise that resolves when the mlkem module is initialized
 * @param {function} [onProgress] Optional callback for boot sequence progress messages
 * @returns {Promise<CryptoKey>} The hybrid AES-GCM key (K_H)
 */
export async function performPQUpgrade(peer, classicalKey, isInitiator, mlkemReady, onProgress) {
  const progress = typeof onProgress === "function" ? onProgress : () => {}
  // Wait for ML-KEM library to be ready
  const mlkem = await mlkemReady

  return new Promise((resolve, reject) => {
    const timeout = setTimeout(() => {
      cleanup()
      reject(new Error("Post-quantum upgrade timed out"))
    }, PQ_TIMEOUT_MS)

    // Message handler for PQ protocol messages
    const handler = async (msgStr) => {
      try {
        const msg = JSON.parse(msgStr)
        if (!msg.type || !msg.type.startsWith("pq-")) return false
        await processMessage(msg)
        return true // consumed
      } catch {
        return false // not a PQ message
      }
    }

    // Store the handler so the room controller can route messages to it
    peer._pqHandler = handler

    function cleanup() {
      clearTimeout(timeout)
      peer._pqHandler = null
    }

    async function processMessage(msg) {
      if (isInitiator) {
        await handleInitiatorMessage(msg)
      } else {
        await handleResponderMessage(msg)
      }
    }

    // ── Initiator Flow ──────────────────────────────────────────────

    async function runInitiator() {
      // Step 1: Generate keypair and send public key
      const { publicKey, secretKey } = await mlkem.generateKeyPair()
      devLog("[PQ] Initiator: generated ML-KEM-768 keypair", { publicKeyBytes: publicKey.length })
      progress(">> EXCHANGING_ML-KEM-768_PUBLIC_SHARES...")
      peer.send(JSON.stringify({ type: "pq-pubkey", data: toBase64(publicKey) }))
      devLog("[PQ] Initiator: sent pq-pubkey")

      // Store secretKey for use in message handler
      peer._pqSecretKey = secretKey
    }

    async function handleInitiatorMessage(msg) {
      if (msg.type === "pq-encap") {
        devLog("[PQ] Initiator: received pq-encap", { ciphertextLen: msg.data.length, hasConfirm: !!msg.confirm })
        // Step 2: Received encapsulated ciphertext + responder confirmation
        const ciphertext = fromBase64(msg.data)
        const responderHmac = fromBase64(msg.confirm)
        const secretKey = peer._pqSecretKey
        delete peer._pqSecretKey

        // Decapsulate to get shared secret
        const sharedSecret = await mlkem.decapsulate(ciphertext, secretKey)
        devLog("[PQ] Initiator: decapsulated shared secret", { bytes: sharedSecret.length })

        // Verify responder's HMAC
        const valid = await verifyConfirmHmac(sharedSecret, CONFIRM_LABEL_RESPONDER, responderHmac)
        devLog("[PQ] Initiator: responder HMAC valid =", valid)
        if (!valid) {
          cleanup()
          reject(new Error("Post-quantum confirmation failed: responder HMAC invalid"))
          return
        }

        progress(">> VERIFYING_MUTUAL_HMAC_INTEGRITY...")

        // Send our confirmation HMAC
        const initiatorHmac = await computeConfirmHmac(sharedSecret, CONFIRM_LABEL_INITIATOR)
        peer.send(JSON.stringify({ type: "pq-confirm", data: toBase64(initiatorHmac) }))
        devLog("[PQ] Initiator: sent pq-confirm")

        // Derive hybrid key
        const hybridKey = await deriveHybridKey(classicalKey, sharedSecret)
        devLog("[PQ] Initiator: hybrid key derived ✓")
        progress(">> DERIVING_PQ_SESSION_KEYS: [HKDF-SHA-256]")
        cleanup()
        resolve(hybridKey)
      }
    }

    // ── Responder Flow ──────────────────────────────────────────────

    async function handleResponderMessage(msg) {
      if (msg.type === "pq-pubkey") {
        devLog("[PQ] Responder: received pq-pubkey", { publicKeyLen: msg.data.length })
        // Step 1: Received initiator's public key
        const publicKey = fromBase64(msg.data)

        // Encapsulate to produce ciphertext + shared secret
        const { ciphertext, sharedSecret } = await mlkem.encapsulate(publicKey)
        devLog("[PQ] Responder: encapsulated", { ciphertextBytes: ciphertext.length, secretBytes: sharedSecret.length })
        progress(">> EXCHANGING_ML-KEM-768_PUBLIC_SHARES...")

        // Store shared secret for confirmation verification
        peer._pqSharedSecret = sharedSecret

        // Compute our confirmation HMAC
        const responderHmac = await computeConfirmHmac(sharedSecret, CONFIRM_LABEL_RESPONDER)

        // Send encapsulated ciphertext + our confirmation in one message
        peer.send(JSON.stringify({
          type: "pq-encap",
          data: toBase64(ciphertext),
          confirm: toBase64(responderHmac)
        }))
        devLog("[PQ] Responder: sent pq-encap + confirm")
      } else if (msg.type === "pq-confirm") {
        devLog("[PQ] Responder: received pq-confirm")
        // Step 2: Received initiator's confirmation HMAC
        const initiatorHmac = fromBase64(msg.data)
        const sharedSecret = peer._pqSharedSecret
        delete peer._pqSharedSecret

        // Verify initiator's HMAC
        const valid = await verifyConfirmHmac(sharedSecret, CONFIRM_LABEL_INITIATOR, initiatorHmac)
        devLog("[PQ] Responder: initiator HMAC valid =", valid)
        if (!valid) {
          cleanup()
          reject(new Error("Post-quantum confirmation failed: initiator HMAC invalid"))
          return
        }

        progress(">> VERIFYING_MUTUAL_HMAC_INTEGRITY...")

        // Derive hybrid key
        const hybridKey = await deriveHybridKey(classicalKey, sharedSecret)
        devLog("[PQ] Responder: hybrid key derived ✓")
        progress(">> DERIVING_PQ_SESSION_KEYS: [HKDF-SHA-256]")
        cleanup()
        resolve(hybridKey)
      }
    }

    // Start the protocol
    if (isInitiator) {
      runInitiator().catch(err => { cleanup(); reject(err) })
    }
    // Responder just waits for the first message
  })
}
