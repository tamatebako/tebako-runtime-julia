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
`build/lib/tebako_julia_builder/` and wired into one platform workflow
(`build-linux-gnu.yml`, a thin trigger over `_build-platform.yml`:
parity → compute → preflight → build → verify), covering **linux-gnu
x86_64** in the digest-pinned tpkg-builder container. The boot smoke
carries the compute-floor scenario (fib(35), `@elapsed` best-of-three,
fail-closed — tebako-runtime-python#79's lesson class). **No release
has been cut**: every increment stays draft-PR-only until the whole
chain is green end-to-end (the owner's rule). What is missing, each its
own increment: the publish pipeline + the first real release, the
windows and macos legs, the linux-musl + arm64 triplets, the julialang
release monitor, the boot-contract parity `spec/` suite, and the
hello-runtimes acceptance arm.

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

The provenance gate proves the consumption did not drift: the shipped
exe's sha256 must equal the release-published launcher digest recorded
in the pair's `.contract.yaml` (`link_unit.launcher_sha256`), and the
exe's runtime library closure must be system-only (the audience rule —
a bare target system satisfies it).

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

The preload shim (`libtfs_preload.so` from the pinned link unit) still
rides the image at `lib/tebako/` — openjdk's rationale: the jail's
host-IO binding is installed by the driver before the exec, and the
shim keeps the binding coherent across the interpreter's own spawned
children.

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
  image: the pruned julia tree + the preload shim at `lib/tebako/` +
  the layout card (`lib/tebako/layout.yaml`: era 2, interpreter
  `/bin/julia`, `visibility: exec-cache`, `preload_shim` path, NO
  `mount_root_override` grant) + the L1 payload manifest
  (`__tpkg__/manifest.yaml`). Packed by `tfs mkimage` (the limnifs
  writer — the current default format; a build-time factory tool,
  never a runtime dependency of the shipped package).
- `<package>.contract.yaml` — the era-2 provenance card
  (`contract_era` / `mount_root` / `image_layout` / `built_from` — the
  archive name + its verified sha256, with NO `cflags`: the bytes are
  upstream's — plus the additive `link_unit` block naming the consumed
  product release, the launcher asset, and its release-published
  digest).
- `<package>.sha256` / `<image>.sha256` — the checksum sidecars next
  to both artifacts, in the tebako store's trust-anchor shape
  (`"<sha256>  <filename>\n"`).

The `<package>.manifest.json` shard — the release manifest entry with
the sidecars folded in — arrives with the publish increment, derived at
publish time (spec 13 §2a's write-once per-leg metadata unit); the
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
        provenance gate (ci/check_pair_provenance.sh: the byte
        anchor, the system-only NEEDED closure, the image read-back)
        boot smoke (tools/boot_smoke: bare/boot/boot-tree/payload/
        compute-floor + bad-mount 69 + TEBAKO_MOUNT_ROOT 65/78 parity)
```

The julia archives are julialang.org's own (no tamatebako julia source
factory exists); the launcher, link unit, and tfs CLI are **published
product release artifacts**. Both are consumed by pin (`versions.yml`
sha256 / `contract.yml link_unit_release`) — never source checkouts of
sibling repos (prebuilt artifacts flow downward).

## Matrix grammar

The env vocabulary lives in `.github/matrix.json` (one row at the
skeleton's scope: linux-gnu x86_64 in the digest-pinned tpkg-builder
container); the version catalog lives in `contract.yml` (the SSOT) —
versions, tags, and SHAs never appear in workflow YAML. The dispatch
filters are `julia_filter=full|tidy|catalog|<list>`,
`platform=linux-gnu` (the trigger fixes it), `arch_filter=all|x86_64|arm64`
— the sibling factories' grammar, so the next platform's increment
adds a matrix row (+ its `versions.yml` sources entry), never a
re-derivation.

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
  at pin time: the release ships all three for linux-gnu-x86_64; the
  pin also floors the manifest model the mkimage re-serialization
  carries — `identity.era` entered the model at v2.8.69).
- `julia:` — the version catalog (`catalog` / `full` / `tidy` sets).
  The per-version **source pins** (url + sha256, per triplet) live in
  `versions.yml`; `scripts/check_contract.rb` cross-locks the two (a
  version in one but not the other is a config bug).

## Building locally

The containerized leg, byte-for-byte what CI runs (needs docker;
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
- `ci/check_pair_provenance.sh` — the pair-provenance gate: the exe is
  byte-identical with the pinned release's launcher (the card's
  recorded digest), the exe's NEEDED closure is system-only, and the
  env image reads back under the tfs CLI that wrote it (manifest
  validates, layout card + `/bin/julia` present).
- `.github/workflows/_build-platform.yml` — the one per-platform
  workflow (parity → compute → preflight → build → verify), called by
  the thin trigger (`build-linux-gnu.yml`).
- `.github/workflows/lint.yml` — the static gate: schema validation,
  catalog/matrix resolution, the `ruby -c` sweep, YAML/JSON parse
  checks.
- `docs/factory-template.md` — the generalized factory template
  extracted from this skeleton's opening (what is universal vs
  runtime-specific — the next factory opens from it).
- `docs/build-chain.md` — the normative CI architecture (update it in
  the same PR as any workflow/tooling change).

## Follow-ups

1. The publish pipeline (`publish.yml` + the release adapter + the
   registry render — the template's §2.9) and the first release
   (cutting `v0.1.0` is the owner's call, never the agent's).
2. The windows leg (upstream ships official windows binaries; the leg
   adds the spawn-semantics scenarios to `tools/boot_smoke`).
3. The macos legs (runner-native, the spec 31 sign+notarize arm).
4. linux-musl + linux-gnu arm64, then the remaining triplets
   upstream publishes (each: a matrix row + a `versions.yml` sources
   entry in the same PR).
5. The julialang release monitor (upstream publishes `versions.json` —
   a poll-diff-pin workflow like the sibling factories').
6. The boot-contract parity suite (`spec/`) against the ruby driver's
   contract suite where the cases overlap.
7. The hello-runtimes acceptance arm.
