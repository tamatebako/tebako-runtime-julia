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
  # Assembles the env image's layout tree from the staged upstream tree
  # (TreeStager): the julia tree with the non-runtime surface pruned,
  # plus the tebako contract card (lib/tebako/layout.yaml — the spec-29
  # declaration: interpreter + visibility), the preload shim (POSIX ONLY —
  # staged so the jail's host-IO binding survives the exec into the
  # interpreter; a missing shim is a hard error, never a silent degrade;
  # windows has no preload tier, so the windows image stages no shim and
  # its layout card omits the grant — the openjdk factory's shape), and
  # the L1 payload manifest (__tpkg__/manifest.yaml).
  #
  # Unlike the source-build arm, the interpreter binary itself STAYS in
  # the image — it is the image's whole point (the exe artifact beside
  # the image is the launcher, spec 29). The prune policy (README's
  # table): build-time/desktop surface only — the embedding headers
  # (include/), the documentation (share/doc/, share/man/), and the
  # desktop-integration metadata (share/applications/,
  # share/metainfo/). Everything else rides: bin/julia, lib/ +
  # lib/julia/ (the sysimage + dependency closure), libexec/, etc/
  # (startup.jl), share/julia/ (the stdlib sources Sys.STDLIB points
  # at), LICENSE.md.
  class ImageBuilder
    # The env image's own contract declaration (spec 18 C3), read by the
    # driver post-mount, before the interpreter starts. Field set per
    # docs/spec/schemas/layout.yaml (snake_case): schema/version, era,
    # image_layout, mount_root, interpreter_api_version; the additive
    # spec-29 declarations (schema_minor 4) — interpreter (the in-image
    # path the wrapper execs; .exe on windows) and visibility
    # ("exec-cache": julia self-locates its home relative to the exe
    # path, the JVM's shape — the whole tree materializes and julia runs
    # from host-real files); the additive preload_shim grant
    # (schema_minor 2) names the staged shim's in-image path — POSIX
    # only, omitted on windows (no preload tier there; a granted-but-
    # absent shim would be exit 78 at boot). mount_root_override stays
    # UNGRANTED (the openjdk rationale: julia self-locates via the
    # launcher path's bin/.. — nothing in it follows TEBAKO_MOUNT_ROOT,
    # so the image grants no override; a granted no-op knob would
    # violate spec 00 §9).
    LAYOUT_DECLARATION = {
      "schema" => "layout",
      "schema_version" => 1,
      "era" => 2,
      "image_layout" => 1
    }.freeze
    LAYOUT_PATH = File.join("lib", "tebako", "layout.yaml").freeze
    INTERPRETER = "/bin/julia"
    INTERPRETER_WINDOWS = "/bin/julia.exe"

    # Pruned under the staged tree (relative spellings): the class
    # comment's policy, exact per the upstream 1.13 tree.
    PRUNE_PATHS = [
      "include",
      File.join("share", "doc"),
      File.join("share", "man"),
      File.join("share", "applications"),
      File.join("share", "metainfo")
    ].freeze

    def initialize(platform:, julia_version:, tebako_version:, src_sha256:, # rubocop:disable Metrics/ParameterLists
                   link_unit:, link_unit_dir:)
      @platform = platform
      @julia = TebakoJuliaBuilder::JuliaVersion.new(julia_version)
      @tebako_version = tebako_version
      @src_sha256 = src_sha256
      @link_unit = link_unit
      @link_unit_dir = link_unit_dir
    end

    # Copy the staged tree into a fresh tree at dest and deploy the
    # tebako surface; returns dest (the image root — its CONTENTS map
    # onto the mount root).
    def assemble(staged_tree, dest)
      FileUtils.rm_rf(dest, secure: true)
      FileUtils.mkdir_p(dest)
      FileUtils.cp_r("#{staged_tree}/.", dest)
      prune(dest)
      deploy_preload(dest) if @platform.posix?
      deploy_layout(dest)
      deploy_manifest(dest)
      dest
    end

    private

    def prune(tree)
      PRUNE_PATHS.each { |path| FileUtils.rm_rf(File.join(tree, path), secure: true) }
      puts "   ... pruned the non-runtime surface: #{PRUNE_PATHS.join(", ")}"
    end

    # The preload shim rides the env image at lib/tebako/ and is declared
    # via the layout's preload_shim grant, which the driver flows to the
    # injection env for the exec'd interpreter (spec 22 §3 — under
    # exec-cache the interpreter is a host process, and the shim is what
    # keeps the jail's host-IO binding across the exec). Declared-but-
    # absent is exit 78 at boot — a missing shim fails the build here,
    # never the boot.
    def deploy_preload(tree)
      src = @link_unit.preload_shim_path(@link_unit_dir)
      unless src && File.file?(src)
        raise TebakoJuliaBuilder::Error.new(
          "no preload shim in the link unit at #{@link_unit_dir} — the image cannot declare " \
          "what it does not hold (the boot refuses such an image with exit 78)", 131
        )
      end

      dest = File.join(tree, "lib", "tebako")
      FileUtils.mkdir_p(dest)
      FileUtils.cp(src, File.join(dest, File.basename(src)))
      puts "   ... preload shim: #{File.join(dest, File.basename(src))}"
    end

    def deploy_layout(tree)
      path = File.join(tree, LAYOUT_PATH)
      FileUtils.mkdir_p(File.dirname(path))
      declaration = LAYOUT_DECLARATION.merge(
        "mount_root" => @platform.mount_root,
        "interpreter_api_version" => @julia.api_version,
        "interpreter" => @platform.msys? ? INTERPRETER_WINDOWS : INTERPRETER,
        "visibility" => "exec-cache"
      )
      # The preload grant exists only where the shim does (POSIX): a
      # windows image declaring it would fail the boot's layout pair
      # check (declared-but-absent is exit 78).
      if @platform.posix?
        declaration["preload_shim"] = File.join("lib", "tebako", @link_unit.preload_shim_name)
      end
      File.write(path, YAML.dump(declaration))
      puts "   ... env image layout declaration: #{path}"
    end

    def deploy_manifest(tree)
      path = TebakoJuliaBuilder::ImageManifest.new(platform: @platform,
                                                   julia_version: @julia.julia_version,
                                                   tebako_version: @tebako_version,
                                                   src_sha256: @src_sha256).deploy(tree)
      puts "   ... env image payload manifest: #{path}"
    end
  end
end
