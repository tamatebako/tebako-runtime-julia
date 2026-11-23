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

module TebakoJuliaBuilder
  # julia version model (the php factory's PhpVersion analog — the
  # version predicates and the derived name grammar). julia lines are
  # plain x.y.z: no flavor axis exists yet (the builds are upstream's
  # official generic linux binaries; a distinction — e.g. a
  # musl/alpine line — rides the triplet axis, never the version
  # string). The source archives carry their integrity pins in
  # versions.yml (this factory IS the pin owner — julialang.org
  # publishes per-platform builds directly).
  class JuliaVersion
    # The one owner of the line grammar (spec 00 §10): the schema's
    # catalog pattern mirrors it (asserted by the lint gate passing on
    # the same strings), and the tebako-release gem's package-filename
    # parse interpolates LINE_GRAMMAR_SOURCE through this factory's
    # adapter when the publish increment lands — nothing re-derives it.
    # LINE_GRAMMAR_SOURCE stays anchor-free: the gem wraps it in its own
    # \A…\z package-name pattern (uploader.rb's parse_package_filename).
    LINE_GRAMMAR_SOURCE = '\d+\.\d+\.\d+'
    LINE_PATTERN = /\A(?<base>\d+\.\d+\.\d+)\z/.freeze

    def initialize(julia_version)
      @julia_version = julia_version
      parse_line
    end

    attr_reader :julia_version, :base_version

    # The version's major.minor line as integers (1.13 for every 1.13.x),
    # so 2.x lines fall out naturally.
    def major_minor
      @major_minor ||= base_version.split(".").first(2).map(&:to_i)
    end

    # The abi_line the image manifest's provides block declares (spec 03
    # §2.2 — what native-extension payloads match their version constraint
    # against): the "1.13"-style line. Julia has no compile-time ABI
    # probe (its extension surface is the language line), so no .abi
    # sidecar is emitted — the template's §3.7.
    def abi_line
      major_minor.join(".")
    end

    # The interpreter API version the layout card declares (the schema's
    # required interpreter_api_version): julia's "1.13"-style line. The
    # era-2 driver parses but does not gate on it.
    def api_version
      abi_line
    end

    private

    # Parse the line, enforcing the grammar. Named errors, exit 109 — a
    # malformed line is a config bug, never a silently misparsed name.
    def parse_line
      match = LINE_PATTERN.match(@julia_version)
      unless match
        raise TebakoJuliaBuilder::Error.new(
          "Invalid julia version format '#{@julia_version}'. Expected format: x.y.z", 109
        )
      end
      @base_version = match[:base]
    end
  end
end
