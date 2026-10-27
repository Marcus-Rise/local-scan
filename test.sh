#!/bin/zsh
set -eu
cd "${0:A:h}"
mkdir -p .build-cache
xcrun swiftc -target arm64-apple-macosx14.0 -module-cache-path .build-cache Sources/ScannerCore.swift Tests/CoreTests.swift -o .build-cache/core-tests
.build-cache/core-tests "$@"

xcrun swiftc -target arm64-apple-macosx14.0 -module-cache-path .build-cache Sources/ScannerCore.swift Sources/PrinterStore.swift Tests/PrinterStoreTests.swift -o .build-cache/printer-store-tests
.build-cache/printer-store-tests
