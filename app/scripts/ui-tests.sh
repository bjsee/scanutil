#!/bin/bash
# Baut das App-Bundle und führt die Oberflächentests aus (steuert die echte App über die Bedienungshilfen).
# Voraussetzung: Das Programm, aus dem das Skript läuft, hat die Berechtigung „Bedienungshilfen“.
# Die App läuft im Hintergrund (kein Fokus, keine Mausbewegung); `HintergrundTests` prüft das nach.
# Am Entwicklerrechner bestätigt: Fokus und Eingaben des Nutzers bleiben unberührt.
set -euo pipefail
cd "$(dirname "$0")/.."
scripts/bundle.sh >/dev/null
SCANUTIL_UI_TESTS=1 swift test --filter "OberflaechenTests" "$@"
