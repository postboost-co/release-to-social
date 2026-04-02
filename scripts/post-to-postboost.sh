#!/usr/bin/env bash
set -euo pipefail

# ── post-to-postboost.sh ──────────────────────────────────────────────────────
# Builds the PostBoost PostInput payload from generated content and creates
# the post via the PostBoost API. Writes a GitHub Actions job summary.
# ─────────────────────────────────────────────────────────────────────────────

echo "::add-mask::$POSTBOOST_API_TOKEN"

POSTBOOST_BASE="https://postboost.co/app/api"

# Read JSON from temp files written by generate-content.sh
if [[ ! -f /tmp/release-social-content.json || ! -f /tmp/release-social-accounts.json ]]; then
  echo "::notice::No generated content found. Skipping PostBoost post creation."
  echo "post_uuid=" >> "$GITHUB_OUTPUT"
  exit 0
fi

GENERATED_CONTENT=$(cat /tmp/release-social-content.json)
ACCOUNTS_JSON=$(cat /tmp/release-social-accounts.json)

ACCOUNTS_COUNT=$(echo "$ACCOUNTS_JSON" | jq 'length')
if [[ "$ACCOUNTS_COUNT" == "0" ]]; then
  echo "::notice::No accounts to post to. Skipping."
  echo "post_uuid=" >> "$GITHUB_OUTPUT"
  exit 0
fi

RELEASE_CONTEXT="${RELEASE_CONTEXT:-{}}"
TAG=$(echo "$RELEASE_CONTEXT" | jq -r '.tag // ""')
PRODUCT_NAME=$(echo "$RELEASE_CONTEXT" | jq -r '.product_name // ""')
RELEASE_URL=$(echo "$RELEASE_CONTEXT" | jq -r '.release_url // ""')
TIER="${RELEASE_TIER:-2}"
SUMMARY=$(echo "$GENERATED_CONTENT" | jq -r '.summary // ""')

echo "Preparing post for: $PRODUCT_NAME $TAG"

# ── Build the accounts array ──────────────────────────────────────────────────
ACCOUNT_IDS=$(echo "$ACCOUNTS_JSON" | jq '[.[].id]')

# ── Build the versions array ──────────────────────────────────────────────────
# First version: account_id=0, is_original=true (default/fallback content)
# Use content from the first account as the default
FIRST_ACCOUNT_ID=$(echo "$ACCOUNTS_JSON" | jq -r '.[0].id | tostring')
DEFAULT_BODY=$(echo "$GENERATED_CONTENT" | jq -r --arg id "$FIRST_ACCOUNT_ID" '.versions[$id].body // ""')

# Build the original version
ORIGINAL_VERSION=$(jq -n \
  --arg body "$DEFAULT_BODY" \
  --arg url "$RELEASE_URL" \
  '{
    account_id: 0,
    is_original: true,
    content: [{ body: $body, url: $url }]
  }')

VERSIONS="[$ORIGINAL_VERSION]"

# Add per-account override versions for each target account
while IFS= read -r account; do
  id=$(echo "$account" | jq -r '.id')
  id_str=$(echo "$id" | tr -d '"')
  provider=$(echo "$account" | jq -r '.provider')

  body=$(echo "$GENERATED_CONTENT" | jq -r --arg id "$id_str" '.versions[$id].body // ""')

  if [[ -z "$body" ]]; then
    echo "::warning::No content generated for account $id ($provider). Skipping override."
    continue
  fi

  # For platforms that support link previews, keep URL separate from body
  # Instagram and Pinterest don't support clickable links in captions
  url_field="$RELEASE_URL"
  if [[ "$provider" == "instagram" || "$provider" == "pinterest" || "$provider" == "tiktok" ]]; then
    url_field=""
  fi

  OVERRIDE_VERSION=$(jq -n \
    --argjson id "$id" \
    --arg body "$body" \
    --arg url "$url_field" \
    '{
      account_id: $id,
      is_original: false,
      content: [{ body: $body, url: $url }]
    }')

  VERSIONS=$(echo "$VERSIONS" | jq --argjson v "$OVERRIDE_VERSION" '. + [$v]')
