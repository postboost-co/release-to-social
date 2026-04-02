#!/usr/bin/env bash
set -euo pipefail

# ── generate-content.sh ───────────────────────────────────────────────────────
# 1. Fetches connected PostBoost accounts and applies platform filters.
# 2. Calls Claude API to generate per-platform social media content.
# 3. Validates output against character limits and writes to GITHUB_OUTPUT.
# ─────────────────────────────────────────────────────────────────────────────

# Skip if parse-release signalled a pre-release skip
SKIP=$(grep "^skip=" "$GITHUB_OUTPUT" 2>/dev/null | tail -1 | cut -d= -f2 || echo "false")
if [[ "$SKIP" == "true" ]]; then
  echo "Skipping content generation (pre-release tag)."
  exit 0
fi

# Mask secrets so they never appear in logs
[[ -n "${ANTHROPIC_API_KEY:-}" ]] && echo "::add-mask::$ANTHROPIC_API_KEY"
[[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]] && echo "::add-mask::$CLAUDE_CODE_OAUTH_TOKEN"
echo "::add-mask::$POSTBOOST_API_TOKEN"

# Resolve which Claude auth method to use (OAuth token takes priority)
if [[ -n "${CLAUDE_CODE_OAUTH_TOKEN:-}" ]]; then
  CLAUDE_AUTH_HEADER="Authorization: Bearer $CLAUDE_CODE_OAUTH_TOKEN"
elif [[ -n "${ANTHROPIC_API_KEY:-}" ]]; then
  CLAUDE_AUTH_HEADER="x-api-key: $ANTHROPIC_API_KEY"
else
  echo "::error::No Claude authentication provided. Set either claude_code_oauth_token or anthropic_api_key."
  exit 1
fi

RELEASE_CONTEXT="${RELEASE_CONTEXT:-}"
if [[ -z "$RELEASE_CONTEXT" ]]; then
  echo "::error::No release context found. parse-release.sh may have failed."
  exit 1
fi

POSTBOOST_BASE="https://postboost.co/app/api"

# ── Character limit map (from config/mixpost.php) ─────────────────────────────
char_limit_for() {
  case "$1" in
    twitter)        echo 280 ;;
    facebook_page)  echo 5000 ;;
    instagram)      echo 2200 ;;
    mastodon)       echo 500 ;;
    youtube)        echo 5000 ;;
    pinterest)      echo 500 ;;
    linkedin)       echo 3000 ;;
    linkedin_page)  echo 3000 ;;
    tiktok)         echo 2200 ;;
    *)              echo 2200 ;;
  esac
}

# ── Step 1: Fetch connected accounts ─────────────────────────────────────────
echo "Fetching connected PostBoost accounts..."

ACCOUNTS_RESPONSE=$(curl -sf \
  -H "Authorization: Bearer $POSTBOOST_API_TOKEN" \
  "$POSTBOOST_BASE/$WORKSPACE_UUID/accounts" || echo "CURL_FAILED")

if [[ "$ACCOUNTS_RESPONSE" == "CURL_FAILED" ]]; then
  echo "::error::Failed to reach PostBoost API. Check your POSTBOOST_API_TOKEN and WORKSPACE_UUID."
  exit 1
fi

HTTP_STATUS=$(echo "$ACCOUNTS_RESPONSE" | jq -r '.message // ""')
if [[ "$HTTP_STATUS" == "Unauthenticated." ]]; then
  echo "::error::PostBoost API returned 401. Check your POSTBOOST_API_TOKEN secret."
  exit 1
fi

ALL_ACCOUNTS=$(echo "$ACCOUNTS_RESPONSE" | jq -r '.data // []')
AUTHORIZED_COUNT=$(echo "$ALL_ACCOUNTS" | jq 'length')
echo "Found $AUTHORIZED_COUNT connected account(s)."

if [[ "$AUTHORIZED_COUNT" == "0" ]]; then
  echo "::warning::No accounts found in this PostBoost workspace. Connect social accounts in the PostBoost dashboard."
  true  # temp files absent signals skip to post step
  exit 0
fi

