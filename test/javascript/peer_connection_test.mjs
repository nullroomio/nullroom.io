/**
 * Unit tests for PeerConnection.detectConnectionType()
 *
 * Verifies that relay detection checks BOTH local and remote candidates.
 *
 * Run: node test/javascript/peer_connection_test.mjs
 */

import { strict as assert } from "node:assert"
import { test, describe } from "node:test"

// ─── Minimal stub of detectConnectionType logic (mirrors peer_connection.js) ───

function detectConnectionType(statsMap) {
  let activePairId = null

  statsMap.forEach(report => {
    if (report.type === "transport" && report.selectedCandidatePairId) {
      activePairId = report.selectedCandidatePairId
    }
  })

  if (!activePairId) {
    statsMap.forEach(report => {
      if (report.type === "candidate-pair" && report.state === "succeeded" && report.nominated) {
        activePairId = report.id
      }
    })
  }

  if (!activePairId) return "direct"

  const pair = statsMap.get(activePairId)
  if (!pair) return "direct"

  const localCandidate = statsMap.get(pair.localCandidateId)
  const remoteCandidate = statsMap.get(pair.remoteCandidateId)

  const localType = localCandidate && localCandidate.candidateType
  const remoteType = remoteCandidate && remoteCandidate.candidateType

  return (localType === "relay" || remoteType === "relay") ? "relay" : "direct"
}

// ─── Helper: build a fake stats Map ───

function buildStats({ localType, remoteType }) {
  const map = new Map()
  map.set("transport-0", {
    type: "transport",
    selectedCandidatePairId: "pair-0"
  })
  map.set("pair-0", {
    type: "candidate-pair",
    state: "succeeded",
    nominated: true,
    localCandidateId: "local-0",
    remoteCandidateId: "remote-0"
  })
  map.set("local-0", { type: "local-candidate", candidateType: localType })
  map.set("remote-0", { type: "remote-candidate", candidateType: remoteType })
  return map
}

// ─── Tests ───

describe("detectConnectionType", () => {
  test("both host → direct", () => {
    const stats = buildStats({ localType: "host", remoteType: "host" })
    assert.equal(detectConnectionType(stats), "direct")
  })

  test("local srflx, remote srflx → direct", () => {
    const stats = buildStats({ localType: "srflx", remoteType: "srflx" })
    assert.equal(detectConnectionType(stats), "direct")
  })

  test("local relay, remote host → relay", () => {
    const stats = buildStats({ localType: "relay", remoteType: "host" })
    assert.equal(detectConnectionType(stats), "relay")
  })

  test("local host, remote relay → relay (the bug scenario)", () => {
    // This is the exact case that caused the mismatch:
    // Phone had local=srflx but remote=relay — must still report relay
    const stats = buildStats({ localType: "host", remoteType: "relay" })
    assert.equal(detectConnectionType(stats), "relay")
  })

  test("local srflx, remote relay → relay", () => {
    const stats = buildStats({ localType: "srflx", remoteType: "relay" })
    assert.equal(detectConnectionType(stats), "relay")
  })

  test("both relay → relay", () => {
    const stats = buildStats({ localType: "relay", remoteType: "relay" })
    assert.equal(detectConnectionType(stats), "relay")
  })

  test("local prflx, remote host → direct", () => {
    const stats = buildStats({ localType: "prflx", remoteType: "host" })
    assert.equal(detectConnectionType(stats), "direct")
  })

  test("no active pair → defaults to direct", () => {
    const map = new Map()
    assert.equal(detectConnectionType(map), "direct")
  })

  test("fallback to nominated candidate-pair when transport has no selectedCandidatePairId", () => {
    const map = new Map()
    map.set("pair-1", {
      type: "candidate-pair",
      state: "succeeded",
      nominated: true,
      id: "pair-1",
      localCandidateId: "local-1",
      remoteCandidateId: "remote-1"
    })
    map.set("local-1", { type: "local-candidate", candidateType: "srflx" })
    map.set("remote-1", { type: "remote-candidate", candidateType: "relay" })
    assert.equal(detectConnectionType(map), "relay")
  })
})

// ─── Connection Type Exchange Convergence ────────────────────────────────────
// When peers exchange their locally-detected connection type over the data channel,
// the "worst" result wins: relay on either side means relay for both.
// This mirrors the logic in room_controller.js handleControlMessage("connection_type").

describe("connection type exchange convergence", () => {
  // Simulates what handleControlMessage does when receiving a "connection_type" message
  function converge(localType, remoteValue) {
    if (remoteValue === "relay" && localType !== "relay") {
      return "relay"
    }
    return localType
  }

  test("local direct + remote relay → upgrades to relay", () => {
    // The real-world scenario: PC detects direct (can't see phone's TURN usage),
    // but phone reports relay — PC must upgrade to relay.
    assert.equal(converge("direct", "relay"), "relay")
  })

  test("local relay + remote direct → stays relay (no downgrade)", () => {
    assert.equal(converge("relay", "direct"), "relay")
  })

  test("both direct → stays direct", () => {
    assert.equal(converge("direct", "direct"), "direct")
  })

  test("both relay → stays relay", () => {
    assert.equal(converge("relay", "relay"), "relay")
  })

  test("local undefined + remote relay → upgrades to relay", () => {
    // Edge case: connectionType not yet set when exchange message arrives
    assert.equal(converge(undefined, "relay"), "relay")
  })
})
