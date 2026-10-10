#!/bin/bash
# Запускает тесты. В Xcode флаги не нужны; без Xcode (только Command Line Tools)
# swift-testing лежит отдельно, и его надо подключить вручную.
set -euo pipefail
cd "$(dirname "$0")/.."

if xcode-select -p | grep -q CommandLineTools; then
    F=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
    exec swift test \
        -Xswiftc -F -Xswiftc "$F" \
        -Xswiftc -Xfrontend -Xswiftc -disable-cross-import-overlays \
        -Xlinker -F -Xlinker "$F" -Xlinker -rpath -Xlinker "$F" "$@"
fi
exec swift test "$@"
