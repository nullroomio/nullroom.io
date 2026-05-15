// Zero-network-call integrity check.
// Compares the importmap in the DOM against the Propshaft manifest
// embedded at render time. No fetches, no external calls, no IP leaks.

export function runIntegrityCheck() {
  const manifestEl = document.getElementById("integrity-manifest")
  const importmapEl = document.querySelector('script[type="importmap"]')

  if (!manifestEl || !importmapEl) {
    return { isConsistent: false, matches: 0, total: 0, sha: getSha(), error: "missing-elements" }
  }

  const manifest = JSON.parse(manifestEl.textContent)
  const importmap = JSON.parse(importmapEl.textContent)
  const imports = importmap.imports || {}

  // Build a lookup: digested filename → true
  // Manifest format: { "application.js": { "digested_path": "application-abc123.js" } }
  const knownDigests = new Set()
  for (const entry of Object.values(manifest)) {
    if (entry.digested_path) knownDigests.add(entry.digested_path)
  }

  let matches = 0
  let total = 0

  for (const [, assetPath] of Object.entries(imports)) {
    // Extract filename from path: "/assets/controllers/room_controller-aa39ca89.js" → "controllers/room_controller-aa39ca89.js"
    const filename = assetPath.replace(/^\/assets\//, "")
    total++

    if (knownDigests.has(filename)) {
      matches++
    }
  }

  return { isConsistent: matches === total, matches, total, sha: getSha() }
}

function getSha() {
  return document.documentElement.dataset.commitSha || "dev"
}
