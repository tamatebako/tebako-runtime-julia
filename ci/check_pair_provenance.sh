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
# non-system library, an image that packs but cannot be read back. The
# fingerprints:
#
#   1. byte anchor: the exe's sha256 IS the pinned release's published
#      launcher digest, recorded in the pair's own .contract.yaml
#      (link_unit.launcher_sha256) — the consumed artifact flowed down
#      unmodified. The exe's .sha256 sidecar must agree with both.
#   2. the exe's runtime library closure is system-only (the audience
#      rule in executable form — the readelf NEEDED allowlist;
#      tebako-runtime-python#76 is the reference defect).
#   3. image read-back: re-read the env image with the same tfs CLI that
#      wrote it — the embedded tier-1 manifest exists and validates, the
#      layout declaration is present, and the declared entrypoint exists
#      (tebako-runtime-openjdk's read-back arm).
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
[ -x "$TFS" ] || { echo "::error::provenance: tfs CLI $TFS is missing or not executable"; exit 1; }
[ -s "$IMAGE" ] || { echo "::error::provenance: env image $IMAGE is missing or empty"; exit 1; }

failures=0
fail() { echo "::error::provenance: $*"; failures=$((failures + 1)); }
note() { echo "provenance: $*"; }

sha256_of() { { sha256sum "$1" 2>/dev/null || shasum -a 256 "$1"; } | cut -d' ' -f1; }

# --- 1. the byte anchor --------------------------------------------------
# YAML.dump renders the scalar as `launcher_sha256: <hex>` — sed-extract
# the value (the card is this factory's own emission; a full YAML parse
# would buy nothing here).
want="$(sed -n 's/^  launcher_sha256: *//p' "$CARD" | tr -d '[:space:]')"
case "$want" in
  '' | *[!0-9a-f]*)
    fail "$CARD carries no parseable link_unit.launcher_sha256 — the byte anchor cannot be checked" ;;
  *)
    got="$(sha256_of "$EXE")"
    if [ "$got" = "$want" ]; then
      note "the exe is byte-identical with the pinned release's published launcher ($want)"
    else
      fail "$EXE sha256 is $got but the card records $want — the shipped exe is NOT the pinned release's launcher (the consumption drifted)"
    fi
    # The sidecar is the store-layout trust anchor; it must agree with
    # the bytes it sits next to.
    sidecar="$(cat "$EXE.sha256" 2>/dev/null || true)"
    case "$sidecar" in
      "$got  $(basename "$EXE")") note "the exe .sha256 sidecar agrees with the bytes" ;;
      '') fail "$EXE.sha256 is missing — the store-shape trust anchor was not emitted" ;;
      *) fail "$EXE.sha256 disagrees with the exe bytes (sidecar: $sidecar; actual: $got)" ;;
    esac
    ;;
esac

# --- 2. the exe's runtime library closure is system-only -----------------
# capture-then-test everywhere (never readelf | grep -q under pipefail:
# grep's early exit SIGPIPEs readelf into a false negative).
if file_out="$(file "$EXE" 2>/dev/null)" && printf '%s' "$file_out" | grep -q ELF; then
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
else
  note "$EXE is not ELF — the NEEDED audit is inapplicable on this platform"
fi

# --- 3. the image reads back ---------------------------------------------
# A broken pair fails THIS leg, never a downstream consumer: the tfs CLI
# that wrote the image re-reads it. The info surface runs the same tpkg
# manifest model the resolvers parse — build-time parity, no YAML-parser
# dependency.
"$TFS" stat "$IMAGE" /__tpkg__/manifest.yaml >/dev/null || {
  fail "no /__tpkg__/manifest.yaml in $IMAGE"; }
"$TFS" stat "$IMAGE" /lib/tebako/layout.yaml >/dev/null || {
  fail "no /lib/tebako/layout.yaml in $IMAGE (the driver's layout grant is absent)"; }
"$TFS" stat "$IMAGE" /bin/julia >/dev/null || {
  fail "the declared entrypoint /bin/julia is missing from $IMAGE"; }
info="$("$TFS" info --json "$IMAGE")" || fail "tfs info cannot read $IMAGE"
case "$info" in
  *'"manifest_error"'*)
    printf '%s\n' "$info" | grep '"manifest_error"' >&2
    fail "the embedded manifest does not validate" ;;
esac
[ "$failures" -eq 0 ] && note "the env image reads back: manifest validates, layout card + /bin/julia present"

if [ "$failures" -gt 0 ]; then
  echo "::error::provenance: $failures check(s) failed"
  exit 1
fi
note "the pair is the pinned release's launcher + a read-back-clean env image — provenance OK ($EXE)"
