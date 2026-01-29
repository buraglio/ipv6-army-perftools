#!/bin/bash
#
# ipv6perftest - IPv6 Performance Test Tool
#
# Remote test point trigger script for NLNOG RING nodes and other endpoints.
# Tests IPv4/IPv6 connectivity and reports results to ipv6.army.
#
# Only requires: curl, bash, hostname, and standard utilities.
#
# Usage:
#   1. Set environment variables:
#      export IPV6_ARMY_TOKEN="your-api-token"
#      export LOCATION="Amsterdam,NL"  # Optional
#
#   2. Run the script:
#      ./ipv6perftest --local      # Run local connectivity tests
#      ./ipv6perftest              # Trigger test via API
#      ./ipv6perftest --wait       # Trigger and wait for results
#
# Or as one-liner:
#   IPV6_ARMY_TOKEN="token" LOCATION="Amsterdam,NL" ./ipv6perftest --local
#
# Cron example (daily at 6 AM):
#   0 6 * * * IPV6_ARMY_TOKEN="token" LOCATION="Amsterdam,NL" /path/to/ipv6perftest --local >> /var/log/ipv6-test.log 2>&1
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
TIMEOUT=10         # Per-site timeout in seconds

# Mode flags
LOCAL_TEST=false
SUBMIT_RESULTS=false
VERBOSE=false

# GitHub submission options (all optional)
SUBMIT_GH=false
SUBMIT_GIT=false
SUBMIT_API=false
GH_REPO="${GH_REPO:-}"
GH_METHOD="${GH_METHOD:-issue}"  # "issue" or "pr"
GIT_REPO="${GIT_REPO:-}"
GIT_BRANCH="${GIT_BRANCH:-main}"
GH_TOKEN="${GITHUB_TOKEN:-}"

# Test sites - matches ipv6.army test sites
declare -a TEST_SITES=(
    "Wikipedia|https://www.wikipedia.org"
    "Google|https://www.google.com"
    "Facebook|https://www.facebook.com"
    "YouTube|https://www.youtube.com"
    "Netflix|https://www.netflix.com"
    "GitHub|https://github.com"
    "Cloudflare|https://www.cloudflare.com"
    "Microsoft|https://www.microsoft.com"
    "Apple|https://www.apple.com"
    "Amazon|https://www.amazon.com"
    "Reddit|https://www.reddit.com"
    "Twitter/X|https://www.x.com"
    "Cisco|https://www.cisco.com"
    "Yahoo|https://www.yahoo.com"
    "Yandex|https://www.yandex.com"
    "Zoom|https://zoom.us"
    "CNN|https://www.cnn.com"
    "ESPN|https://www.espn.com"
    "Spotify|https://www.spotify.com"
    "Gitlab|https://gitlab.com"
    "Codeberg|https://codeberg.org"
    "Dockerhub|https://hub.docker.com"
)

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --local|-l)
            LOCAL_TEST=true
            shift
            ;;
        --wait|-w)
            WAIT_FOR_RESULTS=true
            shift
            ;;
        --submit-results)
            SUBMIT_RESULTS=true
            shift
            ;;
        --verbose)
            VERBOSE=true
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
        --location)
            LOCATION="$2"
            shift 2
            ;;
        --api-url)
            API_URL="$2"
            shift 2
            ;;
        --api-token)
            API_TOKEN="$2"
            shift 2
            ;;
        --help|-h)
            echo "Usage: $0 [OPTIONS]"
            echo ""
            echo "Modes:"
            echo "  --local, -l          Run local connectivity tests (no API trigger)"
            echo "  (default)            Trigger test via API (requires IPV6_ARMY_TOKEN)"
            echo ""
            echo "Options:"
            echo "  --wait, -w           Wait for test results and display them (API mode only)"
            echo "  --submit-results     Submit local test results to ipv6.army API"
            echo "  --verbose            Show detailed output"
            echo "  --location LOC       Geographic location"
            echo "  --api-url URL        Override API endpoint"
            echo "  --api-token TOKEN    API authentication token"
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
            echo "  IPV6_ARMY_TOKEN  API authentication token (not needed with --local)"
            echo "  LOCATION         Geographic location (optional)"
            echo "  TEST_POINT_ID    Custom test point identifier (optional)"
            echo "  API_URL          Override API endpoint (optional)"
            echo "  GITHUB_TOKEN     GitHub PAT for --submit-api (optional)"
            echo "  GH_REPO          Default repo for --submit-gh and --submit-api"
            echo "  GIT_REPO         Default repo URL for --submit-git"
            echo "  GIT_BRANCH       Default branch for --submit-git"
            echo ""
            echo "Examples:"
            echo "  $0 --local                     # Run local tests, no API needed"
            echo "  $0 --local --submit-gh --gh-repo user/repo"
            echo "  $0 --wait                      # Trigger API and wait for results"
            echo "  $0 --submit-gh --gh-repo myuser/ipv6-results --gh-method issue"
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
# Site Test Results Storage
# ============================================================================
declare -a SITE_RESULTS=()

