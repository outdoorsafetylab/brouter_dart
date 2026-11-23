#!/usr/bin/env bash
# Signs build/ios/iphoneos/Runner.app (flutter build ios --release
# --no-codesign) for development with a team's wildcard profile, so the
# bench app needs no App ID of its own. Usage: sign_ios.sh <profile> <identity sha1>
set -euo pipefail
cd "$(dirname "$0")"
profile=$1 identity=$2
app=build/ios/iphoneos/Runner.app
tmp=$(mktemp -d)
security cms -D -i "$profile" > "$tmp/p.plist"
team=$(plutil -extract TeamIdentifier.0 raw -o - "$tmp/p.plist")
bundle=$(plutil -extract CFBundleIdentifier raw -o - "$app/Info.plist")
cat > "$tmp/ent.plist" <<PL
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>application-identifier</key><string>$team.$bundle</string>
<key>com.apple.developer.team-identifier</key><string>$team</string>
<key>get-task-allow</key><true/>
</dict></plist>
PL
cp "$profile" "$app/embedded.mobileprovision"
for f in "$app"/Frameworks/*; do codesign -f -s "$identity" "$f"; done
codesign -f -s "$identity" --entitlements "$tmp/ent.plist" "$app"
codesign -v "$app" && echo "signed $bundle for team $team"
