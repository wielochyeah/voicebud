#!/bin/zsh
# builds the scratch VoiceBudUI: snapshot sources (minus their main.swift) + onboarding + scratch main
set -e
D=/private/tmp/claude-501/-Users-nilswieloch-Claude/a8d8be99-0e31-401d-b1e7-1bcff4e75700/scratchpad/onboarding
export SDKROOT=/Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk
FILES=($(ls $D/snapshot/*.swift | grep -v '/main.swift$') $D/Onboarding.swift $D/OnboardingRender.swift $D/main.swift)
swiftc -sdk $SDKROOT -swift-version 5 -O -target arm64-apple-macosx15.0 -module-name VoiceBudUI -lsqlite3 "${FILES[@]}" -o $D/build/VoiceBudUI