done < <(echo "$ACCOUNTS_JSON" | jq -c '.[]')

# ── Build scheduling fields ───────────────────────────────────────────────────
MODE="${SCHEDULING_MODE:-queue}"
SCHEDULE_FIELDS="{}"

case "$MODE" in
  now)
    SCHEDULE_FIELDS='{"schedule_now": true}'
    ;;
  scheduled)
    DATE="${SCHEDULE_DATE:-}"
    TIME="${SCHEDULE_TIME:-10:00}"
    TZ="${SCHEDULE_TIMEZONE:-UTC}"
    if [[ -z "$DATE" ]]; then
      echo "::warning::scheduling_mode is 'scheduled' but schedule_date is empty. Falling back to queue mode."
      SCHEDULE_FIELDS='{"queue": true}'
    else
      SCHEDULE_FIELDS=$(jq -n \
        --arg date "$DATE" \
        --arg time "$TIME" \
        --arg tz "$TZ" \
        '{"schedule": true, "date": $date, "time": $time, "timezone": $tz}')
    fi
    ;;
  queue|*)
    SCHEDULE_FIELDS='{"queue": true}'
    ;;
esac

# ── Build the full PostInput payload ─────────────────────────────────────────
PAYLOAD=$(jq -n \
  --argjson accounts "$ACCOUNT_IDS" \
  --argjson versions "$VERSIONS" \
  --argjson sched "$SCHEDULE_FIELDS" \
  '$sched + {accounts: $accounts, versions: $versions}')

# ── Dry run: preview and exit ─────────────────────────────────────────────────
if [[ "${DRY_RUN:-false}" == "true" ]]; then
  echo "::notice::Dry run enabled. No post will be created."

  # Write job summary
  {
    echo "## Dry Run: Release to Social"
    echo ""
    echo "| Field | Value |"
    echo "|---|---|"
    echo "| Release | \`$TAG\` |"
    echo "| Product | $PRODUCT_NAME |"
    echo "| Tier | $TIER |"
    echo "| Scheduling | $MODE |"
    echo "| Summary | $SUMMARY |"
    echo ""
    echo "### Generated Content"
    echo ""

    while IFS= read -r account; do
      id=$(echo "$account" | jq -r '.id')
      id_str=$(echo "$id" | tr -d '"')
      provider=$(echo "$account" | jq -r '.provider')
      name=$(echo "$account" | jq -r '.name')
      limit=$(echo "$account" | jq -r '.char_limit')
      body=$(echo "$GENERATED_CONTENT" | jq -r --arg i "$id_str" '.versions[$i].body // "(no content)"')
      char_count=${#body}

      echo "<details>"
      echo "<summary><strong>$provider</strong> — $name ($char_count / $limit chars)</summary>"
      echo ""
      echo "\`\`\`"
      echo "$body"
      echo "\`\`\`"
      echo ""
      echo "</details>"
      echo ""
    done < <(echo "$ACCOUNTS_JSON" | jq -c '.[]')

    echo "### API Payload"
    echo ""
    echo "<details>"
    echo "<summary>View JSON payload that would be sent to PostBoost</summary>"
    echo ""
    echo "\`\`\`json"
    echo "$PAYLOAD" | jq '.'
    echo "\`\`\`"
    echo ""
    echo "</details>"
    echo ""
    echo "> Dry run complete. Set \`dry_run: false\` to post for real."
  } >> "$GITHUB_STEP_SUMMARY"

  echo "post_uuid=" >> "$GITHUB_OUTPUT"
  exit 0
fi

# ── Live post: call PostBoost API ─────────────────────────────────────────────
post_to_postboost() {
  curl -s -w "\n%{http_code}" \
    -X POST "$POSTBOOST_BASE/$WORKSPACE_UUID/posts" \
    -H "Authorization: Bearer $POSTBOOST_API_TOKEN" \
    -H "Content-Type: application/json" \
    -d "$PAYLOAD"
}

echo "Creating post via PostBoost API..."
RESPONSE=$(post_to_postboost || echo -e "\nCURL_FAILED")

HTTP_STATUS=$(echo "$RESPONSE" | tail -1)
BODY=$(echo "$RESPONSE" | head -n -1)

if [[ "$HTTP_STATUS" == "CURL_FAILED" ]]; then
  echo "::error::Network error calling PostBoost API."
  exit 1
fi

# Handle 429 rate limit with one retry
if [[ "$HTTP_STATUS" == "429" ]]; then
  RETRY_AFTER=$(echo "$BODY" | jq -r '.retry_after // 10')
  echo "::warning::Rate limited. Waiting ${RETRY_AFTER}s and retrying..."
  sleep "$RETRY_AFTER"
  RESPONSE=$(post_to_postboost || echo -e "\nCURL_FAILED")
  HTTP_STATUS=$(echo "$RESPONSE" | tail -1)
  BODY=$(echo "$RESPONSE" | head -n -1)
fi

# Handle 5xx with one retry
if [[ "$HTTP_STATUS" =~ ^5 ]]; then
  echo "::warning::PostBoost API returned $HTTP_STATUS. Retrying in 5s..."
  sleep 5
  RESPONSE=$(post_to_postboost || echo -e "\nCURL_FAILED")
  HTTP_STATUS=$(echo "$RESPONSE" | tail -1)
  BODY=$(echo "$RESPONSE" | head -n -1)
fi

# Final status check
case "$HTTP_STATUS" in
  201)
    POST_UUID=$(echo "$BODY" | jq -r '.uuid // ""')
    POST_STATUS=$(echo "$BODY" | jq -r '.status // ""')
    echo "Post created successfully: $POST_UUID (status: $POST_STATUS)"
    ;;
  401)
    echo "::error::PostBoost API returned 401 Unauthenticated. Check your POSTBOOST_API_TOKEN secret."
    exit 1
    ;;
  403)
    echo "::error::PostBoost API returned 403 Forbidden. Your token may lack the required permissions."
    exit 1
    ;;
  404)
    echo "::error::PostBoost API returned 404. Check your WORKSPACE_UUID — it may be incorrect or deleted."
    exit 1
    ;;
  422)
    echo "::error::PostBoost API returned 422 Validation Error."
    VALIDATION_ERRORS=$(echo "$BODY" | jq -r '.errors // {} | to_entries | .[] | "  \(.key): \(.value | join(", "))"')
    echo "$VALIDATION_ERRORS"
    exit 1
    ;;
  *)
    echo "::error::PostBoost API returned unexpected status $HTTP_STATUS."
    echo "Response: $BODY"
    exit 1
    ;;
