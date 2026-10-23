#!/usr/bin/env bash
# Richtet eine Linux-Testumgebung (Ubuntu 24.04) fuer die automatischen Tests des VYRA-KI-Kerns ein:
# Swift 6.0.3 aus dem Ubuntu-Archiv und llama.cpp b7380 (dieselbe Version wie VYRA unter Windows und das iOS-xcframework).
# Nur fuer Tests – die iPhone-App wird auf macOS (GitHub Actions) gebaut.
set -euo pipefail
WORK="${1:-$HOME/vyra-test-deps}"
mkdir -p "$WORK"
if ! command -v swift >/dev/null 2>&1; then
  if [ ! -f /etc/apt/sources.list.d/ubuntu.sources ] || ! grep -q universe /etc/apt/sources.list.d/ubuntu.sources; then
    cat > /etc/apt/sources.list.d/ubuntu.sources <<'SRC'
Types: deb
URIs: http://archive.ubuntu.com/ubuntu/
Suites: noble noble-updates
Components: main universe
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
SRC
  fi
  apt-get update -qq
  DEBIAN_FRONTEND=noninteractive apt-get install -y -qq libedit2 libncurses6 libsqlite3-0 libcurl4t64 binutils gcc libstdc++-13-dev libzstd1 uuid-dev zlib1g-dev cmake >/dev/null
  cd "$WORK"
  for f in universe/s/swiftlang/swiftlang_6.0.3-2build1_amd64.deb universe/s/swiftlang/libswiftlang_6.0.3-2build1_amd64.deb main/libx/libxml2/libxml2-16_2.14.5+dfsg-0.2_amd64.deb; do
    [ -f "$(basename "$f")" ] || curl -sSfO "http://archive.ubuntu.com/ubuntu/pool/$f"
  done
  dpkg -i libxml2-16_2.14.5+dfsg-0.2_amd64.deb >/dev/null
  dpkg -i --force-depends libswiftlang_6.0.3-2build1_amd64.deb swiftlang_6.0.3-2build1_amd64.deb >/dev/null
fi
swift --version | head -1
if [ ! -f "$WORK/llama.cpp/build/bin/libllama.so" ]; then
  cd "$WORK"
  [ -d llama.cpp ] || git clone -q --depth 1 --branch b7380 https://github.com/ggml-org/llama.cpp llama.cpp
  cmake -S llama.cpp -B llama.cpp/build -DBUILD_SHARED_LIBS=ON -DLLAMA_CURL=OFF -DGGML_NATIVE=ON -DLLAMA_BUILD_TESTS=OFF -DLLAMA_BUILD_EXAMPLES=OFF -DLLAMA_BUILD_SERVER=OFF -DLLAMA_BUILD_TOOLS=OFF -DCMAKE_BUILD_TYPE=Release >/dev/null
  cmake --build llama.cpp/build -j"$(nproc)" --target llama >/dev/null
fi
echo "llama.cpp: $WORK/llama.cpp (b7380)"
