#!/usr/bin/env bash
set -euo pipefail

# ── parse-release.sh ──────────────────────────────────────────────────────────
# Reads the GitHub release event, classifies the release by semver tier,
# parses Keep a Changelog sections, and outputs structured context JSON.
# ─────────────────────────────────────────────────────────────────────────────

if [[ -z "${GITHUB_EVENT_PATH:-}" ]]; then
  echo "::error::GITHUB_EVENT_PATH is not set. This script must run inside a GitHub Actions workflow."
  exit 1
fi

EVENT=$(cat "$GITHUB_EVENT_PATH")

# ── Extract release fields ────────────────────────────────────────────────────
TAG=$(echo "$EVENT" | jq -r '.release.tag_name // ""')
TITLE=$(echo "$EVENT" | jq -r '.release.name // ""')
BODY=$(echo "$EVENT" | jq -r '.release.body // ""')
RELEASE_URL=$(echo "$EVENT" | jq -r '.release.html_url // ""')
IS_PRERELEASE=$(echo "$EVENT" | jq -r '.release.prerelease // false')
REPO_NAME=$(echo "$EVENT" | jq -r '.repository.name // ""')
REPO_FULL=$(echo "$EVENT" | jq -r '.repository.full_name // ""')

if [[ -z "$TAG" ]]; then
  echo "::error::Could not read release tag from event. Is the trigger set to 'on: release: types: [published]'?"
  exit 1
fi

echo "Processing release: $TAG ($REPO_FULL)"

# Use override product name or derive from repo name
PRODUCT_NAME="${PRODUCT_NAME:-}"
if [[ -z "$PRODUCT_NAME" ]]; then
  # Convert kebab-case/snake_case to Title Case
  PRODUCT_NAME=$(echo "$REPO_NAME" | sed 's/[-_]/ /g' | awk '{for(i=1;i<=NF;i++) $i=toupper(substr($i,1,1)) substr($i,2); print}')
fi

# ── Semver parsing ────────────────────────────────────────────────────────────
# Strip leading 'v' or 'V'
VERSION="${TAG#v}"
VERSION="${VERSION#V}"

# Separate pre-release suffix (e.g. "1.2.3-alpha.1" → version="1.2.3", prerelease_label="alpha.1")
PRERELEASE_LABEL=""
if [[ "$VERSION" == *"-"* ]]; then
  PRERELEASE_LABEL="${VERSION#*-}"
  VERSION="${VERSION%%-*}"
fi

# Split into major.minor.patch
IFS='.' read -ra PARTS <<< "$VERSION"
MAJOR="${PARTS[0]:-0}"
MINOR="${PARTS[1]:-0}"
PATCH="${PARTS[2]:-0}"

# Validate they are integers
for part in "$MAJOR" "$MINOR" "$PATCH"; do
  if ! [[ "$part" =~ ^[0-9]+$ ]]; then
    echo "::warning::Could not parse semver from tag '$TAG'. Defaulting to tier 2 (standard)."
    MAJOR=0; MINOR=1; PATCH=0
    break
  fi
done

# ── Classify semver type ──────────────────────────────────────────────────────
SEMVER_TYPE="patch"
if [[ -n "$PRERELEASE_LABEL" ]] || [[ "$IS_PRERELEASE" == "true" ]]; then
  SEMVER_TYPE="prerelease"
elif [[ "$PATCH" == "0" && "$MINOR" == "0" ]]; then
  SEMVER_TYPE="major"
elif [[ "$PATCH" == "0" ]]; then
  SEMVER_TYPE="minor"
fi

# ── Milestone detection ───────────────────────────────────────────────────────
IS_MILESTONE="false"
MILESTONE_REASON=""

if [[ "$SEMVER_TYPE" == "major" ]]; then
  IS_MILESTONE="true"
  if [[ "$MAJOR" == "1" ]]; then
    MILESTONE_REASON="first stable release"
  elif (( MAJOR % 5 == 0 )); then
    MILESTONE_REASON="major milestone (v${MAJOR})"
  else
    MILESTONE_REASON="major version"
  fi
fi

# ── Assign tier ───────────────────────────────────────────────────────────────
# Tier 1 = major/milestone, Tier 2 = minor, Tier 3 = patch, Tier 4 = prerelease
if [[ "$SEMVER_TYPE" == "prerelease" ]]; then
  RELEASE_TIER=4
  TIER_LABEL="Pre-release"
elif [[ "$IS_MILESTONE" == "true" ]]; then
  RELEASE_TIER=1
  TIER_LABEL="Major / Milestone"
elif [[ "$SEMVER_TYPE" == "minor" ]]; then
  RELEASE_TIER=2
  TIER_LABEL="Minor"
else
  RELEASE_TIER=3
  TIER_LABEL="Patch"
fi

echo "Semver type: $SEMVER_TYPE | Tier: $RELEASE_TIER ($TIER_LABEL)"

