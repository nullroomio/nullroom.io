<div align="center">
  <img src="public/icon.svg" alt="nullroom logo" width="80" height="80" />

  # nullroom.io

  **The Conversation That Never Happened.**

  [![Test](https://github.com/nullroomio/nullroom.io/actions/workflows/test.yml/badge.svg)](https://github.com/nullroomio/nullroom.io/actions/workflows/test.yml)
  [![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
  ![Post-Quantum](https://img.shields.io/badge/Post--Quantum-ML--KEM--768-blueviolet)
  ![Zero-Knowledge](https://img.shields.io/badge/Zero--Knowledge-Architecture-black)
</div>

Peer-to-peer encrypted messaging that leaves no trace. No accounts. No logs. No server memory.
Messages travel directly between browsers over WebRTC, encrypted with a **hybrid post-quantum + classical key** that the server never possesses.
Rooms self-destruct after 15 minutes. Close the tab and it's gone.

---

## Why nullroom?

Most encrypted messengers still require a phone number, an app install, and an account — creating a permanent identity tied to your conversations. nullroom takes a different approach:

| | Traditional E2EE Apps | nullroom |
|---|---|---|
| **Identity** | Phone number or email required | None — no accounts, ever |
| **Installation** | App store download | Browser tab — nothing to install |
| **Persistence** | Messages stored (encrypted) on servers | Messages exist only in browser memory |
| **Metadata** | Server logs connections, contacts, timestamps | Server logs disabled; Redis-only ephemeral state |
| **Post-quantum** | Rarely | ML-KEM-768 hybrid key exchange by default |
| **After the conversation** | Account persists, contact graph remains | Close the tab. No trace on the device or server |

nullroom is built for conversations that shouldn't leave a footprint: sharing production secrets, sensitive legal consultations, journalist-source communication, or any exchange where **the existence of the conversation is as sensitive as its content**.

---

## Security Architecture

### Hybrid Post-Quantum Encryption

Every session is protected by two independent layers of encryption, fused into a single hybrid key:

```
Classical Layer                  Quantum Layer
─────────────                    ─────────────
AES-GCM-256 key                  ML-KEM-768 (FIPS 203)
generated in browser             key exchange over DataChannel
lives in URL fragment (#)        1184-byte public key
never sent to server             1088-byte ciphertext
                                 32-byte shared secret
        │                                │
        └──────────┐    ┌────────────────┘
                   ▼    ▼
            HKDF-SHA-256 derivation
            salt = classical key
            ikm  = quantum secret
            info = "nullroom-hybrid-v1"
                   │
                   ▼
          Hybrid Session Key (AES-GCM-256)
          ══════════════════════════════════
          Used for all message encryption
```

**Neither key alone is sufficient.** An attacker would need to compromise both the URL fragment *and* break the lattice-based ML-KEM scheme — which is designed to resist quantum computers (NIST Security Level 3).

The post-quantum upgrade follows a **3-message protocol** over the WebRTC data channel with mutual HMAC-SHA-256 confirmation using role-specific labels (`nullroom-pq-confirm-initiator` / `nullroom-pq-confirm-responder`), preventing reflection and man-in-the-middle attacks.

### Zero-Knowledge Signaling

The server is a **dumb relay**. It never possesses encryption keys and cannot decrypt any messages:

- The **encryption key** is generated client-side via the Web Crypto API and placed in the URL fragment (`#`), which [browsers never send to servers](https://www.rfc-editor.org/rfc/rfc3986#section-3.5).
- **ActionCable** relays WebRTC signaling payloads (SDP offers/answers, ICE candidates) without parsing or storing them.
- The **quantum key exchange** happens directly over the peer-to-peer data channel — the server is not involved.
- **Production logging is disabled** (`Logger.new(nil)` + `:fatal` log level). The `no-referrer` meta tag prevents URL leakage to third parties.

### Ephemeral State

No database writes for room or message data. The only server-side state is volatile Redis:

| Key | TTL | Purpose |
|---|---|---|
| `room:<uuid>` | 15 min | Room existence marker |
| `room:<uuid>:count` | 16 min | Participant counter (max 2) |

Both keys auto-expire. When a peer disconnects, the other peer's UI is immediately scrubbed and the room can optionally be destroyed in Redis on the spot.

---

## How It Works

### 1. Create a room

Click **"Create Secure Room"** → browser sends `POST /rooms` → server creates a UUID in Redis and returns TURN credentials → browser generates an AES-GCM-256 key locally → redirects to `/rooms/<uuid>#<key>`.

The server knows the room exists. It never knows the key.

### 2. Invite your peer

Three ways to share the room — pick the one that fits your threat model:

| Method | How | Security |
|---|---|---|
| **Direct Link** | Copy the full URL (with `#key`) and send via a trusted channel | Key travels with the link |
| **QR Code** | Peer scans the on-screen QR code in person | Air-gapped — key never touches the network |
| **4-Word Phrase** | Read a phrase like `neon-zebra-piano-rocket` over a voice call | PBKDF2-derived AES key (100K iterations) encrypts the room URL; SHA-256 of the phrase serves as a one-time Redis lookup key; blob auto-deletes after retrieval or 3 minutes |

### 3. Connect and upgrade

Once both peers are in the room:

1. **WebRTC signaling** — SDP offer/answer and ICE candidates relay through ActionCable
2. **Data channel opens** — direct peer-to-peer connection established
3. **Post-quantum upgrade** — ML-KEM-768 key exchange runs automatically over the data channel
4. **Hybrid key derived** — classical URL key + quantum secret fused via HKDF-SHA-256
5. **Mutual confirmation** — both peers verify role-specific HMACs before activating the hybrid key

Status transitions: `Signaling…` → `Upgrading…` → `Secure P2P`

### 4. Chat and transfer files

- Every message is encrypted with the hybrid key (AES-GCM-256, random 12-byte IV per message) **before leaving the browser**.
- File transfers run over a dedicated `nullroom-files` data channel with **per-chunk encryption** (64 KB chunks, backpressure control at 16 MB buffer). Default size limit: 16 MB.
- Messages and files travel **directly between browsers** — the server is not in the data path.

### 5. Room termination

When either peer closes the tab:
- The remaining peer's message history is **immediately scrubbed from the DOM**.
- Input is disabled and a termination modal is shown.
- The Redis room key auto-expires (or is deleted immediately if `DESTROY_ROOM_ON_PEER_LEAVE` is enabled).
- Refreshing the URL shows "Invalid room link." There is nothing to recover.

---

## Features

| Feature | Details |
|---|---|
| **E2EE Messaging** | AES-GCM-256 via Web Crypto API, per-message random IV |
| **Post-Quantum Key Exchange** | ML-KEM-768 (NIST FIPS 203, Security Level 3) with hybrid HKDF derivation |
| **P2P File Transfer** | Chunked, per-chunk encrypted, dedicated data channel, configurable size limit |
| **4-Word Handshake** | BIP-39 wordlist, PBKDF2 (100K iterations), one-time encrypted Redis blob (180s TTL) |
| **QR Code Sharing** | In-person room joining without transmitting the key over the network |
| **Anonymous Donations** | Monero (XMR) payments with RSA blind signatures — payment identity is cryptographically decoupled from chat sessions |
| **Zero-Trace Termination** | Peer disconnect triggers immediate UI scrub + optional Redis room destruction |
| **NAT Traversal** | Cloudflare TURN relay with short-lived credentials |
| **2-Person Room Lock** | Server-enforced capacity — third connection attempts are rejected |
| **No-Log Production** | Logger disabled, `no-referrer` policy, filtered parameters |
| **CSP Hardened** | Per-request nonces, `frame-ancestors: none`, no `unsafe-inline` |

---

## Tech Stack

| Layer | Technology |
|---|---|
| Backend | Ruby on Rails 8, ActionCable, Redis |
| Frontend | Stimulus, Turbo, Importmap, Tailwind CSS |
| Transport | WebRTC (RTCPeerConnection + DataChannel) |
| Classical Crypto | Web Crypto API — AES-GCM-256, HKDF-SHA-256, HMAC-SHA-256, PBKDF2 |
| Post-Quantum Crypto | ML-KEM-768 (NIST FIPS 203) |
| NAT Traversal | Cloudflare TURN |
| Payments | Monero RPC + RSA blind signatures |
| Database | SQLite (app metadata only — no chat data) |

---

## Configuration

All settings live in [`config/initializers/nullroom.rb`](config/initializers/nullroom.rb) and can be overridden via environment variables:

| Variable | Default | Description |
|---|---|---|
| `NULLROOM_ROOM_TTL_SECONDS` | `900` (15 min) | Room lifetime before auto-expiry |
| `NULLROOM_FILE_TRANSFER_SIZE_LIMIT_BYTES` | `16777216` (16 MB) | Max P2P file transfer size |
| `NULLROOM_DONATION_AMOUNT_PICONERO` | `4000000000` (0.004 XMR) | Donation amount for blind token |
| `NULLROOM_DONATION_CONFIRMATIONS_REQUIRED` | `10` | Monero confirmations before signing |
| `NULLROOM_DONATION_PAYMENT_SESSION_TTL_SECONDS` | `1800` (30 min) | Payment session lifetime |
| `NULLROOM_DONATION_SPENT_TOKEN_TTL_SECONDS` | `86400` (24 hr) | Spent token replay prevention window |
| `NULLROOM_DONATION_SESSION_UNLOCK_TTL_SECONDS` | `43200` (12 hr) | Browser session unlock duration |

### Room lifecycle

By default, rooms remain active until their TTL expires, allowing peers to reconnect via browser history. To destroy rooms immediately when any peer leaves:

```ruby
# config/initializers/nullroom.rb
DESTROY_ROOM_ON_PEER_LEAVE = true
```

---

## Routes

| Method | Path | Description |
|---|---|---|
| `GET` | `/` | Landing page |
| `POST` | `/rooms` | Create room (returns JSON) |
| `GET` | `/rooms/:id` | Room UI |
| `GET` | `/privacy` | Privacy policy & FAQ |
| `GET` | `/up` | Health check (app + Redis) |
| | `/cable` | ActionCable WebSocket |

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Security

Please read our security policy and disclosure process in [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE)
