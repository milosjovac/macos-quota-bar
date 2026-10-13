#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
if [[ -n "${DEVELOPER_DIR:-}" ]]; then
  developer_dir="$DEVELOPER_DIR"
else
  developer_dir="$(/usr/bin/xcode-select -p)"
fi
swiftc="$developer_dir/Toolchains/XcodeDefault.xctoolchain/usr/bin/swiftc"
sdk="$developer_dir/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
if [[ ! -x "$swiftc" ]]; then
  swiftc="$developer_dir/usr/bin/swiftc"
  sdk="$developer_dir/SDKs/MacOSX.sdk"
fi
app="build/Codex Quota.app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources"
"$swiftc" -swift-version 5 -O -sdk "$sdk" -target "$(uname -m)-apple-macosx13.0" Sources/*.swift -o "$app/Contents/MacOS/CodexQuota"
cp Info.plist "$app/Contents/Info.plist"
cp Resources/*.svg "$app/Contents/Resources/"
rm -f "$app/Contents/Resources/Codex.png" "$app/Contents/Resources/Codex.svg"
/usr/bin/codesign --force --sign - "$app"
printf 'Built %s/%s\n' "$PWD" "$app"
if [[ "${1:-}" == "--test" ]]; then
  "$swiftc" -swift-version 5 -sdk "$sdk" -target "$(uname -m)-apple-macosx13.0" Sources/Quota.swift Tests/QuotaTests.swift -o build/QuotaTests
  build/QuotaTests
  "$swiftc" -swift-version 5 -sdk "$sdk" -target "$(uname -m)-apple-macosx13.0" Sources/Quota.swift Sources/CodexClient.swift Sources/ClaudeClient.swift Sources/Tools.swift Tests/ToolsTests.swift -o build/ToolsTests
  build/ToolsTests
fi
