#!/bin/bash
# Kompiliert und zeigt jede Fehlermeldung nur einmal.
cd "$(dirname "$0")/.." && VYRA_DEPS=${VYRA_DEPS:-/home/claude/deps} scripts/linux-swift.sh ${1:-build} 2>&1 | grep -E "^/.*(error|warning: (var|init|imm|will never))" | sort -u | head -${2:-60}
