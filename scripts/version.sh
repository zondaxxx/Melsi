#!/usr/bin/env bash
# Prints the Melsi version string used for artifact names.
#   tag v1.2.3            -> 1.2.3
#   anything else         -> <pubspec version without +build>-<short sha>
# Usage: scripts/version.sh            (prints version)
#        scripts/version.sh --github   (also writes version=... to $GITHUB_OUTPUT
#                                       and MELSI_VERSION=... to $GITHUB_ENV)
set -euo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

ref="${GITHUB_REF:-}"
if [[ -z "$ref" ]]; then
  ref="$(git -C "$root" describe --tags --exact-match 2>/dev/null | sed 's|^|refs/tags/|' || true)"
fi

if [[ "$ref" == refs/tags/v* ]]; then
  version="${ref#refs/tags/v}"
else
  pub="$(sed -n 's/^version:[[:space:]]*//p' "$root/app/pubspec.yaml" | head -n1 | tr -d "\"' \r")"
  pub="${pub%%+*}"
  [[ -n "$pub" ]] || pub="0.0.0"
  sha="${GITHUB_SHA:-$(git -C "$root" rev-parse HEAD 2>/dev/null || echo unknown)}"
  version="${pub}-${sha:0:7}"
fi

# Extra `flutter build` args: a plain x.y.z tag becomes the build name
# (Windows/Android need numeric versions); CI run number becomes the build
# number so Android versionCode keeps increasing.
build_args=""
if [[ "$ref" == refs/tags/v* && "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
  build_args="--build-name=$version"
fi
if [[ -n "${GITHUB_RUN_NUMBER:-}" ]]; then
  build_args="${build_args:+$build_args }--build-number=$GITHUB_RUN_NUMBER"
fi

if [[ "${1:-}" == "--github" ]]; then
  if [[ -n "${GITHUB_OUTPUT:-}" ]]; then
    echo "version=$version" >> "$GITHUB_OUTPUT"
    echo "build_args=$build_args" >> "$GITHUB_OUTPUT"
  fi
  if [[ -n "${GITHUB_ENV:-}" ]]; then
    echo "MELSI_VERSION=$version" >> "$GITHUB_ENV"
    echo "MELSI_BUILD_ARGS=$build_args" >> "$GITHUB_ENV"
  fi
fi
echo "$version"
