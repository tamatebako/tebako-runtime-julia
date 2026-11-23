# The runtime-factory template

**Audience:** a developer (human or agent) opening the NEXT tebako
runtime factory — `tebako-runtime-<lang>` — who has the ecosystem
AGENTS.md and this document, and nothing else memorized. The census's
stated end-state (tebako#1107) is that runtime factories are openable
by their own communities from a proven template, not queued behind the
core team. This is that template: extracted from
[tebako-runtime-php](https://github.com/tamatebako/tebako-runtime-php)
(the cleanest current skeleton) and proven here by the julia skeleton,
which contains nothing this document does not describe (the PR body
carries the completeness self-review).

Read the workspace `AGENTS.md` first — its five laws and twelve
invariants bind every factory. What follows is the factory-shaped
application of those rules, not a second authority. Where this document
and a file disagree, the file is wrong or this document is stale; fix
both in the same PR.

## 0. The shape of a factory

A runtime factory is a **pure builder and verifier of pinned inputs**.
It never compiles the tebako stack, never patches its interpreter's
source in-tree, and never hand-derives a value another repo owns. Per
(version × triplet) it emits a **runtime pair**:

```
tebako-runtime-<tebako-ver>-<lang>-<lang-ver>-<triplet>[.exe]   # the exe artifact
tebako-runtime-<tebako-ver>-<lang>-<lang-ver>-<triplet>.tfs     # the env image
```

plus sidecars (`<image>.sha256`, `<exe>.sha256`, `<exe>.contract.yaml`,
and a compile-probed `<exe>.abi` when the runtime has one). The exe is
the tebako-owned process entry point; the env image is the runtime's
whole file tree, mounted — never extracted — by the driver at boot.

Everything a factory does is one of two kinds:

- **Universal** — the contract/pins layer, the pin-verified consumption
  of the product release, the env-image contract cards, the packaging,
  the staged CI hierarchy, the gates, the boot-smoke structure, the
  determinism rules. Copied as-is; edited only to rename.
- **Runtime-specific (the delta)** — source acquisition, the build
  invocation, the driver-link pattern, the extension/content policy,
  the image declarations, the smoke probes, the version grammar. This
  document names each delta and its decision rule.

The template's own test: opening factory N+1 means copying factory N's
skeleton, making ONLY the edits §3 enumerates, and having CI go green.
Every edit outside §3's enumeration is a template bug — report it.

## 1. The one decision that selects the skeleton arm

**Does the factory compile the interpreter from source, or repack
upstream's prebuilt bytes?**

| | **Source-build arm** (php, python, ruby) | **Repack arm** (julia, openjdk, node, bun) |
|---|---|---|
| Input | upstream source tarball, sha256-pinned | upstream binary archives, sha256-pinned **per triplet** |
| Compile step | ours (configure/make in the pinned container) | none — "no compilation anywhere in this feedstock" (openjdk) |
| Driver link | **linked**: the fs TU substitutes the interpreter's `main` at build time | **wrapper** (spec 29): the exe is the product's `tebako-runtime-launcher`, consumed sha256-verified from the pinned release |
| Why | we own the link step | "the driver cannot be linked into bytes tebako did not compile" (spec 29 §0) |
| Proven by | tebako-runtime-php | tebako-runtime-julia, tebako-runtime-openjdk |

The two arms share EVERYTHING else — that sharing is what makes the
wrapper legal: the spec-17 wire, the boot contract, and the release
grammar are byte-identical between arms (spec 29 §1: "the launcher ABI
and the loader NEVER learn which pattern a runtime uses").

Do not invent a third arm. A runtime whose upstream ships only source
is the source-build arm; a runtime whose upstream ships per-platform
binaries is the repack arm. If upstream ships both, repack is preferred
(the audience rule: nothing compiles that does not have to), and the
repack's build honesty (flags, libc floor) is upstream's published
claim, verified at the smoke — never our compile.

## 2. The universal chassis (ship as-is)

Listed by file, with the edits allowed. "Rename" means the
`php`→`<lang>` / `Php`→`<Lang>` / `tebako_php_builder`→
`tebako_<lang>_builder` mechanical sweep and nothing else.

### 2.1 The pins layer

- **`VERSION`** — one line, `0.1.0` at opening. Package names and the
  release tag follow it. No edit.
- **`contract.yml`** — the factory's SSOT: `contract_version` (2;
  floored at 2 by the schema — no factory has a contract-1 era
  anymore), `link_unit_release` (the tamatebako/tebako tag whose
  published assets the legs consume), and the `<lang>:` catalog
  (`catalog`/`full`/`tidy` sets). **Conditional keys** (present only
  when their leg class exists — spec 00 §9 forbids decorative surface):
  `container_version` + `container_digests` when any leg runs inside a
  tpkg-builder container (§2.6), `macos_deployment_target` when a macOS
  leg exists, `release_tooling` when the publish pipeline lands.
- **`versions.yml`** — the source-pin trust anchor. Source-build arm:
  one `{url, sha256, line}` per version. Repack arm: one
  `{line, sources: {<triplet>: {url, sha256}}}` per version (upstream's
  own sha256, cross-checked against its published sums at pin time).
- **`schema/contract.schema.yml`** — the contract's JSON Schema
  (draft 2020-12). Edit: rename; mirror the conditional keys'
  presence/absence; mirror the version grammar pattern (§3.6).
- **`scripts/check_contract.rb`** — the contract gate: schema
  validation, catalog↔versions.yml cross-lock (BOTH directions), and
  the **driver-source parity arm** — the pinned link-unit release's
  `crates/tebako-driver/src/lib.rs` `TEBAKO_CONTRACT_VERSION` must equal
  `contract_version` (fail-closed; `--fetch-parity` mode exists so CI
  fetches it once, not per platform). Edit: rename only.
- **`scripts/versions`** — emits the catalog, resolves the dispatch
  filter (`full|tidy|catalog|<comma list>`), prints pins. Edit: rename.
- **`scripts/compute_matrix.rb`** — catalog × `.github/matrix.json`
  under the dispatch filters (`<LANG>_FILTER` / `PLATFORM_FILTER` /
  `ARCH_FILTER`) → the GHA matrix JSON, each leg carrying
  `host_id`/`container`/`link_unit_pid` from the Platform tables.
  Edit: rename.
- **`.github/matrix.json`** — the env vocabulary (one row per
  `{host, container, os, arch}`). Edit: keep only the rows this
  factory's legs run; add rows as legs land (never re-derive).

### 2.2 The product-release consumption (both arms, three assets)

Every leg downloads from the **same** `link_unit_release` pin, and each
asset has its own trust anchor — a mismatch is a hard named error,
never a refetch-forever or a silent fallback:

1. **The link unit** (`link-unit-<ver>-<pid>.tar.gz`) — verified against
   the GitHub release API's per-asset `digest` field (the release
   SHA256SUMS does NOT cover it). Source-build arm consumes it whole
   (`libtebako_driver.a`, `libtfs.a`, `closure/`, the c_api header,
   `libtfs_preload`). Repack arm consumes exactly one file from it —
   **`libtfs_preload.{so,dylib}`**, staged into the env image at
   `lib/tebako/` so the jail's host-IO binding survives the exec into
   the interpreter (spec 22 §3 rules E2/E3).
2. **The tfs CLI** (`tfs-<ver>-<pid>`) — verified against its published
   `.sha256` sidecar. Packs the env image (`tfs mkimage` with NO
   `--format` — limnifs is the default; a `--format` pin would drift
   from it) and the smoke's fixture images. A build-time factory tool,
   never a runtime dependency of the shipped pair.
3. **The runtime launcher** (`tebako-runtime-launcher-<ver>-<pid>` —
   repack arm only) — verified against its published `.sha256`
   sidecar. Becomes the pair's exe artifact, byte-identical.

The download core (redirect bound, timeouts, bounded retry with named
attempts, partial-file deletion) lives in
`build/lib/tebako_<lang>_builder/build_helpers.rb` exactly once
(`BuildHelpers.download` / `read_url` / `release_asset_digests`) — every
fetcher rides it. Exit codes: 122 download, 121 source sha mismatch,
123 link-unit miss, 124 link-unit sha/incomplete, 125 tfs CLI, 126
launcher.

### 2.3 The env-image contract cards (both arms)

Two declarations ride every env image; both are flow-authored by the
build model from the same constants the exe side uses:

- **`/lib/tebako/layout.yaml`** (spec 18 C3, grammar owned by
  `docs/spec/schemas/layout.yaml` in the product repo): required keys
  `schema_version: 1`, `era: 2`, `image_layout: 1`, `mount_root`,
  `interpreter_api_version`; additive per the runtime's shape
  (`preload_shim`, `interpreter`, `visibility`, `mount_root_override`).
  A mismatch against the exe's baked root is exit 78 — the pair
  contract, gated by the boot smoke.
- **`/__tpkg__/manifest.yaml`** (spec 03, the L1 payload manifest):
  `identity` (kind `runtime`, era 2, deterministic `created` — §2.7 —
  zeroed blob digest per the fixed-point rule) and `provides`
  (`engine`/`implementation`/`version`/`language_version`/`abi_line`/
  `platform` as the spec 03 triplet, `built_from` provenance,
  `capabilities {exec, read, runtime}`, `entrypoints` per §3.5).
  The driver parses it post-mount; a malformed manifest is exit 65.

The mount root itself (`/__tfs__` POSIX, `A:/t` windows) follows the
ecosystem's one-namespace convention — the wrapper exe compiles it in
(`WRAPPER_RUNTIME_ROOT`), the source-build fs TU takes it as its
`runtime_root` argument; either way the factory's `Platform#mount_root`
is the factory-side owner and the layout card asserts the match.

**The pin floors the manifest model.** `tfs mkimage` re-serializes the
manifest THROUGH the pinned release's tpkg model; additive keys the
model predates are silently dropped from the packed image. The worked
example (the julia skeleton's own find): `identity.era` (the spec-18
field) entered the model at v2.8.69 — pinned at v2.8.66, the shipped
image read back with no `era` (absent = era 1, the pre-era default),
and only the read-back gate's human review caught it. Rule: pin the
NEWEST release that ships §2.2's assets, and after the first green
build read the packed manifest back (`tfs cat <image>
/__tpkg__/manifest.yaml`) and diff the keys against what the factory
emitted — the model's silent-drop is quiet precisely because the
document stays valid.

### 2.4 Packaging and sidecars (both arms)

- `ImagePackager`: `tfs mkimage <tree> -o <pair>.tfs`, no `--format`.
- `Builder#finalize`: the exe copied (never stripped when it is ours to
  strip — the symbol table is provenance evidence), chmod 0755.
- Sidecars written at build: `<image>.sha256` and `<exe>.sha256` in the
  store trust-anchor grammar (`"<sha256>  <filename>\n"` — the boot
  smoke's exec-cache segregation keys on it, so a factory tree boots
  store-faithfully), and `<exe>.contract.yaml`, the era-2 provenance
  card (`contract_era`/`mount_root`/`image_layout`/`built_from`
  [sources with verified sha256; plus `cflags` on the source-build
  arm] + the additive `link_unit` block naming the consumed assets).

### 2.5 The staged CI hierarchy (universal, one reusable workflow)

`_build-platform.yml` (called by one thin trigger per platform —
`build-<platform>.yml` — never dispatched directly):

1. **parity** — fetch the pinned driver's `lib.rs` once (bounded
   retry), hand it to compute as an artifact (the raw.githubusercontent
   fetch flakes under per-platform fan-out).