# ============================================================================
# Local Connectivity Testing Functions
# ============================================================================

# Test connectivity to a URL over IPv4 or IPv6
# Returns: latency in ms if successful, empty string if failed
test_connectivity() {
    local network="$1"  # "4" or "6"
    local url="$2"
    local start end latency

    start=$(date +%s%3N 2>/dev/null || echo "0")

    if curl -s -"$network" --max-time "$TIMEOUT" -o /dev/null -w "%{http_code}" \
        -A "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36" \
        -H "Accept: text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8" \
        -H "Accept-Language: en-US,en;q=0.5" \
        -H "Connection: close" \
        "$url" 2>/dev/null | grep -qE "^[23]"; then

        end=$(date +%s%3N 2>/dev/null || echo "0")
        if [ "$start" != "0" ] && [ "$end" != "0" ]; then
            latency=$((end - start))
            echo "$latency"
        else
            echo "1"  # Success but couldn't measure latency
        fi
    else
        echo ""
    fi
}

# Test a single site for both IPv4 and IPv6
test_site() {
    local name="$1"
    local url="$2"
    local v4_latency v6_latency v4_result v6_result

    # Test IPv4
    v4_latency=$(test_connectivity "4" "$url")
    if [ -n "$v4_latency" ]; then
        v4_result="$v4_latency"
    else
        v4_result="null"
    fi

    # Test IPv6
    v6_latency=$(test_connectivity "6" "$url")
    if [ -n "$v6_latency" ]; then
        v6_result="$v6_latency"
    else
        v6_result="null"
    fi

    # Store result as JSON-like string
    SITE_RESULTS+=("{\"name\":\"$name\",\"url\":\"$url\",\"v4\":$v4_result,\"v6\":$v6_result}")

    # Return success counts (0=both failed, 1=v4 only, 2=v6 only, 3=both)
    local result=0
    [ -n "$v4_latency" ] && result=$((result + 1))
    [ -n "$v6_latency" ] && result=$((result + 2))
    echo "$result"
}

