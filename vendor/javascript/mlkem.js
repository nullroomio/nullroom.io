/**
 * ML-KEM-768 wrapper with native WebCrypto feature detection.
 *
 * Tries native crypto.subtle ML-KEM support first (checking both the final
 * "ML-KEM-768" name and the draft "XYBER768D00" name used in some browsers).
 * Falls back to the vendored pure-JS implementation from mlkem_core.
 *
 * Exports a uniform async API regardless of backend.
 */

import { MlKem768 } from "mlkem_core"

let _native = null // null = untested, false = not available, string = algorithm name
let _instance = null

/**
 * Detect if native WebCrypto supports ML-KEM.
 * Tests "ML-KEM-768" (final NIST name) and "XYBER768D00" (Chrome origin trial draft).
 * @returns {Promise<string|false>} Algorithm name string or false
 */
async function detectNative() {
  if (_native !== null) return _native

  const names = ["ML-KEM-768", "XYBER768D00"]
  for (const name of names) {
    try {
      const kp = await crypto.subtle.generateKey({ name }, true, ["deriveBits"])
      // If we get here without throwing, native support exists
      _native = name
      return _native
    } catch {
      // Not supported, try next
    }
  }
  _native = false
  return false
}

/**
 * Initialize the ML-KEM module. Call once at startup (lazy-loadable).
 * Detects native support or prepares the fallback instance.
 */
export async function init() {
  await detectNative()
  if (!_native) {
    _instance = new MlKem768()
  }
}

/**
 * Generate an ML-KEM-768 keypair.
 * @returns {Promise<{publicKey: Uint8Array, secretKey: Uint8Array}>}
 */
export async function generateKeyPair() {
  if (_native) {
    // Native path (future browsers)
    const kp = await crypto.subtle.generateKey({ name: _native }, true, ["deriveBits"])
    const pk = new Uint8Array(await crypto.subtle.exportKey("raw", kp.publicKey))
    const sk = new Uint8Array(await crypto.subtle.exportKey("raw", kp.privateKey))
    return { publicKey: pk, secretKey: sk }
  }

  // Fallback: pure-JS mlkem library
  if (!_instance) _instance = new MlKem768()
  const [pk, sk] = await _instance.generateKeyPair()
  return { publicKey: pk, secretKey: sk }
}

/**
 * Encapsulate: produce a ciphertext and shared secret from a public key.
 * @param {Uint8Array} publicKey The peer's ML-KEM public key
 * @returns {Promise<{ciphertext: Uint8Array, sharedSecret: Uint8Array}>}
 */
export async function encapsulate(publicKey) {
  if (_native) {
    // Native path (future browsers) — import the peer's public key, deriveBits
    const importedPk = await crypto.subtle.importKey(
      "raw", publicKey, { name: _native }, false, []
    )
    // Native KEM encapsulate via deriveBits returns ct || ss
    const result = await crypto.subtle.deriveBits(
      { name: _native, public: importedPk }, null, 0
    )
    // Split based on ML-KEM-768 sizes: ct=1088, ss=32
    const ct = new Uint8Array(result, 0, 1088)
    const ss = new Uint8Array(result, 1088, 32)
    return { ciphertext: ct, sharedSecret: ss }
  }

  // Fallback
  if (!_instance) _instance = new MlKem768()
  const [ct, ss] = await _instance.encap(publicKey)
  return { ciphertext: ct, sharedSecret: ss }
}

/**
 * Decapsulate: recover the shared secret from a ciphertext and secret key.
 * @param {Uint8Array} ciphertext The encapsulated ciphertext
 * @param {Uint8Array} secretKey Our ML-KEM secret key
 * @returns {Promise<Uint8Array>} The 32-byte shared secret
 */
export async function decapsulate(ciphertext, secretKey) {
  if (_native) {
    // Native path (future browsers)
    const importedSk = await crypto.subtle.importKey(
      "raw", secretKey, { name: _native }, false, ["deriveBits"]
    )
    const ss = await crypto.subtle.deriveBits(
      { name: _native, ciphertext }, importedSk, 256
    )
    return new Uint8Array(ss)
  }

  // Fallback
  if (!_instance) _instance = new MlKem768()
  return await _instance.decap(ciphertext, secretKey)
}
