import { Controller } from "@hotwired/stimulus"
import PeerConnection from "modules/peer_connection"
import { importKey, encrypt, decrypt, encryptBuffer, decryptBuffer } from "modules/encryption"
import { FileTransferSender, FileTransferReceiver, FILE_SIZE_LIMIT } from "modules/file_transfer"
import { devLog } from "modules/dev_logger"

// Manages room lifecycle, signaling, and P2P encrypted messaging UI.
export default class extends Controller {
  static targets = [
    "messagesContainer",
    "waitingPlaceholder",
    "messageInput",
    "sendButton",
    "statusDot",
    "statusText",
    "timerDisplay",
    "shareLink",
    "terminatedModal",
    "errorToast",
    "errorToastText",
    // File transfer
    "fileZone",
    "fileInput",
    "fileProgress",
    "fileProgressBar",
    "fileProgressLabel"
  ]

  static values = {
    roomId: String,
    turnServers: Array,
    roomTtlSeconds: Number
  }

  // Initialize controller state and kick off room setup.
  connect() {
    this.state = {
      signaling: true,
      p2p: false,
      roomTerminated: false,
      messages: [],
      encryptionKey: null,
      peer: null,
      channel: null,
      timer: null,
      connectionId: null, // Store our connection ID
      objectUrls: new Set(),
      // File transfer
      fileSharing: false,
      pendingFile: null,
      fileSizeLimit: FILE_SIZE_LIMIT
    }
    this.sender   = null
    this.receiver = null

    // Populate share link with full URL including hash
    if (this.hasShareLinkTarget) {
      this.shareLinkTarget.value = window.location.href
    }

    this.initializeRoom()
  }

  // Load key from URL, set ICE servers, subscribe to signaling, and start timer.
  async initializeRoom() {
    try {
      // Extract encryption key from URL hash
      const keyString = window.location.hash.substring(1) // Remove leading #
      if (!keyString) {
        this.showError("Invalid room link")
        return
      }

      // Import encryption key
      this.state.encryptionKey = await importKey(keyString)

      // Use provided ICE servers from data attribute (from Cloudflare)
      // These are fetched server-side and never include Google STUN
      this.iceServers = this.turnServersValue && this.turnServersValue.length > 0
        ? this.turnServersValue
        : []

      // Subscribe to ActionCable RoomChannel FIRST
      this.subscribeToChannel()

      // Start timer
      this.startTimer()
    } catch (error) {
      console.error("Room initialization error:", error)
      this.showError("Failed to initialize room")
    }
  }

  // Create the WebRTC peer wrapper and bind signaling/data handlers.
  initializePeer(isInitiator) {
    devLog("[Room] Initializing peer connection")

    // Store whether we're initiator
    this.isInitiator = isInitiator

    this.state.peer = new PeerConnection({
      initiator: isInitiator, // Set this for datachannel creation
      trickleIce: true,
      iceServers: this.iceServers
    })

    // Handle peer signal event (emit offers, answers, ICE candidates)
    this.state.peer.on("signal", (data) => {
      if (this.channel) {
        this.channel.perform("send_signal", { data: data })
      } else {
        console.error("[Room] Channel not ready, cannot send signal")
      }
    })

    // Handle peer connection established
    this.state.peer.on("connect", () => {
      if (this.state.p2p) return // guard against duplicate connect events
      this.updateStatus(true, "🔒 Secure P2P")
      this.clearWaitingPlaceholder()
      this.messageInputTarget.disabled = false
      this.sendButtonTarget.disabled = false
      this.messageInputTarget.focus()
      // Initialise file transfer if the server flagged it as available
      if (this.state.fileSharing) {
        this._initFileTransfer()
      }
    })

    // Handle DataChannel open
    this.state.peer.on("data", (data) => {
      this.handleIncomingMessage(data)
    })

    // Handle incoming file chunks from the dedicated file channel
    this.state.peer.on("file-data", (data) => {
      if (this.receiver) {
        this.receiver.handleChunk(data)
      }
    })

    // Handle peer close or error (Heartbeat: immediate UI scrub)
    this.state.peer.on("close", () => {
      this.handlePeerClosed()
    })

    this.state.peer.on("error", (err) => {
      console.error("Peer error:", err)
      this.handlePeerClosed()
    })
  }

