#!/usr/bin/env bash
# Baut/testet VYRAKit unter Linux gegen das lokal gebaute llama.cpp b7380 (siehe linux-test-setup.sh).
# Aufruf: scripts/linux-swift.sh build|test [weitere swift-Argumente]
set -euo pipefail
DEPS="${VYRA_DEPS:-$HOME/vyra-test-deps}"
L="$DEPS/llama.cpp"
cd "$(dirname "$0")/../VYRAKit"
cmd="$1"; shift
export LD_LIBRARY_PATH="$L/build/bin:${LD_LIBRARY_PATH:-}"
extra=(); [ "$cmd" = test ] && extra=(--enable-xctest --disable-swift-testing)
exec swift "$cmd" "${extra[@]}" -Xcc -I"$L/include" -Xcc -I"$L/ggml/include" -Xlinker -L"$L/build/bin" -Xlinker -rpath -Xlinker "$L/build/bin" "$@"
