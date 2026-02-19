# Contributing to nullroom.io

Thanks for contributing.

This project is privacy-first. Every change must preserve the app’s core guarantees:

- zero-knowledge message handling
- zero-trace operational posture
- simple, reliable 2-peer WebRTC flow

## Core non-negotiables

Before opening a PR, confirm your changes do **not** break these invariants:

1. Encryption keys are generated client-side only.
2. Encryption keys remain in URL fragments (`#...`) and never enter server params, headers, logs, or DB.
3. Message content is never persisted server-side.
4. Signaling remains a relay mechanism, not a message transport.
5. Room capacity remains max 2 peers.
6. Ephemeral room metadata remains TTL-based in Redis.
7. Production logging stays privacy-preserving (Rails + Thruster request logging disabled).

## WebRTC contribution expectations

If your PR touches signaling, peer setup, ICE flow, or connection lifecycle:

- Keep offer/answer/ICE trickling compatible with the existing relay channel.
- Do not add server-side parsing/inspection of encrypted payloads beyond what is required for signaling.
- Preserve disconnect handling behavior (peer-left / room-terminated UX).
- Prefer minimal, incremental changes over protocol rewrites.
- Document interoperability assumptions (browser behavior, TURN fallback, NAT behavior).

Include in PR description:

- what signaling behavior changed
- why it is needed
- how you tested two-browser/two-profile handshake and reconnect/close behavior
- any privacy impact analysis

## Zero-Knowledge maintenance checklist

For any PR that touches controllers, channels, middleware, logging, telemetry, or infra config:

- [ ] No secret key material can reach server-visible surfaces.
- [ ] No plaintext message content is logged, stored, or forwarded through Rails endpoints.
- [ ] No new identifiers are introduced that link user identity to room activity.
- [ ] No analytics, tracking cookies, or fingerprinting additions are introduced.
- [ ] `SECURITY.md` and `README.md` are updated if behavior or guarantees changed.

## Pull request requirements

- Keep PRs focused and scoped.
- Add/update tests when changing behavior.
- Include manual verification steps for user-facing or WebRTC behavior.
- Explain risk and rollback strategy for infra/security-related changes.
- Use clear commit messages and PR title.

Recommended PR template sections:

- Summary
- Privacy/Security impact
- WebRTC impact (if applicable)
- Testing performed
- Rollback notes

## Development and validation

Typical local checks before opening PR:

- `bin/rails test`
- Manual 2-peer room test in separate browser profiles/windows
- Validate room full rejection on 3rd join attempt
- Validate peer disconnect triggers termination UX

## Reporting vulnerabilities

Do not file public issues for unpatched security vulnerabilities.

Follow [SECURITY.md](SECURITY.md) for responsible disclosure via `security@nullroom.io`.

## Code style and scope

- Follow existing Rails + Stimulus patterns in this repository.
- Avoid introducing new dependencies unless clearly justified.
- Favor readability over clever abstractions in security-sensitive flows.
- If a requirement is ambiguous, choose the simplest implementation that preserves privacy guarantees.
