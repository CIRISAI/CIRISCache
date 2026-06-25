# CIRISCache — design

## Goal

A **cross-repo** CI build cache for the four Rust-compiling CIRIS repos
(CIRISPersist, CIRISEdge, CIRISVerify, CIRISServer) that stays entirely inside
GitHub's trust domain — no S3/R2, no external account, no stored credential
beyond the built-in `GITHUB_TOKEN`. The motivation: GitHub's own
`actions/cache` (and sccache's `gha` backend) are **repo-scoped and capped at
10 GB**, so the same substrate compiles are redone in every repo and can't be
shared.

## Mechanism

A **public GHCR package** is a free, unlimited, content-addressable blob store
reachable from any repo. CIRISCache stores a cache as a gzipped tarball pushed
to that package with [ORAS](https://oras.land):

```
restore: oras pull ghcr.io/cirisai/ciriscache:<key>  →  tar -xzP   (anonymous, public)
save:    tar -czP <paths>  →  oras push ghcr.io/cirisai/ciriscache:<key>   (GITHUB_TOKEN)
```

The tarball uses absolute paths (`tar -P`) so it restores in place across runs
of the same OS (HOME / workspace paths are stable per runner OS; the cache key
includes `runner.os`+`runner.arch`, so cross-OS blobs never collide).

## Auth — secret-free

| op | who | auth |
|----|-----|------|
| **restore** (pull) | any repo | **none** — public package, anonymous pull |
| **save** (push) | the warmer job | the job's own `GITHUB_TOKEN` + `permissions: packages: write` |

No PAT, no org secret. A repo can push to the package once it's been **granted
write access** to it (one-time, below).

## One-time setup

1. **Create the package** — the first `save` (e.g. this repo's `selftest`, or a
   manual `oras push`) creates `ghcr.io/cirisai/ciriscache`. It starts *private*.
2. **Make it public** — Org → Packages → `ciriscache` → Package settings →
   *Change visibility* → Public. (Public = unlimited free storage/bandwidth +
   anonymous cross-repo pull.)
3. **Grant writers** — same Package settings → *Manage Actions access* → add
   **CIRISPersist / CIRISEdge / CIRISVerify / CIRISServer** with role **Write**.
   Now each repo's native `GITHUB_TOKEN` can `save` to the package — no secret to
   distribute or rotate.

## Cache keys — the cross-repo lever

The key *is* the OCI tag. Two modes:

- **Auto (per-repo, default):** `v1-<os>-<arch>-<rustc>-<hash(Cargo.lock)>`.
  This is `Swatinem/rust-cache` semantics, but stored in GHCR — so: unlimited
  size, and it survives the tag-ref boundary (a tag publish restores what `main`
  saved, which the repo-scoped GHA cache makes awkward).

- **Shared (cross-repo):** pass an explicit `key:` derived from inputs **every
  repo shares** — the substrate triple + rustc:

  ```
  key: substrate-persist10.2.0-edge7.0.10-verify7.4.0-rustc1.90
  ```

  Warm it once (any repo, on a substrate bump) → every repo restores the same
  blob. This is what makes "build the substrate once, everyone inherits"
  actually happen.

## Honest ceiling

This is **coarse, whole-tarball** caching — dedup is per *cache key*, not per
*crate*. A content-addressed remote (sccache → S3/R2) dedups per compilation
unit and so tolerates partial overlap between repos. CIRISCache cannot, because
**sccache has no GHCR/OCI backend** and bridging one needs a persistently-hosted
S3↔OCI proxy (not free/serverless). The pure-GitHub trade is: you get a shared
blob store for free, but you must align the *inputs* (shared key, same rustc,
same profile/features) for a cross-repo hit. For the CIRIS substrate — where all
four repos pin the *same* triple by design — a shared-key tarball captures the
bulk of the win without leaving GitHub.

Practical guidance:
- **Per-repo speedups:** `Swatinem/rust-cache` is simpler; reach for CIRISCache
  when you've hit the 10 GB GHA cap or want cross-repo sharing.
- **Save on the warmer only** (`if: github.ref == 'refs/heads/main'`), restore
  everywhere — same model as CIRISServer's `warm-release-cache.yml`.

## Limitations / failure modes

- GHCR API rate limit ~5000 req/hr per token — irrelevant for a coarse tarball
  (one pull + one push per job).
- GHCR is a single point of failure; a miss/outage degrades to a cold build
  (never a hard failure — `restore` reports `cache-hit=false` and the build
  proceeds).
- Tarballs accrue; prune old tags periodically (a scheduled `oras` cleanup or
  the GHCR "delete old versions" retention policy).
