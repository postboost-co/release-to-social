# release-to-social

A GitHub Action that automatically posts your release announcements to social media when you publish a GitHub Release.

Pipeline: GitHub Release published → Claude AI transforms the changelog into platform-specific marketing copy → PostBoost publishes to all connected accounts simultaneously.

Features:

- Per-platform content: different copy for Twitter, LinkedIn, Instagram, Mastodon, etc., each respecting character limits
- Changelog-aware: parses Keep a Changelog sections (Added, Fixed, Breaking Changes) and leads with the most impactful change
- Semver-aware: major versions and milestones get celebratory full-length posts; patch releases get brief factual notes
- Scheduling modes: publish immediately, add to PostBoost's smart queue, or schedule for a specific date and time
- Dry run mode: preview all generated content before going live
- Fallback: if the AI call fails, posts a simple template so your release never goes unannounced

## Setup

### 1. Get your credentials

**PostBoost API token.** Go to PostBoost dashboard → Settings → Access Tokens → Create Token.

**PostBoost workspace UUID.** Open the PostBoost dashboard. The UUID is in the URL: `https://postboost.co/app/YOUR-UUID-HERE/posts`.

**Claude auth token.** You need one of these two (OAuth token is recommended):

**Option A — Claude Code OAuth token (recommended)**

This is the token Claude Code uses under the hood. No Anthropic account billing setup required — it draws from your Claude subscription.

1. Install Claude Code: `npm install -g @anthropic-ai/claude-code`
2. Run `claude` and complete the login flow
3. The OAuth token is stored at `~/.claude/.credentials.json` under the `claudeAiOauth` key
4. Copy the `access_token` value and add it as the `CLAUDE_CODE_OAUTH_TOKEN` secret in your repo

**Option B — Anthropic API key**

Standard pay-per-token API access. Claude Sonnet uses roughly 1,000-2,000 tokens per release announcement (~$0.003-0.006 per run).

1. Go to console.anthropic.com → API Keys → Create Key
2. Add it as the `ANTHROPIC_API_KEY` secret in your repo

### 2. Add secrets to your repository

In your repo, go to Settings → Secrets and variables → Actions → New repository secret. Add:

- `POSTBOOST_API_TOKEN`
- `POSTBOOST_WORKSPACE_UUID`
- `CLAUDE_CODE_OAUTH_TOKEN` (or `ANTHROPIC_API_KEY`)

### 3. Connect social accounts

In the PostBoost dashboard, go to Accounts and connect at least one social media account. The action will automatically post to all connected and authorized accounts.

### 4. Add the workflow

Copy `examples/release-to-social.yml` to `.github/workflows/release-to-social.yml` in your repository.

```yaml
name: Announce release on social media

on:
  release:
    types: [published]

jobs:
  announce:
    runs-on: ubuntu-latest
    steps:
      - uses: postboost/release-to-social@v1
        with:
          postboost_api_token: ${{ secrets.POSTBOOST_API_TOKEN }}
          workspace_uuid: ${{ secrets.POSTBOOST_WORKSPACE_UUID }}
          claude_code_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
```

That is it. The next time you publish a release, this action runs automatically.

## Configuration

All inputs are optional except the three credentials.

| Input | Default | Description |
|---|---|---|
| `tone` | `professional` | Writing tone: professional, casual, excited, technical, friendly |
| `platforms` | (all) | Comma-separated platform filter: `twitter,linkedin`. Empty means all connected accounts. |
| `exclude_platforms` | (none) | Comma-separated platforms to skip: `tiktok,youtube` |
| `scheduling_mode` | `queue` | How to schedule: `now` (immediate), `queue` (smart queue), `scheduled` (specific date/time) |
| `schedule_date` | | Date for scheduled mode (YYYY-MM-DD) |
| `schedule_time` | `10:00` | Time for scheduled mode (24-hour HH:MM) |
| `schedule_timezone` | `UTC` | IANA timezone for scheduled mode |
| `hashtags` | `few` | Hashtag quantity: `none`, `few` (1-3), `some` (3-5), `many` (5+) |
| `include_release_url` | `true` | Whether to include the GitHub Release URL in posts |
| `dry_run` | `false` | Preview generated content without posting |
| `product_name` | (repo name) | Override the product name used in posts |
| `custom_instructions` | | Extra instructions appended to the AI prompt |
| `post_on_prerelease` | `false` | Whether to post for alpha/beta/rc tags |

## How it works

### Release classification

The action parses your tag and classifies the release:

| Semver pattern | Tier | Behavior |
|---|---|---|
| `vX.0.0`, `v1.0.0`, round major numbers | 1 (Milestone) | Celebratory tone, full-length posts on all platforms |
| `vX.Y.0` | 2 (Minor) | Standard announcement, highlights new features |
| `vX.Y.Z` | 3 (Patch) | Brief and factual, focuses on bug fixes |
| `*-alpha`, `*-beta`, `*-rc` | 4 (Pre-release) | Skipped unless `post_on_prerelease: true` |

### Changelog parsing

The action looks for Keep a Changelog section headings:

```markdown
## Added
- New dark mode

## Fixed
- Login timeout under heavy load

## Breaking Changes
- Removed legacy v1 API endpoints
```

Breaking changes are always surfaced first. The most impactful additions lead the post body.

### Per-platform content

Each connected social account receives its own version of the post, tailored to the platform:

- Twitter (280 chars): short hook, one or two emojis, release URL
- LinkedIn (3,000 chars): professional paragraphs, business impact
- Instagram (2,200 chars): storytelling, emoji-rich, hashtags at end
- Mastodon (500 chars): developer-friendly, no corporate-speak
- Facebook (5,000 chars): conversational, invites discussion
- YouTube (5,000 chars): keyword-rich description format
- Pinterest, TikTok (500 / 2,200 chars): brief, action-oriented

PostBoost's versions system sends each account its own optimized copy in a single API call.

### Dry run

Test the action before going live:

```yaml
- uses: postboost/release-to-social@v1
  with:
    postboost_api_token: ${{ secrets.POSTBOOST_API_TOKEN }}
    workspace_uuid: ${{ secrets.POSTBOOST_WORKSPACE_UUID }}
    claude_code_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}
    dry_run: 'true'
```

The job summary shows all generated content and the exact API payload that would be sent, without creating any post.

## Requirements

- A PostBoost account with at least one connected social media account
- A Claude Code OAuth token (recommended) or an Anthropic API key
- Runs on `ubuntu-latest` (uses `curl` and `jq`, both pre-installed on GitHub-hosted runners)

## Outputs

| Output | Description |
|---|---|
| `post_uuid` | UUID of the created PostBoost post |
| `release_tier` | Classified release tier (1-4) |
| `generated_content` | JSON of all generated content keyed by account ID |

Use outputs in subsequent steps:

```yaml
- uses: postboost/release-to-social@v1
  id: social
  with:
    postboost_api_token: ${{ secrets.POSTBOOST_API_TOKEN }}
    workspace_uuid: ${{ secrets.POSTBOOST_WORKSPACE_UUID }}
    claude_code_oauth_token: ${{ secrets.CLAUDE_CODE_OAUTH_TOKEN }}

- run: echo "Post UUID is ${{ steps.social.outputs.post_uuid }}"
```