# ── Step 2: Apply platform filters ───────────────────────────────────────────
PLATFORMS="${PLATFORMS:-}"
EXCLUDE_PLATFORMS="${EXCLUDE_PLATFORMS:-}"

FILTERED_ACCOUNTS="$ALL_ACCOUNTS"

# Include filter (if specified, keep only matching providers)
if [[ -n "$PLATFORMS" ]]; then
  INCLUDE_ARRAY=$(echo "$PLATFORMS" | tr ',' '\n' | jq -R . | jq -s .)
  FILTERED_ACCOUNTS=$(echo "$FILTERED_ACCOUNTS" | jq --argjson inc "$INCLUDE_ARRAY" '[.[] | select(.provider as $p | $inc | index($p) != null)]')
fi

# Exclude filter
if [[ -n "$EXCLUDE_PLATFORMS" ]]; then
  EXCLUDE_ARRAY=$(echo "$EXCLUDE_PLATFORMS" | tr ',' '\n' | jq -R . | jq -s .)
  FILTERED_ACCOUNTS=$(echo "$FILTERED_ACCOUNTS" | jq --argjson exc "$EXCLUDE_ARRAY" '[.[] | select(.provider as $p | $exc | index($p) == null)]')
fi

# Keep only authorized accounts
FILTERED_ACCOUNTS=$(echo "$FILTERED_ACCOUNTS" | jq '[.[] | select(.authorized == true)]')

TARGET_COUNT=$(echo "$FILTERED_ACCOUNTS" | jq 'length')
echo "Targeting $TARGET_COUNT account(s) after filtering."

if [[ "$TARGET_COUNT" == "0" ]]; then
  echo "::warning::No authorized accounts remain after applying platform filters. Adjust the platforms/exclude_platforms inputs."
  true  # temp files absent signals skip to post step
  exit 0
fi

# Enrich accounts with character limits
ACCOUNTS_WITH_LIMITS=$(echo "$FILTERED_ACCOUNTS" | jq -c '[.[] | {id: .id, name: .name, provider: .provider, username: (.username // "")}]')

# Build per-account limit entries for jq processing
ACCOUNTS_WITH_LIMITS_FULL="[]"
while IFS= read -r account; do
  provider=$(echo "$account" | jq -r '.provider')
  limit=$(char_limit_for "$provider")
  account_with_limit=$(echo "$account" | jq --argjson limit "$limit" '. + {char_limit: $limit}')
  ACCOUNTS_WITH_LIMITS_FULL=$(echo "$ACCOUNTS_WITH_LIMITS_FULL" | jq --argjson a "$account_with_limit" '. + [$a]')
done < <(echo "$ACCOUNTS_WITH_LIMITS" | jq -c '.[]')

echo "Accounts: $(echo "$ACCOUNTS_WITH_LIMITS_FULL" | jq -r '[.[] | "\(.provider)(\(.name))"] | join(", ")')"

# ── Step 3: Build the Claude prompt ──────────────────────────────────────────
RELEASE=$(echo "$RELEASE_CONTEXT" | jq -r '.')
TAG=$(echo "$RELEASE_CONTEXT" | jq -r '.tag')
PRODUCT_NAME=$(echo "$RELEASE_CONTEXT" | jq -r '.product_name')
SEMVER_TYPE=$(echo "$RELEASE_CONTEXT" | jq -r '.semver_type')
TIER=$(echo "$RELEASE_CONTEXT" | jq -r '.tier')
TIER_LABEL=$(echo "$RELEASE_CONTEXT" | jq -r '.tier_label')
IS_MILESTONE=$(echo "$RELEASE_CONTEXT" | jq -r '.is_milestone')
MILESTONE_REASON=$(echo "$RELEASE_CONTEXT" | jq -r '.milestone_reason')
TITLE=$(echo "$RELEASE_CONTEXT" | jq -r '.title')
RELEASE_URL=$(echo "$RELEASE_CONTEXT" | jq -r '.release_url')
CHANGELOG=$(echo "$RELEASE_CONTEXT" | jq -r '.changelog')

