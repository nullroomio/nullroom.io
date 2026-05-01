/**
 * Zero-Knowledge Handshake Crypto Module
 *
 * Uses a 4-word BIP-39 phrase as both:
 * - A lookup identifier (SHA-256 hash of the phrase)
 * - An encryption key (PBKDF2-derived AES-GCM 256-bit key)
 *
 * The server never sees the phrase or the plaintext URL.
 */

import { WORDLIST } from "utils/wordlist"

const SALT = new TextEncoder().encode("nullroom-handshake")
const PBKDF2_ITERATIONS = 100_000

/**
 * Generate a 4-word phrase from the BIP-39 wordlist.
 * @returns {string} Dash-separated 4-word phrase (e.g. "neon-zebra-piano-rocket")
 */
export function generatePhrase() {
  const indices = crypto.getRandomValues(new Uint16Array(4))
  const words = Array.from(indices, (i) => WORDLIST[i % WORDLIST.length])
  return words.join("-")
}

/**
 * Derive an AES-GCM 256-bit key from a phrase using PBKDF2.
 * @param {string} phrase The 4-word dash-separated phrase
 * @returns {Promise<CryptoKey>} AES-GCM key for encrypt/decrypt
 */
export async function deriveKey(phrase) {
  const keyMaterial = await crypto.subtle.importKey(
    "raw",
    new TextEncoder().encode(phrase),
    "PBKDF2",
    false,
    ["deriveKey"]
  )

  return crypto.subtle.deriveKey(
    {
      name: "PBKDF2",
      salt: SALT,
      iterations: PBKDF2_ITERATIONS,
      hash: "SHA-256"
    },
    keyMaterial,
    { name: "AES-GCM", length: 256 },
    false,
    ["encrypt", "decrypt"]
  )
}

/**
 * Compute a SHA-256 hash of the phrase, returned as a hex string.
 * Used as the Redis key / URL path parameter — the server never sees the phrase.
 * @param {string} phrase The 4-word dash-separated phrase
 * @returns {Promise<string>} 64-character hex string
 */
export async function computeIdentifier(phrase) {
  const data = new TextEncoder().encode(phrase)
  const hashBuffer = await crypto.subtle.digest("SHA-256", data)
  const hashArray = Array.from(new Uint8Array(hashBuffer))
  return hashArray.map((b) => b.toString(16).padStart(2, "0")).join("")
}

/**
 * Encrypt a URL string using a key derived from the phrase.
 * Format: Base64(IV || ciphertext)
 * @param {string} url The full room URL (including #key fragment)
 * @param {string} phrase The 4-word phrase
 * @returns {Promise<string>} Base64-encoded encrypted blob
 */
export async function encryptUrl(url, phrase) {
  const key = await deriveKey(phrase)
  const iv = crypto.getRandomValues(new Uint8Array(12))
  const plaintext = new TextEncoder().encode(url)

  const ciphertext = await crypto.subtle.encrypt(
    { name: "AES-GCM", iv },
    key,
    plaintext
  )

  // Concatenate IV + ciphertext
  const combined = new Uint8Array(iv.length + ciphertext.byteLength)
  combined.set(iv)
  combined.set(new Uint8Array(ciphertext), iv.length)

  return btoa(String.fromCharCode(...combined))
}

/**
 * Decrypt a Base64 blob back to the original URL using the phrase.
 * @param {string} base64Blob Base64-encoded IV || ciphertext
 * @param {string} phrase The 4-word phrase
 * @returns {Promise<string>} The original room URL
 */
export async function decryptUrl(base64Blob, phrase) {
  const key = await deriveKey(phrase)
  const combined = Uint8Array.from(atob(base64Blob), (c) => c.charCodeAt(0))

  // Split IV (12 bytes) from ciphertext
  const iv = combined.slice(0, 12)
  const ciphertext = combined.slice(12)

  const plaintext = await crypto.subtle.decrypt(
    { name: "AES-GCM", iv },
    key,
    ciphertext
  )

  return new TextDecoder().decode(plaintext)
}

/**
 * Orchestrator: generate a phrase, compute identifier, and encrypt the room URL.
 * @param {string} roomUrl The full room URL (including #key fragment)
 * @returns {Promise<{phrase: string, identifier: string, encryptedBlob: string}>}
 */
export async function createHandshake(roomUrl) {
  const phrase = generatePhrase()
  const [identifier, encryptedBlob] = await Promise.all([
    computeIdentifier(phrase),
    encryptUrl(roomUrl, phrase)
  ])

  return { phrase, identifier, encryptedBlob }
}
