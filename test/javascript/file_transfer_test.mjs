/**
 * Unit tests for FileTransferReceiver size-limit enforcement (zero-trace hardening).
 *
 * Verifies the receiver actually bounds memory rather than just displaying a limit:
 *  - rejects a transfer whose declared chunk count alone exceeds the limit
 *  - aborts mid-stream when bytes ACTUALLY received exceed the limit (a peer that
 *    lies about size/totalChunks or sends oversized frames)
 *  - still completes a normal in-memory transfer
 *
 * Run: node --test test/javascript/file_transfer_test.mjs
 */

import { strict as assert } from "node:assert"
import { test, describe } from "node:test"

import { FileTransferReceiver } from "../../app/javascript/modules/file_transfer.js"

const CHUNK_SIZE = 65_536
const identityDecrypt = async (buf) => buf

function fileStart({ size, totalChunks, name = "f.bin" }) {
  return JSON.stringify({
    type: "file-start",
    transferId: "t",
    name,
    size,
    totalChunks,
    mimeType: "application/octet-stream"
  })
}

describe("FileTransferReceiver size-limit enforcement", () => {
  test("rejects a file-start whose declared chunk count exceeds the limit", async () => {
    const errors = []
    let completed = false
    const r = new FileTransferReceiver(
      identityDecrypt,
      () => {},
      () => { completed = true },
      null,
      (msg) => errors.push(msg)
    )
    r.setFileSizeLimit(200_000) // ~3 chunks worth

    // 1000 chunks * 64 KB ≫ 200 KB → must be refused up front, buffering nothing.
    await r.handleChunk(fileStart({ size: 10_000_000, totalChunks: 1000 }))

    assert.equal(completed, false, "must not complete a rejected transfer")
    assert.equal(errors.length, 1, "must surface exactly one rejection")
    assert.match(errors[0], /exceeds/i)
  })

  test("aborts mid-stream when received bytes exceed the limit (lying peer)", async () => {
    const errors = []
    let completed = false
    const r = new FileTransferReceiver(
      identityDecrypt,
      () => {},
      () => { completed = true },
      null,
      (msg) => errors.push(msg)
    )
    r.setFileSizeLimit(200_000)

    // Declares only 2 chunks (passes the up-front guard) but each frame is oversized.
    await r.handleChunk(fileStart({ size: 100_000, totalChunks: 2 }))
    await r.handleChunk(new ArrayBuffer(150_000)) // cumulative 150 KB — ok
    await r.handleChunk(new ArrayBuffer(150_000)) // cumulative 300 KB — overflow → abort

    assert.equal(completed, false, "must abort, not complete, an overflowing transfer")
    assert.ok(errors.length >= 1, "must surface a rejection on overflow")
    assert.match(errors[0], /exceeds/i)
  })

  test("completes a normal in-memory transfer within the limit", async () => {
    // _assemble() builds a Blob + object URL; stub the browser-only URL API.
    globalThis.URL = globalThis.URL || {}
    globalThis.URL.createObjectURL = () => "blob:stub"

    let received = null
    const r = new FileTransferReceiver(
      identityDecrypt,
      () => {},
      (file) => { received = file },
      null,
      () => {}
    )
    r.setFileSizeLimit(10 * CHUNK_SIZE)

    await r.handleChunk(fileStart({ size: 100, totalChunks: 2, name: "ok.bin" }))
    await r.handleChunk(new ArrayBuffer(50))
    await r.handleChunk(new ArrayBuffer(50))
    await r.handleChunk(JSON.stringify({ type: "file-end", transferId: "t" }))

    assert.ok(received, "onComplete must fire for a valid transfer")
    assert.equal(received.name, "ok.bin")
  })
})
