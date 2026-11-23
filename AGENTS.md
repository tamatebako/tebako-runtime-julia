# AGENTS.md — tebako-runtime-julia

The binding rules are the ecosystem's: **tamatebako/AGENTS.md** (the
workspace root) — read it first. The short version as applied here:

- **Draft PRs only.** No merges to `main`, no tags, no releases without
  the owner's explicit go-ahead.
- **Prebuilt artifacts flow downward.** This factory CONSUMES published
  artifacts — the official julialang.org prebuilt archives
  (sha256-pinned per triplet in `versions.yml`) and the launcher +
  link unit + tfs CLI from the pinned tamatebako/tebako release
  (`contract.yml link_unit_release`). Never a source checkout of a
  sibling repo, in CI or locally; never a source build of the driver
  stack; never a compiled julia (the repack law — docs/build-chain.md).
- **SSOT for versions and pins.** Versions, tags, SHAs live in
  `contract.yml` (catalog + pins), `versions.yml` (source url/sha256),
  and `.github/matrix.json` (env vocabulary) — never hardcoded in
  workflow YAML or scripts.
- **No julia source patches and no julia builds.** The archive ships
  pristine (fetch → verify → stage → prune → pack). A genuine julia
  source need means a tamatebako source factory, not a factory-side
  hot-patch.
- **YAML** for all authored config/manifests; named errors and named
  exit codes, never silent fallbacks.

## Repo status: pre-release

`tools/build_runtime` is implemented (the tebako-runtime-php
`build/lib` port, repack arm): fetch/verify → stage/prune → env-image
pack → the launcher shipped byte-identical → sidecars, gated by
`ci/check_pair_provenance.sh` and `tools/boot_smoke`. CI carries one
platform workflow (`build-linux-gnu.yml` — a thin trigger over
`_build-platform.yml`: parity → compute → preflight → build → verify)
plus the static gate (`lint.yml`). There is deliberately **no
publish pipeline, no release, no tag** — those are named increments
(README's status block); the first release is the owner's explicit act.

## Repo-local gotchas

- Tooling is **Ruby** (stdlib-first; gems only via `Gemfile`).
  Ecosystem §12 rules apply: autoload only, no `require_relative`, no
  `send`/`instance_variable_get`/`respond_to?` metaprogramming.
- `Gemfile.lock` is gitignored (factory convention — resolutions float).
- `contract.yml` is validated by `scripts/check_contract.rb` against
  `schema/contract.schema.yml` (`bundle exec`), including the
  driver-source parity arm (contract.yml ↔ the pinned link-unit
  release's compiled-in `TEBAKO_CONTRACT_VERSION`). A contract bump
  edits both in the same commit.
- CI containers are `ghcr.io/tamatebako/tpkg-builder-*`
  (tebako-ci-containers) only, pulled `name:tag@digest`; the archived
  v1 `tebako-<platform>` images are never referenced here.
- The container legs bind-mount the workspace and run as root —
  root-owned files land in `.build/` and `runtime-packages/`. The
  workflow hands them back to the runner user (`chown` at the end of
  the docker-run step); do the same locally before editing or
  `git clean`-ing.
- Local container builds need docker with the linux/amd64 platform
  (`docker run --platform linux/amd64` on arm64 hosts). Under emulation
  the boot smoke's exec-cache materialization and compute floor run
  several times slower than native — do not "fix" a ceiling trip that
  only reproduces under qemu; note it as an emulation artifact.
- The exe artifact is the product's `tebako-runtime-launcher`, shipped
  byte-identical (README's driver-link section). Any itch to patch or
  wrap it is a product-repo change, never a factory-side one.
- `gh pr create` bodies: always `--body-file` — inline `--body` with
  backticks executes them (ecosystem §13).
- Architecture/chain questions: `docs/build-chain.md` first, then
  README.md. If you change a workflow, the build tooling, the matrix,
  or a cache key, update `docs/build-chain.md` in the same PR.
  `docs/factory-template.md` is the generalized form of this skeleton —
  keep its delta surface honest when this factory's shape moves.
