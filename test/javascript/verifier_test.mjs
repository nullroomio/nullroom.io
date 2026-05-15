/**
 * Unit tests for the Integrity Verifier
 *
 * Tests the importmap-vs-manifest comparison logic using plain objects
 * (no DOM dependency). Mirrors the core algorithm from utils/verifier.js.
 *
 * Run: node test/javascript/verifier_test.mjs
 */

import { strict as assert } from "node:assert"
import { test, describe } from "node:test"

// ─── Inline the core verification logic (mirrors utils/verifier.js) ───

function runIntegrityCheck(manifest, importmap, sha = "dev") {
  if (!manifest || !importmap) {
    return { isConsistent: false, matches: 0, total: 0, sha, error: "missing-elements" }
  }

  const imports = importmap.imports || {}

  const knownDigests = new Set()
  for (const entry of Object.values(manifest)) {
    if (entry.digested_path) knownDigests.add(entry.digested_path)
  }

  let matches = 0
  let total = 0

  for (const [, assetPath] of Object.entries(imports)) {
    const filename = assetPath.replace(/^\/assets\//, "")
    total++
    if (knownDigests.has(filename)) matches++
  }

  return { isConsistent: matches === total, matches, total, sha }
}

// ─── Tests ──────────────────────────────────────────────────────────────────

describe("runIntegrityCheck", () => {
  test("returns consistent when all imports match manifest", () => {
    const manifest = {
      "application.js": { digested_path: "application-abc123.js", integrity: null },
      "controllers/room_controller.js": { digested_path: "controllers/room_controller-def456.js", integrity: null },
      "mlkem.js": { digested_path: "mlkem-789abc.js", integrity: null }
    }
    const importmap = {
      imports: {
        "application": "/assets/application-abc123.js",
        "controllers/room_controller": "/assets/controllers/room_controller-def456.js",
        "mlkem": "/assets/mlkem-789abc.js"
      }
    }

    const result = runIntegrityCheck(manifest, importmap, "a".repeat(40))

    assert.equal(result.isConsistent, true)
    assert.equal(result.matches, 3)
    assert.equal(result.total, 3)
    assert.equal(result.sha, "a".repeat(40))
  })

  test("detects mismatch when digest differs", () => {
    const manifest = {
      "application.js": { digested_path: "application-abc123.js", integrity: null }
    }
    const importmap = {
      imports: {
        "application": "/assets/application-TAMPERED.js"
      }
    }

    const result = runIntegrityCheck(manifest, importmap)

    assert.equal(result.isConsistent, false)
    assert.equal(result.matches, 0)
    assert.equal(result.total, 1)
  })

  test("handles partial matches correctly", () => {
    const manifest = {
      "application.js": { digested_path: "application-abc123.js", integrity: null },
      "mlkem.js": { digested_path: "mlkem-789abc.js", integrity: null }
    }
    const importmap = {
      imports: {
        "application": "/assets/application-abc123.js",
        "mlkem": "/assets/mlkem-WRONG.js"
      }
    }

    const result = runIntegrityCheck(manifest, importmap)

    assert.equal(result.isConsistent, false)
    assert.equal(result.matches, 1)
    assert.equal(result.total, 2)
  })

  test("returns error when manifest is null", () => {
    const importmap = { imports: { "application": "/assets/application-abc123.js" } }
    const result = runIntegrityCheck(null, importmap)

    assert.equal(result.isConsistent, false)
    assert.equal(result.error, "missing-elements")
  })

  test("returns error when importmap is null", () => {
    const manifest = { "application.js": { digested_path: "application-abc123.js" } }
    const result = runIntegrityCheck(manifest, null)

    assert.equal(result.isConsistent, false)
    assert.equal(result.error, "missing-elements")
  })

  test("returns consistent with empty manifest and no imports", () => {
    const result = runIntegrityCheck({}, { imports: {} })

    assert.equal(result.isConsistent, true)
    assert.equal(result.matches, 0)
    assert.equal(result.total, 0)
  })

  test("defaults SHA to dev", () => {
    const result = runIntegrityCheck({}, { imports: {} })
    assert.equal(result.sha, "dev")
  })

  test("strips /assets/ prefix correctly for nested paths", () => {
    const manifest = {
      "controllers/landing_controller.js": {
        digested_path: "controllers/landing_controller-1e9a8ad2.js",
        integrity: null
      }
    }
    const importmap = {
      imports: {
        "controllers/landing_controller": "/assets/controllers/landing_controller-1e9a8ad2.js"
      }
    }

    const result = runIntegrityCheck(manifest, importmap)

    assert.equal(result.isConsistent, true)
    assert.equal(result.matches, 1)
  })
})