esac

# ── Write job summary ─────────────────────────────────────────────────────────
DASHBOARD_URL="https://postboost.co/app/$WORKSPACE_UUID/posts"

{
  echo "## Release Announced on Social Media"
  echo ""
  echo "| Field | Value |"
  echo "|---|---|"
  echo "| Release | [\`$TAG\`]($RELEASE_URL) |"
  echo "| Product | $PRODUCT_NAME |"
  echo "| Tier | $TIER |"
  echo "| Scheduling | $MODE |"
  echo "| Post status | \`$POST_STATUS\` |"
  echo "| PostBoost post | [View in dashboard]($DASHBOARD_URL) |"
  echo ""
  echo "### Generated Content"
  echo ""

  while IFS= read -r account; do
    id=$(echo "$account" | jq -r '.id')
    id_str=$(echo "$id" | tr -d '"')
    provider=$(echo "$account" | jq -r '.provider')
    name=$(echo "$account" | jq -r '.name')
    limit=$(echo "$account" | jq -r '.char_limit')
    body=$(echo "$GENERATED_CONTENT" | jq -r --arg i "$id_str" '.versions[$i].body // "(no content)"')
    char_count=${#body}

    echo "<details>"
    echo "<summary><strong>$provider</strong> — $name ($char_count / $limit chars)</summary>"
    echo ""
    echo "\`\`\`"
    echo "$body"
    echo "\`\`\`"
    echo ""
    echo "</details>"
    echo ""
  done < <(echo "$ACCOUNTS_JSON" | jq -c '.[]')

} >> "$GITHUB_STEP_SUMMARY"

echo "post_uuid=$POST_UUID" >> "$GITHUB_OUTPUT"
echo "Done. PostBoost post UUID: $POST_UUID"