# Build the platform lines for the prompt
PLATFORM_LINES=""
while IFS= read -r account; do
  id=$(echo "$account" | jq -r '.id')
  provider=$(echo "$account" | jq -r '.provider')
  name=$(echo "$account" | jq -r '.name')
  username=$(echo "$account" | jq -r '.username')
  limit=$(echo "$account" | jq -r '.char_limit')
  handle_display="${username:+@$username}"
  PLATFORM_LINES+="- $provider (account: $name${handle_display:+ $handle_display}, id: $id, max $limit chars)
"
done < <(echo "$ACCOUNTS_WITH_LIMITS_FULL" | jq -c '.[]')

MILESTONE_NOTE=""
if [[ "$IS_MILESTONE" == "true" && -n "$MILESTONE_REASON" ]]; then
  MILESTONE_NOTE="This is a milestone release: $MILESTONE_REASON. Treat it as a significant event."
fi

CUSTOM_NOTE=""
if [[ -n "${CUSTOM_INSTRUCTIONS:-}" ]]; then
  CUSTOM_NOTE="Additional instructions: $CUSTOM_INSTRUCTIONS"
fi

INCLUDE_URL_NOTE="Include the release URL in each post body where appropriate for the platform."
if [[ "${INCLUDE_RELEASE_URL:-true}" == "false" ]]; then
  INCLUDE_URL_NOTE="Do not include the release URL in the post body."
fi

USER_PROMPT="Generate social media announcements for this software release.

Product: $PRODUCT_NAME
Version: $TAG ($SEMVER_TYPE)
Release Tier: $TIER ($TIER_LABEL)
Release Title: $TITLE
Release URL: $RELEASE_URL
$MILESTONE_NOTE

--- Release Notes ---
$CHANGELOG
--- End Release Notes ---

Target platforms (generate one post per account ID):
$PLATFORM_LINES
Preferences:
- Tone: ${TONE:-professional}
- Hashtags: ${HASHTAGS:-few}
- $INCLUDE_URL_NOTE
$CUSTOM_NOTE

