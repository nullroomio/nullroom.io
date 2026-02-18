<div align="center">
  <img src="public/icon.svg" alt="nullroom logo" width="80" height="80" />

  # nullroom.io

  [![Test](https://github.com/vdw/nullroom.io/actions/workflows/test.yml/badge.svg)](https://github.com/vdw/nullroom.io/actions/workflows/test.yml)
  [![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
</div>

`nullroom.io` is a zero-trace, ephemeral peer-to-peer messaging app built with Rails, Stimulus, WebRTC, and Web Crypto.
Two people share a link, establish a direct encrypted data channel, and exchange messages without message persistence on the server.

## What this app is

- **No accounts, no identities**: users create/join rooms by URL only.
- **Ephemeral rooms**: room state is stored in Redis with a TTL (30 minutes by default).
- **2-person rooms**: the signaling channel enforces max capacity.
- **Client-side encryption**: AES-GCM keys are generated in-browser and stored in the URL fragment (`#...`), which is not sent to the server.
- **P2P messaging**: messages are sent over WebRTC DataChannels after signaling.

## How it works (current implementation)

1. User clicks **Create Room** on `/`.
2. Frontend sends `POST /rooms`; server creates room UUID in Redis and returns JSON with `room_id` and TURN `ice_servers`.
3. Browser generates AES key locally and redirects to `/rooms/:id#<key>`.
4. Room page subscribes to `RoomsChannel` for WebRTC signaling (offer/answer/ICE candidate relay).
5. Once peer connection is established, encrypted messages move directly via DataChannel.
6. If a peer leaves, the other peer gets immediate termination UX and message UI is scrubbed.

## Security model

### Zero-knowledge by design

- Encryption key is generated in browser (`Web Crypto API`) and passed in URL fragment only.
- Rails receives room IDs, not encryption fragments.
- ActionCable relays signaling payloads and does not decrypt chat content.

### Transport and messaging

- WebRTC handles encrypted transport between peers.
- Application-level message encryption uses AES-GCM in `app/javascript/modules/encryption.js`.
- TURN credentials are fetched server-side via `CloudflareTurnService` and passed to clients.

### Ephemeral state

- Redis keys:
	- `room:<uuid>` (room existence / TTL)
	- `room:<uuid>:count` (participant count)
- Room/channel state expires automatically based on TTL.

## Implemented features

- Landing page with one-click room creation.
- JSON room creation endpoint (`POST /rooms`).
- Room view (`GET /rooms/:id`) with:
	- signaling status indicator,
	- room timer,
	- share-link + copy UX,
	- message input and encrypted P2P send/receive,
	- room-terminated modal when peer disconnects.
- ActionCable signaling channel with:
	- room existence checks,
	- max 2 participants,
	- signal relay and peer-left notifications.
- Health endpoint at `/up` with Redis write check and basic rate limiting.

## Planned / roadmap (from product plan)

These are planned but **not fully implemented yet**:

- Blind JWT token system for pro room features (`exp` + feature flags only, no identity binding).
- Optional longer room TTL via valid token (e.g., 24h).
- Hardened CSP policy for production signaling/TURN hosts.
- Additional deployment-level no-log hardening and operational refinements.

## Tech stack

- Ruby on Rails 8
- ActionCable
- Redis
- Stimulus + Turbo + Importmap
- Tailwind CSS
- WebRTC (`RTCPeerConnection` + DataChannel)
- Web Crypto API (AES-GCM)
- SQLite (default app DB)

## Key routes

- `GET /` → room landing page
- `POST /rooms` → create room JSON
- `GET /rooms/:id` → room UI
- `GET /privacy` → privacy page
- `GET /up` → app + Redis health check
- `GET /cable` → ActionCable endpoint

## Deployment

Deployment is configured with Kamal. See:


Production logging posture:

## Security

Please read our security policy and disclosure process in [SECURITY.md](SECURITY.md).


## License

This project is licensed under the MIT License. See [LICENSE](LICENSE).
