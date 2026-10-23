#!/bin/bash
# Packt die im GitHub-Build erzeugte App in zwei unsignierte (ad-hoc signierte) IPA-Dateien fuer Sideloadly:
#   VYRA-KI.ipa                           – mit der Berechtigung »Increased Memory Limit« (mehr Arbeitsspeicher fuer grosse Modelle)
#   VYRA-KI-ohne-Speichererweiterung.ipa  – ohne diese Berechtigung (falls die Signierung damit fehlschlaegt)
# Sideloadly signiert beim Installieren mit deiner Apple-ID neu.
set -euo pipefail
APP=$(find build/Build/Products/Release-iphoneos -maxdepth 1 -name "*.app" | head -1)
[ -n "$APP" ] || { echo "Keine .app gefunden"; exit 1; }
rm -rf dist pkg && mkdir -p dist pkg/Payload
cp -R "$APP" pkg/Payload/
APPDIR="pkg/Payload/$(basename "$APP")"
if [ -d "$APPDIR/Frameworks" ]; then
  for f in "$APPDIR"/Frameworks/*; do codesign -f -s - "$f"; done
fi
codesign -f -s - --entitlements App/VYRAKI/VYRAKI.entitlements "$APPDIR"
codesign -d --entitlements - "$APPDIR" || true
(cd pkg && zip -qry ../dist/VYRA-KI.ipa Payload)
codesign -f -s - "$APPDIR"
(cd pkg && zip -qry ../dist/VYRA-KI-ohne-Speichererweiterung.ipa Payload)
ls -la dist
du -sh "$APPDIR"
