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
  # The tebako-runtime-launcher exe (the spec-29 wrapper) as a build-time
  # input: the pair's EXE artifact — the tebako-owned process entry point
  # for every runtime tebako does not compile from source (spec 29 §0).
  # Consumed from the SAME tamatebako/tebako release pin as the link unit
  # and the tfs CLI (one product release carries all three), verified
  # against its published `<asset>.sha256` sidecar — the store
  # trust-anchor shape ("<sha256>  <filename>\n"). The shipped exe stays
  # BYTE-IDENTICAL with the release asset (prebuilt artifacts flow
  # downward); the provenance gate re-proves the bytes against the
  # digest recorded in the package's .contract.yaml card.
  class Launcher
    REPO = "tamatebako/tebako"

    def initialize(cache_dir:, release:, platform:)
      @cache_dir = cache_dir
      @release = release
      @platform = platform
    end

    def asset_name
      "tebako-runtime-launcher-#{@release.sub(/\Av/, "")}-#{@platform.host_id}#{@platform.exe_suffix}"
    end

    # Fetch + verify + return [path, expected_sha256]; cached by its
    # sha256. The expected value is the release-published digest — the
    # Builder records it in the .contract.yaml card so the provenance
    # gate can re-prove the shipped exe against it.
    def fetch
      expected = expected_sha256
      dest = File.join(@cache_dir, "launcher", expected, asset_name)
      if File.file?(dest) && TebakoJuliaBuilder::BuildHelpers.sha256_file(dest) == expected
        FileUtils.chmod(0o755, dest)
        return [dest, expected]
      end

      FileUtils.rm_f(dest)
      url = "https://github.com/#{REPO}/releases/download/#{@release}/#{asset_name}"
      TebakoJuliaBuilder::BuildHelpers.download(url, dest, code: 126)
      actual = TebakoJuliaBuilder::BuildHelpers.sha256_file(dest)
      unless actual == expected
        FileUtils.rm_f(dest)
        raise TebakoJuliaBuilder::Error.new(
          "#{asset_name}: expected SHA256 #{expected} (the published .sha256 sidecar), got #{actual}; " \
          "download deleted", 126
        )
      end

      FileUtils.chmod(0o755, dest)
      puts "-- Runtime launcher #{asset_name} verified (sha256 #{expected})"
      [dest, expected]
    end

    private

    # The sidecar asset's declared sha256 for the launcher asset —
    # fetched from the release and parsed in the trust-anchor grammar.
    def expected_sha256
      sidecar = "#{asset_name}.sha256"
      cached = File.join(@cache_dir, "launcher", sidecar)
      unless File.file?(cached)
        url = "https://github.com/#{REPO}/releases/download/#{@release}/#{sidecar}"
        TebakoJuliaBuilder::BuildHelpers.download(url, cached, code: 126)
      end
      sha256, file = File.read(cached).strip.split(/\s+/, 2)
      unless sha256 =~ /\A[0-9a-f]{64}\z/ && file == asset_name
        FileUtils.rm_f(cached)
        raise TebakoJuliaBuilder::Error.new(
          "#{sidecar}: not a trust-anchor sidecar for #{asset_name} (got #{File.read(cached).inspect})", 126
        )
      end
      sha256
    end
  end
end
