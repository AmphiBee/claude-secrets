#!/bin/bash
# claude-secrets (macOS) : même script que sous Linux, trousseau macOS via une couche d'adaptation.
D="$HOME/.local/share/claude-secrets"
export DBUS_SESSION_BUS_ADDRESS="${DBUS_SESSION_BUS_ADDRESS:-macos-keychain}"
export XDG_RUNTIME_DIR="${XDG_RUNTIME_DIR:-${TMPDIR%/}}"
export PYTHONPATH="$D/shim${PYTHONPATH:+:$PYTHONPATH}" PYTHONDONTWRITEBYTECODE=1
[ $# -eq 0 ] && set -- help
exec /usr/bin/python3 "$D/claude-secrets.py" "$@"
