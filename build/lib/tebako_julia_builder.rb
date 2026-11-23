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

# Tebako julia runtime builder (tebako-runtime-julia)
#
# Build tooling that produces tebako julia runtime packages from the
# OFFICIAL PREBUILT julia binaries published by julialang.org
# (julia-<version>-<platform>.tar.gz, verified against the sha256 pins in
# versions.yml — the repack arm of docs/factory-template.md §1: no
# compilation anywhere in this factory). The driver rides the pair as the
# spec-29 WRAPPER: the exe artifact is the product's
# tebako-runtime-launcher (consumed sha256-verified from the pinned
# tamatebako/tebako release), and the env image declares the interpreter
# + visibility the launcher's boot tail honors. This is the
# tebako-runtime-php build/lib port, julia/repack edition.
module TebakoJuliaBuilder
  # Autoloads use absolute paths so the library loads regardless of the
  # caller's $LOAD_PATH.
  autoload :BuildHelpers,   File.expand_path("tebako_julia_builder/build_helpers", __dir__)
  autoload :Builder,        File.expand_path("tebako_julia_builder/builder", __dir__)
  autoload :Contract,       File.expand_path("tebako_julia_builder/contract", __dir__)
  autoload :Error,          File.expand_path("tebako_julia_builder/error", __dir__)
  autoload :ImageBuilder,   File.expand_path("tebako_julia_builder/image_builder", __dir__)
  autoload :ImageManifest,  File.expand_path("tebako_julia_builder/image_manifest", __dir__)
  autoload :ImagePackager,  File.expand_path("tebako_julia_builder/image_packager", __dir__)
  autoload :JuliaVersion,   File.expand_path("tebako_julia_builder/julia_version", __dir__)
  autoload :Launcher,       File.expand_path("tebako_julia_builder/launcher", __dir__)
  autoload :LinkUnit,       File.expand_path("tebako_julia_builder/link_unit", __dir__)
  autoload :Platform,       File.expand_path("tebako_julia_builder/platform", __dir__)
  autoload :SourceFetcher,  File.expand_path("tebako_julia_builder/source_fetcher", __dir__)
  autoload :TfsTool,        File.expand_path("tebako_julia_builder/tfs_tool", __dir__)
  autoload :TreeStager,     File.expand_path("tebako_julia_builder/tree_stager", __dir__)
end
