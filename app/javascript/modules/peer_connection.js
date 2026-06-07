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
    this._candidateTypes = new Set()

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
        // Track gathered candidate types (host, srflx, relay)
        const cType = event.candidate.type
        if (cType) this._candidateTypes.add(cType.toUpperCase())
        this._emit("ice-candidate", cType)

        this._emit("signal", {
          type: "candidate",
          candidate: event.candidate
        })
      }
    }

    // Track ICE gathering completion
    this.pc.onicegatheringstatechange = () => {
      if (this.pc.iceGatheringState === "complete") {
        this._emit("ice-gathering-complete", this._candidateTypes)
      }
    }

    // Handle connection state changes
    this.pc.onconnectionstatechange = () => {
      devInfo("[PeerConnection] Connection state", this.pc.connectionState)
      if (this.pc.connectionState === "connected") {
        // Only re-emit connect if already confirmed (post PQ-upgrade)
        if (this._connected) this._emit("connect")
      } else if (this.pc.connectionState === "failed") {
        this._emit("connection-failed")
        this._emit("close")
      } else if (this.pc.connectionState === "closed") {
        this._emit("close")
      }
    }

    this.pc.onicecandidateerror = (error) => {
      devLog("[PeerConnection] ICE candidate error:", error)
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

  // Inspect the nominated ICE candidate pair to determine if connection is direct or relayed.
  async detectConnectionType() {
    try {
      const stats = await this.pc.getStats()
      let activePairId = null

      // Find the nominated/succeeded candidate pair
      stats.forEach(report => {
        if (report.type === "transport" && report.selectedCandidatePairId) {
          activePairId = report.selectedCandidatePairId
        }
      })

      // Fallback: look for a succeeded candidate-pair directly
      if (!activePairId) {
        stats.forEach(report => {
          if (report.type === "candidate-pair" && report.state === "succeeded" && report.nominated) {
            activePairId = report.id
          }
        })
      }

      if (!activePairId) {
        devLog("[PeerConnection] Could not determine active candidate pair")
        return "relay"  // conservative fallback — apply relay limit on stats failure
      }

      const pair = stats.get(activePairId)
      if (!pair) return "relay"  // conservative fallback

      const localCandidate = stats.get(pair.localCandidateId)
      const remoteCandidate = stats.get(pair.remoteCandidateId)

      const localType = localCandidate && localCandidate.candidateType
      const remoteType = remoteCandidate && remoteCandidate.candidateType

      // relay on either side → relayed through TURN; host/srflx/prflx → direct
      const connectionType = (localType === "relay" || remoteType === "relay") ? "relay" : "direct"
      devLog("[PeerConnection] Connection type:", connectionType, { localType, remoteType })
      return connectionType
    } catch (err) {
      devLog("[PeerConnection] getStats() failed:", err)
      return "direct"
    }
  }

  // Return the set of ICE candidate types gathered so far.
  getCandidateTypes() {
    return this._candidateTypes
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
      this._emit("datachannel-open")
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
      devLog("[PeerConnection] File channel error:", error)
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

  /**
   * Mark the connection as fully ready (post PQ-upgrade).
   * Emits the "connect" event that enables UI messaging.
   */
  confirmReady() {
    this._connected = true
    this._emit("connect")
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
