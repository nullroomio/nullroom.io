# Security Policy

## Reporting a Vulnerability

If you discover a security issue, please report it privately:

- Email: security@nullroom.io
- Preferred: include your PGP key so we can reply encrypted
- Include:
  - clear reproduction steps
  - impact assessment
  - affected endpoint, feature, or version
  - proof-of-concept (if possible)

Please do not open public issues for unpatched vulnerabilities.

## Disclosure Process

- Acknowledgement target: within 48 hours
- Triage: we validate, assess severity, and define a fix plan
- Remediation: we prioritize by impact and exploitability
- Coordination: we will coordinate disclosure timing with the reporter
- Credit: we can credit reporters publicly, if requested

## Safe Harbor

We will not pursue legal action against good-faith security research that:

- avoids privacy violations, data destruction, and service disruption
- does not access content beyond what is necessary to demonstrate the issue
- does not use social engineering, phishing, or physical attacks
- gives us reasonable time to investigate and remediate before disclosure

## Zero-Trace Philosophy

nullroom.io is designed to minimize retained data and operator knowledge.

### Design Principles

- Browser-generated keys: encryption keys are created client-side
- Fragment-only key transport: secret key is placed after `#` in the URL, which is not sent to the server in HTTP requests
- Peer-to-peer messaging: message payloads are exchanged via WebRTC DataChannels
- Signaling relay only: server relays WebRTC signaling messages and does not decrypt message content
- Ephemeral room state: room metadata is short-lived in Redis with TTL expiration
- Two-peer room cap: rooms are limited to 2 participants
- Minimal production logging: production Rails logging and Thruster request logging are disabled

### What We Do Not Intend to Store

- account identities (no account system)
- plaintext message content
- encryption keys

## Security Limits and Assumptions

No system can guarantee absolute anonymity or perfect security.

- Endpoint compromise risk: if a device/browser is compromised, message secrecy can fail
- Metadata realities: network-layer metadata may still be observable by infrastructure providers or attackers
- Relay dependencies: STUN/TURN infrastructure is required for connectivity in restrictive NAT environments
- User responsibility: sharing the full room URL (including `#` fragment) shares access

## Scope

In scope examples:

- authorization flaws in room access flow
- signaling channel abuse that breaks privacy or room isolation
- key handling flaws that expose fragment secrets server-side
- vulnerabilities enabling unauthorized room participation or message interception

Out of scope examples:

- social engineering attacks
- physical access attacks
- denial-of-service without a concrete security bypass

## Contact

For all security matters, contact: security@nullroom.io
