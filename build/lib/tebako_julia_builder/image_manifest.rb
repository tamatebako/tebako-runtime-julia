# frozen_string_literal: true

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

require "fileutils"
require "yaml"

module TebakoJuliaBuilder
  # The env image's L1 payload manifest (spec 03 §1-2): the
  # /__tpkg__/manifest.yaml the driver reads post-mount. The grammar is
  # owned by docs/spec/schemas/payload-manifest.yaml (tamatebako/tebako,
  # mirrored by tpkg's PayloadManifest): a malformed manifest is a named
  # boot refusal (exit 65), so this emitter sticks to the locked
  # capability truth tables and digest shapes exactly (the
  # tebako-runtime-php ImageManifest port, repack edition).
  # identity.digest follows the spec 03 §7 fixed-point rule:
  # blob_sha256 is zeroed inside the image (the real digest lives one
  # tier out — the store sidecar), tree_hash is the zero placeholder
  # until the CAS lands.
  #
  # The repack arm's two specializations (docs/factory-template.md §3.5):
  # identity.annotations.home marks the payload root a tool HOME — the
  # exec-cache whole-tree materialization trigger (spec 22 §6;
  # crates/tfs mount_is_home reads it) — and provides.entrypoints
  # declares the spawn surface (spec 30 §2): the complete bin inventory
  # of the staged julia tree, which is exactly [julia].
  class ImageManifest
    # In-image location the driver reads (tpkg::PAYLOAD_MANIFEST_PATH).
    PATH = File.join("__tpkg__", "manifest.yaml").freeze

    def initialize(platform:, julia_version:, tebako_version:, src_sha256:)
      @platform = platform
      @julia_version = julia_version
      @tebako_version = tebako_version
      @src_sha256 = src_sha256
    end

    # Write the manifest into the assembled layout tree (before the image
    # is packed); returns the written path.
    def deploy(tree_root)
      path = File.join(tree_root, PATH)
      FileUtils.mkdir_p(File.dirname(path))
      File.write(path, YAML.dump(to_h))
      path
    end

    def to_h
      {
        "schema_version" => 1,
        "identity" => identity,
        "provides" => provides
      }
    end

    private

    # identity.created, deterministic (the reproducible-build contract,
    # tebako-runtime-ruby#381's idiom): SOURCE_DATE_EPOCH when the leg
    # exports it (the compute job flows the run's HEAD commit time, so
    # two runs of the same tree stamp the image identically), the epoch
    # otherwise — the tfs-cli mkimage convention (unset → 0), so a local
    # build is deterministic too. A malformed value is a named error,
    # never a silent wall-clock fallback.
    def created_timestamp
      Time.at(sde_epoch).utc.strftime("%Y-%m-%dT%H:%M:%SZ")
    end

    def sde_epoch
      sde = ENV.fetch("SOURCE_DATE_EPOCH", nil)
      return 0 if sde.nil? || sde.empty?

      Integer(sde, 10)
    rescue ArgumentError
      raise TebakoJuliaBuilder::Error.new(
        "SOURCE_DATE_EPOCH is malformed (#{sde.inspect} — whole seconds since the epoch)", 64
      )
    end

    def identity
      {
        "schema_version" => 1,
        # The spec-18 contract field: this image is an era-2 artifact (the
        # same declaration lib/tebako/layout.yaml carries on the C3 edge).
        "era" => 2,
        "kind" => "runtime",
        "name" => "tebako-runtime-julia",
        "version" => @tebako_version,
        "producer" => { "tool" => "tebako-runtime-julia", "tool_version" => @tebako_version },
        "created" => created_timestamp,
        "source" => { "src_sha256" => @src_sha256 },
        "digest" => {
          "tree_hash" => "sha256:#{"0" * 64}",
          "blob_sha256" => "0" * 64
        },
        "signing" => { "state" => "unsigned" },
        "encryption" => { "state" => "none" },
        # The payload root IS a julia home (bin/julia self-locates its
        # tree relative to the exe path — the JVM's shape): the
        # annotation is the exec-cache whole-tree materialization trigger
        # (spec 22 §6 — crates/tfs mount_is_home reads
        # identity.annotations.home). Under visibility: exec-cache the
        # mounted env image materializes into the content-addressed exec
        # cache and julia runs from host-real files.
        "annotations" => { "home" => "/" }
      }
    end

    # kind=runtime PROVIDES (spec 03 §2.2): the engine line the dispatcher
    # matches runtime_requirements against, the source provenance, the
    # spawn surface, and the locked runtime capability triple.
    # implementation + language_version are the spec 28 §8 axis:
    # `implementation` is REQUIRED for kind: runtime and `julia` is the
    # implementation of record (the reference implementation — the only
    # one upstream publishes). `version` is the published RELEASE LINE;
    # `language_version` is the language level the runtime implements
    # (equals version — julia tracks its implementation).
    # abi_line is the julia major.minor (the "1.13" line — julia has no
    # compile-time ABI probe; the extension surface is the language
    # line). built_from.patch_set is "none" verbatim: a repack applies
    # no patches; the consumed bytes are julialang.org's official
    # prebuilt archive, pinned in versions.yml.
    def provides
      julia = TebakoJuliaBuilder::JuliaVersion.new(@julia_version)
      {
        "provides" => {
          "engine" => "julia",
          "implementation" => "julia",
          "version" => @julia_version,
          "language_version" => julia.base_version,
          "abi_line" => julia.abi_line,
          "platform" => @platform.tpkg_triplet
        },
        "built_from" => { "src_sha256" => @src_sha256,
                          "patch_set" => "none (official julialang.org prebuilt, versions.yml pin)" },
        "entrypoints" => [
          { "name" => "julia", "path" => "/bin/julia" }
        ],
        "capabilities" => { "exec" => true, "read" => true, "runtime" => true }
      }
    end
  end
end
