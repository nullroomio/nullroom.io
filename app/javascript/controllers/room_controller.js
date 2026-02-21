import { Controller } from "@hotwired/stimulus"
import PeerConnection from "modules/peer_connection"
import { importKey, encrypt, decrypt } from "modules/encryption"

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
    "errorToastText"
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
      connectionId: null // Store our connection ID
    }

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
      this.updateStatus(true, "🔒 Secure P2P")
      this.clearWaitingPlaceholder()
      this.messageInputTarget.disabled = false
      this.sendButtonTarget.disabled = false
      this.messageInputTarget.focus()
    })

    // Handle DataChannel open
    this.state.peer.on("data", (data) => {
      this.handleIncomingMessage(data)
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
            console.log("[Room] Got init message, initiator:", data.initiator, "connection_id:", data.connection_id)
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

    // Clear messages from DOM immediately
    this.messagesContainerTarget.innerHTML = ""

    // Update status
    this.updateStatus(false, "🔒 Room Terminated — One participant left")

    // Disable input and send button
    this.messageInputTarget.disabled = true
    this.sendButtonTarget.disabled = true

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
