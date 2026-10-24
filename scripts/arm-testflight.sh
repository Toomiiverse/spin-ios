#!/usr/bin/env bash
# Run on the server once the App Store Connect API key exists. Puts the four
# secrets the signed build needs into the GitHub repository and starts a build.
#
#   scripts/arm-testflight.sh ~/AuthKey_ABC123DEF4.p8 ABC123DEF4 <issuer-uuid> <team-id>
#
# The key comes from App Store Connect → Users and Access → Integrations →
# App Store Connect API (role: Admin). The Issuer ID is on that same page. The
# Team ID is at developer.apple.com → Membership details.
set -euo pipefail
cd "$(dirname "$0")/.."
p8=${1:?path to the App Store Connect API .p8}
key_id=${2:?Key ID}
issuer=${3:?Issuer ID}
team=${4:?Team ID}
grep -q "BEGIN PRIVATE KEY" "$p8" || { echo "$p8 does not look like a .p8 key" >&2; exit 1; }
repo=$(gh repo view --json nameWithOwner --jq .nameWithOwner)

gh secret set ASC_KEY_ID --repo "$repo" --body "$key_id"
gh secret set ASC_ISSUER_ID --repo "$repo" --body "$issuer"
gh secret set APPLE_TEAM_ID --repo "$repo" --body "$team"
gh secret set ASC_KEY_P8 --repo "$repo" < "$p8"
echo "Secrets set on $repo:"; gh secret list --repo "$repo"

# The workflow on GitHub has to pass those secrets to the build. The server's
# token cannot push .github/workflows, so check rather than assume.
if gh api "repos/$repo/contents/.github/workflows/ios.yml" --jq .content | base64 -d | grep -q ASC_KEY_P8; then
  echo "Workflow passes the secrets. Starting a build."
  gh workflow run ios.yml --repo "$repo"
  sleep 5; gh run list --repo "$repo" --limit 1
else
  cat >&2 <<MSG

The workflow on GitHub is still the unsigned one. Either
  - run  gh auth refresh -h github.com -s workflow  here, then
    cp scripts/ios.yml.wanted .github/workflows/ios.yml && git add -A .github && git commit -m "Signed build" && git push
  - or paste scripts/ios.yml.wanted over .github/workflows/ios.yml on github.com.
The next push then builds signed and uploads to TestFlight.
MSG
  exit 2
fi