# Run local connectivity tests
run_local_tests() {
    echo "IPv6 Connectivity Test Tool"
    echo "==========================="
    echo ""

    # Show configuration in verbose mode
    if [ "$VERBOSE" = true ]; then
        echo -e "${CYAN}Configuration:${NC}"
        echo "  API URL: $API_URL"
        if [ -n "$API_TOKEN" ]; then
            echo "  API Token: ${API_TOKEN:0:4}****${API_TOKEN: -4}"
        else
            echo "  API Token: <not set>"
        fi
        echo "  Submit Results: $SUBMIT_RESULTS"
        echo ""
    fi

    # Auto-detect test point information
    echo -e "${YELLOW}Detecting test point information...${NC}"
    detect_test_point_info

    echo ""
    echo -e "${YELLOW}Testing connectivity to ${#TEST_SITES[@]} sites...${NC}"
    echo ""

    local ipv4_successes=0
    local ipv6_successes=0
    local total=${#TEST_SITES[@]}
    local i=0

    for site in "${TEST_SITES[@]}"; do
        local name="${site%%|*}"
        local url="${site##*|}"
        i=$((i + 1))

        printf "\r  Testing %d/%d: %-20s" "$i" "$total" "$name"

        local result
        result=$(test_site "$name" "$url")

        # Count successes
        if [ "$((result & 1))" -eq 1 ]; then
            ipv4_successes=$((ipv4_successes + 1))
        fi
        if [ "$((result & 2))" -eq 2 ]; then
            ipv6_successes=$((ipv6_successes + 1))
        fi
    done

    # Clear the progress line
    printf "\r%-60s\r" ""

    # Calculate score (weighted: IPv6 worth more)
    local ipv4_pct ipv6_pct score
    ipv4_pct=$(echo "scale=2; $ipv4_successes / $total" | bc)
    ipv6_pct=$(echo "scale=2; $ipv6_successes / $total" | bc)
    # Score: 40% IPv4 + 60% IPv6
    score=$(echo "scale=0; ($ipv4_pct * 0.4 + $ipv6_pct * 0.6) * 10 / 1" | bc)

    local timestamp
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)

    # Determine success flags
    local ipv4_ok="false"
    local ipv6_ok="false"
    [ "$ipv4_successes" -gt 0 ] && ipv4_ok="true"
    [ "$ipv6_successes" -gt 0 ] && ipv6_ok="true"

    # Print results
    echo ""
    echo -e "${GREEN}✓ Tests completed!${NC}"
    echo ""
    echo "═══════════════════════════════════════════════════════════"
    echo -e "${CYAN}TEST RESULTS${NC}"
    echo "═══════════════════════════════════════════════════════════"
    echo ""

    echo -e "  ${BLUE}Score:${NC}        $score / 10"

    if [ "$ipv4_ok" = "true" ]; then
        echo -e "  ${BLUE}IPv4:${NC}         ${GREEN}$ipv4_successes/$total sites reachable${NC}"
    else
        echo -e "  ${BLUE}IPv4:${NC}         ${RED}No connectivity${NC}"
    fi

    if [ "$ipv6_ok" = "true" ]; then
        echo -e "  ${BLUE}IPv6:${NC}         ${GREEN}$ipv6_successes/$total sites reachable${NC}"
    else
        echo -e "  ${BLUE}IPv6:${NC}         ${RED}No connectivity${NC}"
    fi

    echo -e "  ${BLUE}Sites tested:${NC} $total"
    echo -e "  ${BLUE}Timestamp:${NC}    $timestamp"

    # Verbose output: show per-site results
    if [ "$VERBOSE" = true ]; then
        echo ""
        echo "─────────────────────────────────────────────────────────────"
        echo -e "${CYAN}Per-site Results:${NC}"
        echo "─────────────────────────────────────────────────────────────"
        echo ""
        printf "  %-20s %-15s %-15s\n" "Site" "IPv4" "IPv6"
        printf "  %-20s %-15s %-15s\n" "────" "────" "────"

        for result in "${SITE_RESULTS[@]}"; do
            local name url v4 v6
            name=$(echo "$result" | grep -o '"name":"[^"]*"' | cut -d'"' -f4)
            v4=$(echo "$result" | grep -o '"v4":[^,}]*' | cut -d: -f2)
            v6=$(echo "$result" | grep -o '"v6":[^,}]*' | cut -d: -f2)

            local v4_display v6_display
            if [ "$v4" = "null" ]; then
                v4_display="${RED}✗${NC}"
            else
                v4_display="${GREEN}✓${NC} ${v4}ms"
            fi

            if [ "$v6" = "null" ]; then
                v6_display="${RED}✗${NC}"
            else
                v6_display="${GREEN}✓${NC} ${v6}ms"
            fi

            printf "  %-20s %-15b %-15b\n" "$name" "$v4_display" "$v6_display"
        done
    fi

    echo ""
    echo "═══════════════════════════════════════════════════════════"

    # Summary
    echo ""
    if [ "$ipv6_successes" -eq 0 ] && [ "$ipv4_successes" -gt 0 ]; then
        echo -e "${YELLOW}⚠ No IPv6 connectivity detected. Your network may be IPv4-only.${NC}"
    elif [ "$ipv6_successes" -gt 0 ] && [ "$ipv6_successes" -lt "$ipv4_successes" ]; then
        echo -e "${YELLOW}⚠ Partial IPv6 connectivity. Some sites may not have IPv6 or your connection is unstable.${NC}"
    elif [ "$ipv6_successes" -ge "$ipv4_successes" ] && [ "$ipv6_successes" -gt 0 ]; then
        echo -e "${GREEN}✓ Good IPv6 connectivity!${NC}"
    fi

    # Submit results to ipv6.army API if enabled
    if [ "$SUBMIT_RESULTS" = true ] && [ -n "$API_TOKEN" ]; then
        echo ""
        submit_local_results "$score" "$ipv4_ok" "$ipv6_ok" "$total" "$timestamp"
    fi

    # Submit to GitHub if enabled
    if [ "$SUBMIT_GH" = true ] || [ "$SUBMIT_GIT" = true ] || [ "$SUBMIT_API" = true ]; then
        echo ""
        local result_data
        result_data=$(generate_result_data "$score" "$ipv4_ok" "$ipv6_ok" "$total" "$timestamp")
        run_submissions "$result_data"
    fi
}