Return a JSON object with exactly this structure:
{\"summary\":\"one-line summary\",\"versions\":{\"ACCOUNT_ID\":{\"provider\":\"platform_name\",\"body\":\"post text\"}}}

Replace ACCOUNT_ID with the numeric account ID. Include an entry for every account listed above. Every body must be under its platform character limit."

# ── Step 4: Call Claude API ───────────────────────────────────────────────────
SYSTEM_PROMPT=$(cat "$ACTION_PATH/prompts/system.txt")

call_claude() {
  local user_prompt="$1"
  # Build JSON payload safely with jq
  local payload
  payload=$(jq -n \
    --arg model "claude-sonnet-4-20250514" \
    --arg system "$SYSTEM_PROMPT" \
    --arg user "$user_prompt" \
    '{
      model: $model,
      max_tokens: 4096,
      system: $system,
      messages: [{ role: "user", content: $user }]
    }')

  curl -sf \
    -X POST "https://api.anthropic.com/v1/messages" \
    -H "$CLAUDE_AUTH_HEADER" \
    -H "anthropic-version: 2023-06-01" \
    -H "content-type: application/json" \
    -d "$payload"
}

echo "Calling Claude API to generate content..."
CLAUDE_RESPONSE=$(call_claude "$USER_PROMPT" || echo "CURL_FAILED")

if [[ "$CLAUDE_RESPONSE" == "CURL_FAILED" ]]; then
  echo "::warning::Claude API call failed. Falling back to template content."
  CLAUDE_RESPONSE=""
fi

# ── Step 5: Parse and validate Claude's response ─────────────────────────────
extract_json() {
  local raw="$1"
  local text
  text=$(echo "$raw" | jq -r '.content[0].text // ""')
  # Strip markdown code fences if present
  text=$(echo "$text" | sed 's/^```[a-z]*//;s/```$//' | sed '/^[[:space:]]*$/d')
  echo "$text"
}

AI_JSON=""
if [[ -n "$CLAUDE_RESPONSE" ]]; then
  AI_TEXT=$(extract_json "$CLAUDE_RESPONSE")
  if echo "$AI_TEXT" | jq -e '.versions' > /dev/null 2>&1; then
    AI_JSON="$AI_TEXT"
  else
    echo "::warning::Claude returned invalid JSON. Retrying with a simplified prompt..."
    RETRY_PROMPT="The previous response was not valid JSON. Return only the JSON object described below with no markdown fences.

$(echo "$USER_PROMPT" | tail -10)"
    CLAUDE_RETRY=$(call_claude "$RETRY_PROMPT" || echo "CURL_FAILED")
    if [[ "$CLAUDE_RETRY" != "CURL_FAILED" ]]; then
      AI_TEXT=$(extract_json "$CLAUDE_RETRY")
      if echo "$AI_TEXT" | jq -e '.versions' > /dev/null 2>&1; then
        AI_JSON="$AI_TEXT"
      fi
    fi
  fi
fi

# Fallback template if AI failed entirely
if [[ -z "$AI_JSON" ]]; then
  echo "::warning::Using fallback template (AI content generation failed)."
  FALLBACK_BODY="$PRODUCT_NAME $TAG released!"
  if [[ -n "$TITLE" && "$TITLE" != "$TAG" ]]; then
    FALLBACK_BODY="$FALLBACK_BODY $TITLE."
  fi
  if [[ "${INCLUDE_RELEASE_URL:-true}" == "true" ]]; then
    FALLBACK_BODY="$FALLBACK_BODY $RELEASE_URL"
  fi

  AI_JSON=$(jq -n \
    --arg summary "Fallback template for $TAG" \
    '{summary: $summary, versions: {}}')

  while IFS= read -r account; do
    id=$(echo "$account" | jq -r '.id')
    provider=$(echo "$account" | jq -r '.provider')
    limit=$(echo "$account" | jq -r '.char_limit')
    body="${FALLBACK_BODY:0:$limit}"
    AI_JSON=$(echo "$AI_JSON" | jq \
      --arg id "$id" \
      --arg provider "$provider" \
      --arg body "$body" \
      '.versions[$id] = {provider: $provider, body: $body}')
  done < <(echo "$ACCOUNTS_WITH_LIMITS_FULL" | jq -c '.[]')
fi

# ── Step 6: Enforce character limits ─────────────────────────────────────────
echo "Validating character limits..."
VALIDATED_JSON="$AI_JSON"

while IFS= read -r account; do
  id=$(echo "$account" | jq -r '.id' | tr -d '"')
  provider=$(echo "$account" | jq -r '.provider')
  limit=$(echo "$account" | jq -r '.char_limit')

  body=$(echo "$VALIDATED_JSON" | jq -r --arg id "$id" '.versions[$id].body // ""')
  body_len=${#body}

  if (( body_len > limit )); then
    echo "::warning::$provider content ($body_len chars) exceeds $limit char limit. Truncating..."
    # Truncate at last sentence boundary within the limit
    truncated="${body:0:$limit}"
    # Try to cut at last period, exclamation, or question mark
    last_sentence=$(echo "$truncated" | grep -oP '.*[.!?]' | tail -1 || echo "")
    if [[ -n "$last_sentence" && ${#last_sentence} -gt $((limit / 2)) ]]; then
      truncated="$last_sentence"
    else
      # Fallback: cut at last space
      truncated="${truncated% *}..."
    fi
    VALIDATED_JSON=$(echo "$VALIDATED_JSON" | jq \
      --arg id "$id" \
      --arg body "$truncated" \
      '.versions[$id].body = $body')
  fi
done < <(echo "$ACCOUNTS_WITH_LIMITS_FULL" | jq -c '.[]')

# ── Step 7: Write outputs ─────────────────────────────────────────────────────
# Write JSON to temp files to avoid GitHub Actions expression parser corrupting
# JSON that contains '}}' sequences.
echo "$VALIDATED_JSON" | jq -c '.' > /tmp/release-social-content.json
echo "$ACCOUNTS_WITH_LIMITS_FULL" | jq -c '.' > /tmp/release-social-accounts.json

SUMMARY=$(echo "$VALIDATED_JSON" | jq -r '.summary // "Release generated"')
echo "Summary: $SUMMARY"

echo "Content generation complete."
