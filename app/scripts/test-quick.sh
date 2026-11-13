#!/bin/bash
# Schneller Testlauf während der Arbeit: nur die Tests, die von den geänderten Dateien berührt sind.
#
#   scripts/test-quick.sh            der Arbeitsstand: Geändertes und Neues seit dem letzten Commit
#   scripts/test-quick.sh main       alles gegen main (Commits des Branches, Arbeitsstand, neue Dateien)
#
# Vorgehen: Aus jeder geänderten Quelldatei werden die Typnamen gelesen (enum/struct/class/actor). Jede Testdatei, die einen dieser
# Namen als Wort enthält, und jede geänderte Testdatei liefert ihre Suiten (`struct …` ganz links). Nur diese Suiten laufen.
# Ein Typ, der in mehr als 6 Testdateien vorkommt (`AppModel`, `Corrections`), zählt nicht: Er würde fast alles auswählen. Wer ihn ändert,
# ändert dazu Tests; deren Suiten laufen, weil die Testdatei selbst geändert ist. Über 25 Suiten insgesamt rät das Skript zum ganzen Lauf.
#
# Das ist eine Abkürzung für die Schleife „ändern, prüfen“, kein Ersatz für den ganzen Lauf: Wer eine Änderung nur mittelbar berührt
# (HandRemover wird vom CorrectionRenderer benutzt, dessen Tests den Namen nicht nennen), sieht das hier nicht. Vor Push und Merge
# läuft darum einmal alles: `swift test --skip ScanutilAutomationTests`, bei geänderter Oberfläche dazu `scripts/ui-tests.sh`.
set -euo pipefail
cd "$(dirname "$0")/.."
base="${1:-HEAD}"

changed="$( { if [ "$base" != HEAD ]; then git diff --name-only --relative "$base"...HEAD -- . 2>/dev/null || true; fi
              git diff --name-only --relative HEAD -- .
              git ls-files --others --exclude-standard -- . ; } | grep '\.swift$' | sort -u || true )"
if [ -z "$changed" ]; then echo "Keine geänderten Swift-Dateien gegen $base."; exit 0; fi

suites_of() {   # Suiten (struct ganz links) einer Testdatei
  grep -E '^struct [A-Za-z0-9_]+' "$1" | sed -E 's/^struct ([A-Za-z0-9_]+).*/\1/' || true
}

suites=""
skipped=""
tests_to_scan="$(find Tests -name '*.swift' -not -path 'Tests/ScanutilAutomationTests/*')"
for file in $changed; do
  case "$file" in
    Tests/ScanutilAutomationTests/*) continue ;;                 # Oberflächentests: eigener Lauf (scripts/ui-tests.sh)
    Tests/*) suites="$suites $(suites_of "$file")" ;;
    Sources/*)
      names="$(grep -hoE '^[[:space:]]*(public |final |private |internal |indirect )*(enum|struct|class|actor) [A-Za-z0-9_]+' "$file" \
               | sed -E 's/.*(enum|struct|class|actor) ([A-Za-z0-9_]+)/\2/' | sort -u || true)"
      for name in $names; do
        users="$(grep -lw "$name" $tests_to_scan 2>/dev/null || true)"
        if [ "$(echo "$users" | grep -c . || true)" -gt 6 ]; then skipped="$skipped $name"; continue; fi
        for test in $users; do suites="$suites $(suites_of "$test")"; done
      done ;;
  esac
done

suites="$(echo $suites | tr ' ' '\n' | grep -v '^$' | sort -u || true)"
count="$(echo "$suites" | grep -c . || true)"
if [ "$count" -eq 0 ]; then
  echo "Keine Tests gefunden, die zu den Änderungen gehören:"; echo "$changed" | sed 's/^/  /'
  echo "Dann hilft nur der ganze Lauf: swift test --skip ScanutilAutomationTests"; exit 0
fi
if [ "$count" -gt 25 ]; then
  echo "$count Suiten betroffen: Die Änderung berührt fast alles. Besser gleich: swift test --skip ScanutilAutomationTests"; exit 0
fi

echo "Geänderte Dateien:"; echo "$changed" | sed 's/^/  /'
[ -n "$skipped" ] && echo "Nicht gezählt (in mehr als 6 Testdateien): $(echo $skipped | tr ' ' '\n' | sort -u | tr '\n' ' ')"
echo "Laufende Suiten ($count): $(echo $suites | tr '\n' ' ')"
args=()
for suite in $suites; do args+=(--filter "$suite"); done
exec swift test --skip ScanutilAutomationTests "${args[@]}"