  // Subscribe to ActionCable signaling channel and route messages to peer.
  subscribeToChannel() {
    this.channel = window.cable.subscriptions.create(
      { channel: "RoomsChannel", room_id: this.roomIdValue },
      {
        connected: () => {
          devLog("[Room] Connected to RoomChannel")
        },
        disconnected: () => {
          devLog("[Room] Disconnected from RoomChannel")
        },
        rejected: () => {
          console.error("[Room] Subscription rejected - room may be full")
          this.showError("Room is full or unavailable")
        },
        received: (data) => {
          if (data.type === "init") {
            // Store our connection ID and initialize peer
            this.state.connectionId = data.connection_id
            this.state.fileSharing  = data.file_sharing === true
            this.state.fileSizeLimit = Number(data.file_size_limit) > 0 ? Number(data.file_size_limit) : FILE_SIZE_LIMIT
            devLog("[Room] Received init event")
            this.initializePeer(data.initiator)
          } else if (data.type === "peer_ready") {
            // Second peer is ready, initiator can now create offer
            if (this.isInitiator && this.state.peer) {
              devLog("[Room] Peer ready")
              this.state.peer.createOffer()
            }
          } else if (data.type === "peer_left") {
            // Peer left the room
            devLog("[Room] Peer left")
            if (data.connection_id === this.state.connectionId) {
              return
            }
            this.handlePeerClosed()
          } else if (data.type === "file_transfer_authorized") {
            // Server approved the transfer — start sending over the DataChannel
            if (this.state.pendingFile && this.sender) {
              const file = this.state.pendingFile
              this.state.pendingFile = null
              // Await completion then show a sent-confirmation bubble on the sender side.
              // The sender already has the file locally so no download link is needed.
              this.sender.send(file).then(() => {
                this.appendFileDownload({ name: file.name, url: null, size: file.size, isSent: true })
              }).catch((err) => {
                console.error("[Room] File send error:", err)
                this.showError("File transfer failed.")
              })
            }
          } else if (data.type === "file_transfer_error") {
            this.state.pendingFile = null
            this.showError(data.error || "File transfer rejected.")
          } else if (data.type === "signal") {
            // Ignore signals from ourselves
            if (data.connection_id === this.state.connectionId) {
              return
            }

            devLog("[Room] Processing peer signal", data.data?.type || "unknown")
            // Relay signal to PeerConnection
            try {
              if (this.state.peer) {
                this.state.peer.signal(data.data)
              } else {
                console.warn("[Room] Peer not ready yet, buffering signal")
              }
            } catch (error) {
              console.error("[Room] Error signaling peer:", error)
            }
          }
        }
      }
    )
  }

  // Encrypt and send a message over the P2P data channel.
  async sendMessage(event) {
    if (event.type === "keydown" && event.key !== "Enter") return
    if (event.type === "keydown") event.preventDefault()

    const input = this.messageInputTarget
    const text = this.normalizeChatText(input.value)

    if (!text || this.state.roomTerminated || this.state.signaling) return

    try {
      // Encrypt message
      const encrypted = await encrypt(text, this.state.encryptionKey)

      // Send via DataChannel (P2P, NOT ActionCable)
      this.state.peer.send(encrypted)

      // Display in UI immediately (optimistic)
      this.displayMessage(text, true)

      // Clear input
      input.value = ""
    } catch (error) {
      console.error("Error sending message:", error)
      this.showError("Failed to send message")
    }
  }

  // Decrypt incoming P2P data and render it in the UI.
  async handleIncomingMessage(encryptedString) {
    try {
      // Decrypt message
      const plaintext = await decrypt(encryptedString.toString(), this.state.encryptionKey)
      const safeText = this.normalizeChatText(plaintext)

      // Display in UI
      this.displayMessage(safeText, false)
    } catch (error) {
      console.error("Error decrypting message:", error)
      this.showError("Failed to decrypt message")
    }
  }

  // Render a message bubble and auto-scroll the container.
  displayMessage(text, isMine) {
    this.clearWaitingPlaceholder()

    const safeText = this.normalizeChatText(text)

    const timestamp = new Date().toLocaleTimeString()
    const timestampClass = isMine ? "text-green-400" : "text-blue-400"
    const messageEl = document.createElement("div")
    messageEl.className = `px-3 py-2 text-xs font-mono ${
      isMine
        ? "bg-green-900 bg-opacity-20 text-green-300 ml-8"
        : "bg-blue-900 bg-opacity-20 text-blue-300 mr-8"
    }`

    const timestampEl = document.createElement("div")
    timestampEl.className = `${timestampClass} text-xs`
    timestampEl.textContent = timestamp

    const textEl = document.createElement("div")
    textEl.className = "mt-1 break-words"
    textEl.textContent = safeText

    messageEl.appendChild(timestampEl)
    messageEl.appendChild(textEl)

    this.messagesContainerTarget.appendChild(messageEl)

    // Auto-scroll to bottom
    this.messagesContainerTarget.scrollTop = this.messagesContainerTarget.scrollHeight
  }

