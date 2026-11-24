# tebako-runtime-julia

Builds the prebuilt tebako julia runtime packages
(`tebako-runtime-<tebako-version>-julia-<julia-version>-<triplet>[.exe]`)
that the tebako bootstrap/shim resolves at press/run time. Modeled on
[tebako-runtime-php](https://github.com/tamatebako/tebako-runtime-php)
(the cleanest current skeleton), with the driver-link shape of
[tebako-runtime-openjdk](https://github.com/tamatebako/tebako-runtime-openjdk)
— julia, like the JDK, arrives as upstream-compiled binaries, so this
factory is a **repack**: nothing here compiles.

The package-name spelling carries the `julia` language segment from the
first build — the [tebako#716](https://github.com/tamatebako/tebako/issues/716)
spelling, with **no era gate**: this factory was born after the lang-ful
spelling landed, so no immutable lang-less line exists to stay
compatible with.

**Status: pre-release.** The chain — fetch/verify the official
julialang.org archive → stage/prune the tree → fetch/verify the pinned
product assets (launcher, link unit, tfs CLI) → env-image pack →
packaging → provenance gate → boot smoke — is implemented in
`build/lib/tebako_julia_builder/` and wired into three platform
workflows (`build-linux-gnu.yml`, `build-macos.yml`,
`build-windows.yml` — thin triggers over `_build-platform.yml`: parity
→ compute → preflight → build → publish → verify), covering
**linux-gnu x86_64** (digest-pinned tpkg-builder container), **macos
arm64 + x86_64** (runner-native, with the spec 31 sign+notarize arm
gated on `APPLE_SIGNING_ENABLED`), and **windows x64** (Git-bash + the
runner's hosted ruby — the repack arm needs no toolchain there). The
boot smoke carries the compute-floor scenario (fib(35), `@elapsed`
best-of-three, fail-closed — tebako-runtime-python#79's lesson class).
The publish pipeline is present — `publish.yml` (the php factory's
coordinator port: per-leg publish+sign via the tebako-release gem,
SLSA attest, `.manifest.json` shards, registry render) — but **never
fired**: no release has been cut, and every increment stays
draft-PR-only until the whole chain is green end-to-end (the owner's
rule). What is missing, each its own increment: the first real release
(the owner fires the coordinator), the linux-gnu arm64 triplet
(upstream ships the aarch64 linux archive — a matrix row + a
`versions.yml` sources entry in one PR), the julialang release monitor,
the boot-contract parity `spec/` suite, and the hello-runtimes
acceptance arm. linux-musl and windows arm64 have **no upstream
binaries** (julialang.org publishes no musl julia ≥ 1.11 and no
windows aarch64 — checked against `versions.json` 2026-11-23; a musl
leg means a tamatebako source factory, not a repack row). The windows
leg carries the spec 34 Azure Trusted Signing lane
(`ci/windows-sign-gate.sh`, gated on the `WINDOWS_SIGNING_ENABLED`
repo variable; gate-off ships unsigned byte-identically).

## Why a tebako julia runtime (the honest framing)

The pain: shipping a julia tool to someone who does not have julia.
Today the answers are: ask them to install julia (juliaup — fine for
developers, not for recipients of a tool), ship a PackageCompiler.jl
sysimage (a compile farm per app per platform, minutes-to-tens-of-minutes
per build, and the app is frozen into the sysimage), or ship a container
(needs a container runtime on the receiving end). The tebako answer is
the ecosystem's: **one file** — the app payload stitched with or
resolved against this runtime — that runs on a bare system, mounts its
filesystem instead of extracting it, caches the runtime machine-wide,
and carries the jail/trust policy declaratively. The runtime itself is
built once here, from upstream's official bytes, and flows downward as
a published artifact; the app packager never compiles anything.

The audience is real but not mass-market: scientific and
technical-computing teams distributing julia-based tools to
non-julia users, and CI estates that want a hermetic, pinned julia
without per-job installs. The nearest overlapping solutions are the
official binaries + juliaup (an install step, no composition),
PackageCompiler.jl (compile-time cost per app, the app baked into the
image), containers (a runtime prerequisite), and the emerging
`juliac --trim` static path (smaller binaries, but a per-app compile
and a trimmed-feature subset). Tebako's trade: the env image is large
(julia ships its sysimage and full stdlib — the packed `.tfs` is
hundreds of MB) and the first boot of an image materializes the
interpreter home into the exec cache (see below); in exchange there is
no per-app compile step anywhere in the chain.

## The driver rides as the wrapper exe, not a relink

julia runtimes ship the spec-17 driver as the **spec-29 wrapper**: the
pair's EXE artifact is the product's `tebako-runtime-launcher`, fetched
from the pinned tamatebako/tebako release and shipped **byte-identical**
(the openjdk pattern), not a php/python-style relink of the driver
into the interpreter.

Rationale:

- The wrapper exists for exactly this class: runtimes that arrive as
  third-party compiled bytes tebako does not build (spec 29 §0: "the
  standing answer for every runtime tebako does not compile from
  source"). julialang.org publishes official per-platform binaries;
  this factory repacks them. There is no link step to own, so the
  driver cannot go inside the interpreter — and a hand-rolled launcher
  would re-implement the product's own class-E materialization
  (a kernel cannot exec an in-VFS path) that
  `crates/tebako-driver/src/wrapper.rs` already ships, tested.
- The boot/exit-code contract is then *literally* the product driver's:
  `TEBAKO_RUNTIME_IMAGE` handoff (unset → exit 65 naming it), the
  `TEBAKO_MOUNT_ROOT` grammar (malformed → 65; ungranted → 78), an
  unavailable payload image → 69 — all asserted by `tools/boot_smoke`.
- Contract 2 from day one: this factory has no contract-1 era (no
  merged env+app images). The env image is always the standalone `.tfs`
  the wrapper mounts whole at the runtime root.

The provenance gate proves the consumption did not drift. On linux and
windows the shipped exe's sha256 must equal the release-published
launcher digest recorded in the pair's `.contract.yaml`
(`link_unit.launcher_sha256`) — the byte anchor — and on linux the
exe's runtime library closure must be system-only (the audience rule —
a bare target system satisfies it). macOS is the deliberate exception:
the exe is **signed and notarized in-leg** (spec 31 —
`ci/macos-sign-notarize-runtime.sh`, Developer ID Application +
hardened runtime + the `ci/runtime.entitlements` pair, gated on the
`APPLE_SIGNING_ENABLED` repo variable), so its shipped bytes are not
the release's bytes; the gate's Mach-O arm anchors the exe `.sha256`
sidecar to the SIGNED bytes (the sign step rewrites it — sign-then-hash),
verifies the signature strict, and, when armed, asserts the team
identity, the embedded entitlement pair, and the notarization ticket.
The card keeps recording the fetch-verified release digest as
consumption provenance. The windows PE arm of the gate is the same
shape under spec 34: with `WINDOWS_SIGNING_ENABLED` unset the exe
ships the release's bytes byte-identical and the byte anchor holds
(spec 00 invariant 7); armed, the exe is Azure Trusted Signed in-leg
(the `windows-signing` environment, the RFC 3161 timestamp mandatory)
and the gate anchors the exe `.sha256` sidecar to the SIGNED bytes
(the verify step re-anchors it — sign-then-hash) plus a Valid
timestamped Authenticode signature.

## The interpreter home: exec-cache visibility

The env image's layout card declares `visibility: exec-cache` with
`identity.annotations.home: "/"` — the JVM's exact shape, for the same
reason: julia **self-locates its home relative to the exe path**
(`Sys.BINDIR` → `..`; the sysimage, the stdlib, `etc/julia/startup.jl`
all resolve from it), so the whole interpreter tree must exist as real
host files at run time. The driver's exec-cache tier materializes the
mount once per image content (the `.tfs.sha256` sidecar is the cache
segregation key) and re-execs the materialized `bin/julia`; every
subsequent boot of the same image reuses the cache. The alternative
(preload interposition) would serve only the load closure and leave
julia's home-relative reads — runtime-discovered files, not opened
paths — seeing an empty prefix.

`mount_root_override` is **not granted**: julia follows the exe path,
never `TEBAKO_MOUNT_ROOT`, so the grant would be decorative (the spec
00 §9 rule). The override-ungranted named error (exit 78) is asserted
by the boot smoke.

The preload shim (`libtfs_preload.so` / `libtfs_preload.dylib` from the
pinned link unit) still rides the image at `lib/tebako/` on POSIX —
openjdk's rationale: the jail's host-IO binding is installed by the
driver before the exec, and the shim keeps the binding coherent across
the interpreter's own spawned children. **windows has no preload tier**
(the link-unit tarball carries no windows shim), so the windows image
stages no shim and its layout card omits the `preload_shim` grant — a
declared-but-absent grant would fail the boot at exit 78.

## The prune set

The env image keeps the runtime-relevant tree of the official archive
and drops the build-time/documentation surface (verified against the
real 1.13.4 tree):

| Kept | Pruned |
|------|--------|
| `bin/julia` | `include/` (C headers — extension-build tooling) |
| `lib/` + `lib/julia/` (sysimage, deps) | `share/doc/`, `share/man/` |
| `libexec/` | `share/applications/`, `share/metainfo/` (desktop files) |
| `etc/julia/startup.jl` | |
| `share/julia/` (the stdlib — `Sys.STDLIB`) | |
| `LICENSE.md` | |

In-tree symlink chains (e.g. `libjulia.so` → `libjulia.so.1.13.4`) are
dereferenced to plain files at staging time: under exec-cache the
SONAME names must carry real bytes, and a missing interpreter binary or
a dangling link is a named build error (exit 131), never a quietly
broken image.

## The artifacts (per version × triplet)

- `tebako-runtime-<tebako>-julia-<julia>-<triplet>[.exe]` — the
  runtime launcher (the spec-29 wrapper), byte-identical with the
  pinned release's published asset.
- `tebako-runtime-<tebako>-julia-<julia>-<triplet>.tfs` — the env
  image: the pruned julia tree + the preload shim at `lib/tebako/`
  (POSIX only) + the layout card (`lib/tebako/layout.yaml`: era 2,
  interpreter `/bin/julia` (`/bin/julia.exe` on windows),
  `visibility: exec-cache`, `preload_shim` path (POSIX only), NO
  `mount_root_override` grant) + the L1 payload manifest
  (`__tpkg__/manifest.yaml`). Packed by `tfs mkimage` (the limnifs
  writer — the current default format; a build-time factory tool,
  never a runtime dependency of the shipped package).
- `<package>.contract.yaml` — the era-2 provenance card
  (`contract_era` / `mount_root` / `image_layout` / `built_from` — the
  archive name + its verified sha256, with NO `cflags`: the bytes are
  upstream's — plus the additive `link_unit` block naming the consumed
  product release, the launcher asset, and its release-published
  digest; the link-unit tarball itself is named only where it was
  staged — POSIX, for the shim).
- `<package>.sha256` / `<image>.sha256` — the checksum sidecars next
  to both artifacts, in the tebako store's trust-anchor shape
  (`"<sha256>  <filename>\n"`). On macOS the sign step rewrites the
  exe's sidecar to the SIGNED bytes (sign-then-hash).

The `<package>.manifest.json` shard — the release manifest entry with
the sidecars folded in — is derived at publish time by the per-leg
publish job (spec 13 §2a's write-once per-leg metadata unit); the
factory emits exactly the sidecars it folds.

## The flow

```
julialang.org official archive      tamatebako/tebako release (pinned)
julia-<v>-<platform>.tar.gz         link-unit-<ver>-<pid>.tar.gz
(sha256-pinned per triplet          tebako-runtime-launcher-<ver>-<pid>
in versions.yml)                    tfs-<ver>-<pid>
        |                                   |
        v                                   v
   fetch + verify            fetch + verify (sidecar / release-API
        |                    digest anchors; LinkUnit → preload shim)
        v                                   |
   stage + prune (strip the nesting dir,    |
   dereference symlinks, assert bin/julia)  |
        |                                   |
        +───────────────┬───────────────────+
                        v
        assemble env layout (pruned tree + preload shim
        + layout card + L1 manifest)
        pack <package>.tfs  (tfs mkimage — limnifs writer)
        ship the launcher byte-identical as the exe
                        |
                        v
        macOS only: sign + notarize the exe in-leg (spec 31,
        gated on APPLE_SIGNING_ENABLED; the exe .sha256 sidecar
        is rewritten to the SIGNED bytes — sign-then-hash)
                        |
                        v
        provenance gate (ci/check_pair_provenance.sh: the byte
        anchor (POSIX + windows) / the signed-bytes + signature-chain
        arm (macOS), the system-only NEEDED closure (ELF), the image
        read-back)
        boot smoke (tools/boot_smoke: bare/boot/boot-tree/payload/
        compute-floor + bad-mount 69 + TEBAKO_MOUNT_ROOT 65/78 parity)
                        |
                        v
        publish.yml only: per-leg publish + sign (the tebako-release
        gem), SLSA attest, the .manifest.json shard; the coordinator's
        release job audits the matrix and renders the registry
```

The julia archives are julialang.org's own (no tamatebako julia source
factory exists); the launcher, link unit, and tfs CLI are **published
product release artifacts**. Both are consumed by pin (`versions.yml`
sha256 / `contract.yml link_unit_release`) — never source checkouts of
sibling repos (prebuilt artifacts flow downward).

## Matrix grammar

The env vocabulary lives in `.github/matrix.json` (four rows: linux-gnu
x86_64 in the digest-pinned tpkg-builder container, macos arm64 +
x86_64 runner-native, windows x64 runner-native); the version catalog
lives in `contract.yml` (the SSOT) — versions, tags, and SHAs never
appear in workflow YAML. The dispatch filters are
`julia_filter=full|tidy|catalog|<list>`,
`platform=all|linux-gnu|macos|windows` (each trigger fixes its own),
`arch_filter=all|x86_64|arm64` — the sibling factories' grammar, so the
next platform's increment adds a matrix row (+ its `versions.yml`
sources entry), never a re-derivation. linux-musl has no rows because
upstream ships no musl binaries ≥ 1.11; windows arm64 likewise (no
upstream archive) — both arrive, if ever, as their own increments.

## contract.yml — the pins

- `contract_version: 2` — the bootstrap ↔ runtime contract (spec 17
  grammar). Floored at 2 by the schema: no contract-1 era exists here.
  Bump rules mirror the other factories' (+1 in lockstep with the
  compiled-in `TEBAKO_CONTRACT_VERSION`, same commit — enforced by the
  driver-source parity arm of `scripts/check_contract.rb`).
- `container_version: "v1"` + `container_digests:` — the tpkg-builder
  tag line and its immutable ghcr manifest digests (born pinned — the
  ruby#381 idiom); the preflight job proves recorded == live before any
  leg spends compute.
- `link_unit_release: "v2.8.83"` — the tamatebako/tebako release whose
  published launcher + link unit + tfs CLI the legs consume (verified
  at pin time: the release ships all three for linux-gnu-x86_64,
  macos-arm64, macos-x86_64, and windows-ucrt64; the pin also floors
  the manifest model the mkimage re-serialization carries —
  `identity.era` entered the model at v2.8.69).
- `release_tooling: "v0.5.3"` — the tamatebako/tebako-release-tooling
  tag the Gemfile pins (the publish/sign/audit machinery's single
  owner; the factory's identity + policy ride
  `scripts/release_adapter.rb`).
- `julia:` — the version catalog (`catalog` / `full` / `tidy` sets).
  The per-version **source pins** (url + sha256, per triplet) live in
  `versions.yml`; `scripts/check_contract.rb` cross-locks the two (a
  version in one but not the other is a config bug).

## Building locally

A runner-native leg on its own host (macOS arm64 shown; the same
command shape builds any leg on its matching host — the build fetches
and verifies every input itself):

```sh
tools/build_runtime --julia 1.13.4
stem=runtime-packages/tebako-runtime-$(cat VERSION)-julia-1.13.4-macos-arm64
ci/check_pair_provenance.sh --exe "$stem" --card "$stem.contract.yaml" \
  --tfs "$(echo .build/downloads/tfs/*/tfs-*)" --image "$stem.tfs"
export TEBAKO_RUNTIME_ROOT=runtime-packages
TEBAKO_TFS=$(echo .build/downloads/tfs/*/tfs-*); export TEBAKO_TFS
tools/boot_smoke
```

The containerized linux leg, byte-for-byte what CI runs (needs docker;
`--platform linux/amd64` on arm64 hosts — under emulation the
exec-cache materialization and the compute floor run several times
slower than native):

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

The container runs as root: `.build/` and `runtime-packages/` land
root-owned on the bind mount — `chown -R "$(id -u):$(id -g)" .build
runtime-packages` before editing or `git clean`-ing.

## Layout

- `VERSION` — the package version: package names and (eventually) the
  release tag follow it (`v$(cat VERSION)`). `0.1.0` is the opening
  line.
- `contract.yml` + `schema/` — the pins and the version catalog, and
  their JSON Schema; `scripts/check_contract.rb` validates (CI),
  including the driver-source parity arm (contract.yml ↔ the tebako
  driver's compiled-in contract version at the pinned link-unit
  release).
- `versions.yml` — the julialang.org source pins (url + sha256 per
  version per triplet; cross-checked against upstream's
  `versions.json` at pin time).
- `scripts/versions` — emits the catalog / resolves the dispatch
  filter grammar / reads the pins (contract.yml is the SSOT).
- `scripts/compute_matrix.rb` — the matrix engine: catalog × env
  vocabulary under the dispatch filters → the leg matrix (with
  `host_id` and `link_unit_pid`), plus the `--format env|julias` forms
  the publish increment's expectations read.
- `tools/build_runtime` — the build entry point (fetch → verify →
  stage → prune → pack → package → sidecars).
- `tools/boot_smoke` — the post-build acceptance gate (8 scenarios:
  bare/boot/boot-tree/payload/compute-floor + bad-mount +
  `TEBAKO_MOUNT_ROOT` malformed/override-ungranted). Needs `TEBAKO_TFS`
  (the tfs CLI, for the fixture image) and the runtime-packages tree.
- `build/lib/tebako_julia_builder/` — the build model (the
  tebako-runtime-php `build/lib` port, repack arm): Contract, Platform,
  JuliaVersion, SourceFetcher, LinkUnit, Launcher, TfsTool, TreeStager,
  ImageBuilder, ImageManifest, ImagePackager, Builder.
- `ci/check_pair_provenance.sh` — the pair-provenance gate, per exe
  shape (magic-sniffed): ELF + PE carry the byte anchor (the shipped
  exe IS the pinned release's launcher — the card's recorded digest),
  ELF adds the system-only NEEDED closure audit; Mach-O anchors the
  sidecar to the SIGNED bytes and verifies the signature chain
  (sign-then-hash — the in-leg sign step rewrote them); every platform
  reads the env image back under the tfs CLI that wrote it (manifest
  validates, layout card + `/bin/julia[.exe]` present).
- `ci/macos-sign-notarize-runtime.sh` + `ci/runtime.entitlements` —
  the spec 31 macOS sign+notarize arm (Developer ID Application,
  hardened runtime, the entitlement pair; notarize, poll the ticket,
  quarantine-mark, rewrite the exe sidecar), gated on
  `APPLE_SIGNING_ENABLED`.
- `scripts/release_adapter.rb` — this factory's tebako-release
  declaration (the gem's adapter seam: the version grammar source, the
  `julia` language segment, the repo identity).
- `tools/registry_update.rb` — renders `tpkg-registry.yaml` from the
  release's `.manifest.json` shards (the spec 04 §2 mirror; landed by
  bot PR from the coordinator's release job).
- `.github/workflows/_build-platform.yml` — the one per-platform
  workflow (parity → compute → preflight → build → publish → verify),
  called by the thin triggers (`build-linux-gnu.yml`,
  `build-macos.yml`, `build-windows.yml`) and the coordinator.
- `.github/workflows/publish.yml` — the release coordinator
  (dispatch-only; `publish` defaults false): the per-platform fan-out
  plus the ONE release job (the whole-matrix audit, the registry
  render + bot PR, the aggregate nudge).
- `.github/workflows/lint.yml` — the static gate: schema validation,
  catalog/matrix resolution, the `ruby -c` sweep, YAML/JSON parse
  checks.
- `docs/factory-template.md` — the generalized factory template
  extracted from this skeleton's opening (what is universal vs
  runtime-specific — the next factory opens from it).
- `docs/build-chain.md` — the normative CI architecture (update it in
  the same PR as any workflow/tooling change).

## Follow-ups

1. The first release (cutting `v0.1.0` is the owner's call, never the
   agent's): the publish pipeline is wired end-to-end but has never
   been fired — the owner dispatches `publish.yml` (audit first, then
   the publish run).
2. linux-gnu arm64 (upstream ships the aarch64 linux archive — a
   matrix row + a `versions.yml` sources entry in one PR, inside the
   digest-pinned arm64 tpkg-builder container). windows arm64 has **no
   upstream archive** (checked against `versions.json` 2026-11-23) —
   it arrives, if ever, with upstream.
3. linux-musl — **blocked upstream**: julialang.org publishes no musl
   binaries ≥ 1.11 (checked against `versions.json` 2026-11-23; musl
   entries exist only ≤ 1.10.x). A musl julia runtime means a
   tamatebako source factory compiling musl julia, not a repack row.
4. The julialang release monitor (upstream publishes `versions.json` —
   a poll-diff-pin workflow like the sibling factories').
5. The boot-contract parity suite (`spec/`) against the ruby driver's
   contract suite where the cases overlap.
6. The hello-runtimes acceptance arm.
