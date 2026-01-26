#!/bin/bash
#
# Remote Test Point Trigger Script
#
# Simple script for Remote testing of IPv6 vs legacy IP performance.
# Only requires: curl, bash, hostname, and standard utilities.
#
# Usage:
#   1. Set environment variables:
#      export IPV6_ARMY_TOKEN="your-api-token"
#      export LOCATION="Amsterdam,NL"  # Optional
#
#   2. Run the script:
#      ./trigger-test.sh           # Trigger and exit
#      ./trigger-test.sh --wait    # Trigger and wait for results
#
# Or as one-liner:
#   IPV6_ARMY_TOKEN="token" LOCATION="Amsterdam,NL" ./trigger-test.sh --wait
#
# Cron example (daily at 6 AM):
#   0 6 * * * IPV6_ARMY_TOKEN="token" LOCATION="Amsterdam,NL" /path/to/trigger-test.sh >> /var/log/ipv6-test.log 2>&1
#
# Apache 2.0 licensed https://www.apache.org/licenses/LICENSE-2.0.txt
#

set -euo pipefail

# Configuration
API_URL="${API_URL:-https://ipv6.army/api/test/trigger}"
API_TOKEN="${IPV6_ARMY_TOKEN:-}"
WAIT_FOR_RESULTS=false
MAX_WAIT_TIME=300  # 5 minutes max wait
POLL_INTERVAL=10   # Check every 10 seconds

# GitHub submission options (all optional)
SUBMIT_GH=false
SUBMIT_GIT=false
SUBMIT_API=false
GH_REPO="${GH_REPO:-}"
GH_METHOD="${GH_METHOD:-issue}"  # "issue" or "pr"
GIT_REPO="${GIT_REPO:-}"
GIT_BRANCH="${GIT_BRANCH:-main}"
GH_TOKEN="${GITHUB_TOKEN:-}"

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --wait|-w)
            WAIT_FOR_RESULTS=true
            shift
            ;;
        --submit-gh)
            SUBMIT_GH=true
            shift
            ;;
        --submit-git)
            SUBMIT_GIT=true
            shift
            ;;
        --submit-api)
            SUBMIT_API=true
            shift
            ;;
        --gh-repo)
            GH_REPO="$2"
            shift 2
            ;;
        --gh-method)
            GH_METHOD="$2"
            shift 2
            ;;
        --git-repo)
            GIT_REPO="$2"
            shift 2
            ;;
        --git-branch)
            GIT_BRANCH="$2"
            shift 2
            ;;
        --gh-token)
            GH_TOKEN="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Options:"
            echo "  --wait, -w           Wait for test results and display them"
            echo "  --help, -h           Show this help message"
            echo ""
            echo "GitHub Submission (all optional):"
            echo "  --submit-gh          Submit results via GitHub CLI (gh)"
            echo "  --submit-git         Submit results via direct git push"
            echo "  --submit-api         Submit results via GitHub REST API"
            echo ""
            echo "GitHub CLI options (--submit-gh):"
            echo "  --gh-repo REPO       Target repo, e.g., owner/repo (required for --submit-gh)"
            echo "  --gh-method METHOD   Submission method: 'issue' or 'pr' (default: issue)"
            echo ""
            echo "Git push options (--submit-git):"
            echo "  --git-repo URL       Git repository URL to push to (required for --submit-git)"
            echo "  --git-branch BRANCH  Branch to push to (default: main)"
            echo ""
            echo "GitHub API options (--submit-api):"
            echo "  --gh-repo REPO       Target repo, e.g., owner/repo (required for --submit-api)"
            echo "  --gh-token TOKEN     GitHub PAT (or set GITHUB_TOKEN env var)"
            echo ""
            echo "Environment variables:"
            echo "  IPV6_ARMY_TOKEN  API authentication token (required)"
            echo "  LOCATION         Geographic location (optional)"
            echo "  TEST_POINT_ID    Custom test point identifier (optional)"
            echo "  API_URL          Override API endpoint (optional)"
            echo "  GITHUB_TOKEN     GitHub PAT for --submit-api (optional)"
            echo "  GH_REPO          Default repo for --submit-gh and --submit-api"
            echo "  GIT_REPO         Default repo URL for --submit-git"
            echo "  GIT_BRANCH       Default branch for --submit-git"
            echo ""
            echo "Examples:"
            echo "  $0 --wait"
            echo "  $0 --submit-gh --gh-repo myuser/ipv6-results --gh-method issue"
            echo "  $0 --submit-git --git-repo git@github.com:myuser/ipv6-results.git"
            echo "  $0 --submit-api --gh-repo myuser/ipv6-results --gh-token ghp_xxx"
            exit 0
            ;;
        *)
            echo "Unknown option: $1"
            echo "Use --help for usage information"
            exit 1
            ;;
    esac
