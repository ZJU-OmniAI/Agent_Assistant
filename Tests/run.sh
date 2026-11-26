#!/bin/bash
# Runs the backend checks against fake Claude Code and Codex CLIs.
set -euo pipefail
cd "$(dirname "$0")/.."
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/old" "$work/new" "$work/fixture"
for cli in claude codex; do
    cp Tests/fake-cli.py "$work/new/$cli"
    chmod +x "$work/new/$cli"
done
# A stale copy earlier on PATH, like an old npm install.
printf '#!/bin/sh\necho "codex-cli 0.100.0"\nexit 0\n' >"$work/old/codex"
chmod +x "$work/old/codex"
./swiftc.sh -swift-version 5 -parse-as-library Sources/Backend.swift Sources/Subprocess.swift \
    Sources/AssistantView.swift Sources/Latency.swift Tests/BackendChecks.swift -o "$work/checks"
FIXTURE_DIR="$work/fixture" AGENT_ASSISTANT_SKIP_SHELL=1 PATH="$work/old:$work/new:$PATH" "$work/checks"
