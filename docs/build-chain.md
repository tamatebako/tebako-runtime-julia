# The build chain — architecture and invariants

This document is the normative description of how this repository's CI
turns a pristine julialang.org prebuilt archive into a verified runtime
pair, and of the pin contracts that keep the skeleton honest. **If you
change any workflow, the build tooling, the matrix computation, or a
cache key, update this file in the same PR.** A future agent that skips
this file and "just fixes" a red run is the classic failure mode — read
it first. (tebako-runtime-php's docs/build-chain.md is the sibling
reference; this file carries the julia factory's subset — the REPACK
arm of docs/factory-template.md §1: nothing in this factory compiles.)

## The staged hierarchy

One reusable workflow, `_build-platform.yml` (tebako-runtime-php's
port), called by the thin triggers (`build-linux-gnu.yml`,
`build-macos.yml`, `build-windows.yml`) and by the `publish.yml`
coordinator. Stages:

1. **parity** — the contract gate's driver-source parity arm needs the
   pinned link-unit release's `lib.rs` off raw.githubusercontent.com, a
   fetch that flakes under near-simultaneous per-platform reads
   (tamatebako/tebako-runtime-python#4). ONE job fetches it (bounded
   retry) and hands it to compute as an artifact.
2. **compute** — the contract gate (`scripts/check_contract.rb`:
   contract.yml against `schema/contract.schema.yml`, the
   catalog ↔ versions.yml cross-lock, and the parity arm reading the
   stage-1 artifact via `TEBAKO_DRIVER_SRC`) runs first; then
   `scripts/compute_matrix.rb` expands this platform's legs from
   `contract.yml`'s catalog × `.github/matrix.json`'s env vocabulary
   under the dispatch filters. Every downstream value flows from these
   outputs — workflow YAML never hardcodes a version, a tag, or a SHA.
   The run's `SOURCE_DATE_EPOCH` (the HEAD commit's epoch, the ruby#381
   idiom) is computed here and exported to every leg, and the
   `--format env|julias` planner forms feed the publish pipeline's
   expectation surfaces (`EXPECTED_ENV_MATRIX` /
   `EXPECTED_JULIA_MATRIX`).
3. **preflight** — the container digest pin (the ruby#381 idiom, born
   pinned here): `contract.yml container_digests` must equal the ghcr
   registry's CURRENT digest for the tag — per (container × leg arch) —
   before any leg spends compute; the build leg then pulls
   `name:tag@digest`. A retagged toolchain container fails the preflight
   by name instead of moving the environment under the matrix, and a
   failed preflight skips the build legs outright.
4. **build** — one leg per (julia × arch): `tools/build_runtime` →
   (macOS only: the spec 31 sign+notarize arm — see below) →
   `ci/check_pair_provenance.sh` → `tools/boot_smoke` → the
   `runtime-packages-<os>-<arch>-<julia>` artifact. The linux leg
   docker-runs the digest-pinned `tpkg-builder` image per step; the
   macos legs are runner-native (setup-ruby only — the repack arm
   compiles nothing); the windows leg is runner-native under Git-bash
   with the runner's hosted ruby and NO msys2 provisioning (julia ships
   tar.gz with zero symlinks, so Git-bash's GNU tar suffices — the
   openjdk factory's msys2 need was bsdtar-for-zip + the gcc runtime,
   neither of which this leg touches; the launcher/tfs artifacts are
   native static exes). The `.leg-complete` marker the leg emits on
   success is the publish job's completeness gate.
