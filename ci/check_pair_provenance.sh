#!/usr/bin/env bash
# Copyright (c) 2026 [Ribose Inc](https://www.ribose.com).
# All rights reserved.
# This file is a part of tamatebako
#
# Redistribution and use in source and binary forms, with or without
# modification, are permitted provided that the following conditions
# are met:
# 1. Redistributions of source code must retain the above copyright
#    notice, this list of conditions and the following disclaimer.
# 2. Redistributions in binary form must reproduce the above copyright
#    notice, this list of conditions and the following disclaimer in the
#    documentation and/or other materials provided with the distribution.
#
# THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
# ``AS IS'' AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT LIMITED
# TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR A PARTICULAR
# PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT HOLDERS OR CONTRIBUTORS
# BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, SPECIAL, EXEMPLARY, OR
# CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT LIMITED TO, PROCUREMENT OF
# SUBSTITUTE GOODS OR SERVICES; LOSS OF USE, DATA, OR PROFITS; OR BUSINESS
# INTERRUPTION) HOWEVER CAUSED AND ON ANY THEORY OF LIABILITY, WHETHER IN
# CONTRACT, STRICT LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE)
# ARISING IN ANY WAY OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
# POSSIBILITY OF SUCH DAMAGE.

# ci/check_pair_provenance.sh — the provenance assert for a built tebako
# julia runtime pair. This factory is the REPACK arm (spec 29): it
# compiles nothing, so its provenance is identity, not symbols. The
# shadow class here is the QUIETLY DRIFTED CONSUMPTION — a launcher that
# is not quite the pinned release's bytes, a dynamic closure that grew a
# non-system library, a signed macOS exe whose sidecar still anchors the
# pre-sign bytes, an image that packs but cannot be read back. The
# fingerprints, per exe kind (magic-sniffed — Git-bash carries no
# `file`):
#
#   1. byte anchor (ELF): the exe's sha256 IS the pinned release's
#      published launcher digest, recorded in the pair's own
#      .contract.yaml (link_unit.launcher_sha256) — the consumed
#      artifact flowed down unmodified. The exe's .sha256 sidecar must
#      agree with both.
#      PE (sign-then-hash): the exe may be Authenticode-signed IN-LEG
#      after the build (the workflow's spec 34 §8.2 block —
#      ci/windows-sign-gate.sh's arm), so the shipped bytes legitimately
#      differ from the card's recorded release digest (that record stays
#      as consumption provenance). The anchors here are: the exe .sha256
#      sidecar agrees with the SIGNED bytes, and — when
#      WINDOWS_SIGNING_ENABLED=true — Get-AuthenticodeSignature reports
#      a Valid signature WITH a timestamp certificate; the unsigned
#      (byte-identical) outcome is then a failure, because the armed
#      sign step cannot silently no-op. Unsigned with
#      WINDOWS_SIGNING_ENABLED unset stays first-class (spec 00
#      invariant 7: byte-identical with the release's launcher, notice
#      only). (PE imports are not separately audited: the byte anchor
#      plus the product's own ship gate cover the closure.)
#      Mach-O (sign-then-hash): the exe is signed IN-LEG after the build
#      (ci/macos-sign-notarize-runtime.sh — spec 31 §5), so the shipped
#      bytes legitimately differ from the card's recorded release digest
#      (that record stays as consumption provenance). The anchors here
#      are: the exe .sha256 sidecar agrees with the SIGNED bytes, and
#      codesign verifies strict; when APPLE_SIGNING_ENABLED=true the
#      gate additionally asserts the TeamIdentifier, the embedded
#      entitlement pair, and the notarization ticket — and the unsigned
#      (byte-identical) outcome is then a failure, because the armed
#      sign step cannot silently no-op. Unsigned with
#      APPLE_SIGNING_ENABLED unset stays first-class (spec 00 invariant
#      7: byte-identical with the release's launcher, notice only).
#   2. ELF only: the exe's runtime library closure is system-only (the
#      audience rule in executable form — the readelf NEEDED allowlist;
#      tebako-runtime-python#76 is the reference defect).
#   3. image read-back: re-read the env image with the same tfs CLI that
#      wrote it — the embedded tier-1 manifest exists and validates, the
#      layout declaration is present, and the declared entrypoint exists
#      (/bin/julia.exe on windows — tebako-runtime-openjdk's read-back
#      arm, exe-suffixed).
#
# Env: APPLE_SIGNING_ENABLED / APPLE_TEAM_ID ride the Mach-O arm;
# WINDOWS_SIGNING_ENABLED rides the PE arm (the workflow passes them;
# unset means the unsigned path's asserts only).
#
# Usage:
#   ci/check_pair_provenance.sh --exe PATH --card PATH --tfs PATH --image PATH
set -euo pipefail

