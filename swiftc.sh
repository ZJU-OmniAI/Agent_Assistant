#!/bin/bash
set -euo pipefail

# Some in-place Command Line Tools upgrades leave two definitions of SwiftBridging.
# Mask just the obsolete map for this compiler invocation.
compiler=$(xcrun --find swiftc)
includes="$(dirname "$compiler")/../include/swift"
cache="${TMPDIR:-/tmp}/org.agent-assistant.swift-modules"
mkdir -p "$cache"
flags=(-module-cache-path "$cache")
if grep -q '^module SwiftBridging ' "$includes/bridging.modulemap" 2>/dev/null &&
   grep -q '^module SwiftBridging ' "$includes/module.modulemap" 2>/dev/null; then
    overlay="$cache/bridging-overlay.json"
    python3 - "$includes/module.modulemap" "$overlay" <<'PY'
import json, os, sys, tempfile
path, overlay = sys.argv[1:]
data = json.dumps({"version": 0, "roots": [{"type": "file", "name": os.path.realpath(path),
                                           "external-contents": "/dev/null"}]})
try:
    with open(overlay) as f:
        if f.read() == data:
            sys.exit(0)
except FileNotFoundError:
    pass
with tempfile.NamedTemporaryFile(mode="w", dir=os.path.dirname(overlay), delete=False) as f:
    f.write(data)
os.replace(f.name, overlay)
PY
    flags+=(-vfsoverlay "$overlay" -Xcc -ivfsoverlay -Xcc "$overlay")
fi
exec xcrun swiftc "${flags[@]}" "$@"