# Submit local test results to ipv6.army API
submit_local_results() {
    local score="$1"
    local ipv4_ok="$2"
    local ipv6_ok="$3"
    local site_count="$4"
    local timestamp="$5"

    echo -e "${YELLOW}Submitting results to ipv6.army API...${NC}"
    echo "  API URL: $API_URL"

    # Build siteTests JSON array
    local site_tests="["
    local first=true
    for result in "${SITE_RESULTS[@]}"; do
        if [ "$first" = true ]; then
            first=false
        else
            site_tests+=","
        fi
        site_tests+="$result"
    done
    site_tests+="]"

    # Build flat payload matching Go version
    local payload
    payload=$(cat <<EOF
{
  "testPointId": "$TEST_POINT_ID",
  "location": "$LOCATION",
  "asn": "$ASN",
  "ipv4Prefix": "$IPV4_OBFUSCATED",
  "ipv6Prefix": "$IPV6_OBFUSCATED",
  "score": $score,
  "ipv4Success": $ipv4_ok,
  "ipv6Success": $ipv6_ok,
  "siteTests": $site_tests,
  "timestamp": "$timestamp"
}
EOF
)

    # Show payload in verbose mode
    if [ "$VERBOSE" = true ]; then
        echo "  Payload:"
        echo "$payload" | sed 's/^/    /'
    fi

    # Submit to API
    local response http_code response_body
    response=$(curl -s -w "\n%{http_code}" -X POST "$API_URL" \
        -H "Authorization: Bearer $API_TOKEN" \
        -H "Content-Type: application/json" \
        -H "User-Agent: ipv6perftest/1.0" \
        -d "$payload" 2>&1)

    http_code=$(echo "$response" | tail -n1)
    response_body=$(echo "$response" | head -n-1)

    if [ "$http_code" = "200" ] || [ "$http_code" = "201" ]; then
        echo -e "${GREEN}✓ Results submitted to ipv6.army${NC}"
        if [ "$VERBOSE" = true ] && [ -n "$response_body" ]; then
            echo "  Response: $response_body"
        fi
    else
        echo -e "${RED}✗ API submission failed (HTTP $http_code): $response_body${NC}"
    fi
}

# ============================================================================
# Test Point Detection
# ============================================================================

detect_test_point_info() {
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
}

# ============================================================================
# GitHub Submission Functions (all optional)
# ============================================================================

# Generate result data for submission
generate_result_data() {
    local score="${1:-0}"
    local ipv4_ok="${2:-false}"
    local ipv6_ok="${3:-false}"
    local site_count="${4:-0}"
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
  "asn": "${ASN:-}",
  "ipv4Prefix": "${IPV4_OBFUSCATED:-}",
  "ipv6Prefix": "${IPV6_OBFUSCATED:-}"
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
*Submitted by ipv6perftest*"

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

    local body="## IPv6 Connectivity Test Results\n\n**Test Point:** $TEST_POINT_ID\n**Location:** $LOCATION\n**Timestamp:** $(date -u +%Y-%m-%dT%H:%M:%SZ)\n\n### Results\n\`\`\`json\n$escaped_data\n\`\`\`\n\n---\n*Submitted by ipv6perftest*"

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
# API Mode (Original Trigger Functionality)
# ============================================================================

run_api_mode() {
    # Check for required token
    if [ -z "$API_TOKEN" ]; then
        echo -e "${RED}Error: IPV6_ARMY_TOKEN environment variable is required${NC}"
        echo "Usage: IPV6_ARMY_TOKEN='your-token' $0"
        echo "Or use --local for local tests without API"
        exit 1
    fi

    echo "IPv6.army Remote Test Point Trigger"
    echo "===================================="
    echo ""

    # Auto-detect test point information
    echo -e "${YELLOW}Detecting test point information...${NC}"
    detect_test_point_info

    echo ""

    # Build JSON payload
    JSON_PAYLOAD=$(cat <<EOF
{
  "testPointId": "$TEST_POINT_ID",
  "location": "$LOCATION",
  "asn": "${ASN:-}",
  "ipv4": "${IPV4_OBFUSCATED:-}",
  "ipv6": "${IPV6_OBFUSCATED:-}"
}
EOF
)

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
            TODAY=$(date -u +%Y-%m-%d)

            while [ $ELAPSED -lt $MAX_WAIT_TIME ]; do
                # Show progress
                printf "\r  Waiting... %ds / %ds" $ELAPSED $MAX_WAIT_TIME

                # Try to fetch today's results for this test point
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
}

# ============================================================================
# Main Script
# ============================================================================

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

# Auto-enable result submission when running local tests with API token
if [ "$LOCAL_TEST" = true ] && [ -n "$API_TOKEN" ] && [ "$SUBMIT_RESULTS" = false ]; then
    SUBMIT_RESULTS=true
fi

# Run appropriate mode
if [ "$LOCAL_TEST" = true ]; then
    run_local_tests
else
    run_api_mode
fi
