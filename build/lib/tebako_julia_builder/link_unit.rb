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

module TebakoJuliaBuilder
  # The PUBLISHED link unit (a tamatebako/tebako release asset), consumed
  # by the repack arm for exactly one file: the POSIX preload shim
  # (libtfs_preload.{so,dylib}), staged into the env image so the jail's
  # host-IO binding survives the exec into the interpreter (spec 22 §3
  # rules E2/E3 — the openjdk factory's consumption, tebako-runtime-php's
  # LinkUnit trust anchor). WINDOWS LEGS STAGE NOTHING: the link-unit
  # tarball carries no windows preload tier (its remaining contents are
  # link-time inputs, and a repack factory never links), so the Builder
  # never calls #stage there — verified-but-unconsumed bytes would be
  # decorative provenance (spec 00 §9). The driver link itself is NOT
  # this factory's to compose: the pair's exe is the shipped
  # tebako-runtime-launcher (Launcher), and a repack factory never
  # compiles.
  #
  # Trust anchor: the GitHub release API's per-asset `digest` field — the
  # release SHA256SUMS does NOT cover the link-unit assets. A checksum
  # MISMATCH is a hard error (124), never a silent fallback — bytes that
  # disagree with the API are a supply-chain event. A pin MISS (the
  # release ships no unit for this platform) is a named error too (123):
  # this factory has no source-build path for the driver stack.
  class LinkUnit
    REPO = "tamatebako/tebako"

    def initialize(cache_dir:, release:, platform:, pid: nil)
      @cache_dir = cache_dir
      @release = release
      @platform = platform
      @pid = pid || platform.link_unit_pid
    end

    def asset_name
      "link-unit-#{@release.sub(/\Av/, "")}-#{@pid}.tar.gz"
    end

    # Download + verify + extract the unit into dest; returns dest.
    # Idempotent: a dest whose marker names this asset's verified sha256
    # is reused as-is. POSIX only — a windows leg has no consumption
    # (the class comment); calling #stage there is a config bug.
    def stage(dest)
      if @platform.msys?
        raise TebakoJuliaBuilder::Error.new(
          "the link unit is POSIX-only consumption (the preload shim) — the windows leg stages " \
          "nothing (Builder gates the call); being here is a config bug", 123
        )
      end

      expected = expected_digest
      marker = File.join(dest, ".sha256")
      if File.file?(marker) && File.read(marker).strip == expected && complete?(dest)
        puts "-- Link unit #{asset_name} already staged (sha256 #{expected})"
        return dest
      end

      tarball = File.join(@cache_dir, "link-unit", asset_name)
      unless File.file?(tarball) && TebakoJuliaBuilder::BuildHelpers.sha256_file(tarball) == expected
        FileUtils.rm_f(tarball)
        url = "https://github.com/#{REPO}/releases/download/#{@release}/#{asset_name}"
        TebakoJuliaBuilder::BuildHelpers.download(url, tarball, code: 123)
      end

      actual = TebakoJuliaBuilder::BuildHelpers.sha256_file(tarball)
      unless actual == expected
        FileUtils.rm_f(tarball)
        raise TebakoJuliaBuilder::Error.new(
          "#{asset_name} sha256 mismatch: the #{REPO} #{@release} release API declares #{expected}, " \
          "the download is #{actual} — refusing the unit (never a silent fallback on a " \
          "supply-chain mismatch)", 124
        )
      end

      FileUtils.rm_rf(dest, secure: true)
      FileUtils.mkdir_p(dest)
      TebakoJuliaBuilder::BuildHelpers.run_with_capture(["tar", "-xzf", tarball, "-C", dest, "--strip-components=1"])
      assert_complete!(dest)
      File.write(marker, "#{expected}\n")
      puts "-- Link unit #{asset_name} verified (sha256 #{expected}) and staged at #{dest}"
      dest
    end

    # The preload shim's staged path (POSIX only; nil on windows — no
    # preload tier there).
    def preload_shim_path(dir)
      name = preload_shim_name
      name && File.join(dir, name)
    end

    def preload_shim_name
      return nil if @platform.msys?

      @platform.macos? ? "libtfs_preload.dylib" : "libtfs_preload.so"
    end

    private

    def expected_digest
      digests = TebakoJuliaBuilder::BuildHelpers.release_asset_digests(REPO, @release, code: 123)
      digests.fetch(asset_name) do
        raise TebakoJuliaBuilder::Error.new(
          "no published #{asset_name} on #{REPO} release #{@release} — the pinned link unit does not " \
          "cover #{@pid} (a source-build fallback is the follow-up; never a silent one)", 123
        )
      end
    end

    def complete?(dir)
      !preload_shim_name.nil? && File.size?(File.join(dir, preload_shim_name))
    end

    def assert_complete!(dir)
      return if preload_shim_name && File.size?(File.join(dir, preload_shim_name))

      raise TebakoJuliaBuilder::Error.new(
        "downloaded link unit #{asset_name} lacks #{preload_shim_name} — the env image cannot " \
        "declare what it does not hold (the preload grant the jail binding rides, README)", 124
      )
    end
  end
end
