/**
 * Unit tests for the Post-Quantum Hybrid Upgrade
 *
 * Tests:
 * 1. ML-KEM-768 keypair generation + encap/decap produce same shared secret
 * 2. HKDF key derivation produces deterministic output
 * 3. Full PQ upgrade protocol with mock peers (initiator + responder)
 * 4. HMAC confirmation with role-specific labels prevents reflection
 * 5. Tampered HMAC is rejected
 *
 * Run: node test/javascript/pq_upgrade_test.mjs
 */

import { webcrypto } from "node:crypto"
import { strict as assert } from "node:assert"
import { test, describe } from "node:test"

// Polyfill globalThis.crypto for Node.js environment
if (!globalThis.crypto) globalThis.crypto = webcrypto

// ─── Inline the relevant functions (since importmap modules can't be loaded in Node directly) ───

// From mlkem_core.js — import the library directly
import { MlKem768 } from "../../vendor/javascript/mlkem_core.js"

// From encryption.js — deriveHybridKey
async function deriveHybridKey(classicalKey, quantumSecret) {
  const classicalRaw = new Uint8Array(
    await crypto.subtle.exportKey("raw", classicalKey)
  )
  const hkdfKey = await crypto.subtle.importKey(
    "raw", quantumSecret, "HKDF", false, ["deriveKey"]
  )
  return crypto.subtle.deriveKey(
    {
      name: "HKDF",
      hash: "SHA-256",
      salt: classicalRaw,
      info: new TextEncoder().encode("nullroom-hybrid-v1")
    },
    hkdfKey,
    { name: "AES-GCM", length: 256 },
    true,
    ["encrypt", "decrypt"]
  )
}

// From pq_upgrade.js — HMAC helpers
const CONFIRM_LABEL_RESPONDER = "nullroom-pq-confirm-responder"
const CONFIRM_LABEL_INITIATOR = "nullroom-pq-confirm-initiator"

async function computeConfirmHmac(sharedSecret, label) {
  const key = await crypto.subtle.importKey(
    "raw", sharedSecret, { name: "HMAC", hash: "SHA-256" }, false, ["sign"]
  )
  const sig = await crypto.subtle.sign("HMAC", key, new TextEncoder().encode(label))
  return new Uint8Array(sig)
}

async function verifyConfirmHmac(sharedSecret, label, received) {
  const key = await crypto.subtle.importKey(
    "raw", sharedSecret, { name: "HMAC", hash: "SHA-256" }, false, ["verify"]
  )
  return crypto.subtle.verify("HMAC", key, received, new TextEncoder().encode(label))
}

function toBase64(bytes) {
  return Buffer.from(bytes).toString("base64")
}
function fromBase64(str) {
  return new Uint8Array(Buffer.from(str, "base64"))
}

// ─── Tests ──────────────────────────────────────────────────────────────────

describe("ML-KEM-768 Library", () => {
  test("generateKeyPair returns valid keypair", async () => {
    const kem = new MlKem768()
    const [pk, sk] = await kem.generateKeyPair()

    assert.ok(pk instanceof Uint8Array, "public key is Uint8Array")
    assert.ok(sk instanceof Uint8Array, "secret key is Uint8Array")
    assert.equal(pk.length, 1184, "ML-KEM-768 public key is 1184 bytes")
    assert.equal(sk.length, 2400, "ML-KEM-768 secret key is 2400 bytes")
  })

  test("encap + decap produce identical shared secret", async () => {
    const kem = new MlKem768()
    const [pk, sk] = await kem.generateKeyPair()
    const [ct, ssEncap] = await kem.encap(pk)
    const ssDecap = await kem.decap(ct, sk)

    assert.equal(ssEncap.length, 32, "shared secret is 32 bytes")
    assert.equal(ssDecap.length, 32, "decapsulated secret is 32 bytes")
    assert.deepEqual(ssEncap, ssDecap, "encap and decap produce same shared secret")
  })

  test("different keypairs produce different shared secrets", async () => {
    const kem = new MlKem768()
    const [pk1, sk1] = await kem.generateKeyPair()
    const [pk2, sk2] = await kem.generateKeyPair()

    const [ct1, ss1] = await kem.encap(pk1)
    const [ct2, ss2] = await kem.encap(pk2)

    assert.notDeepEqual(ss1, ss2, "different keys produce different secrets")
  })

  test("decap with wrong secret key fails gracefully", async () => {
    const kem = new MlKem768()
    const [pk1, sk1] = await kem.generateKeyPair()
    const [pk2, sk2] = await kem.generateKeyPair()

    const [ct, ssEncap] = await kem.encap(pk1)
    // Decap with the WRONG secret key — should produce different shared secret
    const ssWrong = await kem.decap(ct, sk2)
    assert.notDeepEqual(ssEncap, ssWrong, "wrong key produces different secret")
  })
})

