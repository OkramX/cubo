#!/bin/bash
# Instala o serviço que envia as notificações do Mac para o cubo.
set -euo pipefail
cd "$(dirname "$0")"

DESTINO="$HOME/Library/Application Support/Cubo"
PLIST="$HOME/Library/LaunchAgents/pt.cubo.notificacoes.plist"
LOG="$HOME/Library/Logs/cubo-notificacoes.log"

if ! command -v python3 >/dev/null 2>&1; then
  echo "Não encontrei o python3. Instala as ferramentas da Apple com: xcode-select --install"
  exit 1
fi
PY="$(python3 -c 'import os,sys;print(os.path.realpath(sys.executable))')"
PYAPP="$(python3 -c 'import os,sys;p=os.path.join(sys.base_prefix,"Resources","Python.app");print(p if os.path.isdir(p) else "")')"

mkdir -p "$DESTINO" "$HOME/Library/LaunchAgents" "$HOME/Library/Logs"
cp cubo_notificacoes.py "$DESTINO/"
if [ ! -f "$DESTINO/config.json" ]; then
  cp config.exemplo.json "$DESTINO/config.json"
  NOVO_CONFIG=1
else
  NOVO_CONFIG=0
fi

cat > "$PLIST" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>pt.cubo.notificacoes</string>
  <key>ProgramArguments</key>
  <array>
    <string>$PY</string>
    <string>$DESTINO/cubo_notificacoes.py</string>
    <string>--config</string>
    <string>$DESTINO/config.json</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>ThrottleInterval</key><integer>15</integer>
  <key>StandardOutPath</key><string>$LOG</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict>
</plist>
PL

launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
launchctl bootstrap "gui/$(id -u)" "$PLIST"

echo
echo "Instalado."
echo
if [ "$NOVO_CONFIG" = 1 ]; then
  echo "1) Edita o token (e, se preciso, o endereço do cubo) em:"
  echo "   $DESTINO/config.json"
  echo "   Depois reinicia o serviço: launchctl kickstart -k gui/$(id -u)/pt.cubo.notificacoes"
  echo
fi
echo "2) Dá Acesso Total ao Disco ao Python, em Definições do Sistema >"
echo "   Privacidade e Segurança > Acesso total ao disco > botão +"
echo "   (no seletor de ficheiros carrega em Cmd+Shift+G e cola o caminho):"
echo "     $PY"
[ -n "$PYAPP" ] && echo "   Se continuar sem acesso, adiciona também:" && echo "     $PYAPP"
echo
echo "3) Testa:  python3 \"$DESTINO/cubo_notificacoes.py\" --verificar"
echo "   Registo: $LOG"
open "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles" 2>/dev/null || true
