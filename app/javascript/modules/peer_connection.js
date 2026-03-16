/**
 * Lightweight WebRTC wrapper for nullroom P2P connections
 * Replaces simple-peer with vanilla WebRTC API
 */

import { devInfo, devLog } from "modules/dev_logger"

export class PeerConnection {
  constructor(options = {}) {
    this.initiator = options.initiator || false
    this.iceServers = options.iceServers || []
    this.trickleIce = options.trickleIce !== false

    this.pc = null
    this.dataChannel = null
    this.fileChannel = null
    this.listeners = {}
    this._connected = false
    this._pendingCandidates = []

    this._init()
  }

  _init() {
    devLog("[PeerConnection] Initializing", { initiator: this.initiator })

    // Create RTCPeerConnection
    this.pc = new RTCPeerConnection({
      iceServers: this.iceServers
    })

    // Handle ICE candidates
    this.pc.onicecandidate = (event) => {
      if (event.candidate && this.trickleIce) {
        this._emit("signal", {
          type: "candidate",
          candidate: event.candidate
        })
      }
    }

    // Handle connection state changes
    this.pc.onconnectionstatechange = () => {
      devInfo("[PeerConnection] Connection state", this.pc.connectionState)
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
      // If not initiator, wait for data channel(s) opened by the initiator
      this.pc.ondatachannel = (event) => {
        if (event.channel.label === "nullroom-files") {
          this.fileChannel = event.channel
          this._setupFileChannel()
        } else {
          this.dataChannel = event.channel
          this._setupDataChannel()
        }
      }
    }
  }

  _createDataChannel() {
    this.dataChannel = this.pc.createDataChannel("nullroom", {
      ordered: true
    })
    this._setupDataChannel()

    // Dedicated channel for P2P file transfer (binary, ordered)
    this.fileChannel = this.pc.createDataChannel("nullroom-files", {
      ordered: true
    })
    this._setupFileChannel()
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

  _setupFileChannel() {
    this.fileChannel.binaryType = "arraybuffer"

    this.fileChannel.onopen = () => {
      this._emit("file-channel-ready")
    }

    this.fileChannel.onmessage = (event) => {
      this._emit("file-data", event.data)
    }

    this.fileChannel.onerror = (error) => {
      console.warn("[PeerConnection] File channel error:", error)
    }
  }

  async _createOffer() {
    devLog("[PeerConnection] Creating offer")
    try {
      const offer = await this.pc.createOffer()
      await this.pc.setLocalDescription(offer)

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
    devLog("[PeerConnection] Creating answer")
    try {
      const answer = await this.pc.createAnswer()
      await this.pc.setLocalDescription(answer)

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
    devLog("[PeerConnection] Processing signal", data.type)
    try {
      if (data.type === "offer") {
        await this.pc.setRemoteDescription(new RTCSessionDescription(data.sdp))
        await this._flushPendingCandidates()
        await this._createAnswer()
      } else if (data.type === "answer") {
        await this.pc.setRemoteDescription(new RTCSessionDescription(data.sdp))
        await this._flushPendingCandidates()
      } else if (data.type === "candidate" && data.candidate) {
        if (this.pc.remoteDescription && this.pc.remoteDescription.type) {
          await this.pc.addIceCandidate(new RTCIceCandidate(data.candidate))
        } else {
          this._pendingCandidates.push(data.candidate)
        }
      }
    } catch (error) {
      console.error("[PeerConnection] Error processing signal:", error)
      this._emit("error", error)
    }
  }

  async _flushPendingCandidates() {
    if (!this._pendingCandidates.length) return

    const queued = this._pendingCandidates
    this._pendingCandidates = []

    for (const candidate of queued) {
      await this.pc.addIceCandidate(new RTCIceCandidate(candidate))
    }
  }

  send(data) {
    if (this.dataChannel && this.dataChannel.readyState === "open") {
      this.dataChannel.send(data)
    } else {
      console.warn("DataChannel not ready, cannot send data")
    }
  }

  sendFile(data) {
    if (this.fileChannel && this.fileChannel.readyState === "open") {
      this.fileChannel.send(data)
    } else {
      console.warn("[PeerConnection] File channel not ready, cannot send file data")
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
    if (this.fileChannel) {
      this.fileChannel.close()
    }
    if (this.pc) {
      this.pc.close()
    }
    this.listeners = {}
  }
}

export default PeerConnection
