# Verification

## The Problem

Web apps are "leased" from the server every time you hit refresh. Unlike a native app you install once, your browser downloads the code fresh on each visit. This gives the server a unique opportunity to silently swap legitimate code for a malicious version.

For a zero-knowledge app like nullroom — where the server never possesses encryption keys — a compromised server is the single biggest threat. If a rogue admin or attacker modifies the JavaScript, they could exfiltrate keys or plaintext before encryption ever happens.

nullroom's answer: **don't trust the server — verify the code.**

---

## Deterministic Builds

nullroom's Docker build is designed to produce identical output every time, regardless of when or where it runs. This is achieved through five measures:

| Measure | Purpose |
|---|---|
| **Pinned base image (SHA256 digest)** | The exact OS layer is locked — no silent Debian updates |
| **`SOURCE_DATE_EPOCH`** | All build timestamps normalized to a fixed value |
| **Frozen dependencies (`BUNDLE_DEPLOYMENT=1`)** | `bundle install` fails if `Gemfile.lock` is modified |
| **Vendored JavaScript** | `mlkem.js`, `qr-creator.js` stored locally — no CDN fetches |
| **Single-threaded compilation (`-j 1`)** | Eliminates race conditions in asset output ordering |

The asset pipeline (Propshaft) uses SHA256 content-based digests. If the source files are identical, the compiled output is byte-for-byte identical.

---

## Verify Locally

Clone the repository and run the verification script:

```bash
git clone https://github.com/nullroomio/nullroom.io.git
cd nullroom.io
bin/verify-deterministic-build
```

This performs two independent Docker builds (`--no-cache`) and compares:
1. The asset manifest (`.manifest.json`)
2. SHA256 checksums of every compiled file in `public/assets/`

If both match, you'll see:

```
✓ PASS: Asset manifests are identical. Build is deterministic.
✓ PASS: All asset files are bit-for-bit identical.
```

---

## Verify the Attestation

Every push to `main` triggers a GitHub Actions workflow that builds the production image, extracts all compiled assets, computes their SHA256 checksums, and signs the result using [GitHub Artifact Attestations](https://docs.github.com/en/actions/security-for-github-actions/using-artifact-attestations).

### Quick check

Download the attested checksums and verify the signature in one step:

```bash
# Download the checksums artifact from the latest workflow run
gh run download --repo nullroomio/nullroom.io -n asset-checksums

# Verify its attestation (confirms it was signed by GitHub Actions for this repo)
gh attestation verify asset-checksums/checksums.sha256 --repo nullroomio/nullroom.io
```

### Full rebuild (paranoid mode)

Build the image yourself and compare against the attested checksums:

1. Build the image locally from the same commit:
   ```bash
   git checkout <commit-sha>
   docker build --platform linux/amd64 -t nullroom-local .
   ```

2. Extract and checksum the assets:
   ```bash
   docker create --name local-ctr nullroom-local true
   docker cp local-ctr:/rails/public/assets/ ./my-assets/
   docker rm local-ctr
   cd my-assets && find . -type f | sort | xargs sha256sum > ../my-checksums.sha256
   ```

3. Download the attested checksums and compare:
   ```bash
   gh run download --repo nullroomio/nullroom.io -n asset-checksums
   diff my-checksums.sha256 asset-checksums/checksums.sha256
   ```

   If the diff is empty, the code you built matches what GitHub Actions signed.

---

## What's Attested

The `checksums.sha256` file contains the SHA256 hash of every compiled asset (CSS, JS, images) that the production server serves. It is signed by GitHub Actions using Sigstore OIDC — meaning the signature is tied to:

- The specific GitHub repository (`nullroomio/nullroom.io`)
- The specific commit that triggered the build
- The GitHub Actions workflow identity (not a human key that can be stolen)

This creates a chain of trust: **source code → deterministic build → signed checksums → what your browser receives.**