EXE=""
CARD=""
TFS=""
IMAGE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --exe) EXE="$2"; shift 2 ;;
    --card) CARD="$2"; shift 2 ;;
    --tfs) TFS="$2"; shift 2 ;;
    --image) IMAGE="$2"; shift 2 ;;
    *) echo "check_pair_provenance: unknown argument '$1'" >&2; exit 2 ;;
  esac
done
[ -n "$EXE" ] || { echo "check_pair_provenance: --exe PATH is required" >&2; exit 2; }
[ -n "$CARD" ] || { echo "check_pair_provenance: --card PATH is required" >&2; exit 2; }
[ -n "$TFS" ] || { echo "check_pair_provenance: --tfs PATH is required" >&2; exit 2; }
[ -n "$IMAGE" ] || { echo "check_pair_provenance: --image PATH is required" >&2; exit 2; }
[ -s "$EXE" ] || { echo "::error::provenance: exe $EXE is missing or empty"; exit 1; }
[ -s "$CARD" ] || { echo "::error::provenance: contract card $CARD is missing or empty"; exit 1; }
[ -s "$TFS" ] || { echo "::error::provenance: tfs CLI $TFS is missing or empty"; exit 1; }
[ -s "$IMAGE" ] || { echo "::error::provenance: env image $IMAGE is missing or empty"; exit 1; }

failures=0
fail() { echo "::error::provenance: $*"; failures=$((failures + 1)); }
note() { echo "provenance: $*"; }

sha256_of() { { sha256sum "$1" 2>/dev/null || shasum -a 256 "$1"; } | cut -d' ' -f1; }

# The exe shape from its magic bytes (od + head are coreutils/BSD — no
# `file` dependency, which Git-bash lacks). Mach-O covers the thin
# little-endian forms the legs ship (arm64/x86_64) plus fat.
exe_kind() {
  local magic
  magic="$(head -c 4 "$1" | od -An -tx1 | tr -d ' \n')"
  case "$magic" in
    7f454c46) echo elf ;;
    cffaedfe | cefaedfe | cafebabe) echo macho ;;
    4d5a*) echo pe ;;
    *) echo unknown ;;
  esac
}

KIND="$(exe_kind "$EXE")"
ARMED="${APPLE_SIGNING_ENABLED:-false}"
WIN_ARMED="${WINDOWS_SIGNING_ENABLED:-false}"
ENTRYPOINT="/bin/julia"
[ "$KIND" = "pe" ] && ENTRYPOINT="/bin/julia.exe"
note "exe kind: $KIND (entrypoint $ENTRYPOINT)"

# Path rules (windows leg): native exes (the tfs CLI below, powershell's
# Get-AuthenticodeSignature in the PE arm) take the host path in native
# form (cygpath; inert on POSIX).
native_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

