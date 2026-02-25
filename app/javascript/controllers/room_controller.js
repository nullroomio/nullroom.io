import { Controller } from "@hotwired/stimulus"
import PeerConnection from "modules/peer_connection"
import { importKey, encrypt, decrypt, encryptBuffer, decryptBuffer } from "modules/encryption"
import { FileTransferSender, FileTransferReceiver, FILE_SIZE_LIMIT } from "modules/file_transfer"

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
    turnServers: Array
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
      // File transfer
      fileSharing: false,
      pendingFile: null
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

      // Log ICE servers for debugging
      console.log("[Room] ICE servers configured:", this.iceServers)

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
    console.log("[Room] Initializing peer connection")
    console.log("[Room] Creating peer, initiator:", isInitiator)

    // Store whether we're initiator
    this.isInitiator = isInitiator

    this.state.peer = new PeerConnection({
      initiator: isInitiator, // Set this for datachannel creation
      trickleIce: true,
      iceServers: this.iceServers
    })

    // Handle peer signal event (emit offers, answers, ICE candidates)
    this.state.peer.on("signal", (data) => {
      console.log("[Room] Sending signal:", data.type)
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
    console.log("[Room] Subscribing to channel, room_id:", this.roomIdValue)
    this.channel = window.cable.subscriptions.create(
      { channel: "RoomsChannel", room_id: this.roomIdValue },
      {
        connected: () => {
          console.log("[Room] Connected to RoomChannel - waiting for init message")
        },
        disconnected: () => {
          console.log("[Room] Disconnected from RoomChannel")
        },
        rejected: () => {
          console.error("[Room] Subscription rejected - room may be full")
          this.showError("Room is full or unavailable")
        },
        received: (data) => {
          console.log("[Room] Received data:", data)

          if (data.type === "init") {
            // Store our connection ID and initialize peer
            this.state.connectionId = data.connection_id
            this.state.fileSharing  = data.file_sharing === true
            console.log("[Room] Got init message, initiator:", data.initiator, "connection_id:", data.connection_id, "file_sharing:", this.state.fileSharing)
            this.initializePeer(data.initiator)
          } else if (data.type === "peer_ready") {
            // Second peer is ready, initiator can now create offer
            if (this.isInitiator && this.state.peer) {
              console.log("[Room] Peer ready signal received, creating offer")
              this.state.peer.createOffer()
            }
          } else if (data.type === "peer_left") {
            // Peer left the room
            console.log("[Room] Peer left the room")
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
              console.log("[Room] Ignoring own signal:", data.data.type)
              return
            }

            console.log("[Room] Processing signal from peer:", data.data.type)
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
    const text = input.value.trim()

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

      // Display in UI
      this.displayMessage(plaintext, false)
    } catch (error) {
      console.error("Error decrypting message:", error)
      this.showError("Failed to decrypt message")
    }
  }

  // Render a message bubble and auto-scroll the container.
  displayMessage(text, isMine) {
    this.clearWaitingPlaceholder()

    const timestamp = new Date().toLocaleTimeString()
    const timestampClass = isMine ? "text-green-400" : "text-blue-400"
    const messageEl = document.createElement("div")
    messageEl.className = `px-3 py-2 text-xs font-mono ${
      isMine
        ? "bg-green-900 bg-opacity-20 text-green-300 ml-8"
        : "bg-blue-900 bg-opacity-20 text-blue-300 mr-8"
    }`

    messageEl.innerHTML = `
      <div class="${timestampClass} text-xs">${timestamp}</div>
      <div class="mt-1 break-words">${this.escapeHtml(text)}</div>
    `

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
    this.messagesContainerTarget.innerHTML = ""

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
    const duration = 30 * 60 * 1000 // 30 minutes in ms

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
    if (file.size > FILE_SIZE_LIMIT) {
      this.showError("Files must be under 24 MB.")
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

    const timestamp    = new Date().toLocaleTimeString()
    const paperclipSVG = `<svg class="w-4 h-4 shrink-0" viewBox="0 0 24 24" fill="none"
         stroke="currentColor" stroke-width="1.5"
         stroke-linecap="round" stroke-linejoin="round">
      <path d="M21.44 11.05l-9.19 9.19a6 6 0 0 1-8.49-8.49l9.19-9.19a4 4 0 0 1 5.66 5.66l-9.2 9.19a2 2 0 0 1-2.83-2.83l8.49-8.48"/>
    </svg>`

    const el = document.createElement("div")

    if (isSent) {
      // Outgoing: matches sent text message style — green, pushed to the right
      el.className = "px-3 py-2 text-xs font-mono bg-green-900 bg-opacity-20 text-green-300 ml-8"
      el.innerHTML = `
        <div class="text-green-400 text-xs">${timestamp}</div>
        <div class="mt-1 flex items-center gap-2 break-all">
          ${paperclipSVG}
          ${this.escapeHtml(name)} <span class="text-white/40">(${this.formatFileSize(size)})</span>
          <span class="text-green-500/60 text-xs ml-1">✓ sent</span>
        </div>
      `
    } else {
      // Incoming: blue bubble with a clickable download anchor
      el.className = "px-3 py-2 text-xs font-mono bg-blue-900 bg-opacity-20 text-blue-300 mr-8"
      el.innerHTML = `
        <div class="text-blue-400 text-xs">${timestamp}</div>
        <a
          href="${url}"
          download="${this.escapeHtml(name)}"
          class="mt-1 flex items-center gap-2 underline hover:text-blue-200 break-all"
        >
          ${paperclipSVG}
          ${this.escapeHtml(name)} <span class="text-white/40">(${this.formatFileSize(size)})</span>
        </a>
      `
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

  // ── Utilities ─────────────────────────────────────────────────────────────

  // Escape user-provided text before injecting into the DOM.
  escapeHtml(text) {
    const div = document.createElement("div")
    div.textContent = text
    return div.innerHTML
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

    if (this.channel) {
      window.cable.subscriptions.remove(this.channel)
    }
  }
}
