#!/bin/sh
# Wrapper for `swift test` in environments with only Xcode Command Line Tools
# installed (no full Xcode, no XCTest.framework). Swift Testing's
# Testing.framework lives outside the default framework/library search
# paths in that configuration, so we add explicit -F/-rpath flags.
#
# Usage: ./swift-test.sh --filter DatabaseManagerTests
exec swift test \
  -Xswiftc -F -Xswiftc /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/Frameworks \
  -Xlinker -rpath -Xlinker /Library/Developer/CommandLineTools/Library/Developer/usr/lib \
  "$@"
