#!/bin/bash
# Exercise the production app audio controller with memory-only audio and time.
set -euo pipefail
cd "$(dirname "$0")/.."
audio_test_directory="$(mktemp -d "${TMPDIR:-/tmp}/mx-ergo-audio-tests.XXXXXX")"
trap 'rm -rf "$audio_test_directory"' EXIT

# This source is the controller's only Core dependency. Building it under its
# real module name avoids altering production imports or adding package edges.
swiftc -swift-version 6 -module-cache-path "$audio_test_directory/module-cache" \
    -emit-library -emit-module -module-name MXErgoCore \
    Packages/MXErgoKit/Sources/MXErgoCore/VolumeRampAccumulator.swift \
    -emit-module-path "$audio_test_directory/MXErgoCore.swiftmodule" \
    -o "$audio_test_directory/libMXErgoCore.dylib"
swiftc -swift-version 6 -module-cache-path "$audio_test_directory/module-cache" \
    -parse-as-library \
    -I "$audio_test_directory" -L "$audio_test_directory" -lMXErgoCore \
    -Xlinker -rpath -Xlinker "$audio_test_directory" \
    App/AudioExecutionStatus.swift App/SystemAudioController.swift \
    Tests/AppAudioRegression.swift -o "$audio_test_directory/app-audio-regression"
"$audio_test_directory/app-audio-regression"