  clearWaitingPlaceholder() {
    if (this.hasWaitingPlaceholderTarget) {
      this.waitingPlaceholderTarget.remove()
    }
  }

  // Handle peer close (Heartbeat: immediate UI scrub on disconnect)
  // Handle peer disconnect by scrubbing UI and ending the session.
  handlePeerClosed() {
    this.state.roomTerminated = true
    this.state.pendingFile    = null

    // Clear messages from DOM immediately
    this.messagesContainerTarget.textContent = ""

    // Update status
    this.updateStatus(false, "🔒 Room Terminated — One participant left")

    // Disable input and send button
    this.messageInputTarget.disabled = true
    this.sendButtonTarget.disabled = true

    // Hide file transfer zone
    if (this.hasFileZoneTarget) {
      this.fileZoneTarget.classList.add("hidden")
    }
    this.sender   = null
    this.receiver = null
    this.revokeObjectUrls()

    // Show termination modal
    this.terminatedModalTarget.classList.remove("hidden")

    // Unsubscribe from ActionCable
    if (this.channel) {
      window.cable.subscriptions.remove(this.channel)
    }
  }

  // Destroy Room button: notify peer, clean up, and return home.
  destroyRoom() {
    if (this.state.timerInterval) {
      clearInterval(this.state.timerInterval)
    }

    if (this.state.peer) {
      this.state.peer.destroy()
    }
    this.revokeObjectUrls()

    // Removing the subscription triggers unsubscribed on the server,
    // which broadcasts peer_left to the other participant.
    if (this.channel) {
      window.cable.subscriptions.remove(this.channel)
      this.channel = null
    }

    window.location.href = "/"
  }

  // Return to the landing page after termination.
  closeRoom() {
    window.location.href = "/"
  }

  // Copy share link to clipboard with a fallback for older browsers.
  copyLink(event) {
    const link = this.shareLinkTarget.value
    const button = event.currentTarget || event.target

    if (!navigator.clipboard) {
      // Fallback for older browsers
      this.shareLinkTarget.select()
      document.execCommand('copy')
      const originalText = button.textContent
      button.textContent = "✓ Copied"
      setTimeout(() => {
        button.textContent = originalText
      }, 2000)
      return
    }

    navigator.clipboard.writeText(link).then(() => {
      // Visual feedback
      const originalText = button.textContent
      button.textContent = "✓ Copied"
      setTimeout(() => {
        button.textContent = originalText
      }, 2000)
    }).catch((err) => {
      console.error("Clipboard error:", err)
      this.showError("Failed to copy link")
    })
  }

  // Start the room countdown timer and disable input on expiry.
  startTimer() {
    const startTime = Date.now()
    const ttlSeconds = this.roomTtlSecondsValue > 0 ? this.roomTtlSecondsValue : (15 * 60)
    const duration = ttlSeconds * 1000

    this.state.timerInterval = setInterval(() => {
      const elapsed = Date.now() - startTime
      const remaining = Math.max(0, duration - elapsed)

      const minutes = Math.floor(remaining / 1000 / 60)
      const seconds = Math.floor((remaining / 1000) % 60)

      this.timerDisplayTarget.textContent = `${String(minutes).padStart(2, "0")}:${String(seconds).padStart(2, "0")}`

      if (remaining <= 0) {
        clearInterval(this.state.timerInterval)
        this.messageInputTarget.disabled = true
        this.timerDisplayTarget.textContent = "00:00"
      }
    }, 1000)
  }

  // Update status indicator and internal state flags.
  updateStatus(isP2P, statusText) {
    if (isP2P) {
      this.state.p2p = true
      this.state.signaling = false
      this.statusDotTarget.className = "w-3 h-3 rounded-full bg-green-500"
      this.statusDotTarget.classList.remove("animate-pulse")
    } else {
      this.statusDotTarget.className = "w-3 h-3 rounded-full bg-red-500"
    }

    this.statusTextTarget.textContent = statusText
  }

  // Show a transient error toast.
  showError(message) {
    this.errorToastTextTarget.textContent = message
    this.errorToastTarget.classList.remove("hidden")

    setTimeout(() => {
      this.errorToastTarget.classList.add("hidden")
    }, 5000)
  }

  // ── File Transfer ─────────────────────────────────────────────────────────

