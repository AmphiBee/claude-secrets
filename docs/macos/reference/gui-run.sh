#!/bin/bash
# Exécute un script dans la session graphique du Mac (trousseau déverrouillé) via un LaunchAgent éphémère.
# usage: gui-run.sh /chemin/script.sh   -> sortie dans /tmp/gui-run.out
SCRIPT="$1"; L=fr.amphibee.tmp-guirun; P=$HOME/Library/LaunchAgents/$L.plist; OUT=/tmp/gui-run.out
rm -f $OUT /tmp/gui-run.done
cat > $P <<PL
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><Label>$L</Label>
<key>ProgramArguments</key><array><string>/bin/bash</string><string>-c</string><string>/bin/bash $SCRIPT > $OUT 2>&1; touch /tmp/gui-run.done</string></array>
<key>RunAtLoad</key><true/></dict></plist>
PL
sed -i '' 's#<Label>#<key>Label</key><string>#; s#</Label>#</string>#' $P
launchctl bootout gui/$(id -u)/$L 2>/dev/null; launchctl bootstrap gui/$(id -u) $P
for i in $(seq 1 120); do [ -f /tmp/gui-run.done ] && break; sleep 1; done
launchctl bootout gui/$(id -u)/$L 2>/dev/null; rm -f $P /tmp/gui-run.done
cat $OUT
