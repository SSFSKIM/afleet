#!/bin/sh
# Fetches the pinned Agent SDK package (all rights reserved: never committed) into .typings/ for the drift test.
set -eu
cd "$(dirname "$0")/.."
VERSION="${1:-0.3.259}"
mkdir -p .typings
rm -rf .typings/package
npm pack "@anthropic-ai/claude-agent-sdk@${VERSION}" --pack-destination .typings >/dev/null
tar xzf ".typings/anthropic-ai-claude-agent-sdk-${VERSION}.tgz" -C .typings
test -f .typings/package/sdk.d.ts && echo "typings ${VERSION} at .typings/package/sdk.d.ts"
