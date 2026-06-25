# CIRISCache

**Free, cross-repo CI build cache for the CIRIS substrate — backed entirely by GitHub Container Registry (GHCR).**

No third-party account, no S3, no stored secret beyond the built-in `GITHUB_TOKEN`.
Public GHCR packages get **unlimited storage and bandwidth for free**, and they're
reachable from *any* repo — which is exactly what a shared build cache needs and
what GitHub's own `actions/cache` (repo-scoped, 10 GB) cannot do.

It's two tiny composite actions wrapping [ORAS](https://oras.land) push/pull of a
tarball to/from a GHCR package:

- **`CIRISAI/CIRISCache/restore@v1`** — pull + extract the cache before a build.
- **`CIRISAI/CIRISCache/save@v1`** — tar + push the cache after a build.

## Quick start

```yaml
permissions:
  contents: read
  packages: write          # only the job that SAVEs needs this

steps:
  - uses: actions/checkout@v4
  - uses: dtolnay/rust-toolchain@stable

  - uses: CIRISAI/CIRISCache/restore@v1
    id: cache
    # public package → anonymous pull, no token needed

  - run: cargo build --release   # your build

  - uses: CIRISAI/CIRISCache/save@v1
    if: github.ref == 'refs/heads/main'   # save on the warmer, not every PR/tag
    with:
      token: ${{ secrets.GITHUB_TOKEN }}
```

Restore is anonymous (public package). Save uses the job's own `GITHUB_TOKEN` —
no PAT, no org secret — once the saving repo has been **granted write access to
the package** (one-time, see [docs/DESIGN.md](docs/DESIGN.md#one-time-setup)).

## Cross-repo sharing

By default the cache key is auto-derived per repo (`rustc` + `Cargo.lock` hash) —
i.e. a drop-in `rust-cache` that lives in GHCR instead of the per-repo GHA cache
(so: unlimited storage, survives across the tag-ref boundary).

To let **one repo's compile feed another** (e.g. warm the substrate once, restore
it everywhere), pass an **explicit `key` derived from shared inputs** — the
substrate triple + `rustc` — so every repo computes the *same* key:

```yaml
  - uses: CIRISAI/CIRISCache/restore@v1
    with:
      key: substrate-persist10.2.0-edge7.0.10-verify7.4.0-rustc1.90
```

See [docs/DESIGN.md](docs/DESIGN.md) for the design, the honest granularity
ceiling (this is coarse whole-dir caching, not sccache per-crate addressing),
and the one-time package setup.

## Why not R2 / S3 / sccache-remote?

Those work, but each adds an external account + credential = another point of
failure. CIRISCache keeps the whole thing inside GitHub's trust domain. The
trade is granularity: a content-addressed remote (sccache → S3/R2) dedups
per *crate*; CIRISCache dedups per *cache key* (a whole tarball). For the CIRIS
substrate — where every repo pins the *same* triple — a shared-key tarball
captures the bulk of the win without leaving GitHub.
