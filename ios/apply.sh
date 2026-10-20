#!/bin/bash
# Aplica los cambios de SFS App sobre una copia de Telegram-iOS (ruta en $1).
# Cada cambio verifica que el codigo de Telegram sea el esperado; si no, se detiene con error.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
TG="$1"

echo "==> Modulo SFS"
rm -rf "$TG/submodules/SFSModule"
cp -R "$HERE/SFSModule" "$TG/submodules/SFSModule"

echo "==> Puente SFS en TelegramCore"
mkdir -p "$TG/submodules/TelegramCore/Sources/SFS"
cp "$HERE/TelegramCoreSFS/SFSBridge.swift" "$TG/submodules/TelegramCore/Sources/SFS/SFSBridge.swift"

echo "==> Icono"
cp "$HERE/icon/Plane.svg" "$TG/Telegram/Telegram-iOS/Telegram.icon/Assets/Plane.svg"

echo "==> Cambios en el codigo de Telegram"
python3 "$HERE/patch_telegram.py" "$TG"

echo "Listo: cambios de SFS App aplicados"
