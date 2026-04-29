function stripHexPrefix(value) {
  return String(value || "").replace(/^0x/i, "")
}

function hexToBigInt(value) {
  const hex = stripHexPrefix(value)
  if (!/^[0-9a-fA-F]+$/.test(hex)) throw new Error("Invalid hex input")
  return BigInt(`0x${hex}`)
}

function bigIntToHex(value) {
  if (value < 0n) throw new Error("Negative values are not supported")
  return value.toString(16)
}

function modPow(base, exponent, modulus) {
  if (modulus <= 0n) throw new Error("Modulus must be positive")
  let result = 1n
  let b = base % modulus
  let e = exponent

  while (e > 0n) {
    if (e & 1n) result = (result * b) % modulus
    e >>= 1n
    b = (b * b) % modulus
  }

  return result
}

function gcd(a, b) {
  let x = a
  let y = b
  while (y !== 0n) {
    const temp = y
    y = x % y
    x = temp
  }
  return x < 0n ? -x : x
}

function modInverse(a, m) {
  let t = 0n
  let newT = 1n
  let r = m
  let newR = ((a % m) + m) % m

  while (newR !== 0n) {
    const q = r / newR
    ;[t, newT] = [newT, t - q * newT]
    ;[r, newR] = [newR, r - q * newR]
  }

  if (r !== 1n) throw new Error("Value is not invertible modulo n")
  if (t < 0n) t += m
  return t
}

function randomBigInt(bytes = 32) {
  const random = new Uint8Array(bytes)
  crypto.getRandomValues(random)

  let hex = ""
  random.forEach((byte) => {
    hex += byte.toString(16).padStart(2, "0")
  })

  return BigInt(`0x${hex}`)
}

function randomMessage(n) {
  // Blind-token message must carry strong entropy for raw RSA blind signatures.
  // 32 bytes = 256 bits of entropy.
  let message
  do {
    message = randomBigInt(32)
  } while (message <= 1n || message >= n)

  return message
}

function randomCoprime(n) {
  let candidate

  do {
    candidate = randomBigInt(64) % n
  } while (candidate <= 1n || gcd(candidate, n) !== 1n)

  return candidate
}

export function createBlindedPayload({ modulusHex, exponentHex }) {
  const n = hexToBigInt(modulusHex)
  const e = hexToBigInt(exponentHex)

  const message = randomMessage(n)
  const blindingFactor = randomCoprime(n)
  const blindedMessage = (message * modPow(blindingFactor, e, n)) % n

  return {
    messageHex: bigIntToHex(message),
    blindingFactorHex: bigIntToHex(blindingFactor),
    blindedMessageHex: bigIntToHex(blindedMessage)
  }
}

export function unblindSignature({ signedBlindedHex, blindingFactorHex, modulusHex }) {
  const sPrime = hexToBigInt(signedBlindedHex)
  const r = hexToBigInt(blindingFactorHex)
  const n = hexToBigInt(modulusHex)

  const rInverse = modInverse(r, n)
  const signature = (sPrime * rInverse) % n

  return bigIntToHex(signature)
}

export function verifySignature({ messageHex, signatureHex, exponentHex, modulusHex }) {
  const message = hexToBigInt(messageHex)
  const signature = hexToBigInt(signatureHex)
  const e = hexToBigInt(exponentHex)
  const n = hexToBigInt(modulusHex)

  return modPow(signature, e, n) === message
}