# --- 1. the byte anchor / the signed-bytes anchor ------------------------
# YAML.dump renders the scalar as `launcher_sha256: <hex>` — sed-extract
# the value (the card is this factory's own emission; a full YAML parse
# would buy nothing here).
want="$(sed -n 's/^  launcher_sha256: *//p' "$CARD" | tr -d '[:space:]')"
case "$want" in
  '' | *[!0-9a-f]*)
    fail "$CARD carries no parseable link_unit.launcher_sha256 — the consumption provenance cannot be checked" ;;
  *)
    got="$(sha256_of "$EXE")"
    sidecar="$(cat "$EXE.sha256" 2>/dev/null || true)"
    case "$KIND" in
      elf)
        if [ "$got" = "$want" ]; then
          note "the exe is byte-identical with the pinned release's published launcher ($want)"
        else
          fail "$EXE sha256 is $got but the card records $want — the shipped exe is NOT the pinned release's launcher (the consumption drifted)"
        fi
        # The sidecar is the store-layout trust anchor; it must agree
        # with the bytes it sits next to.
        case "$sidecar" in
          "$got  $(basename "$EXE")") note "the exe .sha256 sidecar agrees with the bytes" ;;
          '') fail "$EXE.sha256 is missing — the store-shape trust anchor was not emitted" ;;
          *) fail "$EXE.sha256 disagrees with the exe bytes (sidecar: $sidecar; actual: $got)" ;;
        esac
        ;;
      pe)
        if [ "$got" = "$want" ]; then
          # The unsigned path: the product's own bytes flowed down
          # untouched (spec 00 invariant 7's first-class unsigned).
          if [ "$WIN_ARMED" = "true" ]; then
            fail "WINDOWS_SIGNING_ENABLED=true yet the exe is byte-identical with the UNSIGNED release launcher — the armed sign step cannot no-op (the workflow's spec 34 §8.2 block must run before this gate)"
          else
            note "the exe is byte-identical with the pinned release's published launcher (the unsigned path — spec 00 invariant 7)"
          fi
          case "$sidecar" in
            "$got  $(basename "$EXE")") note "the exe .sha256 sidecar agrees with the bytes" ;;
            '') fail "$EXE.sha256 is missing — the store-shape trust anchor was not emitted" ;;
            *) fail "$EXE.sha256 disagrees with the exe bytes (sidecar: $sidecar; actual: $got)" ;;
          esac
          note "PE import closure: covered by the byte anchor + the product's ship gate"
        else
          # The signed path: sign-then-hash — the sidecar (re-anchored
          # by the verify step) anchors the SIGNED bytes; the card's
          # record stays as consumption provenance (the Mach-O arm's
          # mirror).
          [ "$WIN_ARMED" = "true" ] || fail "$EXE differs from the release's launcher digest yet WINDOWS_SIGNING_ENABLED is not true — an unexplained re-sign is a drifted consumption"
          case "$sidecar" in
            "$got  $(basename "$EXE")") note "the exe .sha256 sidecar agrees with the SIGNED bytes (sign-then-hash)" ;;
            '') fail "$EXE.sha256 is missing — the sign step must re-anchor it to the signed bytes" ;;
            *) fail "$EXE.sha256 anchors the PRE-SIGN bytes (sidecar: $sidecar; actual: $got) — sign-then-hash is mandatory" ;;
          esac
          if [ "$WIN_ARMED" = "true" ]; then
            # The Authenticode arm (the Mach-O arm's codesign cascade,
            # PE-shaped): armed means a VALID, timestamped signature on
            # the shipped bytes — the workflow's pwsh verify step owns
            # signtool /pa; here the identity anchor.
            if command -v powershell.exe >/dev/null 2>&1; then
              if MSYS2_ARG_CONV_EXCL='*' powershell.exe -NoProfile -Command \
                "\$s = Get-AuthenticodeSignature -FilePath '$(native_path "$EXE")'; if (\$s.Status -eq 'Valid' -and \$null -ne \$s.TimeStamperCertificate) { exit 0 } else { exit 1 }"; then
                note "Get-AuthenticodeSignature: Valid + timestamped (the armed spec 34 sign landed)"
              else
                fail "WINDOWS_SIGNING_ENABLED=true but Get-AuthenticodeSignature does not report a Valid, timestamped signature on $EXE"
              fi
            else
              fail "WINDOWS_SIGNING_ENABLED=true on a host without powershell.exe — the Authenticode asserts cannot run"
            fi
          fi
        fi
        ;;
      macho)
        if [ "$got" = "$want" ]; then
          # The unsigned path: the product's own signed bytes flowed
          # down untouched (spec 00 invariant 7's first-class unsigned).
          if [ "$ARMED" = "true" ]; then
            fail "APPLE_SIGNING_ENABLED=true yet the exe is byte-identical with the UNSIGNED release launcher — the armed sign step cannot no-op (ci/macos-sign-notarize-runtime.sh must run before this gate)"
          else
            note "the exe is byte-identical with the pinned release's published launcher (the unsigned path — spec 00 invariant 7)"
          fi
        else
          # The signed path: sign-then-hash — the sidecar (rewritten by
          # the sign step) anchors the SIGNED bytes; the card's record
          # stays as consumption provenance.
          [ "$ARMED" = "true" ] || fail "$EXE differs from the release's launcher digest yet APPLE_SIGNING_ENABLED is not true — an unexplained re-sign is a drifted consumption"
          case "$sidecar" in
            "$got  $(basename "$EXE")") note "the exe .sha256 sidecar agrees with the SIGNED bytes (sign-then-hash)" ;;
            '') fail "$EXE.sha256 is missing — the sign step must rewrite it to the signed bytes" ;;
            *) fail "$EXE.sha256 anchors the PRE-SIGN bytes (sidecar: $sidecar; actual: $got) — sign-then-hash is mandatory" ;;
          esac
        fi
        if command -v codesign >/dev/null 2>&1; then
          codesign --verify --strict "$EXE" 2>/dev/null \
            && note "codesign --verify --strict passes" \
            || fail "codesign --verify --strict rejects $EXE"
          if [ "$ARMED" = "true" ]; then
            TEAM_ID="${APPLE_TEAM_ID:-}"
            [ -n "$TEAM_ID" ] || fail "APPLE_SIGNING_ENABLED=true but APPLE_TEAM_ID is unset — the TeamIdentifier assert cannot run"
            if [ -n "$TEAM_ID" ]; then
              codesign -dvv "$EXE" 2>&1 | grep -q "TeamIdentifier=$TEAM_ID" \
                && note "TeamIdentifier=$TEAM_ID (the expected identity)" \
                || fail "TeamIdentifier is not $TEAM_ID — signed by an unexpected identity"
            fi
            embedded="$(codesign -d --entitlements :- "$EXE" 2>/dev/null || true)"
            trues="$(printf '%s' "$embedded" | grep -o '<true/>' | wc -l | tr -d ' ')"
            [ "$trues" = "2" ] \
              && note "the entitlement pair is embedded (disable-library-validation + allow-jit)" \
              || fail "the entitlement pair is not embedded (got $trues <true/> values)"
            codesign --verify --strict --check-notarization -R=notarized "$EXE" 2>/dev/null \
              && note "the notarization ticket is visible to codesign" \
              || fail "the notarization ticket is not visible — the sign step's notary arm did not complete"
          fi
        else
          [ "$ARMED" = "true" ] && fail "APPLE_SIGNING_ENABLED=true on a host without codesign — the macOS signing asserts cannot run" \
                                || note "no codesign on this host — the signature asserts are inapplicable"
        fi
        ;;
      *)
        fail "unrecognized exe shape ($KIND) — the provenance gate names every shape, never skips one"
        ;;
    esac
    ;;
