#!/bin/bash
# Crée une identité de signature locale « Claude Secrets (local) » dans ton trousseau de connexion.
#
# Pourquoi : avec une signature ad hoc, l'empreinte de l'app change à chaque compilation et macOS
# redemande l'accès au trousseau. Avec une identité stable, « Toujours autoriser » tient d'une version
# à l'autre. Le certificat reste sur ce Mac (auto-signé, jamais envoyé nulle part) ; il ne sert qu'à signer.
#
#   Tools/make-signing-identity.sh            crée l'identité (à lancer dans un Terminal : il demande le
#                                             mot de passe de ta session, saisi masqué)
#   Tools/make-signing-identity.sh --test     même chose dans un trousseau TEMPORAIRE, sans toucher au tien
set -euo pipefail
NAME="Claude Secrets (local)"
TEST=0; [ "${1:-}" = "--test" ] && TEST=1

if [ "$TEST" = 0 ] && security find-identity -p codesigning 2>/dev/null | grep -q "$NAME"; then
  echo "L'identité « $NAME » existe déjà."; exit 0
fi

W="$(mktemp -d)"; chmod 700 "$W"
trap 'rm -rf "$W"; [ "$TEST" = 1 ] && security delete-keychain "$W.keychain-db" >/dev/null 2>&1 || true' EXIT
PW="$(openssl rand -hex 16)"       # mot de passe jetable du .p12, transmis par l'environnement à openssl

openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -keyout "$W/key.pem" -out "$W/cert.pem" \
  -subj "/CN=$NAME" -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" -addext "basicConstraints=critical,CA:false" 2>/dev/null
# Chiffrement « ancien » : l'outil `security` de macOS ne lit pas le PBKDF2/AES par défaut d'OpenSSL récent.
PW="$PW" openssl pkcs12 -export -inkey "$W/key.pem" -in "$W/cert.pem" -out "$W/id.p12" -name "$NAME" \
  -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES -macalg sha1 -passout env:PW

if [ "$TEST" = 1 ]; then
  KC="$W.keychain-db"
  security create-keychain -p "$PW" "$KC"; security unlock-keychain -p "$PW" "$KC"
  security import "$W/id.p12" -k "$KC" -P "$PW" -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S "apple-tool:,apple:,codesign:" -s -k "$PW" "$KC" >/dev/null
  security find-identity -p codesigning "$KC" | grep -q "$NAME"
  cp /bin/echo "$W/essai" && codesign --force --options runtime --keychain "$KC" --sign "$NAME" "$W/essai" 2>&1 | tail -1
  codesign --verify "$W/essai" && echo "TEST OK : l'identité s'importe et signe (empreinte stable : $(codesign -dr - "$W/essai" 2>&1 | grep -o 'leaf = H"[0-9a-f]*"' | head -1))"
  exit 0
fi

KC="$HOME/Library/Keychains/login.keychain-db"
security import "$W/id.p12" -k "$KC" -P "$PW" -T /usr/bin/codesign >/dev/null
echo "Identité importée. macOS va demander le mot de passe de ta session pour autoriser codesign à utiliser la clé"
echo "(sinon une boîte de dialogue s'affichera à chaque signature)."
security set-key-partition-list -S "apple-tool:,apple:,codesign:" -s "$KC" >/dev/null
echo "Terminé : « $NAME » est prête. Relance « make mac-install »."