2. **compute** — the contract gate (schema + cross-locks + the parity
   arm against the artifact), then the matrix expansion; also derives
   the run's one `SOURCE_DATE_EPOCH` from the HEAD commit
   (`fetch-depth: 0`; the ruby#381 idiom).
3. **preflight** — container legs only: `contract.yml`'s recorded ghcr
   digests must equal the registry's CURRENT digest per (container ×
   arch) before compute is spent; the legs then pull `name:tag@digest`.
   Skips cleanly when no leg is containerized.
4. **build** — one leg per (version × arch): `tools/build_runtime` →
   the provenance gate → `tools/boot_smoke` → `.leg-complete` marker →
   artifacts (`runtime-packages-*`, retained 1d; the build log 7d).
   Container legs docker-run the pinned image per step and `chown` the
   bind-mount back; runner-native legs run directly.
5. **verify** — the terminal aggregate with a STABLE check name
   ("all legs green") — branch protection pins it, because the dynamic
   leg names shift with the catalog.

Plus **`lint.yml`** (the static gate): contract validation, catalog
resolution under the full filter grammar, matrix computability
(non-empty), `ruby -c` over every authored ruby file (extensionless
`tools/` executables included), YAML/JSON parse sweep.

Rules that keep the skeleton honest (all factories):

