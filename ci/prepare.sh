#!/usr/bin/env bash
# Genera las carpetas de plataforma de Flutter y aplica los ajustes de la app.
set -euo pipefail
cd "$(dirname "$0")/../app"
PLATFORMS="${1:-web}"
flutter create --platforms="$PLATFORMS" --project-name apuntes --org es.apuntes . >/dev/null
rm -rf test

if [ -f android/app/src/main/AndroidManifest.xml ]; then
  M=android/app/src/main/AndroidManifest.xml
  grep -q 'android.permission.INTERNET' "$M" || \
    sed -i 's|<manifest xmlns:android="http://schemas.android.com/apk/res/android">|&\n    <uses-permission android:name="android.permission.INTERNET"/>|' "$M"
  sed -i 's|android:label="apuntes"|android:label="Apuntes"|' "$M"
  # El análisis "lint" de Android falla con algunos plugins; no es necesario para compilar.
  if [ -f android/app/build.gradle.kts ] && ! grep -q checkReleaseBuilds android/app/build.gradle.kts; then
    printf '\nandroid {\n    lint {\n        checkReleaseBuilds = false\n        abortOnError = false\n    }\n}\n' >> android/app/build.gradle.kts
  elif [ -f android/app/build.gradle ] && ! grep -q checkReleaseBuilds android/app/build.gradle; then
    printf '\nandroid {\n    lintOptions {\n        checkReleaseBuilds false\n        abortOnError false\n    }\n}\n' >> android/app/build.gradle
  fi
fi

if [ -f web/index.html ]; then
  sed -i 's|<title>apuntes</title>|<title>Apuntes</title>|; s|content="apuntes"|content="Apuntes"|g' web/index.html
fi

flutter pub get