done

# Color output (disable if not a terminal)
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    CYAN='\033[0;36m'
    NC='\033[0m' # No Color
else
    RED=''
    GREEN=''
    YELLOW=''
    BLUE=''
    CYAN=''
    NC=''
fi

# ============================================================================
# GitHub Submission Functions (all optional)
# ============================================================================

# Generate result data for submission
generate_result_data() {
    local score="${1:-N/A}"
    local ipv4_ok="${2:-N/A}"
    local ipv6_ok="${3:-N/A}"
    local site_count="${4:-N/A}"
    local timestamp="${5:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

    cat <<EOF
{
  "testPointId": "$TEST_POINT_ID",
  "location": "$LOCATION",
  "timestamp": "$timestamp",
  "score": $score,
  "ipv4Success": $ipv4_ok,
  "ipv6Success": $ipv6_ok,
  "siteTestCount": $site_count,
  "asn": ${ASN:+\"$ASN\"},
  "ipv4Prefix": ${IPV4_OBFUSCATED:+\"$IPV4_OBFUSCATED\"},
  "ipv6Prefix": ${IPV6_OBFUSCATED:+\"$IPV6_OBFUSCATED\"}
}
EOF
}

# Submit results via GitHub CLI (gh)
submit_via_gh_cli() {
    local result_data="$1"
    local title="IPv6 Test Results: $TEST_POINT_ID - $(date -u +%Y-%m-%d)"

    echo -e "${YELLOW}Submitting results via GitHub CLI...${NC}"

    local body="## IPv6 Connectivity Test Results

**Test Point:** $TEST_POINT_ID
**Location:** $LOCATION
**Timestamp:** $(date -u +%Y-%m-%dT%H:%M:%SZ)

### Results
\`\`\`json
$result_data
\`\`\`

---
*Submitted automatically by trigger-tests.sh*"

    if [ "$GH_METHOD" = "issue" ]; then
        if gh issue create --repo "$GH_REPO" --title "$title" --body "$body" 2>/dev/null; then
            echo -e "${GREEN}✓ Results submitted as GitHub issue${NC}"
            return 0
        else
            echo -e "${RED}✗ Failed to create GitHub issue${NC}"
            return 1
        fi
    elif [ "$GH_METHOD" = "pr" ]; then
        # For PR, we need to create a branch and file first
        local temp_dir=$(mktemp -d)
        local branch_name="test-results-$TEST_POINT_ID-$(date -u +%Y%m%d%H%M%S)"
        local filename="test-runs/individual/${TEST_POINT_ID}-$(date -u +%Y-%m-%d).json"

        (
            cd "$temp_dir"
            gh repo clone "$GH_REPO" . -- --depth 1 2>/dev/null
            git checkout -b "$branch_name"
            mkdir -p "$(dirname "$filename")"
            echo "$result_data" > "$filename"
            git add "$filename"
            git commit -m "Add test results for $TEST_POINT_ID"
            git push origin "$branch_name"
            gh pr create --repo "$GH_REPO" --title "$title" --body "$body" --head "$branch_name"
        ) 2>/dev/null

        local exit_code=$?
        rm -rf "$temp_dir"

        if [ $exit_code -eq 0 ]; then
            echo -e "${GREEN}✓ Results submitted as GitHub PR${NC}"
            return 0
        else
            echo -e "${RED}✗ Failed to create GitHub PR${NC}"
            return 1
        fi
    fi
}

# Submit results via direct git push
submit_via_git_push() {
    local result_data="$1"
    local temp_dir=$(mktemp -d)
    local filename="test-runs/individual/${TEST_POINT_ID}-$(date -u +%Y-%m-%d).json"

    echo -e "${YELLOW}Submitting results via git push...${NC}"

    (
        cd "$temp_dir"
        git clone --depth 1 --branch "$GIT_BRANCH" "$GIT_REPO" . 2>/dev/null
        mkdir -p "$(dirname "$filename")"
        echo "$result_data" > "$filename"
        git add "$filename"
        git commit -m "Add test results for $TEST_POINT_ID - $(date -u +%Y-%m-%d)"
        git push origin "$GIT_BRANCH"
    ) 2>/dev/null

    local exit_code=$?
    rm -rf "$temp_dir"

    if [ $exit_code -eq 0 ]; then
        echo -e "${GREEN}✓ Results pushed to git repository${NC}"
        return 0
    else
        echo -e "${RED}✗ Failed to push results to git repository${NC}"
        return 1
    fi
}

# Submit results via GitHub REST API
submit_via_github_api() {
    local result_data="$1"
    local title="IPv6 Test Results: $TEST_POINT_ID - $(date -u +%Y-%m-%d)"

    echo -e "${YELLOW}Submitting results via GitHub API...${NC}"

    # Escape the result data for JSON
    local escaped_data=$(echo "$result_data" | sed 's/"/\\"/g' | tr '\n' ' ')

    local body="## IPv6 Connectivity Test Results\n\n**Test Point:** $TEST_POINT_ID\n**Location:** $LOCATION\n**Timestamp:** $(date -u +%Y-%m-%dT%H:%M:%SZ)\n\n### Results\n\`\`\`json\n$escaped_data\n\`\`\`\n\n---\n*Submitted automatically by trigger-tests.sh*"

    local api_response=$(curl -s -w "\n%{http_code}" -X POST \
        "https://api.github.com/repos/$GH_REPO/issues" \
        -H "Authorization: token $GH_TOKEN" \
        -H "Accept: application/vnd.github.v3+json" \
        -H "Content-Type: application/json" \
        -d "{\"title\": \"$title\", \"body\": \"$body\", \"labels\": [\"test-results\", \"automated\"]}" \
        2>&1)

    local api_http_code=$(echo "$api_response" | tail -n1)

    if [ "$api_http_code" = "201" ]; then
        local issue_url=$(echo "$api_response" | head -n-1 | grep -o '"html_url":"[^"]*"' | head -1 | cut -d'"' -f4)
        echo -e "${GREEN}✓ Results submitted as GitHub issue${NC}"
        [ -n "$issue_url" ] && echo "  Issue URL: $issue_url"
        return 0
    else
        echo -e "${RED}✗ Failed to create GitHub issue (HTTP $api_http_code)${NC}"
        return 1
    fi
}

# Run all enabled submission methods
run_submissions() {
    local result_data="$1"
    local any_submission=false

    if [ "$SUBMIT_GH" = true ]; then
        any_submission=true
        submit_via_gh_cli "$result_data"
    fi

    if [ "$SUBMIT_GIT" = true ]; then
        any_submission=true
        submit_via_git_push "$result_data"
    fi

    if [ "$SUBMIT_API" = true ]; then
        any_submission=true
        submit_via_github_api "$result_data"
    fi

    if [ "$any_submission" = true ]; then
        echo ""
    fi
}

# ============================================================================
# Main Script
# ============================================================================

# Check for required token
if [ -z "$API_TOKEN" ]; then
    echo -e "${RED}Error: IPV6_ARMY_TOKEN environment variable is required${NC}"
    echo "Usage: IPV6_ARMY_TOKEN='your-token' $0"
    exit 1
fi

# Validate GitHub submission options
if [ "$SUBMIT_GH" = true ]; then
    if [ -z "$GH_REPO" ]; then
        echo -e "${RED}Error: --gh-repo is required when using --submit-gh${NC}"
        exit 1
    fi
    if ! command -v gh >/dev/null 2>&1; then
        echo -e "${RED}Error: GitHub CLI (gh) is required for --submit-gh${NC}"
        echo "Install from: https://cli.github.com/"
        exit 1
    fi
    if [[ "$GH_METHOD" != "issue" && "$GH_METHOD" != "pr" ]]; then
        echo -e "${RED}Error: --gh-method must be 'issue' or 'pr'${NC}"
        exit 1
    fi
fi

if [ "$SUBMIT_GIT" = true ]; then
    if [ -z "$GIT_REPO" ]; then
        echo -e "${RED}Error: --git-repo is required when using --submit-git${NC}"
        exit 1
    fi
    if ! command -v git >/dev/null 2>&1; then
        echo -e "${RED}Error: git is required for --submit-git${NC}"
        exit 1
    fi
fi

if [ "$SUBMIT_API" = true ]; then
    if [ -z "$GH_REPO" ]; then
        echo -e "${RED}Error: --gh-repo is required when using --submit-api${NC}"
        exit 1
    fi
    if [ -z "$GH_TOKEN" ]; then
        echo -e "${RED}Error: --gh-token or GITHUB_TOKEN env var is required for --submit-api${NC}"
        exit 1
    fi
fi

echo "IPv6.army Remote Test Point Trigger"
echo "===================================="
echo ""

# Auto-detect test point information
echo -e "${YELLOW}Detecting test point information...${NC}"

# Hostname
TEST_POINT_ID="${TEST_POINT_ID:-$(hostname -f 2>/dev/null || hostname)}"
echo "  Test Point: $TEST_POINT_ID"

# IPv4 address
IPV4=""
IPV4_OBFUSCATED=""
if command -v curl >/dev/null 2>&1; then
    IPV4=$(curl -s -4 --max-time 5 https://api.ipify.org 2>/dev/null || echo "")
fi
if [ -z "$IPV4" ]; then
    echo "  IPv4: Not detected"
else
    # Obfuscate IPv4 (keep /24 prefix)
    IPV4_OBFUSCATED=$(echo "$IPV4" | awk -F. '{print $1"."$2"."$3".0"}')
    echo "  IPv4: $IPV4_OBFUSCATED/24 (obfuscated)"
fi

# IPv6 address
IPV6=""
IPV6_OBFUSCATED=""
if command -v curl >/dev/null 2>&1; then
    IPV6=$(curl -s -6 --max-time 5 https://api64.ipify.org 2>/dev/null || echo "")
fi
if [ -z "$IPV6" ]; then
    echo "  IPv6: Not detected"
else
    # Obfuscate IPv6 (keep /48 prefix)
    IPV6_OBFUSCATED=$(echo "$IPV6" | awk -F: '{print $1":"$2":"$3"::"}')
    echo "  IPv6: $IPV6_OBFUSCATED/48 (obfuscated)"
fi

# ASN detection
ASN=""
if [ -n "$IPV4" ] && command -v curl >/dev/null 2>&1; then
    ASN=$(curl -s --max-time 5 "https://ipinfo.io/${IPV4}/org" 2>/dev/null | cut -d' ' -f1 || echo "")
fi
if [ -z "$ASN" ]; then
    echo "  ASN: Not detected"
else
    echo "  ASN: $ASN"
fi

# Location (from environment or default)
LOCATION="${LOCATION:-unknown}"
echo "  Location: $LOCATION"

# Show enabled submission methods
if [ "$SUBMIT_GH" = true ] || [ "$SUBMIT_GIT" = true ] || [ "$SUBMIT_API" = true ]; then
    echo ""
    echo -e "${CYAN}GitHub submission enabled:${NC}"
    [ "$SUBMIT_GH" = true ] && echo "  • GitHub CLI ($GH_METHOD) → $GH_REPO"
    [ "$SUBMIT_GIT" = true ] && echo "  • Git push → $GIT_REPO ($GIT_BRANCH)"
    [ "$SUBMIT_API" = true ] && echo "  • GitHub API → $GH_REPO"
fi

echo ""

# Build JSON payload
JSON_PAYLOAD=$(cat <<EOF
{
  "testPointId": "$TEST_POINT_ID",
  "location": "$LOCATION",
  "asn": ${ASN:+\"$ASN\"},
  "ipv4": ${IPV4_OBFUSCATED:+\"$IPV4_OBFUSCATED\"},
  "ipv6": ${IPV6_OBFUSCATED:+\"$IPV6_OBFUSCATED\"}
}
EOF
)

# Remove null fields
JSON_PAYLOAD=$(echo "$JSON_PAYLOAD" | grep -v ': ,$' || echo "$JSON_PAYLOAD")

echo -e "${YELLOW}Triggering test via API...${NC}"
echo "  API URL: $API_URL"
echo ""

# Make API request
RESPONSE=$(curl -s -w "\n%{http_code}" -X POST "$API_URL" \
  -H "Authorization: Bearer $API_TOKEN" \
  -H "Content-Type: application/json" \
  -d "$JSON_PAYLOAD" \
  2>&1)

# Extract HTTP status code (last line)
HTTP_CODE=$(echo "$RESPONSE" | tail -n1)
RESPONSE_BODY=$(echo "$RESPONSE" | head -n-1)

# Check response
if [ "$HTTP_CODE" = "200" ]; then
    echo -e "${GREEN}✓ Test triggered successfully${NC}"
    echo ""

    # Extract job ID
    JOB_ID=$(echo "$RESPONSE_BODY" | grep -o '"jobId":"[^"]*"' | cut -d'"' -f4 || echo "")

    echo "Response:"
    echo "$RESPONSE_BODY" | grep -E '"(success|jobId|message|workflowUrl)"' || echo "$RESPONSE_BODY"
    echo ""

    # Extract workflow URL if available
    WORKFLOW_URL=$(echo "$RESPONSE_BODY" | grep -o '"workflowUrl":"[^"]*"' | cut -d'"' -f4 || echo "")
    if [ -n "$WORKFLOW_URL" ]; then
        echo "View test execution: $WORKFLOW_URL"
    fi

    # If --wait flag is set, poll for results
    if [ "$WAIT_FOR_RESULTS" = true ]; then
        echo ""
        echo -e "${YELLOW}Waiting for test results...${NC}"
        echo "(This may take 3-5 minutes. Press Ctrl+C to cancel.)"
        echo ""

        ELAPSED=0
        RESULTS_URL="https://raw.githubusercontent.com/ipv6-logbot/ipv6.army-data/main/test-runs/individual/${TEST_POINT_ID}-"
        TODAY=$(date -u +%Y-%m-%d)

        while [ $ELAPSED -lt $MAX_WAIT_TIME ]; do
            # Show progress
            printf "\r  Waiting... %ds / %ds" $ELAPSED $MAX_WAIT_TIME

            # Try to fetch today's results for this test point
            # Check the daily JSONL file for our job
            JSONL_URL="https://raw.githubusercontent.com/ipv6-logbot/ipv6.army-data/main/test-runs/${TODAY}.jsonl"
            JSONL_CONTENT=$(curl -s --max-time 10 "$JSONL_URL" 2>/dev/null || echo "")

            if [ -n "$JSONL_CONTENT" ] && echo "$JSONL_CONTENT" | grep -q "\"testPointId\":\"$TEST_POINT_ID\""; then
                # Found results! Get the latest entry for our test point
                LATEST_RESULT=$(echo "$JSONL_CONTENT" | grep "\"testPointId\":\"$TEST_POINT_ID\"" | tail -1)

                if [ -n "$LATEST_RESULT" ]; then
                    echo ""
                    echo ""
                    echo -e "${GREEN}✓ Test results received!${NC}"
                    echo ""
                    echo "═══════════════════════════════════════════════════════════"
                    echo -e "${CYAN}TEST RESULTS${NC}"
                    echo "═══════════════════════════════════════════════════════════"
                    echo ""

                    # Parse and display results
                    SCORE=$(echo "$LATEST_RESULT" | grep -o '"score":[0-9]*' | cut -d: -f2 || echo "N/A")
                    IPV4_OK=$(echo "$LATEST_RESULT" | grep -o '"ipv4Success":[a-z]*' | cut -d: -f2 || echo "N/A")
                    IPV6_OK=$(echo "$LATEST_RESULT" | grep -o '"ipv6Success":[a-z]*' | cut -d: -f2 || echo "N/A")
                    SITE_COUNT=$(echo "$LATEST_RESULT" | grep -o '"siteTestCount":[0-9]*' | cut -d: -f2 || echo "N/A")
                    TIMESTAMP=$(echo "$LATEST_RESULT" | grep -o '"timestamp":"[^"]*"' | cut -d'"' -f4 || echo "N/A")

                    echo -e "  ${BLUE}Score:${NC}        $SCORE / 10"
                    echo -e "  ${BLUE}IPv4:${NC}         $([ "$IPV4_OK" = "true" ] && echo -e "${GREEN}Connected${NC}" || echo -e "${RED}No connectivity${NC}")"
                    echo -e "  ${BLUE}IPv6:${NC}         $([ "$IPV6_OK" = "true" ] && echo -e "${GREEN}Connected${NC}" || echo -e "${RED}No connectivity${NC}")"
                    echo -e "  ${BLUE}Sites tested:${NC} $SITE_COUNT"
                    echo -e "  ${BLUE}Timestamp:${NC}    $TIMESTAMP"
                    echo ""
                    echo "═══════════════════════════════════════════════════════════"
                    echo ""
                    echo "Full results: https://github.com/ipv6-logbot/ipv6.army-data/tree/main/test-runs"
                    echo ""

                    # Submit results to GitHub if any submission method is enabled
                    RESULT_DATA=$(generate_result_data "$SCORE" "$IPV4_OK" "$IPV6_OK" "$SITE_COUNT" "$TIMESTAMP")
                    run_submissions "$RESULT_DATA"

                    exit 0
                fi
            fi

            sleep $POLL_INTERVAL
            ELAPSED=$((ELAPSED + POLL_INTERVAL))
        done

        echo ""
        echo ""
        echo -e "${YELLOW}⏱ Timeout waiting for results${NC}"
        echo "The test may still be running. Check results at:"
        echo "  $WORKFLOW_URL"
        echo "  https://github.com/ipv6-logbot/ipv6.army-data/tree/main/test-runs"
        exit 0
    fi

    # Submit trigger info to GitHub if any submission method is enabled (no results yet)
    if [ "$SUBMIT_GH" = true ] || [ "$SUBMIT_GIT" = true ] || [ "$SUBMIT_API" = true ]; then
        echo ""
        echo -e "${YELLOW}Note: Submitting trigger info only (use --wait to submit full results)${NC}"
        RESULT_DATA=$(generate_result_data "null" "null" "null" "null")
        run_submissions "$RESULT_DATA"
    fi

    exit 0
else
    echo -e "${RED}✗ Test trigger failed (HTTP $HTTP_CODE)${NC}"
    echo ""
    echo "Response:"
    echo "$RESPONSE_BODY"
    echo ""

    # Provide helpful error messages
    case "$HTTP_CODE" in
        401|403)
            echo -e "${YELLOW}Hint: Check that your IPV6_ARMY_TOKEN is correct${NC}"
            ;;
        429)
            echo -e "${YELLOW}Hint: Rate limit exceeded. Wait before retrying.${NC}"
            ;;
        500)
            echo -e "${YELLOW}Hint: Server error. Try again later or contact support.${NC}"
            ;;
    esac

    exit 1
fi

