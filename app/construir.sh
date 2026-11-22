#!/bin/bash
# Compila a Cubo e instala em ~/Applications/Cubo.app
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release
IS=$(mktemp -d)/Cubo.iconset; mkdir -p "$IS"
for s in 16 32 128 256 512; do
  sips -z $s $s Recursos/logo-1024.png --out "$IS/icon_${s}x${s}.png" >/dev/null
  d=$((s*2)); sips -z $d $d Recursos/logo-1024.png --out "$IS/icon_${s}x${s}@2x.png" >/dev/null
done
APP="$HOME/Applications/Cubo.app"
rm -rf "$APP"; mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp .build/release/Cubo "$APP/Contents/MacOS/Cubo"
cp Recursos/Info.plist "$APP/Contents/Info.plist"
iconutil -c icns "$IS" -o "$APP/Contents/Resources/Cubo.icns"
cp Recursos/chegou.wav "$APP/Contents/Resources/chegou.wav"
# Assinatura fixa (porta-chaves local em Assinatura/, fora do git): assim o macOS
# lembra-se das autorizações (Acesso Total ao Disco, Acessibilidade) entre atualizações.
KC="$PWD/Assinatura/cubo.keychain-db"
if [ -f "$KC" ] && [ -f Assinatura/.senha-keychain ]; then
  security unlock-keychain -p "$(cat Assinatura/.senha-keychain)" "$KC"
  ID=$(security find-identity -p codesigning "$KC" | awk '/Cubo Assinatura Local/ {print $2; exit}')
  codesign --force --keychain "$KC" --sign "$ID" --identifier pt.cubo.app "$APP"
else
  codesign --force --sign - --identifier pt.cubo.app "$APP"
fi
echo "Instalada em $APP"
