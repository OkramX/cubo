#!/bin/bash
# Compila a edição «sem cubo» (sem cubo físico e sem OkramX) para instalar
# noutro Mac. Fica em ~/Desktop/Cubo sem cubo/: um .zip cor-de-rosa e um amarelo, prontos a enviar,
# e as instruções de instalação.
set -euo pipefail
cd "$(dirname "$0")"
DEST="$HOME/Desktop/Cubo sem cubo"
rm -rf "$DEST"; mkdir -p "$DEST"
swift build -c release -Xswiftc -DSEM_CUBO --scratch-path .build-sem-cubo
for COR in rosa amarelo; do
  if [ $COR = rosa ]; then PNG=Recursos/rosa; else PNG=Recursos; fi
  TMP=$(mktemp -d)
  IS=$(mktemp -d)/Cubo.iconset; mkdir -p "$IS"
  for s in 16 32 128 256 512; do
    sips -z $s $s $PNG/logo-1024.png --out "$IS/icon_${s}x${s}.png" >/dev/null
    d=$((s*2)); sips -z $d $d $PNG/logo-1024.png --out "$IS/icon_${s}x${s}@2x.png" >/dev/null
  done
  APP="$TMP/Cubo.app"
  mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
  cp .build-sem-cubo/release/Cubo "$APP/Contents/MacOS/Cubo"
  cp Recursos/Info.plist "$APP/Contents/Info.plist"
  iconutil -c icns "$IS" -o "$APP/Contents/Resources/Cubo.icns"
  cp Recursos/chegou.wav "$APP/Contents/Resources/chegou.wav"
  cp $PNG/mascote.png $PNG/mascote-piscar.png "$APP/Contents/Resources/"
  # Mesma assinatura fixa da versão normal: o outro Mac lembra-se das autorizações entre atualizações.
  KC="$PWD/Assinatura/cubo.keychain-db"
  if [ -f "$KC" ] && [ -f Assinatura/.senha-keychain ]; then
    security unlock-keychain -p "$(cat Assinatura/.senha-keychain)" "$KC"
    ID=$(security find-identity -p codesigning "$KC" | awk '/Cubo Assinatura Local/ {print $2; exit}')
    codesign --force --keychain "$KC" --sign "$ID" --identifier pt.cubo.app "$APP"
  else
    codesign --force --sign - --identifier pt.cubo.app "$APP"
  fi
  (cd "$TMP" && ditto -c -k --keepParent Cubo.app "$DEST/Cubo $COR.zip")
  rm -rf "$TMP"
done
cp LEIA-ME-instalar.txt "$DEST/Como instalar.txt"
echo "Pronta em $DEST"
