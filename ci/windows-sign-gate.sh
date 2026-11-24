#!/bin/bash
# windows-sign-gate.sh — the spec 34 §4 enablement gate for the windows
# runtime leg (the ruby factory's same-named script, mirrored through
# tebako-runtime-python#107's: the factory mirror of tamatebako/tebako
# PR #566's ci/windows-sign-gate.sh). The repo variable
# WINDOWS_SIGNING_ENABLED=true arms Azure Trusted Signing (Authenticode)
# for the leg's ONE shippable PE — the launcher exe
# (tebako-runtime-launcher, shipped byte-identical from the pinned
# product release; julia.exe + its DLLs live INSIDE the .tfs env image —
# the exec-cache shape — so there is no DLL facet to sign);
# anything else ships unsigned BY DESIGN (spec 00 invariant 7: unsigned
# stays first-class) and this step is a loud notice. Armed but a
# secret/variable unresolved is a FAST named failure BEFORE any signing
# call — never a partial release (spec 34 §7.5; the same discipline as
# ci/macos-sign-notarize-runtime.sh's spec 31 gate).
#
# Emits armed=<true|false> to GITHUB_OUTPUT; the leg's PE staging,
# azure/login, artifact-signing and signtool-verify steps all gate on
# it. Sign-then-hash (spec 34 §1.3): the build emitted the exe's
# .sha256 sidecar over the PRE-SIGN bytes, so the verify step re-anchors
# it to the SIGNED bytes after signtool passes (the macOS arm's idiom)
# — the provenance gate's sidecar arm and the publish stage then anchor
# exactly the shipped bytes.
#
# Required env when armed (spec 34 §3): AZURE_CLIENT_ID, AZURE_TENANT_ID,
# AZURE_SUBSCRIPTION_ID (org secrets — the OIDC identity; no
# AZURE_CLIENT_SECRET exists anywhere), AZURE_ENDPOINT,
# AZURE_SIGNING_ACCOUNT_NAME, AZURE_SIGNING_CERT_PROFILE (org variables).
# Runner env: WINDOWS_SIGNING_ENABLED (from vars.), GITHUB_OUTPUT.
set -euo pipefail

if [ "${WINDOWS_SIGNING_ENABLED:-false}" != "true" ]; then
  echo "::notice::spec 34: WINDOWS_SIGNING_ENABLED != true — this leg ships UNSIGNED (spec 00 invariant 7)"
  echo "armed=false" >> "$GITHUB_OUTPUT"
  exit 0
fi

missing=""
for v in AZURE_CLIENT_ID AZURE_TENANT_ID AZURE_SUBSCRIPTION_ID \
         AZURE_ENDPOINT AZURE_SIGNING_ACCOUNT_NAME AZURE_SIGNING_CERT_PROFILE; do
  [ -n "${!v:-}" ] || missing="$missing $v"
done
if [ -n "$missing" ]; then
  echo "::error::WINDOWS_SIGNING_ENABLED=true but unset:$missing — spec 34 §7.5: fast failure before any signing call, never a partial release"
  exit 1
fi

echo "armed=true" >> "$GITHUB_OUTPUT"
echo "spec 34: signing armed — Artifact Signing account $AZURE_SIGNING_ACCOUNT_NAME / profile $AZURE_SIGNING_CERT_PROFILE ($AZURE_ENDPOINT)"
