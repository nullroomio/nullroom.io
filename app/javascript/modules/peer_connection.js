/**
 * Lightweight WebRTC wrapper for nullroom P2P connections
 * Replaces simple-peer with vanilla WebRTC API
 */

export class PeerConnection {
  constructor(options = {}) {
    this.initiator = options.initiator || false
    this.iceServers = options.iceServers || []
    this.trickleIce = options.trickleIce !== false

    this.pc = null
    this.dataChannel = null
    this.listeners = {}
    this._connected = false

    this._init()
  }

  _init() {
    console.log("[PeerConnection] Initializing, initiator:", this.initiator)

    // Create RTCPeerConnection
    this.pc = new RTCPeerConnection({
      iceServers: this.iceServers
    })

    // Handle ICE candidates
    this.pc.onicecandidate = (event) => {
      if (event.candidate && this.trickleIce) {
        console.log("[PeerConnection] Emitting ICE candidate")
        this._emit("signal", {
          type: "candidate",
          candidate: event.candidate
        })
      }
    }

    // Handle connection state changes
    this.pc.onconnectionstatechange = () => {
      console.log("[PeerConnection] Connection state:", this.pc.connectionState)
      if (this.pc.connectionState === "connected") {
        this._connected = true
        this._emit("connect")
      } else if (this.pc.connectionState === "failed" || this.pc.connectionState === "closed") {
        this._emit("close")
      }
    }

    this.pc.onicecandidateerror = (error) => {
      console.warn("ICE candidate error:", error)
    }

    // If initiator, create data channel (but don't create offer yet)
    if (this.initiator) {
      this._createDataChannel()
      // Offer will be created manually via createOffer() method
    } else {
      // If not initiator, wait for data channel
      this.pc.ondatachannel = (event) => {
        this.dataChannel = event.channel
        this._setupDataChannel()
      }
    }
  }

  _createDataChannel() {
    this.dataChannel = this.pc.createDataChannel("nullroom", {
      ordered: true
    })
    this._setupDataChannel()
  }

  _setupDataChannel() {
    this.dataChannel.onopen = () => {
      this._connected = true
      this._emit("connect")
    }

    this.dataChannel.onclose = () => {
      this._emit("close")
    }

    this.dataChannel.onerror = (error) => {
      this._emit("error", error)
    }

    this.dataChannel.onmessage = (event) => {
      this._emit("data", event.data)
    }
  }

  async _createOffer() {
    console.log("[PeerConnection] Creating offer")
    try {
      const offer = await this.pc.createOffer()
      await this.pc.setLocalDescription(offer)

      console.log("[PeerConnection] Emitting offer")
      this._emit("signal", {
        type: "offer",
        sdp: this.pc.localDescription
      })
    } catch (error) {
      console.error("[PeerConnection] Error creating offer:", error)
      this._emit("error", error)
    }
  }

  async _createAnswer() {
    console.log("[PeerConnection] Creating answer")
    try {
      const answer = await this.pc.createAnswer()
      await this.pc.setLocalDescription(answer)

      console.log("[PeerConnection] Emitting answer")
      this._emit("signal", {
        type: "answer",
        sdp: this.pc.localDescription
      })
    } catch (error) {
      console.error("[PeerConnection] Error creating answer:", error)
      this._emit("error", error)
    }
  }

  async signal(data) {
    console.log("[PeerConnection] Received signal:", data.type)
    try {
      if (data.type === "offer") {
        console.log("[PeerConnection] Setting remote description (offer)")
        await this.pc.setRemoteDescription(new RTCSessionDescription(data.sdp))
        await this._createAnswer()
      } else if (data.type === "answer") {
        console.log("[PeerConnection] Setting remote description (answer)")
        await this.pc.setRemoteDescription(new RTCSessionDescription(data.sdp))
      } else if (data.type === "candidate" && data.candidate) {
        console.log("[PeerConnection] Adding ICE candidate")
        await this.pc.addIceCandidate(new RTCIceCandidate(data.candidate))
      }
    } catch (error) {
      console.error("[PeerConnection] Error processing signal:", error)
      this._emit("error", error)
    }
  }

  send(data) {
    if (this.dataChannel && this.dataChannel.readyState === "open") {
      this.dataChannel.send(data)
    } else {
      console.warn("DataChannel not ready, cannot send data")
    }
  }

  // Public method to manually create offer (for initiator)
  createOffer() {
    if (!this.dataChannel) {
      console.warn("[PeerConnection] Data channel not ready, creating it first")
      this._createDataChannel()
    }
    this._createOffer()
  }

  on(event, callback) {
    if (!this.listeners[event]) {
      this.listeners[event] = []
    }
    this.listeners[event].push(callback)
  }

  _emit(event, data) {
    if (this.listeners[event]) {
      this.listeners[event].forEach(callback => callback(data))
    }
  }

  destroy() {
    if (this.dataChannel) {
      this.dataChannel.close()
    }
    if (this.pc) {
      this.pc.close()
    }
    this.listeners = {}
  }
}

export default PeerConnection