  /** Proxy a click on the invisible <input type="file"> from the drop zone. */
  triggerFileInput() {
    if (this.hasFileInputTarget) {
      this.fileInputTarget.click()
    }
  }

  /** Called when the user selects a file via the file picker. */
  uploadFile(event) {
    const file = event.target.files && event.target.files[0]
    event.target.value = "" // reset so the same file can be re-selected
    if (file) this._requestFileTransfer(file)
  }

  /** Called when the user drops a file onto the drop zone. */
  handleDrop(event) {
    event.preventDefault()
    const file = event.dataTransfer && event.dataTransfer.files && event.dataTransfer.files[0]
    if (file) this._requestFileTransfer(file)
  }

  /** Prevent the browser from navigating away on dragover. */
  preventDrop(event) {
    event.preventDefault()
  }

  /**
   * Client-side size guard, then ask the server to authorise the transfer.
   * Actual bytes travel P2P; the server only sees the metadata for the gate check.
   */
  _requestFileTransfer(file) {
    if (this.state.roomTerminated || !this.state.p2p) return
    if (file.size > this.state.fileSizeLimit) {
      this.showError(`Files must be under ${this._fileSizeLimitLabel()}.`)
      return
    }
    // Store the file and ask the server gate
    this.state.pendingFile = file
    if (this.channel) {
      this.channel.perform("initiate_file_transfer", {
        metadata: { file_name: file.name, file_size: file.size }
      })
    }
  }

  /** Instantiate sender + receiver and reveal the file zone after P2P connects. */
  _initFileTransfer() {
    const encryptFn = (buf) => encryptBuffer(buf, this.state.encryptionKey)
    const decryptFn = (buf) => decryptBuffer(buf, this.state.encryptionKey)

    this.sender = new FileTransferSender(
      this.state.peer,
      encryptFn,
      (name, percent) => this.updateFileProgress(name, percent),
      (msg) => this.showError(msg)
    )
    this.sender.setFileSizeLimit(this.state.fileSizeLimit)

    this.receiver = new FileTransferReceiver(
      decryptFn,
      (name, percent) => this.updateFileProgress(name, percent),
      (file) => this.appendFileDownload(file)
    )

    // Reveal the file drop zone
    if (this.hasFileZoneTarget) {
      this.fileZoneTarget.classList.remove("hidden")
    }
  }

  /** Update the progress bar and label. Hides the bar once transfer completes. */
  updateFileProgress(name, percent) {
    if (!this.hasFileProgressTarget) return

    this.fileProgressTarget.classList.remove("hidden")
    this.fileProgressBarTarget.style.width = `${percent}%`
    this.fileProgressLabelTarget.textContent =
      percent < 100 ? `${name} — ${percent}%` : `${name} — complete`

    if (percent >= 100) {
      setTimeout(() => {
        if (this.hasFileProgressTarget) {
          this.fileProgressTarget.classList.add("hidden")
          this.fileProgressBarTarget.style.width = "0%"
        }
      }, 1500)
    }
  }

