#!/usr/bin/env bash
# Compiles the rialto command line to a native executable, build/rialto.
# `dart run` compiles the command line on every start (about 9 s); the executable starts at once, which matters for
# tools/conformance.py in rialto-spec, which starts it once per test contract.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
mkdir -p "$root/build"
dart compile exe "$root/packages/rialto_cli/bin/rialto.dart" -o "$root/build/rialto" >/dev/null
echo "$root/build/rialto"
