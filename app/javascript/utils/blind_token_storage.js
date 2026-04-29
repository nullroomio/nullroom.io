const BLIND_TOKEN_STORAGE_KEY = "nullroom_blind_token"

export function saveBlindToken({ messageHex, signatureHex }) {
  localStorage.setItem(BLIND_TOKEN_STORAGE_KEY, JSON.stringify({
    messageHex,
    signatureHex,
    issuedAt: Date.now()
  }))
}

export function loadBlindToken() {
  const raw = localStorage.getItem(BLIND_TOKEN_STORAGE_KEY)
  if (!raw) return null

  try {
    const parsed = JSON.parse(raw)
    if (!parsed.messageHex || !parsed.signatureHex) return null
    return parsed
  } catch (_) {
    return null
  }
}

export function clearBlindToken() {
  localStorage.removeItem(BLIND_TOKEN_STORAGE_KEY)
}

export function buildBlindTokenHeaders() {
  const token = loadBlindToken()
  if (!token) return {}

  return {
    "X-Blind-Token-Message": token.messageHex,
    "X-Blind-Token-Signature": token.signatureHex
  }
}
