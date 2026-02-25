/**
 * Web Crypto API helper module for nullroom E2EE
 * All encryption/decryption happens in the browser
 */

/**
 * Generate an AES-GCM 256-bit key and export as Base64 string for URL
 * @returns {Promise<string>} Base64-encoded key suitable for URL fragment
 */
export async function generateKey() {
  try {
    // Generate AES-GCM 256-bit key
    const key = await crypto.subtle.generateKey(
      { name: "AES-GCM", length: 256 },
      true, // extractable
      ["encrypt", "decrypt"]
    )

    // Export as JWK (JSON Web Key)
    const jwk = await crypto.subtle.exportKey("jwk", key)

    // Convert to JSON and Base64 encode
    const jsonString = JSON.stringify(jwk)
    const base64 = btoa(jsonString)

    return base64
  } catch (error) {
    console.error("Error generating key:", error)
    throw error
  }
}

/**
 * Import a Base64-encoded key back into a CryptoKey
 * @param {string} keyString Base64-encoded key string
 * @returns {Promise<CryptoKey>} Imported CryptoKey ready for encryption/decryption
 */
export async function importKey(keyString) {
  try {
    // Base64 decode
    const jsonString = atob(keyString)

    // Parse JSON
    const jwk = JSON.parse(jsonString)

    // Import as CryptoKey
    const key = await crypto.subtle.importKey(
      "jwk",
      jwk,
      { name: "AES-GCM" },
      true,
      ["encrypt", "decrypt"]
    )

    return key
  } catch (error) {
    console.error("Error importing key:", error)
    throw error
  }
}

/**
 * Encrypt plaintext with AES-GCM
 * @param {string} plaintext Message to encrypt
 * @param {CryptoKey} key Encryption key
 * @returns {Promise<string>} Base64(IV || ciphertext)
 */
export async function encrypt(plaintext, key) {
  try {
    // Generate random IV (Initialization Vector) - 12 bytes for GCM
    const iv = crypto.getRandomValues(new Uint8Array(12))

    // Encode plaintext as UTF-8
    const encoder = new TextEncoder()
    const plaintextBuffer = encoder.encode(plaintext)

    // Encrypt with AES-GCM
    const ciphertextBuffer = await crypto.subtle.encrypt(
      { name: "AES-GCM", iv: iv },
      key,
      plaintextBuffer
    )

    // Concatenate IV + ciphertext
    const combined = new Uint8Array(iv.length + ciphertextBuffer.byteLength)
    combined.set(iv, 0)
    combined.set(new Uint8Array(ciphertextBuffer), iv.length)

    // Base64 encode for transport/storage
    const binaryString = Array.from(combined)
      .map(byte => String.fromCharCode(byte))
      .join("")
    const base64 = btoa(binaryString)

    return base64
  } catch (error) {
    console.error("Error encrypting:", error)
    throw error
  }
}

/**
 * Decrypt Base64(IV || ciphertext) with AES-GCM
 * @param {string} encryptedString Base64-encoded (IV || ciphertext)
 * @param {CryptoKey} key Decryption key
 * @returns {Promise<string>} Decrypted plaintext
 */
export async function decrypt(encryptedString, key) {
  try {
    // Base64 decode
    const binaryString = atob(encryptedString)
    const bytes = new Uint8Array(binaryString.length)
    for (let i = 0; i < binaryString.length; i++) {
      bytes[i] = binaryString.charCodeAt(i)
    }

    // Extract IV (first 12 bytes)
    const iv = bytes.slice(0, 12)

    // Extract ciphertext (remaining bytes)
    const ciphertextBuffer = bytes.slice(12).buffer

    // Decrypt with AES-GCM
    const plaintextBuffer = await crypto.subtle.decrypt(
      { name: "AES-GCM", iv: iv },
      key,
      ciphertextBuffer
    )

    // Decode UTF-8
    const decoder = new TextDecoder()
    const plaintext = decoder.decode(plaintextBuffer)

    return plaintext
  } catch (error) {
    console.error("Error decrypting:", error)
    throw error
  }
}

/**
 * Encrypt a binary ArrayBuffer with AES-GCM.
 * Returns a new ArrayBuffer of the form: IV (12 bytes) || ciphertext.
 * Used for per-chunk file transfer encryption.
 * @param {ArrayBuffer} buffer Binary data to encrypt
 * @param {CryptoKey} key Encryption key
 * @returns {Promise<ArrayBuffer>}
 */
export async function encryptBuffer(buffer, key) {
  try {
    const iv = crypto.getRandomValues(new Uint8Array(12))

    const ciphertextBuffer = await crypto.subtle.encrypt(
      { name: "AES-GCM", iv: iv },
      key,
      buffer
    )

    // Combine IV + ciphertext into a single ArrayBuffer
    const combined = new Uint8Array(12 + ciphertextBuffer.byteLength)
    combined.set(iv, 0)
    combined.set(new Uint8Array(ciphertextBuffer), 12)

    return combined.buffer
  } catch (error) {
    console.error("Error encrypting buffer:", error)
    throw error
  }
}

/**
 * Decrypt an ArrayBuffer whose first 12 bytes are the AES-GCM IV.
 * Counterpart to encryptBuffer.
 * @param {ArrayBuffer} buffer IV (12 bytes) || ciphertext
 * @param {CryptoKey} key Decryption key
 * @returns {Promise<ArrayBuffer>} Decrypted plaintext as ArrayBuffer
 */
export async function decryptBuffer(buffer, key) {
  try {
    const bytes = new Uint8Array(buffer)
    const iv = bytes.slice(0, 12)
    const ciphertext = bytes.slice(12).buffer

    const plaintextBuffer = await crypto.subtle.decrypt(
      { name: "AES-GCM", iv: iv },
      key,
      ciphertext
    )

    return plaintextBuffer
  } catch (error) {
    console.error("Error decrypting buffer:", error)
    throw error
  }
}