describe("HKDF Key Derivation (deriveHybridKey)", () => {
  test("produces a valid AES-GCM 256-bit key", async () => {
    const classicalKey = await crypto.subtle.generateKey(
      { name: "AES-GCM", length: 256 }, true, ["encrypt", "decrypt"]
    )
    const quantumSecret = crypto.getRandomValues(new Uint8Array(32))

    const hybridKey = await deriveHybridKey(classicalKey, quantumSecret)

    assert.equal(hybridKey.type, "secret", "hybrid key is a secret key")
    assert.equal(hybridKey.algorithm.name, "AES-GCM", "hybrid key is AES-GCM")
    assert.equal(hybridKey.algorithm.length, 256, "hybrid key is 256-bit")
    assert.ok(hybridKey.usages.includes("encrypt"), "key can encrypt")
    assert.ok(hybridKey.usages.includes("decrypt"), "key can decrypt")
  })

  test("same inputs produce same output (deterministic)", async () => {
    const classicalKey = await crypto.subtle.generateKey(
      { name: "AES-GCM", length: 256 }, true, ["encrypt", "decrypt"]
    )
    const quantumSecret = crypto.getRandomValues(new Uint8Array(32))

    const key1 = await deriveHybridKey(classicalKey, quantumSecret)
    const key2 = await deriveHybridKey(classicalKey, quantumSecret)

    const raw1 = new Uint8Array(await crypto.subtle.exportKey("raw", key1))
    const raw2 = new Uint8Array(await crypto.subtle.exportKey("raw", key2))

    assert.deepEqual(raw1, raw2, "same inputs produce same hybrid key")
  })

  test("different quantum secrets produce different keys", async () => {
    const classicalKey = await crypto.subtle.generateKey(
      { name: "AES-GCM", length: 256 }, true, ["encrypt", "decrypt"]
    )
    const qs1 = crypto.getRandomValues(new Uint8Array(32))
    const qs2 = crypto.getRandomValues(new Uint8Array(32))

    const key1 = await deriveHybridKey(classicalKey, qs1)
    const key2 = await deriveHybridKey(classicalKey, qs2)

    const raw1 = new Uint8Array(await crypto.subtle.exportKey("raw", key1))
    const raw2 = new Uint8Array(await crypto.subtle.exportKey("raw", key2))

    assert.notDeepEqual(raw1, raw2, "different quantum secrets produce different keys")
  })

  test("different classical keys produce different hybrid keys", async () => {
    const ck1 = await crypto.subtle.generateKey(
      { name: "AES-GCM", length: 256 }, true, ["encrypt", "decrypt"]
    )
    const ck2 = await crypto.subtle.generateKey(
      { name: "AES-GCM", length: 256 }, true, ["encrypt", "decrypt"]
    )
    const quantumSecret = crypto.getRandomValues(new Uint8Array(32))

    const key1 = await deriveHybridKey(ck1, quantumSecret)
    const key2 = await deriveHybridKey(ck2, quantumSecret)

    const raw1 = new Uint8Array(await crypto.subtle.exportKey("raw", key1))
    const raw2 = new Uint8Array(await crypto.subtle.exportKey("raw", key2))

    assert.notDeepEqual(raw1, raw2, "different classical keys produce different hybrid keys")
  })
})

describe("HMAC Confirmation", () => {
  test("valid HMAC verifies correctly", async () => {
    const secret = crypto.getRandomValues(new Uint8Array(32))
    const hmac = await computeConfirmHmac(secret, CONFIRM_LABEL_RESPONDER)
    const valid = await verifyConfirmHmac(secret, CONFIRM_LABEL_RESPONDER, hmac)
    assert.ok(valid, "valid HMAC should verify")
  })

  test("role-specific labels produce different HMACs (anti-reflection)", async () => {
    const secret = crypto.getRandomValues(new Uint8Array(32))
    const hmacR = await computeConfirmHmac(secret, CONFIRM_LABEL_RESPONDER)
    const hmacI = await computeConfirmHmac(secret, CONFIRM_LABEL_INITIATOR)
    assert.notDeepEqual(hmacR, hmacI, "different labels produce different HMACs")
  })

  test("reflection attack fails — responder HMAC doesn't verify as initiator", async () => {
    const secret = crypto.getRandomValues(new Uint8Array(32))
    const hmacR = await computeConfirmHmac(secret, CONFIRM_LABEL_RESPONDER)
    const valid = await verifyConfirmHmac(secret, CONFIRM_LABEL_INITIATOR, hmacR)
    assert.ok(!valid, "responder HMAC must not verify under initiator label")
  })

  test("wrong secret fails verification", async () => {
    const secret1 = crypto.getRandomValues(new Uint8Array(32))
    const secret2 = crypto.getRandomValues(new Uint8Array(32))
    const hmac = await computeConfirmHmac(secret1, CONFIRM_LABEL_RESPONDER)
    const valid = await verifyConfirmHmac(secret2, CONFIRM_LABEL_RESPONDER, hmac)
    assert.ok(!valid, "HMAC with wrong secret must not verify")
  })
})

