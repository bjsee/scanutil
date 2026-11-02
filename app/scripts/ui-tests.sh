#!/bin/bash
# Baut das App-Bundle und führt die Oberflächentests aus (steuert die echte App über die Bedienungshilfen).
# Voraussetzung: Das Programm, aus dem das Skript läuft, hat die Berechtigung „Bedienungshilfen“.
# Achtung: Es gehen Fenster auf, die App kommt kurz in den Vordergrund. Währenddessen nichts tippen.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/bundle.sh >/dev/null
SCANUTIL_UI_TESTS=1 swift test --filter "OberflaechenTests" "$@"
