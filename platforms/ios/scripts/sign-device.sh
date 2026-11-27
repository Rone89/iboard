#!/bin/sh
# Sign the unsigned iBoard device build with the user's Personal Team
# (773JTTH9DK) development certificate and Xcode-managed profiles.
#
# Recipe proven by GlideKeyboard Builds 2-48: keep the original bundle ids,
# embed each target's provisioning profile, derive signed entitlements from
# what the profile authorizes (plus the app group the profile grants), sign
# inside-out (frameworks -> appex -> app), then verify.
#
# usage: sign-device.sh <MSIMEApp.app>
set -eu

APP="${1:?usage: sign-device.sh <MSIMEApp.app>}"
[ -d "$APP" ] || { echo "no such app bundle: $APP" >&2; exit 1; }

IDENTITY="2D4648A900F245259AC890A532D4FAC17167AED1"  # Apple Development: 87292831@qq.com, OU=773JTTH9DK
TEAM="773JTTH9DK"
APP_BUNDLE="com.rayc.corvid"
KB_BUNDLE="com.rayc.corvid.keyboard"
APP_GROUP="group.773JTTH9DK.app.msime.ios"
DEVICE="00008160-001C311028434036"  # RCe2027 (iPhone 18 Pro Max)
PP_DIR="$HOME/Library/Developer/Xcode/UserData/Provisioning Profiles"

security find-identity -v -p codesigning 2>/dev/null | grep -q "$IDENTITY" || {
  echo "signing identity not found: $IDENTITY" >&2; exit 1;
}

stage=$(mktemp -d)
trap 'rm -rf "$stage"' EXIT

# Pick the Xcode-managed profile for a bundle id; validate team, device, expiry.
select_profile() {
  python3 - "$PP_DIR" "$2" "$TEAM" "$DEVICE" "$stage/$1.plist" <<'PYEOF'
import glob, plistlib, sys, shutil, datetime

pp_dir, bundle, team, device, out = sys.argv[1:6]
found = None
for path in glob.glob(pp_dir + "/*.mobileprovision"):
    data = open(path, "rb").read()
    start, end = data.find(b"<?xml"), data.find(b"</plist>") + 8
    if start < 0:
        continue
    pl = plistlib.loads(data[start:end])
    ent = pl.get("Entitlements", {})
    if ent.get("application-identifier") != f"{team}.{bundle}":
        continue
    if team not in pl.get("TeamIdentifier", []):
        continue
    if device not in pl.get("ProvisionedDevices", []):
        continue
    exp = pl.get("ExpirationDate")
    now_utc = datetime.datetime.now(datetime.timezone.utc).replace(tzinfo=None)
    if exp and exp < now_utc:
        continue
    found = (path, pl, ent)
    break
if not found:
    sys.exit(f"no valid profile for {bundle} (team {team}, device {device})")
path, pl, ent = found
groups = [g for g in ent.get("com.apple.security.application-groups", [])]
minimal = {
    "application-identifier": ent["application-identifier"],
    "com.apple.developer.team-identifier": team,
    "get-task-allow": bool(ent.get("get-task-allow", False)),
    "com.apple.security.application-groups": groups,
}
with open(out, "wb") as f:
    plistlib.dump(minimal, f)
shutil.copy(path, out[: -len(".plist")] + ".mobileprovision")
print(f"{bundle}: profile '{pl.get('Name')}' expires {pl.get('ExpirationDate')} groups={groups}")
PYEOF
}

select_profile app "$APP_BUNDLE"
select_profile kb "$KB_BUNDLE"

cp "$stage/app.mobileprovision" "$APP/embedded.mobileprovision"

# Sign nested code first: pods frameworks, then the keyboard appex.
find "$APP" -type d -name '*.framework' | while IFS= read -r fw; do
  codesign --force --sign "$IDENTITY" --timestamp=none "$fw"
done

find "$APP/PlugIns" -maxdepth 1 -type d -name '*.appex' | while IFS= read -r appex; do
  cp "$stage/kb.mobileprovision" "$appex/embedded.mobileprovision"
  codesign --force --sign "$IDENTITY" --entitlements "$stage/kb.plist" --timestamp=none "$appex"
done

codesign --force --sign "$IDENTITY" --entitlements "$stage/app.plist" --timestamp=none "$APP"
codesign --verify --strict "$APP"

# The embedded profile must authorize what was actually signed.
codesign -d --entitlements - --xml "$APP" > "$stage/signed.bin" 2>/dev/null
python3 - "$stage/signed.bin" "$TEAM" "$APP_BUNDLE" "$APP_GROUP" <<'PYEOF'
import plistlib, sys
ent = plistlib.load(open(sys.argv[1], "rb"))
team, bundle, group = sys.argv[2:5]
app_id = ent.get("application-identifier", "")
assert app_id == f"{team}.{bundle}", f"bad app-id: {app_id}"
assert group in ent.get("com.apple.security.application-groups", []), "app group missing"
print("signed app-id:", app_id)
print("signed groups:", ent.get("com.apple.security.application-groups"))
PYEOF

echo "Signed: $APP"