esac

# --- 2. ELF: the exe's runtime library closure is system-only ------------
# capture-then-test everywhere (never readelf | grep -q under pipefail:
# grep's early exit SIGPIPEs readelf into a false negative).
if [ "$KIND" = "elf" ]; then
  needed=""
  if command -v readelf >/dev/null 2>&1; then
    needed="$(readelf -d "$EXE" 2>/dev/null | awk '/NEEDED/ { gsub(/[][]/, ""); print $NF }' || true)"
  elif command -v llvm-readelf >/dev/null 2>&1; then
    needed="$(llvm-readelf -d "$EXE" 2>/dev/null | awk '/NEEDED/ { gsub(/[][]/, ""); print $NF }' || true)"
  else
    fail "an ELF exe and no readelf/llvm-readelf to audit its NEEDED rows — the harness must carry binutils"
  fi
  if [ -z "$needed" ] && { command -v readelf >/dev/null 2>&1 || command -v llvm-readelf >/dev/null 2>&1; }; then
    fail "the dynamic section of $EXE yielded no NEEDED rows (a static exe? the probe cannot run)"
  fi
  needed_failures_before=$failures
  while IFS= read -r lib; do
    [ -z "$lib" ] && continue
    case "$lib" in
      libc.musl-*.so.1 | ld-musl-*.so.1 | \
      libc.so.6 | libm.so.6 | libdl.so.2 | librt.so.2 | libpthread.so.0 | \
      libutil.so.1 | libresolv.so.2 | \
      ld-linux-*.so.2 | ld-linux-*.so.1 | libgcc_s.so.1) : ;;
      *) fail "$EXE NEEDs $lib — a runtime .so dependency a bare system cannot satisfy (the audience rule; tebako-runtime-python#76)" ;;
    esac
  done <<< "$needed"
  [ -n "$needed" ] && [ "$failures" -eq "$needed_failures_before" ] && note "the exe's NEEDED set is system-only: $(printf '%s\n' "$needed" | tr '\n' ' ')"
