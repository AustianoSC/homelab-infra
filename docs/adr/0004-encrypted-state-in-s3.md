# 0004. OpenTofu state in S3, encrypted client-side

Status: Accepted (2026-10)

## Context

OpenTofu state records every resource's attributes and can contain secrets.
This repo is public, and work happens from two machines (a WSL desktop and a
MacBook, the latter over WireGuard). The options were local state, Cloudflare
R2, or AWS S3.

## Decision

Store state in a versioned S3 bucket with native lockfile locking
(`use_lockfile`), and encrypt it client-side with OpenTofu's state encryption
(`pbkdf2` key derivation, `aes_gcm`, `enforced = true`). The passphrase lives in
1Password and is injected with `op run`.

## Consequences

- Both machines see the same state, and the lock stops them applying at the
  same time.
- Versioning lets a bad state write be rolled back.
- Even with bucket access, the state is unreadable without the passphrase, so
  the bucket doesn't have to be trusted with secrets.
- Local state was rejected because it couldn't be shared between two machines
  without a sync step that is easy to get wrong. R2 would also have worked,
  but S3 is the backend's native target and AWS was already in use.
- Losing the passphrase means losing the state. Recovery would be re-importing
  the three VMs, or, since they are disposable, destroying and rebuilding.
