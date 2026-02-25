/**
 * P2P File Transfer module for nullroom.
 *
 * Handles chunked, per-chunk AES-GCM encrypted file send/receive
 * over a dedicated RTCDataChannel ("nullroom-files").
 *
 * Files never touch the server — zero-trace preserved.
 * The server only authorises the transfer (size gate); actual bytes are P2P.
 */

const CHUNK_SIZE   = 65_536       // 64 KB per spec
const MAX_BUFFER   = 16_777_216   // 16 MB — pause sending above this (backpressure)

/** Maximum file size allowed in the Beta phase. Mirrors the server-side gate. */
export const FILE_SIZE_LIMIT = 25_165_824  // 24 MiB (24 × 1024 × 1024)

// ─────────────────────────────────────────────────────────────────────────────
// FileTransferSender
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Sends a single file over a WebRTC DataChannel in encrypted 64 KB chunks.
 *
 * Usage:
 *   const sender = new FileTransferSender(peer, encryptFn, onProgress, onError)
 *   await sender.send(file)
 */
export class FileTransferSender {
  /**
   * @param {PeerConnection} peer       The active PeerConnection (accesses fileChannel lazily)
   * @param {Function}       encryptFn  async (ArrayBuffer) => ArrayBuffer
   * @param {Function}       onProgress (name: string, percent: number) => void
   * @param {Function}       onError    (message: string) => void
   */
  constructor(peer, encryptFn, onProgress, onError) {
    this.peer      = peer
    this.encryptFn = encryptFn
    this.onProgress = onProgress
    this.onError    = onError
    this._sending   = false
  }

  /**
   * Validate and stream a File object over the file data channel.
   * Caller should already have received server authorisation before calling this.
   * @param {File} file
   */
  async send(file) {
    if (this._sending) {
      this.onError("A file transfer is already in progress.")
      return
    }

    // Client-side size guard (mirrors server gate — instant UX feedback)
    if (file.size > FILE_SIZE_LIMIT) {
      this.onError("Files must be under 24 MB.")
      return
    }

    const ch = this.peer.fileChannel
    if (!ch || ch.readyState !== "open") {
      this.onError("File channel is not ready yet. Please wait a moment.")
      return
    }

    this._sending = true
    const transferId  = crypto.randomUUID()
    const totalChunks = Math.ceil(file.size / CHUNK_SIZE)

    // ── 1. Send JSON metadata header as a text frame ──────────────────────
    ch.send(JSON.stringify({
      type: "file-start",
      transferId,
      name:        file.name,
      size:        file.size,
      totalChunks,
      mimeType:    file.type || "application/octet-stream"
    }))

    // ── 2. Read the entire file into memory ───────────────────────────────
    let buffer
    try {
      buffer = await file.arrayBuffer()
    } catch (err) {
      console.error("[FileTransfer] Failed to read file:", err)
      this.onError("Failed to read the file.")
      this._sending = false
      return
    }

    // ── 3. Send encrypted chunks with backpressure control ────────────────
    try {
      for (let i = 0; i < totalChunks; i++) {
        const start     = i * CHUNK_SIZE
        const chunk     = buffer.slice(start, start + CHUNK_SIZE)
        const encrypted = await this.encryptFn(chunk)

        // Backpressure: pause when the send buffer is saturated
        if (ch.bufferedAmount > MAX_BUFFER) {
          await this._waitForDrain(ch)
        }

        ch.send(encrypted)

        const percent = Math.round(((i + 1) / totalChunks) * 100)
        this.onProgress(file.name, percent)
      }

      // ── 4. Send end sentinel ─────────────────────────────────────────────
      ch.send(JSON.stringify({ type: "file-end", transferId }))
    } catch (err) {
      console.error("[FileTransfer] Send error:", err)
      this.onError("File transfer failed during sending.")
    } finally {
      this._sending = false
    }
  }