  /**
   * Append a file bubble to the message thread.
   * Sent files (isSent=true) render as outgoing (green, right-aligned, no download link).
   * Received files render as incoming (blue, left-aligned, clickable download link).
   * @param {{name: string, url: string|null, size: number, isSent?: boolean}} fileInfo
   */
  appendFileDownload({ name, url, size, isSent = false }) {
    this.clearWaitingPlaceholder()

    const timestamp = new Date().toLocaleTimeString()
    const safeName = this.normalizeFileName(name)
    const safeSize = this.normalizeFileSize(size)

    const el = document.createElement("div")

    const timestampEl = document.createElement("div")

    if (isSent) {
      // Outgoing: matches sent text message style — green, pushed to the right
      el.className = "px-3 py-2 text-xs font-mono bg-green-900 bg-opacity-20 text-green-300 ml-8"
      timestampEl.className = "text-green-400 text-xs"

      const rowEl = document.createElement("div")
      rowEl.className = "mt-1 flex items-center gap-2 break-all"

      rowEl.appendChild(this.createPaperclipIcon())

      const fileNameEl = document.createElement("span")
      fileNameEl.textContent = safeName

      const sizeEl = document.createElement("span")
      sizeEl.className = "text-white/40"
      sizeEl.textContent = `(${this.formatFileSize(safeSize)})`

      const sentEl = document.createElement("span")
      sentEl.className = "text-green-500/60 text-xs ml-1"
      sentEl.textContent = "✓ sent"

      rowEl.appendChild(fileNameEl)
      rowEl.appendChild(sizeEl)
      rowEl.appendChild(sentEl)

      timestampEl.textContent = timestamp
      el.appendChild(timestampEl)
      el.appendChild(rowEl)
    } else {
      // Incoming: blue bubble with a clickable download anchor
      el.className = "px-3 py-2 text-xs font-mono bg-blue-900 bg-opacity-20 text-blue-300 mr-8"
      timestampEl.className = "text-blue-400 text-xs"

      const linkEl = document.createElement("a")
      linkEl.className = "mt-1 flex items-center gap-2 underline hover:text-blue-200 break-all"
      linkEl.download = safeName
      if (typeof url === "string" && url.startsWith("blob:")) {
        linkEl.href = url
        this.state.objectUrls.add(url)
      } else {
        linkEl.href = "#"
        linkEl.addEventListener("click", (event) => event.preventDefault())
      }

      linkEl.appendChild(this.createPaperclipIcon())

      const fileNameEl = document.createElement("span")
      fileNameEl.textContent = safeName

      const sizeEl = document.createElement("span")
      sizeEl.className = "text-white/40"
      sizeEl.textContent = `(${this.formatFileSize(safeSize)})`

      linkEl.appendChild(fileNameEl)
      linkEl.appendChild(sizeEl)

      timestampEl.textContent = timestamp
      el.appendChild(timestampEl)
      el.appendChild(linkEl)
    }

    this.messagesContainerTarget.appendChild(el)
    this.messagesContainerTarget.scrollTop = this.messagesContainerTarget.scrollHeight
  }

  /** Format bytes into a human-readable string (KB / MB). */
  formatFileSize(bytes) {
    if (bytes < 1024)          return `${bytes} B`
    if (bytes < 1_048_576)     return `${(bytes / 1024).toFixed(1)} KB`
    return `${(bytes / 1_048_576).toFixed(1)} MB`
  }

  _fileSizeLimitLabel() {
    const mebibytes = this.state.fileSizeLimit / (1024 * 1024)
    return Number.isInteger(mebibytes) ? `${mebibytes} MB` : `${mebibytes.toFixed(1)} MB`
  }

  // ── Utilities ─────────────────────────────────────────────────────────────

  normalizeChatText(value) {
    return String(value ?? "")
      .normalize("NFKC")
      .replace(/[\u0000-\u0008\u000B\u000C\u000E-\u001F\u007F]/g, "")
      .slice(0, 5000)
      .trim()
  }

  normalizeFileName(value) {
    const fallback = "download"
    const normalized = String(value ?? "")
      .normalize("NFKC")
      .replace(/[\u0000-\u001F\u007F]/g, "")
      .replace(/[\\/:*?"|]/g, "_")
      .replace(/[<>]/g, "_")
      .trim()

    return (normalized || fallback).slice(0, 255)
  }

  normalizeFileSize(value) {
    const parsed = Number(value)
    if (!Number.isFinite(parsed) || parsed < 0) return 0
    return Math.floor(parsed)
  }

  createPaperclipIcon() {
    const ns = "http://www.w3.org/2000/svg"
    const svg = document.createElementNS(ns, "svg")
    svg.setAttribute("class", "w-4 h-4 shrink-0")
    svg.setAttribute("viewBox", "0 0 24 24")
    svg.setAttribute("fill", "none")
    svg.setAttribute("stroke", "currentColor")
    svg.setAttribute("stroke-width", "1.5")
    svg.setAttribute("stroke-linecap", "round")
    svg.setAttribute("stroke-linejoin", "round")

    const path = document.createElementNS(ns, "path")
    path.setAttribute("d", "M21.44 11.05l-9.19 9.19a6 6 0 0 1-8.49-8.49l9.19-9.19a4 4 0 0 1 5.66 5.66l-9.2 9.19a2 2 0 0 1-2.83-2.83l8.49-8.48")
    svg.appendChild(path)

    return svg
  }

  // Cleanup timers, peer connection, and channel subscription.
  disconnect() {
    // Cleanup on disconnect
    if (this.state.timerInterval) {
      clearInterval(this.state.timerInterval)
    }

    if (this.state.peer) {
      this.state.peer.destroy()
    }

    this.revokeObjectUrls()

    if (this.channel) {
      window.cable.subscriptions.remove(this.channel)
    }
  }

  revokeObjectUrls() {
    for (const url of this.state.objectUrls) {
      URL.revokeObjectURL(url)
    }
    this.state.objectUrls.clear()
  }
}
