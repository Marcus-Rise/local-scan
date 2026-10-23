#!/bin/zsh
set -eu
cd "${0:A:h}"
mkdir -p .build-cache
xcrun swiftc -target arm64-apple-macosx14.0 -module-cache-path .build-cache Sources/ScannerCore.swift Tests/CoreTests.swift -o .build-cache/core-tests
.build-cache/core-tests "$@"
