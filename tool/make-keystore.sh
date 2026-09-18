#!/usr/bin/env bash
# Creates the Android release signing key and prints what to paste into the
# repository secrets.
#
#   bash tool/make-keystore.sh
#
# The key never leaves your machine: this script writes android/release.jks and
# android/key.properties, both of which are gitignored. Back the .jks up
# somewhere safe — losing it means you can never ship an update that Android
# will accept as the same app.
set -euo pipefail

cd "$(dirname "$0")/.."

KEYSTORE="android/release.jks"
PROPERTIES="android/key.properties"
ALIAS="anipocket"

if [ -e "$KEYSTORE" ]; then
  echo "$KEYSTORE already exists — refusing to overwrite it." >&2
  echo "Delete it yourself first if you really mean to start over." >&2
  exit 1
fi

read -r -s -p "Password for the new keystore: " STORE_PASSWORD; echo
read -r -s -p "Repeat it: " STORE_PASSWORD_AGAIN; echo
if [ "$STORE_PASSWORD" != "$STORE_PASSWORD_AGAIN" ]; then
  echo "Passwords do not match." >&2
  exit 1
fi
if [ ${#STORE_PASSWORD} -lt 6 ]; then
  echo "keytool requires at least 6 characters." >&2
  exit 1
fi

keytool -genkeypair \
  -keystore "$KEYSTORE" \
  -alias "$ALIAS" \
  -keyalg RSA \
  -keysize 4096 \
  -validity 10000 \
  -storetype PKCS12 \
  -storepass "$STORE_PASSWORD" \
  -keypass "$STORE_PASSWORD" \
  -dname "CN=AniPocket, OU=, O=, L=, S=, C="

cat > "$PROPERTIES" <<EOF
storeFile=$(cd android && pwd)/release.jks
storePassword=$STORE_PASSWORD
keyAlias=$ALIAS
keyPassword=$STORE_PASSWORD
EOF

echo
echo "Wrote $KEYSTORE and $PROPERTIES (both gitignored)."
echo
echo "Now add four repository secrets — Settings -> Secrets and variables -> Actions,"
echo "or with the gh CLI:"
echo
echo "  base64 -w0 $KEYSTORE | gh secret set ANDROID_KEYSTORE_BASE64"
echo "  gh secret set ANDROID_KEYSTORE_PASSWORD"
echo "  gh secret set ANDROID_KEY_ALIAS      # value: $ALIAS"
echo "  gh secret set ANDROID_KEY_PASSWORD"
echo
echo "After that, tagging a commit builds and publishes a signed release:"
echo
echo "  git tag -a v1.0.0 -m 'v1.0.0' && git push origin v1.0.0"
