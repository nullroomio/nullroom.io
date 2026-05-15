# Roadmap

## Build Integrity & Supply Chain

- [ ] **Migrate to Chainguard hardened Ruby image** — Replace `ruby:4.0.1-slim` (7 high CVEs in Debian base) with `cgr.dev/chainguard/ruby` for near-zero OS-level vulnerabilities. Requires adapting package installs and jemalloc linking to the Alpine/wolfi base.

- [ ] **BuildKit `rewrite-timestamp`** — Enable `--output type=image,rewrite-timestamp=true` on production builds to normalize all file timestamps in image layers, complementing the existing `SOURCE_DATE_EPOCH` env.

- [ ] **CI-gated deterministic verification** — Run `bin/verify-deterministic-build` in CI when build-critical files change (`Dockerfile`, `Gemfile.lock`, `importmap.rb`, `app/assets/**`, `vendor/javascript/**`).

- [ ] **Byte-level reproducibility audit** — Use `diffoscope` to identify and eliminate any remaining sources of image-level non-determinism beyond asset content (layer metadata, gzip headers, tar timestamps).

## Pro Encryption Tiers (Donor-Unlocked)

Encryption upgrades available to users who support nullroom with a Monero donation. Each tier is additive — higher tiers include all protections below them. The existing blind-token receipt system ensures donation status is cryptographically verified without linking payment identity to chat sessions.

- [ ] **Donation → Feature gate wiring** — Encode the unlocked encryption tier inside the blind-token `token_traits` field at signing time. Client reads traits from the stored token and surfaces pro options in the room UI. No accounts or identity linkage required.

- [ ] **ML-KEM-1024 (NIST Level 5)** — Upgrade the post-quantum key exchange from Level 3 (768) to the highest NIST security level. Equivalent to AES-256 brute-force resistance; designed to withstand even optimistic future quantum designs. Minimal latency impact.

- [ ] **PQ Continuous Re-keying (Quantum Double Ratchet)** — Fresh ML-KEM exchange on every message. If any single session key is compromised, the next message heals forward secrecy automatically. Trades a small per-message latency cost for continuous post-quantum resistance.

- [ ] **Classic McEliece option** — Code-based post-quantum algorithm from an entirely different mathematical family (error-correcting codes vs. lattices). ~1 MB public key causes a brief connection delay, but the scheme has never been significantly weakened since 1978.

- [ ] **Multi-Algorithm Cascading** — Messages wrapped in three independent cryptographic layers: AES-GCM-256 (classical) → ML-KEM-1024 (lattice) → Classic McEliece (code-based). An attacker must simultaneously break all three mathematical problems to read a single message.

## Pro Room Features (Donor-Unlocked)

Quality-of-life upgrades for donors that don't compromise the zero-trace security model.

- [ ] **Extended & renewable room expiration** — Allow pro users to set a custom room TTL (up to a configurable maximum) when creating a room, and to renew the timer from the room UI before it expires. Token is verified server-side before granting the extension.

- [ ] **Larger file transfers** — Raise the P2P file transfer size limit for pro rooms. The current 16 MB cap remains the default; donors unlock a higher ceiling (e.g. 256 MB) after blind-token verification.

## Infrastructure & Privacy

- [ ] **Self-hosted STUN/TURN server** — Replace Cloudflare's STUN/TURN relay with a privately operated server to eliminate third-party visibility into connection metadata (IP pairs, session timing, bandwidth patterns). Removes the last external party that can observe routing-level information about room participants.