  /** Returns a Promise that resolves once bufferedAmount drops below the threshold. */
  _waitForDrain(ch) {
    return new Promise((resolve) => {
      ch.bufferedAmountLowThreshold = MAX_BUFFER / 2
      ch.onbufferedamountlow = () => {
        ch.onbufferedamountlow = null
        resolve()
      }
    })
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// FileTransferReceiver
// ─────────────────────────────────────────────────────────────────────────────

/**
 * Receives chunked encrypted file data and reassembles it into a Blob download.
 *
 * Usage:
 *   const receiver = new FileTransferReceiver(decryptFn, onProgress, onComplete)
 *   // Feed every "file-data" event from PeerConnection:
 *   peer.on("file-data", data => receiver.handleChunk(data))
 */
export class FileTransferReceiver {
  /**
   * @param {Function} decryptFn   async (ArrayBuffer) => ArrayBuffer
   * @param {Function} onProgress  (name: string, percent: number) => void
   * @param {Function} onComplete  ({name, url, size, mimeType}) => void
   */
  constructor(decryptFn, onProgress, onComplete) {
    this.decryptFn  = decryptFn
    this.onProgress = onProgress
    this.onComplete = onComplete
    this._reset()
  }

  _reset() {
    this._meta           = null
    this._chunks         = []      // pre-sized array; slots assigned by arrival index
    this._nextIndex      = 0       // monotonic counter assigned *before* each await
    this._received       = 0       // completed decrypts
    this._pendingDecrypts = 0      // in-flight decrypt calls
    this._endReceived    = false   // true once file-end frame has been seen
  }

  /**
   * Feed an incoming DataChannel message into the receiver.
   * Handles both JSON control frames (string) and binary chunk frames (ArrayBuffer).
   *
   * Why the ordering/assembly logic works this way:
   *  - Each binary frame starts an async decrypt. We capture the chunk's slot index
   *    *before* the await so that even if decrypts complete out of order, each
   *    result lands in the correct position.
   *  - `file-end` merely sets a flag; actual assembly is deferred until all
   *    pending decrypts have resolved (_tryAssemble checks both conditions).
   * @param {string|ArrayBuffer} data
   */
  async handleChunk(data) {
    if (typeof data === "string") {
      // JSON control frame
      let msg
      try { msg = JSON.parse(data) } catch { return }

      if (msg.type === "file-start") {
        this._reset()
        this._meta   = msg
        this._chunks = new Array(msg.totalChunks) // pre-allocate for ordered insertion
        console.log("[FileTransfer] Receiving:", msg.name, "-", msg.size, "bytes,", msg.totalChunks, "chunks")
      } else if (msg.type === "file-end") {
        this._endReceived = true
        this._tryAssemble()
      }
    } else if (data instanceof ArrayBuffer) {
      // Binary chunk frame
      if (!this._meta) return

      // Capture this chunk's position before any await
      const myIndex = this._nextIndex++
      this._pendingDecrypts++

      try {
        const decrypted = await this.decryptFn(data)
        this._chunks[myIndex] = decrypted  // write into the correct slot
        this._received++

        const percent = Math.round((this._received / this._meta.totalChunks) * 100)
        this.onProgress(this._meta.name, percent)
      } catch (err) {
        console.error("[FileTransfer] Chunk decrypt error:", err)
      } finally {
        this._pendingDecrypts--
        this._tryAssemble()
      }
    }
  }

  /**
   * Assemble only when the end-of-transfer sentinel has been received AND
   * every in-flight decrypt has finished. This prevents premature assembly
   * when `file-end` races ahead of the last chunk decrypts.
   */
  _tryAssemble() {
    if (this._endReceived && this._pendingDecrypts === 0 && this._meta) {
      this._assemble()
    }
  }

  /** Assemble all decrypted chunks into a Blob and fire onComplete. */
  _assemble() {
    if (!this._meta || this._chunks.length === 0) return

    // Filter out any unfilled slots (defensive — should not happen in practice)
    const safeChunks = this._chunks.filter(Boolean)
    const blob = new Blob(safeChunks, { type: this._meta.mimeType })
    const url  = URL.createObjectURL(blob)

    this.onComplete({
      name:     this._meta.name,
      url,
      size:     this._meta.size,
      mimeType: this._meta.mimeType
    })

    this._reset()
  }
}
