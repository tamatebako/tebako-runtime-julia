#!/usr/bin/env ruby
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

# Compute the build-leg matrix for _build-platform.yml: the julia set
# (resolved from contract.yml — the same read scripts/versions performs)
# x the env vocabulary (.github/matrix.json — tebako-runtime-php's
# grammar), sliced by the dispatch filters. Emits a GitHub Actions
# matrix JSON document on stdout. Stdlib only.
#
# Usage: compute_matrix.rb [--format matrix|env|julias]
#   matrix  (default) the GHA matrix document {"include": [leg, ...]} —
#           extra top-level keys are impossible (GHA would read them as
#           matrix variables), so the other two forms exist
#   env     the selected matrix.json rows as a JSON array (each + host_id)
#           — the publish increment's EXPECTED_ENV_MATRIX
#   julias  the selected julia versions as a JSON array — the publish
#           increment's EXPECTED_JULIA_MATRIX
#
# Filters (env vars, mirroring the other factories' dispatch grammar):
#   JULIA_FILTER     full | tidy | catalog | comma-separated versions (default: full)
#   PLATFORM_FILTER  all | linux-gnu | linux-musl | macos | windows      (default: all)
#   ARCH_FILTER      all | x86_64 | arm64                                (default: all)
#
# Every leg carries:
#   julia / os / arch / host  — the matrix coordinates
#   host_id                   — this factory's package-name platform id
#                               (Platform::HOST_IDS — the exe/image
#                               grammar tebako-runtime-<ver>-julia-<jv>-<host_id>)
#   container                 — the tpkg-builder image ref with
#                               contract.yml's container_version tag
#                               applied, null for runner-native legs (none
#                               today — the skeleton's only leg is
#                               containerized; a macos increment adds its
#                               runner-native row to matrix.json)
#   link_unit_pid             — the product release's platform id for the
#                               link-unit/launcher/tfs asset names
#                               (Platform::LINK_UNIT_PIDS)
#
# Named errors, exit 64: an unknown platform/arch filter, an unknown
# --format, or a matrix.json row outside the known vocabulary is a config
# bug, never a skipped leg.

require "json"
require "yaml"

REPO_ROOT = File.expand_path("..", __dir__).freeze
$LOAD_PATH.unshift(File.join(REPO_ROOT, "build", "lib"))

require "tebako_julia_builder"

CONTRACT_YML = File.join(REPO_ROOT, "contract.yml").freeze
MATRIX_JSON = File.join(REPO_ROOT, ".github", "matrix.json").freeze

PLATFORMS = %w[linux-gnu linux-musl macos windows].freeze
ARCHES = %w[x86_64 arm64].freeze

def usage_error(message)
  warn "compute_matrix: #{message}"
  exit 64
end

format = "matrix"
if (idx = ARGV.index("--format"))
  format = ARGV[idx + 1].to_s
  usage_error "--format expects matrix | env | julias" unless %w[matrix env julias].include?(format)
elsif !ARGV.empty?
  usage_error "unknown argument(s): #{ARGV.join(', ')} (the only option is --format matrix|env|julias)"
end

contract = YAML.load_file(CONTRACT_YML)
julia_sets = contract.fetch("julia") { usage_error "#{CONTRACT_YML} carries no julia: catalog" }
catalog = julia_sets.fetch("catalog") { usage_error "#{CONTRACT_YML} julia: carries no catalog key" }
container_version = contract.fetch("container_version") do
  usage_error "#{CONTRACT_YML} carries no container_version pin"
end

julia_filter = ENV.fetch("JULIA_FILTER", "full")
julias =
  case julia_filter
  when "full", "tidy", "catalog"
    julia_sets.fetch(julia_filter) { usage_error "#{CONTRACT_YML} julia: carries no #{julia_filter} set" }
  when ""
    usage_error "JULIA_FILTER is empty — expected full | tidy | catalog | a comma-separated version list"
  else
    versions = julia_filter.split(",").map(&:strip).reject(&:empty?)
    unknown = versions - catalog
    usage_error "unknown julia version(s) #{unknown.join(', ')} — catalog knows: #{catalog.join(', ')}" unless unknown.empty?
    versions
  end

platform_filter = ENV.fetch("PLATFORM_FILTER", "all")
unless platform_filter == "all" || PLATFORMS.include?(platform_filter)
  usage_error "unknown platform #{platform_filter.inspect} — expected all | #{PLATFORMS.join(' | ')}"
end

arch_filter = ENV.fetch("ARCH_FILTER", "all")
unless arch_filter == "all" || ARCHES.include?(arch_filter)
  usage_error "unknown arch #{arch_filter.inspect} — expected all | #{ARCHES.join(' | ')}"
end

env = JSON.parse(File.read(MATRIX_JSON)).fetch("env")

legs = []
selected_env = []
env.each do |row|
  os = row.fetch("os")
  arch = row.fetch("arch")
  host_id = TebakoJuliaBuilder::Platform.host_id_for(os, arch)
  link_unit_pid = TebakoJuliaBuilder::Platform.link_unit_pid_for(os, arch)
  next unless platform_filter == "all" || platform_filter == os
  next unless arch_filter == "all" || arch_filter == arch

  container = row["container"] && "#{row['container']}:#{container_version}"
  env_admitted = false
  julias.each do |julia|
    # The line grammar is validated at the contract gate; the planner
    # re-validates so a catalog drift fails HERE (exit 64), never mid-leg.
    begin
      TebakoJuliaBuilder::JuliaVersion.new(julia)
    rescue TebakoJuliaBuilder::Error => e
      usage_error "catalog line #{julia.inspect}: #{e.message}"
    end
    legs << {
      julia: julia,
      os: os,
      arch: arch,
      host: row.fetch("host"),
      host_id: host_id,
      container: container,
      link_unit_pid: link_unit_pid
    }
    # The env row joins the expectations only when the row EMITTED a leg:
    # the publish increment's audit reads EXPECTED_ENV_MATRIX x
    # EXPECTED_JULIA_MATRIX, so a gated row must not survive into env.
    # matrix/env/julias all derive from the same filtered walk.
    unless env_admitted
      selected_env << row.merge("host_id" => host_id)
      env_admitted = true
    end
  end
end

case format
when "matrix" then puts JSON.generate({ include: legs })
when "env" then puts JSON.generate(selected_env)
when "julias" then puts JSON.generate(julias.select { |julia| legs.any? { |leg| leg[:julia] == julia } })
end
