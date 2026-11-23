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
  # Stages the pristine upstream julia tree from the verified prebuilt
  # tarball (the repack arm's "build" — extract, never compile):
  # strip the archive's one nesting directory, dereference in-tree
  # symlinks to plain files (one tree shape on every platform — the
  # openjdk factory's pass; julia's lib/lib*.so → lib*.so.1 →
  # lib*.so.1.x chains keep their name surface with real bytes, which
  # the loader's SONAME lookup needs under the exec-cache mirror), and
  # assert the declared interpreter exists at the declared path. A
  # dangling or tree-escaping symlink is a named build error (exit 131),
  # never a silent surprise in the image.
  class TreeStager
    INTERPRETER_PATH = File.join("bin", "julia").freeze
    INTERPRETER_PATH_WINDOWS = File.join("bin", "julia.exe").freeze

    def initialize(prefix:, tarball:, src_sha256:, julia_version:, triplet:, platform:)
      @prefix = prefix
      @tarball = tarball
      @src_sha256 = src_sha256
      @julia_version = julia_version
      @triplet = triplet
      @platform = platform
    end

    # Extract the tarball into a fresh tree; returns the staged tree's
    # path (the image root's content — its CONTENTS map onto the mount
    # root).
    def stage
      dest = File.join(@prefix, "src", "julia-#{@julia_version}-#{@triplet}")
      marker = "#{dest}.src-sha256"
      if File.directory?(dest) && File.file?(marker) && File.read(marker).strip == @src_sha256
        puts "-- julia tree #{@julia_version} (#{@triplet}) already staged (sha256 #{@src_sha256})"
        return dest
      end

      FileUtils.rm_rf(dest, secure: true)
      FileUtils.mkdir_p(dest)
      # The archive nests julia-<version>/; strip it (the recipe's
      # strip_components=1 — the openjdk factory's repack shape).
      TebakoJuliaBuilder::BuildHelpers.run_with_capture(
        ["tar", "-xzf", @tarball, "-C", dest, "--strip-components=1"]
      )
      assert_interpreter!(dest)
      dereference_symlinks!(dest)
      File.write(marker, "#{@src_sha256}\n")
      puts "-- julia tree staged at #{dest} (#{File.basename(@tarball)}, sha256 #{@src_sha256})"
      dest
    end

    private

    def assert_interpreter!(tree)
      interpreter = @platform.msys? ? INTERPRETER_PATH_WINDOWS : INTERPRETER_PATH
      return if File.file?(File.join(tree, interpreter))

      raise TebakoJuliaBuilder::Error.new(
        "the staged julia tree carries no #{interpreter} — the upstream archive's layout " \
        "drifted from the layout.interpreter declaration (#{interpreter.insert(0, '/')})", 131
      )
    end

    # Every link whose terminal target is a real file INSIDE the staged
    # tree is resolved to a plain file — the name surface stays
    # upstream's, the bytes are the target's. A dangling, looping, or
    # tree-escaping link is a named error (the openjdk factory's
    # discipline — content-addressed drops dedup the duplicated content,
    # and no leg depends on host symlink semantics).
    def dereference_symlinks!(tree)
      count = 0
      Dir.glob(File.join(tree, "**", "*"), File::FNM_DOTMATCH).each do |path|
        next unless File.symlink?(path)

        resolved = resolve_link(path)
        unless resolved && resolved.start_with?("#{tree}/") && File.file?(resolved)
          raise TebakoJuliaBuilder::Error.new(
            "symlink #{path.sub("#{tree}/", "")} dangles, loops, or escapes the payload tree " \
            "(target: #{File.readlink(path)})", 131
          )
        end
        FileUtils.rm(path)
        FileUtils.cp(resolved, path)
        count += 1
      end
      puts "   ... symlinks dereferenced: #{count}"
    end

    # Follows a relative symlink chain to its terminal real file;
    # absolute targets escape the VFS root and read as unresolvable.
    def resolve_link(path, depth = 0)
      return nil if depth > 8
      return path unless File.symlink?(path)

      target = File.readlink(path)
      return nil if target.start_with?("/")

      resolved = File.expand_path(target, File.dirname(path))
      resolve_link(resolved, depth + 1)
    end
  end
end
