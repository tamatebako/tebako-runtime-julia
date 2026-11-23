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

require "yaml"

module TebakoJuliaBuilder
  # contract.yml — the factory's pin/catalog SSOT (repo AGENTS.md). The
  # build entry points read their defaults from here; an EMPTY pin fails
  # closed by name (a pin the schema requires but the value has not been
  # opened yet is a config state, never a silent skip).
  #
  # There is no source_release pin: julia has no tamatebako source
  # factory (the repack arm consumes julialang.org's official prebuilt
  # archives) — the source pins live in versions.yml (url + sha256 per
  # version per triplet), which this class also loads. The conditional
  # pins of the php schema (macos_deployment_target, release_tooling)
  # arrive with their leg/increment classes — no decorative keys.
  class Contract
    PATH = File.expand_path("../../../contract.yml", __dir__).freeze
    VERSIONS_YML = File.expand_path("../../../versions.yml", __dir__).freeze

    def initialize(path = PATH, versions_path = VERSIONS_YML)
      @path = path
      @data = YAML.load_file(path)
      unless @data.is_a?(Hash)
        raise TebakoJuliaBuilder::Error.new("#{path} is not a YAML mapping (schema: schema/contract.schema.yml)", 64)
      end
      @versions_path = versions_path
    end

    def contract_version
      pin("contract_version")
    end

    # The tamatebako/tebako release pin whose prebuilt link unit (the
    # preload shim), runtime launcher, and tfs CLI the legs consume.
    def link_unit_release
      nonempty_pin("link_unit_release")
    end

    def catalog
      sets = @data.fetch("julia") do
        raise TebakoJuliaBuilder::Error.new("#{@path} carries no julia: catalog", 64)
      end
      sets.fetch("catalog") do
        raise TebakoJuliaBuilder::Error.new("#{@path} julia: carries no catalog key", 64)
      end
    end

    # The source pin for one (julia version, spec 03 triplet) from
    # versions.yml ({url, sha256}); a catalog version with no pin, or a
    # version with no source for THIS leg's triplet, is a config bug,
    # named here (the schema/check_contract cross-locks the two files,
    # so this never silently mis-builds).
    def source_pin(julia_version, triplet)
      pins = YAML.load_file(@versions_path)
      entry = pins.is_a?(Hash) && pins["versions"].is_a?(Hash) ? pins["versions"][julia_version] : nil
      sources = entry.is_a?(Hash) ? entry["sources"] : nil
      pin = sources.is_a?(Hash) ? sources[triplet] : nil
      unless pin.is_a?(Hash) && pin["url"].is_a?(String) && pin["sha256"].is_a?(String)
        raise TebakoJuliaBuilder::Error.new(
          "#{@versions_path} carries no url/sha256 pin for julia #{julia_version} on #{triplet} — " \
          "every catalog version needs a source pin per built triplet", 64
        )
      end
      pin
    end

    private

    def pin(key)
      @data.fetch(key) do
        raise TebakoJuliaBuilder::Error.new("#{@path} carries no #{key} pin", 64)
      end
    end

    def nonempty_pin(key)
      value = pin(key).to_s
      return value unless value.empty?

      raise TebakoJuliaBuilder::Error.new(
        "#{@path} pin #{key} is empty — the release it names has not been published/opened yet " \
        "(build legs fail closed on an empty pin)", 64
      )
    end
  end
end