5. **publish** — its OWN job (tebako-runtime-ruby#190's split), gated
   on the `publish` input (default false — only the coordinator's
   operator-fired runs arm it): the leg that built a package downloads
   its immutable in-run artifact, verifies `.leg-complete`, and
   publishes its write-once names (spec 13 §2a's de-rendezvous) via the
   tebako-release gem (`bundle exec tebako-release upload` — payload +
   `.sha256` sidecars + the `.manifest.json` shard + the blksum), signs
   every served name (`tebako-release sign`, spec 09 §5), and attests
   the bytes (SLSA L3, `actions/attest-build-provenance`). A re-run of
   a failed publish leg is a minutes-long download + upload, never a
   rebuild.
6. **verify** — the terminal aggregate and the branch-protection gate.
   The build legs are a dynamic matrix whose check names shift with the
   catalog, so protection pins this job's stable check name; on
   publish-armed runs the gate depends on the publish legs too
   (tebako-runtime-ruby#190's lesson).

The **macOS sign+notarize arm** (spec 31 §5/§8.4 —
`ci/macos-sign-notarize-runtime.sh`, `ci/runtime.entitlements`) runs
in-leg between the build and the gates: Developer ID Application +
hardened runtime + the entitlement pair
(`disable-library-validation` — the unsigned preload-shim injection —
+ `allow-jit` — julia's LLVM JIT), notarize via the App Store Connect
key, poll the ticket, quarantine-mark the exe so the boot smoke runs
under Gatekeeper's exact download path, then **rewrite the exe
`.sha256` sidecar to the SIGNED bytes** (sign-then-hash — every later
stage anchors the shipped bytes). Gated on the `APPLE_SIGNING_ENABLED`
repo variable: anything else ships unsigned BY DESIGN (spec 00
invariant 7, a loud notice); armed + a missing `APPLE_*` secret is a
fast named failure. Only the LAUNCHER is signed — the interpreter
inside the env image keeps upstream's own Developer ID signature
byte-identical (the repack arm never re-signs upstream bytes; upstream
julia ships hardened-runtime with its own JIT/injection grants, which
govern the materialized interpreter process post-exec).

The **windows Authenticode arm** (spec 34 §8.2 —
`ci/windows-sign-gate.sh` + the in-leg sign block) runs in-leg at the
same point, between the build and the gates. The arm check gates on
the `WINDOWS_SIGNING_ENABLED` repo variable: anything else ships
unsigned BY DESIGN (spec 00 invariant 7, a loud notice — the byte
anchor holds byte-identical); armed + a missing `AZURE_*`
secret/variable is a fast named failure before any signing call. When
armed, the leg's ONE shippable PE — the launcher exe (julia.exe and
its DLLs live inside the env image, the exec-cache shape, so there is
no DLL facet) — stages under `sign-staging/` (the signing action
enumerates by extension, so the `.tfs`, the card, and the sidecars
never enter `files-folder`), `azure/login` OIDCs into the
`windows-signing` environment (the job-level `id-token: write`
boundary; the environment carries no protection rules — reviewers
there would gate every platform's legs), the
`Azure/artifact-signing-action` signs with the mandatory RFC 3161
timestamp, and the pwsh verify step moves the signed bytes BACK over
the contract path, runs `signtool verify /pa /v` +
`Get-AuthenticodeSignature` (Valid + TimeStamperCertificate), and
**re-anchors the exe `.sha256` sidecar to the SIGNED bytes**
(sign-then-hash, the macOS arm's idiom). The provenance gate's PE arm
mirrors the Mach-O arm: armed anchors the signed bytes + the
signature; gate-off keeps the byte anchor.

The **coordinator** (`publish.yml`, dispatch-only, `publish` default
false) fans out to `_build-platform.yml` per platform and keeps ONE
release job: the read-only whole-matrix audit (`AUDIT_ONLY=true
tebako-release upload` per platform that built), the registry render
(`tools/registry_update.rb` from the release's `.manifest.json`
shards) landed by bot PR, the aggregate nudge, and the versions ping.
A `force_rebuild` republication first recreates the release OBJECT
under the kept tag (tebako-runtime-ruby#189). No release has been cut;
the first release is the owner's explicit act.

`lint.yml` is the static gate (no builds): the same contract check, the
catalog/matrix resolution (all three planner formats, so the publish
pipeline's expectation surfaces never rot unconsumed), a `ruby -c`
sweep over every authored ruby file, and a parse pass over every
authored YAML/JSON.

## The inputs (all pinned, all verified)

- **the julia archive** — the OFFICIAL prebuilt
  `julia-<v>-<platform>.tar.gz` off julialang.org, sha256-pinned per
  version per triplet in `versions.yml` (cross-checked against
  upstream's `versions.json` at pin time). Julia ships compiled bytes,
  so there is NO tamatebako julia source factory and no build of the
  interpreter anywhere in the chain. `SourceFetcher` downloads and
  verifies; a checksum mismatch is a named error (exit 121), never a
  re-fetch.
- **the runtime launcher** — `tebako-runtime-launcher-<ver>-<pid>` from
  the pinned tamatebako/tebako release (`contract.yml
  link_unit_release`), verified against its published `.sha256`
  sidecar. The pair's EXE artifact is this binary, copied
  byte-identical on linux and windows — the spec-29 wrapper shape
  (README's driver-link decision). On macOS the binary is the sign
  arm's input: the shipped exe is the SIGNED re-stamping of these
  bytes, and the fetch-verified digest stays in the `.contract.yaml`
  as consumption provenance.
- **the link unit** — `link-unit-<ver>-<pid>.tar.gz` from the same
  pinned release, digest-anchored via the release API (the release's
  SHA256SUMS does not cover it). **POSIX legs only**: this factory
  consumes only `libtfs_preload.{so,dylib}` from it — the shim rides
  the env image at `lib/tebako/` so the jail's host-IO binding
  survives the exec into the interpreter (the openjdk rationale). The
  tarball carries no windows shim, and its remaining contents are
  link-time inputs a repack factory never touches, so the windows leg
  stages nothing (`LinkUnit#stage` refuses it by name) and the windows
  layout card omits the `preload_shim` grant.
- **the tfs CLI** — `tfs-<ver>-<pid>` from the same pinned release,
  sidecar-verified; packs the env image (`tfs mkimage`, the default
  limnifs writer) and the boot smoke's payload fixture.
- **the release tooling** — the tebako-release gem, git-pinned by the
  Gemfile to contract.yml's `release_tooling` tag (the publish/sign/
  audit machinery's single owner — ecosystem invariant 10). The
  factory's identity + policy ride `scripts/release_adapter.rb` (the
  gem's adapter seam); the repo carries no copy of the machinery.

An empty pin, a missing asset, or a checksum mismatch are hard named
errors — this factory has no source-build path for the driver stack
(a supply-chain event is reported, never worked around).

All downloads land under `.build/downloads/` and are re-verified
against the pins on every use, so a poisoned or stale cache entry
cannot survive a pin bump.

## The repack law (the factory never edits julia's bytes)

This repo is a **pure repackager** of pristine upstream binaries. The
runtime pair is composed, never compiled:

- the EXE is the pin-verified `tebako-runtime-launcher`, copied
  byte-identical — on linux and windows the provenance gate's byte
  anchor re-proves the shipped bytes against the release-published
  digest recorded in the pair's `.contract.yaml`
  (`link_unit.launcher_sha256`). macOS is the ONE sanctioned
  re-stamping: the in-leg spec 31 sign+notarize arm rewrites the bytes
  (a signature is an identity stamp, never a patch — spec 31's own
  class), the gate's Mach-O arm anchors the SIGNED bytes + the
  signature chain instead, and the card keeps the fetch-verified
  digest as consumption provenance;
- the env image is the upstream tree with the documented prune set
  removed (`include/`, `share/doc/`, `share/man/`,
  `share/applications/`, `share/metainfo/` — README's prune table),
  in-tree symlink chains dereferenced to plain files (the exec-cache
  mirror serves real bytes under SONAME names), plus the preload shim
  (POSIX only) and the layout card, packed by `tfs mkimage`.

If a genuine julia source need ever appears (a patch the runtime cannot
live without), the answer is a tamatebako **source factory** for julia
— the tamatebako/ruby pattern — never a factory-side hot-patch of
upstream's tree.

## The cache architecture

One cache, keyed on what it contains:

| Cache | Key | Contents |
|-------|-----|----------|
| downloads + staged link unit | `tebako-julia-dl-<os>-<arch>-<hash(contract.yml, versions.yml)>-v<CACHE_VER>` | `.build/downloads` (the sha256-verified archives + launcher + tfs CLI) and `.build/link-unit` (the staged unit) |

`save-always: true` — a red boot smoke must never tax the next leg a
cold re-download. The key carries the pins' hashes, so a pin bump mints
a fresh entry and the stale one ages out. `CACHE_VER` stays the manual
escape hatch — bump ONLY for a build-recipe shape change under
UNCHANGED pins, and say why in the workflow comment.

## The determinism notes

Born pinned: the toolchain container digests (recorded == live proven
in preflight) and every input pin above. `SOURCE_DATE_EPOCH` follows
the ruby#381 idiom: the compute job derives ONE epoch from the HEAD
commit (`git log -1 --format=%ct` under a full-history checkout) and
every leg stamps it into the image manifest's `identity.created`
(`ImageManifest` honors it; unset falls to epoch 0), so a same-commit
re-run stamps identically. The packed image's own metadata is
deterministic the same way (tfs-cli's mkimage honors the variable).

The source-build arm's optimization-flags honesty pair
(tebako-runtime-python#79's lesson) does NOT apply here: the bytes are
upstream's official builds, the `.contract.yaml` records the archive +
its verified sha256 under `built_from` (no `cflags` — there is nothing
to record), and the provenance gate's byte anchor covers the exe side.
What remains is the run-time half: the boot smoke's compute-floor
scenario (fib(35), `@elapsed` best-of-three after a JIT warm-up, under
a generous fail-closed ceiling) trips if the pair ever computes
anomalously slowly — the regression tripwire, never a benchmark.

## Dispatch filters and the local build

The dispatch grammar mirrors the sibling factories': `JULIA_FILTER`
(`full` | `tidy` | `catalog` | comma-separated versions),
`PLATFORM_FILTER` (`all` | `linux-gnu` | `macos` | `windows` — each
trigger fixes its own; the coordinator passes its slice), `ARCH_FILTER`
(`all` | `x86_64` | `arm64`). `scripts/compute_matrix.rb` is the single
planner CI and the lint gate both exercise.

Local build of a runner-native leg on its own host (macOS arm64 shown —
the same shape builds any leg on its matching host, and is also how the
macOS leg's unsigned path behaves when `APPLE_SIGNING_ENABLED` is
unset):

```sh
tools/build_runtime --julia 1.13.4
stem=runtime-packages/tebako-runtime-$(cat VERSION)-julia-1.13.4-macos-arm64
ci/check_pair_provenance.sh --exe "$stem" --card "$stem.contract.yaml" \
  --tfs "$(echo .build/downloads/tfs/*/tfs-*)" --image "$stem.tfs"
export TEBAKO_RUNTIME_ROOT=runtime-packages
TEBAKO_TFS=$(echo .build/downloads/tfs/*/tfs-*); export TEBAKO_TFS
tools/boot_smoke
```

Local build of the containerized linux leg, matching CI byte-for-byte:

```sh
docker run --rm --platform linux/amd64 \
  -v "$PWD:/mnt/w" -w /mnt/w \
  ghcr.io/tamatebako/tpkg-builder-x86_64-linux-gnu:v1@sha256:6ab7d71bcae6b93bcba4e5201835d7135ee99b29f72755d7f4bb8f48b398ae90 \
  bash -c 'set -euo pipefail
    tools/build_runtime --julia 1.13.4 --arch x86_64
    stem=runtime-packages/tebako-runtime-$(cat VERSION)-julia-1.13.4-linux-gnu-x86_64
    ci/check_pair_provenance.sh --exe "$stem" --card "$stem.contract.yaml" \
      --tfs "$(echo .build/downloads/tfs/*/tfs-*)" --image "$stem.tfs"
    export TEBAKO_RUNTIME_ROOT=runtime-packages
    TEBAKO_TFS=$(echo .build/downloads/tfs/*/tfs-*); export TEBAKO_TFS
    tools/boot_smoke'
```

`--platform linux/amd64` is required on arm64 hosts (the container is
x86_64; under emulation the ~1.2 GB exec-cache materialization and the
compute floor run several times slower than native — the smoke's
ceilings are sized for CI-native execution). The container runs as
root: `.build/` and `runtime-packages/` land root-owned on the bind
mount — `chown -R "$(id -u):$(id -g)" .build runtime-packages` on the
host before editing or `git clean`-ing (CI's build step hands them back
inside the container).

## Failure paths (named exits, never silent)

`tools/build_runtime`: 64 usage · 109 version grammar · 112
platform/link input · 121/122 source fetch (sha mismatch / download) ·
123/124 link-unit miss/verify · 125 tfs CLI fetch/verify · 126 launcher
fetch/verify · 131 image assemble/pack. `tools/boot_smoke`: 141
(scenario failure) / 143 (harness error). The provenance gate exits 1
with `::error::provenance:` lines naming the failed check. The boot
smoke's driver-side assertions pin the named exit codes the contract
promises: 65 (bare boot with no env image; malformed TEBAKO_MOUNT_ROOT),
69 (unavailable image), 78 (ungranted mount-root override).

## Where each value lives (SSOT)

- Version catalog + pins (including `container_digests`,
  `link_unit_release`, `release_tooling`): `contract.yml` (+
  `schema/contract.schema.yml`).
- Source url/sha256 pins (per version per triplet): `versions.yml`
  (cross-locked to the catalog by `scripts/check_contract.rb`).
- Env vocabulary (os/arch/host/container): `.github/matrix.json`.
- The prune set, the layout card (interpreter / visibility: exec-cache
  / preload_shim (POSIX only)), the mount root, the manifest emission:
  `build/lib/tebako_julia_builder/` (`image_builder.rb`,
  `image_manifest.rb`, `platform.rb`).
- The boot-contract scenarios: `tools/boot_smoke`.
- The macOS signing profile + mechanics: `ci/runtime.entitlements` +
  `ci/macos-sign-notarize-runtime.sh` (spec 31's fixed pair — never
  re-derived per factory).
- The release identity + policy (the gem's adapter seam):
  `scripts/release_adapter.rb`; the registry render:
  `tools/registry_update.rb`; the release machinery itself:
  tamatebako/tebako-release-tooling at contract.yml's
  `release_tooling` pin (the single owner).
- The factory-opening recipe (what of this is universal vs
  julia-specific): `docs/factory-template.md`.
- This architecture: `docs/build-chain.md`.