fi

# --- 3. the image reads back ---------------------------------------------
# A broken pair fails THIS leg, never a downstream consumer: the tfs CLI
# that wrote the image re-reads it. The info surface runs the same tpkg
# manifest model the resolvers parse — build-time parity, no YAML-parser
# dependency. Path rules (windows leg): the native tfs takes the host
# image path in native form (native_path, hoisted above), while the VFS
# paths must reach it verbatim — Git-bash/msys2 argument conversion
# would otherwise rewrite them to host paths (MSYS2_ARG_CONV_EXCL, inert
# on POSIX).
IMAGE_NATIVE="$(native_path "$IMAGE")"
MSYS2_ARG_CONV_EXCL='*' "$TFS" stat "$IMAGE_NATIVE" /__tpkg__/manifest.yaml >/dev/null || {
  fail "no /__tpkg__/manifest.yaml in $IMAGE"; }
MSYS2_ARG_CONV_EXCL='*' "$TFS" stat "$IMAGE_NATIVE" /lib/tebako/layout.yaml >/dev/null || {
  fail "no /lib/tebako/layout.yaml in $IMAGE (the driver's layout grant is absent)"; }
MSYS2_ARG_CONV_EXCL='*' "$TFS" stat "$IMAGE_NATIVE" "$ENTRYPOINT" >/dev/null || {
  fail "the declared entrypoint $ENTRYPOINT is missing from $IMAGE"; }
info="$(MSYS2_ARG_CONV_EXCL='*' "$TFS" info --json "$IMAGE_NATIVE")" || fail "tfs info cannot read $IMAGE"
case "$info" in
  *'"manifest_error"'*)
    printf '%s\n' "$info" | grep '"manifest_error"' >&2
    fail "the embedded manifest does not validate" ;;
esac
[ "$failures" -eq 0 ] && note "the env image reads back: manifest validates, layout card + $ENTRYPOINT present"

if [ "$failures" -gt 0 ]; then
  echo "::error::provenance: $failures check(s) failed"
  exit 1
fi
note "the pair is the pinned release's launcher + a read-back-clean env image — provenance OK ($EXE)"
