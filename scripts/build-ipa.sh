#!/usr/bin/env bash
# Builds Spin on a macOS machine (GitHub's xcode-27 runner). Cut down from haru-ios/scripts/build-ipa.sh.
# Signed and uploaded to TestFlight when the App Store Connect key is in the environment
# (repository secrets ASC_KEY_ID, ASC_ISSUER_ID, ASC_KEY_P8, APPLE_TEAM_ID); an unsigned .ipa otherwise.
set -euo pipefail
cd "$(dirname "$0")/.."

export DEVELOPER_DIR=/Applications/Xcode_27.0.app/Contents/Developer
xcodebuild -version
bash scripts/test-transport.sh
command -v xcodegen >/dev/null || brew install xcodegen
xcodegen generate

if [ -n "${ASC_KEY_ID:-}" ] && [ -n "${ASC_ISSUER_ID:-}" ] && [ -n "${ASC_KEY_P8:-}" ] && [ -n "${APPLE_TEAM_ID:-}" ]; then
  mkdir -p ~/private_keys
  key=~/private_keys/AuthKey_${ASC_KEY_ID}.p8
  # The secret may be pasted raw or base64; either way it ends up as the .p8.
  if printf '%s' "$ASC_KEY_P8" | grep -q "BEGIN PRIVATE KEY"; then printf '%s\n' "$ASC_KEY_P8" > "$key"; else printf '%s' "$ASC_KEY_P8" | base64 --decode > "$key"; fi
  # Each ephemeral runner gets a new development certificate; the account fills up unless old ones go first.
  node scripts/prune-dev-certs.mjs
  build_number="${GITHUB_RUN_NUMBER:-1}"
  auth=(-allowProvisioningUpdates -authenticationKeyPath "$key" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
  xcodebuild \
    -project Spin.xcodeproj -scheme Spin -configuration Release \
    -sdk iphoneos -destination 'generic/platform=iOS' \
    -archivePath build/Spin.xcarchive archive \
    "${auth[@]}" DEVELOPMENT_TEAM="$APPLE_TEAM_ID" CURRENT_PROJECT_VERSION="$build_number" \
    -quiet
  cat > build/ExportOptions.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>app-store-connect</string>
  <key>destination</key><string>upload</string>
  <key>signingStyle</key><string>automatic</string>
  <key>teamID</key><string>${APPLE_TEAM_ID}</string>
  <key>uploadSymbols</key><true/>
  <key>manageAppVersionAndBuildNumber</key><false/>
</dict></plist>
PLIST
  xcodebuild -exportArchive -archivePath build/Spin.xcarchive -exportOptionsPlist build/ExportOptions.plist -exportPath build/export "${auth[@]}"
  echo "Uploaded build $build_number to App Store Connect — it appears in TestFlight once Apple has processed it."
  exit 0
fi

xcodebuild \
  -project Spin.xcodeproj -scheme Spin -configuration Release \
  -sdk iphoneos -destination 'generic/platform=iOS' \
  -derivedDataPath build \
  CODE_SIGN_IDENTITY="" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=NO \
  -quiet
app=build/Build/Products/Release-iphoneos/Spin.app
test -f "$app/Spin" || { echo "No Spin binary in $app — the build did not finish." >&2; exit 1; }
rm -rf Payload Spin-unsigned.ipa
mkdir -p Payload
cp -R "$app" Payload/
zip -qr Spin-unsigned.ipa Payload
ls -la Spin-unsigned.ipa
