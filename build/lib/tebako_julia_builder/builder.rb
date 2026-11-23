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
  # End-to-end runtime package build (tools/build_runtime): fetch +
  # verify the official prebuilt julia archive (sha256 against
  # versions.yml's pins — the repack arm: no compilation), stage the
  # pin-verified link unit (POSIX — for the preload shim; windows has
  # no preload tier and stages nothing), the runtime launcher, and
  # the tfs CLI (all from the pinned tamatebako/tebako release), stage +
  # prune the julia tree, assemble + pack the env image
  # (ImageBuilder/ImagePackager), and emit the pair with its sidecars
  # (the store-shape .sha256 for both artifacts, the era-2
  # .contract.yaml provenance card the publish increment folds into
  # the manifest entry).
  class Builder
    # The era-2 contract card constants (spec 18 C2): what this factory
    # builds. Written into every package's .contract.yaml sidecar.
    CONTRACT_CARD = { "contract_era" => 2, "image_layout" => 1 }.freeze

    # The package name carries tebako#716's language segment from this
    # factory's FIRST line — tebako-runtime-<tebako>-julia-<jv>-<triplet>
    # — with no era gate: a factory born after the flip composes the
    # segment always (the tebako-runtime-php Builder rationale; the era
    # gate exists only for factories with immutable pre-#716 lines, and
    # julia has none).
    LANG_SEGMENT = "julia"

    def initialize(repo_root:, julia_version:, tebako_version:, prefix:, output:,
                   src_mirror: nil, link_unit_release: nil, link_unit_pid: nil, arch: nil)
      @repo_root = repo_root
      @julia_version = julia_version
      @julia = TebakoJuliaBuilder::JuliaVersion.new(julia_version)
      @tebako_version = tebako_version
      @prefix = File.expand_path(prefix)
      @output = output
      @contract = TebakoJuliaBuilder::Contract.new
      @src_mirror = src_mirror
      @link_unit_release = link_unit_release || @contract.link_unit_release
      @link_unit_pid = link_unit_pid
      # The leg's DECLARED arch beats the tooling process's self-report:
      # under emulation host_cpu can lie, and every arch-keyed decision
      # (the link-unit pid, the package name) follows the lie.
      @platform = arch ? TebakoJuliaBuilder::Platform.new(RUBY_PLATFORM, arch) : TebakoJuliaBuilder::Platform.new
    end

    def run
      (tarball, sha256) = fetcher.fetch(@julia.base_version, @platform.tpkg_triplet)
      puts "-- Building tebako runtime for julia #{@julia_version} " \
           "(tebako #{@tebako_version}, #{@platform.host_id}, #{File.basename(tarball)})"
      # The link unit's only repack consumption is the POSIX preload
      # shim (LinkUnit's class comment) — windows stages nothing.
      link_unit_dir = @platform.posix? ? link_unit.stage(File.join(@prefix, "link-unit")) : nil
      (launcher_path, launcher_sha256) = launcher.fetch
      tfs = tfs_tool.fetch
      staged = TebakoJuliaBuilder::TreeStager.new(prefix: @prefix, tarball: tarball, src_sha256: sha256,
                                                  julia_version: @julia.base_version,
                                                  triplet: @platform.tpkg_triplet,
                                                  platform: @platform).stage
      finalize(launcher_path)
      assemble_and_pack_image(staged, sha256, link_unit, link_unit_dir, tfs)
      write_sidecars(launcher_sha256)
      write_contract_sidecar(tarball, sha256, link_unit, launcher, launcher_sha256)
      @output = output
      puts "-- Runtime package: #{output}"
      puts "-- Runtime env image: #{image_output}"
      output
    end

    def default_output
      File.join(Dir.pwd, "runtime-packages",
                "tebako-runtime-#{@tebako_version}-#{LANG_SEGMENT}-#{@julia_version}-#{@platform.host_id}#{@platform.exe_suffix}")
    end

    # The standalone runtime filesystem image published next to the
    # runtime executable (the image era's only filesystem image).
    def image_output
      "#{output.sub(/\.exe\z/, "")}.tfs"
    end

    private

    def output
      @output ||= default_output
    end

    def fetcher
      @fetcher ||= TebakoJuliaBuilder::SourceFetcher.new(cache_dir: File.join(@prefix, "downloads"),
                                                         contract: @contract, mirror: @src_mirror)
    end

    def link_unit
      @link_unit ||= TebakoJuliaBuilder::LinkUnit.new(release: @link_unit_release, platform: @platform,
                                                      pid: @link_unit_pid,
                                                      cache_dir: File.join(@prefix, "downloads"))
    end

    def launcher
      @launcher ||= TebakoJuliaBuilder::Launcher.new(release: @link_unit_release, platform: @platform,
                                                     cache_dir: File.join(@prefix, "downloads"))
    end

    def tfs_tool
      @tfs_tool ||= TebakoJuliaBuilder::TfsTool.new(release: @link_unit_release, platform: @platform,
                                                    cache_dir: File.join(@prefix, "downloads"))
    end

    # The shipped exe is the pin-verified tebako-runtime-launcher,
    # copied BYTE-IDENTICAL (the repack arm: prebuilt artifacts flow
    # downward — the provenance gate re-proves the bytes against the
    # release-published digest recorded in the contract card).
    def finalize(launcher_path)
      FileUtils.mkdir_p(File.dirname(output))
      FileUtils.cp(launcher_path, output)
      FileUtils.chmod(0o755, output)
    end

    def assemble_and_pack_image(staged, sha256, link_unit, link_unit_dir, tfs)
      tree = TebakoJuliaBuilder::ImageBuilder.new(platform: @platform, julia_version: @julia_version,
                                                  tebako_version: @tebako_version, src_sha256: sha256,
                                                  link_unit: link_unit, link_unit_dir: link_unit_dir)
                                             .assemble(staged, File.join(@prefix, "image-tree"))
      TebakoJuliaBuilder::ImagePackager.new(@platform, tfs: tfs).package(tree, image_output)
    end

    # The store-layout trust markers next to BOTH artifacts (the store:
    # every cached runtime artifact carries its .sha256 sidecar): the
    # image sidecar's leading token is the content key the driver's
    # exec-cache segregation (spec 22 §6) reads, so a factory tree boots
    # store-faithfully; the exe sidecar is the pair's byte anchor
    # (spec 13 §2a's write-once names, ready for the publish increment).
    def write_sidecars(launcher_sha256)
      image_hex = TebakoJuliaBuilder::BuildHelpers.sha256_file(image_output)
      File.write("#{image_output}.sha256", "#{image_hex}  #{File.basename(image_output)}\n")
      File.write("#{output}.sha256", "#{launcher_sha256}  #{File.basename(output)}\n")
    end

    # The era-2 contract provenance (spec 18 C2) as
    # `<output>.contract.yaml`. built_from names the consumed archive
    # with its verified sha256 and the pin file that anchored it (the
    # repack arm records NO cflags — the bytes are upstream's; the boot
    # smoke's compute-floor therefore carries no flags arm, only the
    # timing tripwire); the additive link_unit block names the consumed
    # product release's assets, including the launcher's
    # release-published digest (the provenance gate's byte anchor —
    # open parse: consumers that predate the key ignore it). The
    # link-unit tarball itself is named only where it was staged
    # (POSIX — the preload shim; windows consumes nothing from it, and
    # a card naming unconsumed bytes would be decorative provenance).
    def write_contract_sidecar(tarball, sha256, link_unit, launcher, launcher_sha256)
      link_unit_block = {
        "release" => @link_unit_release,
        "launcher" => launcher.asset_name,
        "launcher_sha256" => launcher_sha256
      }
      link_unit_block["asset"] = link_unit.asset_name if @platform.posix?
      card = CONTRACT_CARD.merge(
        "mount_root" => @platform.mount_root,
        "built_from" => {
          "pin" => "versions.yml",
          "sources" => [{ "name" => File.basename(tarball), "sha256" => sha256 }]
        },
        "link_unit" => link_unit_block
      )
      File.write("#{output.sub(/\.exe\z/, "")}.contract.yaml", YAML.dump(card))
    end
  end
end