# ── Handle pre-releases ───────────────────────────────────────────────────────
if [[ "$RELEASE_TIER" == "4" && "${POST_ON_PRERELEASE:-false}" != "true" ]]; then
  echo "::notice::Skipping pre-release tag '$TAG'. Set post_on_prerelease: true to enable posting for pre-releases."
  # Write empty outputs and exit cleanly — the next steps will no-op
  {
    echo "release_tier=4"
    echo "release_context="
    echo "skip=true"
  } >> "$GITHUB_OUTPUT"
  exit 0
fi

# ── Parse changelog sections ──────────────────────────────────────────────────
# Supports Keep a Changelog format: ## Added, ## Fixed, ## Changed, ## Breaking Changes, etc.
parse_section() {
  local heading="$1"
  local content="$2"
  # Match ## Heading (case insensitive) and extract until next ## heading
  echo "$content" | awk -v h="$heading" '
    BEGIN { found=0; IGNORECASE=1 }
    /^##[[:space:]]/ {
      if (found) exit
      if (tolower($0) ~ "## " tolower(h)) { found=1; next }
    }
    found && /^[[:space:]]*$/ { next }
    found { print }
  ' | head -20
}

SECTION_ADDED=$(parse_section "Added" "$BODY")
SECTION_FIXED=$(parse_section "Fixed" "$BODY")
SECTION_CHANGED=$(parse_section "Changed" "$BODY")
SECTION_BREAKING=$(parse_section "Breaking" "$BODY")
SECTION_REMOVED=$(parse_section "Removed" "$BODY")
SECTION_SECURITY=$(parse_section "Security" "$BODY")

# Build structured changelog text for the prompt
STRUCTURED_CHANGELOG=""
if [[ -n "$SECTION_BREAKING" ]]; then
  STRUCTURED_CHANGELOG+="## Breaking Changes
$SECTION_BREAKING

"
fi
if [[ -n "$SECTION_ADDED" ]]; then
  STRUCTURED_CHANGELOG+="## What's New
$SECTION_ADDED

"
fi
if [[ -n "$SECTION_FIXED" ]]; then
  STRUCTURED_CHANGELOG+="## Bug Fixes
$SECTION_FIXED

"
fi
if [[ -n "$SECTION_CHANGED" ]]; then
  STRUCTURED_CHANGELOG+="## Changes
$SECTION_CHANGED

"
fi
if [[ -n "$SECTION_REMOVED" ]]; then
  STRUCTURED_CHANGELOG+="## Removed
$SECTION_REMOVED

"
fi
if [[ -n "$SECTION_SECURITY" ]]; then
  STRUCTURED_CHANGELOG+="## Security
$SECTION_SECURITY

"
fi

# Fall back to raw body if no sections were found
if [[ -z "$STRUCTURED_CHANGELOG" ]]; then
  STRUCTURED_CHANGELOG="$BODY"
fi

# Truncate to 4000 chars to stay within Claude's context budget
STRUCTURED_CHANGELOG="${STRUCTURED_CHANGELOG:0:4000}"

if [[ -z "$STRUCTURED_CHANGELOG" ]]; then
  echo "::warning::Release body is empty. Content will be generated from the release title only."
  STRUCTURED_CHANGELOG="(No release notes provided)"
fi

# ── Build output JSON ─────────────────────────────────────────────────────────
RELEASE_CONTEXT=$(jq -n \
  --arg tag "$TAG" \
  --arg version "$VERSION" \
  --arg semver_type "$SEMVER_TYPE" \
  --argjson tier "$RELEASE_TIER" \
  --arg tier_label "$TIER_LABEL" \
  --argjson is_milestone "$IS_MILESTONE" \
  --arg milestone_reason "$MILESTONE_REASON" \
  --arg title "$TITLE" \
  --arg release_url "$RELEASE_URL" \
  --arg product_name "$PRODUCT_NAME" \
  --arg repo_full "$REPO_FULL" \
  --arg changelog "$STRUCTURED_CHANGELOG" \
  '{
    tag: $tag,
    version: $version,
    semver_type: $semver_type,
    tier: $tier,
    tier_label: $tier_label,
    is_milestone: $is_milestone,
    milestone_reason: $milestone_reason,
    title: $title,
    release_url: $release_url,
    product_name: $product_name,
    repo_full: $repo_full,
    changelog: $changelog
  }')

# ── Write outputs ─────────────────────────────────────────────────────────────
# Encode as single line for GITHUB_OUTPUT
RELEASE_CONTEXT_SINGLE=$(echo "$RELEASE_CONTEXT" | jq -c '.')

{
  echo "release_tier=$RELEASE_TIER"
  echo "skip=false"
  echo "release_context=$RELEASE_CONTEXT_SINGLE"
} >> "$GITHUB_OUTPUT"

echo "Release context written to output."
echo "  Product:  $PRODUCT_NAME"
echo "  Tag:      $TAG ($SEMVER_TYPE)"
echo "  Tier:     $RELEASE_TIER - $TIER_LABEL"
echo "  Milestone: $IS_MILESTONE${MILESTONE_REASON:+ ($MILESTONE_REASON)}"
