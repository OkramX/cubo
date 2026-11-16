#!/bin/bash
# Remove o serviço (mantém o config.json).
PLIST="$HOME/Library/LaunchAgents/pt.cubo.notificacoes.plist"
launchctl bootout "gui/$(id -u)" "$PLIST" 2>/dev/null || true
rm -f "$PLIST" "$HOME/Library/Application Support/Cubo/cubo_notificacoes.py"
echo "Serviço removido. A configuração ficou em ~/Library/Application Support/Cubo/config.json"