describe("Full PQ Upgrade Protocol (Mock Peers)", () => {
  test("initiator and responder derive identical hybrid keys", async () => {
    const kem = new MlKem768()

    // Shared classical key (simulates the URL key both sides have)
    const classicalKey = await crypto.subtle.generateKey(
      { name: "AES-GCM", length: 256 }, true, ["encrypt", "decrypt"]
    )

    // ── Simulate protocol ──

    // Step 1: Initiator generates keypair, sends public key
    const [pk, sk] = await kem.generateKeyPair()
    const msg1 = { type: "pq-pubkey", data: toBase64(pk) }

    // Step 2: Responder receives pubkey, encapsulates, sends ct + confirm
    const receivedPk = fromBase64(msg1.data)
    const [ct, ssResponder] = await kem.encap(receivedPk)
    const responderHmac = await computeConfirmHmac(ssResponder, CONFIRM_LABEL_RESPONDER)
    const msg2 = {
      type: "pq-encap",
      data: toBase64(ct),
      confirm: toBase64(responderHmac)
    }

    // Step 3: Initiator receives encap, decapsulates, verifies responder HMAC
    const receivedCt = fromBase64(msg2.data)
    const ssInitiator = await kem.decap(receivedCt, sk)

    // Verify shared secrets match
    assert.deepEqual(ssInitiator, ssResponder, "both sides have same shared secret")

    // Verify responder's HMAC
    const responderHmacReceived = fromBase64(msg2.confirm)
    const validR = await verifyConfirmHmac(ssInitiator, CONFIRM_LABEL_RESPONDER, responderHmacReceived)
    assert.ok(validR, "initiator verifies responder HMAC")

    // Initiator sends confirmation
    const initiatorHmac = await computeConfirmHmac(ssInitiator, CONFIRM_LABEL_INITIATOR)
    const msg3 = { type: "pq-confirm", data: toBase64(initiatorHmac) }

    // Step 4: Responder verifies initiator HMAC
    const initiatorHmacReceived = fromBase64(msg3.data)
    const validI = await verifyConfirmHmac(ssResponder, CONFIRM_LABEL_INITIATOR, initiatorHmacReceived)
    assert.ok(validI, "responder verifies initiator HMAC")

    // Both derive hybrid keys
    const hybridKeyInitiator = await deriveHybridKey(classicalKey, ssInitiator)
    const hybridKeyResponder = await deriveHybridKey(classicalKey, ssResponder)

    const rawI = new Uint8Array(await crypto.subtle.exportKey("raw", hybridKeyInitiator))
    const rawR = new Uint8Array(await crypto.subtle.exportKey("raw", hybridKeyResponder))

    assert.deepEqual(rawI, rawR, "both sides derive identical hybrid key")
  })

  test("MITM with different quantum secret is detected", async () => {
    const kem = new MlKem768()

    const classicalKey = await crypto.subtle.generateKey(
      { name: "AES-GCM", length: 256 }, true, ["encrypt", "decrypt"]
    )

    // Initiator generates keypair
    const [pk, sk] = await kem.generateKeyPair()

    // MITM generates their own encapsulation (NOT using the real pk)
    const [mitmPk, mitmSk] = await kem.generateKeyPair()
    const [mitmCt, mitmSs] = await kem.encap(mitmPk)

    // MITM sends their ct but claims it's for the initiator's pk
    const mitmHmac = await computeConfirmHmac(mitmSs, CONFIRM_LABEL_RESPONDER)

    // Initiator decapsulates with real sk — gets DIFFERENT shared secret
    // Note: decap won't throw, it just produces a different SS (KEM property)
    const ssInitiator = await kem.decap(mitmCt, sk)

    // The HMAC verification should fail because secrets differ
    const valid = await verifyConfirmHmac(ssInitiator, CONFIRM_LABEL_RESPONDER, mitmHmac)
    assert.ok(!valid, "MITM HMAC fails verification — attack detected")
  })

  test("hybrid key can encrypt and decrypt", async () => {
    const kem = new MlKem768()
    const classicalKey = await crypto.subtle.generateKey(
      { name: "AES-GCM", length: 256 }, true, ["encrypt", "decrypt"]
    )

    const [pk, sk] = await kem.generateKeyPair()
    const [ct, ss] = await kem.encap(pk)
    const hybridKey = await deriveHybridKey(classicalKey, ss)

    // Encrypt with hybrid key
    const iv = crypto.getRandomValues(new Uint8Array(12))
    const plaintext = new TextEncoder().encode("Hello, quantum-safe world!")
    const ciphertext = await crypto.subtle.encrypt(
      { name: "AES-GCM", iv }, hybridKey, plaintext
    )

    // Decrypt with same hybrid key
    const decrypted = await crypto.subtle.decrypt(
      { name: "AES-GCM", iv }, hybridKey, ciphertext
    )

    assert.deepEqual(
      new Uint8Array(decrypted),
      plaintext,
      "hybrid key encrypts and decrypts correctly"
    )
  })
})