- **Workflow YAML never carries a version, tag, or SHA** — everything
  flows from `contract.yml` / `versions.yml` / `.github/matrix.json`.
- Action pins are full-SHA with a version comment.
- One cache (`save-always: true`), keyed on the pins' hashes
  (`hashFiles('contract.yml', 'versions.yml')`) + `CACHE_VER` (the
  manual escape hatch — bump only for a recipe-shape change under
  unchanged pins, and say why in a comment).
- A red gate blocks the artifact's publishability (the `.leg-complete`
  marker is the publish job's completeness gate when publish lands).
- Docs-only changes skip the build (`paths-ignore: "**/*.md"`).

### 2.6 The container grammar (conditional)

Legs run **inside** the digest-pinned
`ghcr.io/tamatebako/tpkg-builder-<triplet>:<tag>@<digest>` image when
they compile (the toolchain floor is a pin, not the runner's accident)
or when their binaries execute only under a foreign libc (the musl
legs — a musl binary cannot exec on the glibc host). A repack leg on a
native libc MAY run runner-native (openjdk does: "no compilation
anywhere in this feedstock"); the julia skeleton still runs
containerized — the pinned environment is reproducible in a way the
rolling runner image is not, and the smoke then proves the pair against
the builder line's glibc. Whichever a leg does is matrix.json data
(`container` null ⇔ runner-native), never workflow logic.

### 2.7 Determinism (born pinned)

`SOURCE_DATE_EPOCH` is computed once per run (HEAD commit epoch) and
exported to every leg; the image manifest's `identity.created` honors
it (unset ⇒ epoch 0), and tfs-cli's mkimage honors it for the packed
metadata. A same-commit re-run stamps identically. Both input pins and
the container digests are immutable from day one; the preflight proves
recorded == live.

### 2.8 The boot smoke's universal structure

`tools/boot_smoke` runs post-build, per leg, with
`TEBAKO_RUNTIME_ROOT=runtime-packages` and `TEBAKO_TFS` naming the
fetched CLI. Universal harness rules: the child env is REPLACED and
scrubbed of `TEBAKO_*`/`LD_PRELOAD`/dyld vars; every boot has a hard
kill deadline (never `Timeout.timeout` around popen3 — the unwind
blocks on the immortal child); checks print `ok`/`FAIL` per line and
exit 143 on any failure, 141 on usage. The scenario SET is §3.8's
delta, but every factory's smoke covers: the bare boot's honest
behavior, the mounted pair boot, a payload entry executed from a
fixture image, an unavailable image named at exit 69, and the
`TEBAKO_MOUNT_ROOT` grammar enforced (65 malformed / 78 ungranted —
whichever arms the runtime's layout declaration supports).

### 2.9 The publish pipeline (next increment, universal when it lands)

`publish.yml` + `scripts/release_adapter.rb` +
`tools/registry_update.rb` + the `tebako-release` gem pin
(`release_tooling`) + `tpkg-registry.yaml`: spec 13 §2a's de-rendezvous
(the leg that built a pair publishes and signs its write-once names
from its own job), the whole-matrix audit, the registry render by bot
PR. The php factory carries the complete reference implementation;
copy it wholesale when the first release is the owner's go-ahead. Until
then a factory is **pre-release**: draft PRs only, no tags, no
releases.

## 3. The delta surface (the only edits a new factory makes)

Each subsection names the decision rule and the worked answer from BOTH
template instances (php = source-build, julia = repack).

### 3.1 Source acquisition

- **Rule:** the pin grammar follows upstream's publication shape. One
  tarball per version (source-build) → one `{url, sha256}` per version.
  Per-platform archives (repack) → per-version `sources:` keyed by the
  spec 03 triplet, each `{url, sha256}`. The sha256 is upstream's own
  published value, recorded at pin time; a mismatch is a hard error,
  never a refetch.
- php: `https://www.php.net/distributions/php-<v>.tar.gz`, one per
  version. julia: julialang.org's per-platform binaries
  (`julia-<v>-linux-x86_64.tar.gz` under
  `https://julialang-s3.julialang.org/bin/linux/x64/<line>/`), pinned
  per triplet from upstream's `versions.json`.

### 3.2 The driver link (the arm decision, §1)

- **Source-build arm — the fs TU.** A C template
  (`build/resources/tebako_<lang>_main.c`) provides the real `main`:
  boots the driver in-process (`tebako_driver_boot(&argc, &argv,
  mount_root)`), exports `TEBAKO_CONTRACT_VERSION`, and re-execs itself
  under the driver-armed preload env (`LD_PRELOAD` +
  `TEBAKO_PRELOAD_SHIM` + `TEBAKO_TFS_MOUNTS` + a boot sentinel) so the
  unpatched interpreter's libc IO is served from the VFS. The link is
  composed by **build-time substitution on the generated build file**
  (php: the generated `Makefile` — rename the interpreter's entry at
  compile time with `-Dmain=<lang>_cli_main`, append the fs TU object +
  `$(TEBAKO_LIBS)` to the link recipe; every anchor matches exactly
  once or it is exit 103). Never a source patch: a genuine source need
  means a tamatebako source factory, not a factory-side hot-patch.
- **Repack arm — the spec-29 wrapper.** No C anywhere: the exe artifact
  IS `tebako-runtime-launcher` (§2.2), and the env image declares
  `layout.interpreter` (the in-image interpreter path) + `visibility`
  (§3.3). The launcher's boot is the shared spec-17 boot; its tail
  materializes the interpreter per the visibility mechanism and execs
  it (POSIX) with the composed argv
  `[<interpreter>, <args_default…>, <entry>, <user args…>]`.
- **julia's documented choice (the evidence the task asked for):** the
  python/php re-exec shape presumes an exe we link — a `main` we own
  and can re-exec. Julia arrives as upstream's compiled bytes, so there
  is no link step to own; a hand-rolled C launcher would re-implement
  the spec-22 class-E materialization (the kernel execs host files
  only) in C, duplicating `crates/tebako-driver/src/wrapper.rs`, which
  the product already ships as a per-platform release asset. Spec 29 §0
  locks the wrapper as "the standing answer for every runtime tebako
  does not compile from source"; openjdk proves it end-to-end. The
  "cleaner direct link" does not exist for prebuilt bytes — direct
  linking requires compiling the interpreter.

### 3.3 Kernel visibility (repack arm: the layout.visibility declaration)

- **Rule:** how do the interpreter's reads reach the mounts?
  `exec-cache` (tier 2b) when the interpreter **self-locates its home
  relative to its exe path** (the JVM, julia): the whole image tree
  materializes into the content-addressed exec cache and the
  interpreter runs from host-real files — the trigger is
  `identity.annotations.home: "/"` in the manifest.
  `preload` (tier 1) when the interpreter's paths are compiled-in or
  env-driven (node/bun): only the exe's load closure materializes and
  the armed shim serves its reads from the still-mounted image. A
  declaration the host cannot honor is exit 65, never a silent
  fallback; omitting the key picks the locked default order and is
  journaled.
- julia: `exec-cache` — julia resolves `Sys.BINDIR`/its home from the
  exe path and expects `lib/julia/*.so` (the sysimage) and
  `share/julia/` (stdlib sources) beside it, exactly the JVM's shape.
  The preload shim still rides the image (the jail binding survives the
  exec — §2.2).

### 3.4 The content policy (what the image holds, what it prunes)

- **Rule:** the image carries the runtime's whole RUNTIME surface and
  prunes the build-time/desktop surface. The interpreter binary itself
  is pruned ONLY on the source-build arm (it ships as the exe); on the
  repack arm the interpreter binary is the image's whole point. Prune
  lists are factory data (named constants), never a heuristic; a tree
  shape assertion at build time (the staged tree carries the declared
  interpreter at the declared path) backs them.
- php: `--prefix`-installed tree minus `bin/ include/ share/
  lib/php/build/` (the exe ships beside; phpize/php-config are
  extension-build tooling; man pages ride `share/`).
- julia: the upstream tree kept whole except `include/` (embedding
  headers — build-time surface), `share/doc/ share/man/`
  (documentation), `share/appdata/ share/applications/ share/icons/`
  (desktop integration), and `etc/julia/startup.jl`'s nothing (kept —
  tiny, upstream's own). In-tree symlinks are dereferenced to plain
  files (one tree shape on every platform; a dangling or tree-escaping
  link is a named build error) — julia's `lib/libjulia.so → .so.1 →
  .so.1.x` chains keep their name surface with real bytes, which the
  loader's SONAME lookup needs under the exec-cache mirror.

### 3.5 The manifest declarations (the provides block + entrypoints)

- **Rule:** `engine`/`implementation` are the runtime's distribution
  identity (spec 28 §8's flavor axis — plain names, one
  `implementation` per flavor, default flavor first); `version` is the
  published release line; `language_version` the language level;
  `abi_line` the line a native-extension payload pins (the
  major.minor); `platform` the spec 03 triplet from the Platform
  tables. `entrypoints` is the runtime's spawn surface (spec 30 §2):
  the complete bin inventory a consumer can boot by bare name — each
  `{name, path}` existence-checked at build read-back. The repack arm
  adds `identity.annotations.home: "/"` when §3.3 says exec-cache.
- php: engine/implementation `php`, no entrypoints (the minimal
  extension set ships no console scripts; the composer lane lands with
  extension breadth). julia: engine/implementation `julia`,
  entrypoints `[{name: julia, path: /bin/julia}]`, `home: "/"`.

### 3.6 The version grammar and catalog

- **Rule:** the version model (`<Lang>Version`) owns the line grammar
  (`LINE_GRAMMAR_SOURCE` + `LINE_PATTERN`), derives `abi_line` and
  `api_version`, and fails malformed input at exit 109. The schema's
  catalog pattern mirrors the grammar; the release adapter interpolates
  `LINE_GRAMMAR_SOURCE` (never a second regex). The catalog starts at
  ONE version — the current stable at factory opening — and grows by
  contract edit.
- php: plain `x.y.z`, catalog `[8.4.28]`, abi_line `8.4`. julia: plain
  `x.y.z`, catalog `[1.13.4]`, abi_line `1.13`.

### 3.7 The abi facet (conditional)

- **Rule:** a compile-time ABI a native extension pins is probed from
  the built tree and written to `<exe>.abi` (php reads
  `Zend/zend_modules.h`'s `ZEND_MODULE_API_NO` — the value's single
  upstream owner). Runtimes with no such probe (julia — its extension
  surface is the language line) emit nothing; `abi_line` in the
  manifest already carries the matching grammar. Never invent a probe.

### 3.8 The boot-smoke scenario set (probes are runtime data)

- **Universal harness** (§2.8); the scenario set below is the template
  default, each probe written in the runtime's own idiom. The
  `TEBAKO_MOUNT_ROOT` trio is conditional: runtimes whose layout grants
  `mount_root_override` (php — "the mounts move, never php's
  configuration") assert the granted boot reads the card at the
  override root; runtimes that self-locate via the exe path (julia,
  openjdk) omit the grant and assert ANY override is refused at 78.
- php's set: bare (the driver names the missing handoff; the static
  exe still answers — php's extensions are compiled in) · boot
  (`php -v` off the pair + the layout card read THROUGH the
  interpreter, proving the preload re-exec serves the VFS) · payload
  (`--tebako-image fixture:-:/app --tebako-entry /bin/hello.php` runs
  from the mount; `__FILE__` proves the VFS spelling) · compute-floor
  (the flags arm — the `.contract.yaml`'s recorded CFLAGS pins -O2,
  exit 103 class — plus a fib(35) inner-timed tripwire, best-of-3 under
  a generous ceiling; tebako-runtime-python#79's lesson: a slow BUILD
  ships green under a boot-only gate) · bad-mount (exit 69, the image
  named) · mount-root override/malformed/ungranted (78/65/78).
- julia's set: bare (no `TEBAKO_RUNTIME_IMAGE` ⇒ exit 65 naming the
  handoff — the wrapper's interpreter lives in the env image) · boot
  (`--tebako-entry julia --version` answers off the pair — the
  bare-name runtime-entrypoint form) · boot-tree (the materialized home
  carries the image: `isfile(.../lib/tebako/layout.yaml)` and
  `isdir(Sys.STDLIB)` from inside julia) · payload (a fixture image's
  `/hello.jl` executes) · compute-floor (fib inner-timed in julia with
  a JIT warm-up call, best-of-3 under a generous ceiling; NO flags arm
  — the bytes are upstream's, the card records the archive not
  CFLAGS) · bad-mount (69) · mount-root malformed (65) ·
  override-ungranted (78).

### 3.9 The provenance gate (per arm)

- **Source-build arm** (`ci/check_symbol_provenance.sh`): nm asserts
  the exe defines the driver ABI symbols + `main` + the renamed
  interpreter entry, and the disassembly of `main` references
  `tebako_driver_boot` (the fs TU landed); the ELF NEEDED rows / Mach-O
  dylibs are confined to the system allowlist (the audience rule in
  executable form; tebako-runtime-python#76/#80 are the reference
  defects); the macOS minos equals the pinned floor.
- **Repack arm** (`ci/check_pair_provenance.sh`): the shipped exe's
  sha256 equals the release-published digest recorded in
  `.contract.yaml` (the pin's byte anchor, re-proven); the NEEDED
  allowlist holds; and the image read-back passes — the pinned tfs CLI
  re-reads the image: `/__tpkg__/manifest.yaml` validates (no
  `manifest_error` from `tfs info --json`), `/lib/tebako/layout.yaml`
  is present, and every declared entrypoint exists (a broken pair fails
  THIS leg, never a later publish).

### 3.10 Platform legs and the matrix

- Start with **linux-gnu-x86_64**, one version. Additional triplets
  land one increment each: add the matrix.json row (and the container
  digest pin when containerized), the versions.yml source pins for that
  triplet (repack arm), the thin trigger workflow, and any platform
  branch in `Platform`/`Mlibs`-class files. The windows leg needs the
  spec 17 §7 materialize tier (source-build arm) or rides the wrapper's
  spawn semantics (repack arm); macOS adds the sign+notarize arm
  (spec 31, gated on `APPLE_SIGNING_ENABLED`) and the
  `macos_deployment_target` pin.

## 4. The opening checklist

1. Fork the skeleton (php for source-build, julia for repack) into
   `tamatebako/tebako-runtime-<lang>`, branch `feat/skeleton`. BSD-2.
2. The rename sweep (§2): module/dir/const names, README, AGENTS.md.
3. `versions.yml`: pin the current stable (per triplet for repack),
   cross-checked against upstream's published sums — record the
   verification date in a comment.
4. `contract.yml`: the catalog `[<that version>]`; the
   `link_unit_release` pin = the newest published tamatebako/tebako
   release that ships every asset §2.2 names for the leg's platform
   (verify the asset listing, not just the tag); conditional keys per
   §2.1; `container_digests` re-read live from ghcr (the preflight
   command is in the contract comment).
5. The delta edits, §3.1–§3.9 — each in its owning file, each
   cross-referenced from README.
6. README: the status block (what exists, what each follow-up
   increment is) and the honest framing — the pain this factory
   relieves, the audience size, and the nearest overlapping solution.
   Never discovered-by-users limitations.
7. Local proof where docker exists (`docker run --platform
   linux/amd64` on arm64 hosts): `tools/build_runtime --<lang> <ver>`
   then the provenance gate then `tools/boot_smoke`. Else CI is the
   proof.
8. Draft PR, one per repo; the PR body cites the run id, artifact
   sizes, the smoke output, and the self-review list (anything the
   build needed that this document did not describe — that list is the
   template's completeness proof). No merge without the owner's
   go-ahead.

## 5. The standing next increments (name them per factory, never ship silently)

1. Additional triplets (§3.10). 2. The publish pipeline (§2.9) and the
   first release — the owner's explicit act. 3. The upstream release
   monitor (the propose-bump shape: rewrite the pins with fresh digests,
   never cross a line pin). 4. The registry row +
   `tools/registry_update.rb`. 5. The boot-contract parity `spec/`
   suite against the product's contract cases. 6. The payload-census
   lanes (the runtime's own packaging ecosystem — composer for php, Pkg
   for julia) as app/data slices.
