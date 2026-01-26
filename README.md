# ipv6perftest

A lightweight command-line tool for testing IPv4/IPv6 connectivity from remote test points. Designed for use with headless nodes and similar distributed network infrastructure.

## Overview

`ipv6perftest` triggers IPv6 connectivity tests via the [ipv6.army](https://ipv6.army) API and optionally submits results to GitHub repositories. It auto-detects network information including:

- Hostname / Test Point ID
- IPv4 and IPv6 addresses (privacy-obfuscated)
- ASN (Autonomous System Number)
- Geographic location

## Requirements

**Required:**
- `bash` (4.0+)
- `curl`
- `hostname`

**Optional (for GitHub submission):**
- `gh` (GitHub CLI) - for `--submit-gh`
- `git` - for `--submit-git`

## Installation

```bash
# Clone the repository
git clone https://github.com/yourusername/ipv6-army-perftools.git
cd ipv6-army-perftools

# Make executable
chmod +x ipv6perftest

# Optional: Add to PATH
sudo ln -s $(pwd)/ipv6perftest /usr/local/bin/ipv6perftest
```

## Quick Start

```bash
# Set your API token
export IPV6_ARMY_TOKEN="your-api-token"

# Run a basic test
./ipv6perftest

# Run and wait for results
./ipv6perftest --wait

# With location
LOCATION="Amsterdam,NL" ./ipv6perftest --wait
```

## Usage

```
Usage: ipv6perftest [OPTIONS]

Options:
  --wait, -w           Wait for test results and display them
  --help, -h           Show this help message

GitHub Submission (all optional):
  --submit-gh          Submit results via GitHub CLI (gh)
  --submit-git         Submit results via direct git push
  --submit-api         Submit results via GitHub REST API

GitHub CLI options (--submit-gh):
  --gh-repo REPO       Target repo, e.g., owner/repo (required for --submit-gh)
  --gh-method METHOD   Submission method: 'issue' or 'pr' (default: issue)

Git push options (--submit-git):
  --git-repo URL       Git repository URL to push to (required for --submit-git)
  --git-branch BRANCH  Branch to push to (default: main)

GitHub API options (--submit-api):
  --gh-repo REPO       Target repo, e.g., owner/repo (required for --submit-api)
  --gh-token TOKEN     GitHub PAT (or set GITHUB_TOKEN env var)
```

## Environment Variables

| Variable | Required | Description |
|----------|----------|-------------|
| `IPV6_ARMY_TOKEN` | Yes | API authentication token from ipv6.army |
| `LOCATION` | No | Geographic location (e.g., "Amsterdam,NL") |
| `TEST_POINT_ID` | No | Custom test point identifier (defaults to hostname) |
| `API_URL` | No | Override API endpoint |
| `GITHUB_TOKEN` | No | GitHub PAT for `--submit-api` |
| `GH_REPO` | No | Default repo for `--submit-gh` and `--submit-api` |
| `GIT_REPO` | No | Default repo URL for `--submit-git` |
| `GIT_BRANCH` | No | Default branch for `--submit-git` (default: main) |

## Examples

### Basic Usage

```bash
# Simple test trigger (fire and forget)
./ipv6perftest

# Wait for results and display them
./ipv6perftest --wait

# With custom location
LOCATION="Frankfurt,DE" ./ipv6perftest --wait

# One-liner with all options
IPV6_ARMY_TOKEN="token" LOCATION="London,UK" ./ipv6perftest --wait
```

### GitHub Submission

#### Using GitHub CLI (Recommended)

```bash
# Submit as GitHub issue
./ipv6perftest --wait --submit-gh --gh-repo myuser/ipv6-results

# Submit as Pull Request
./ipv6perftest --wait --submit-gh --gh-repo myuser/ipv6-results --gh-method pr
```

#### Using Direct Git Push

```bash
# Push results directly to a repository
./ipv6perftest --wait --submit-git --git-repo git@github.com:myuser/ipv6-results.git

# Specify a different branch
./ipv6perftest --wait --submit-git --git-repo git@github.com:myuser/ipv6-results.git --git-branch develop
```

#### Using GitHub API

```bash
# Submit via REST API
./ipv6perftest --wait --submit-api --gh-repo myuser/ipv6-results --gh-token ghp_xxxxxxxxxxxx

# Using environment variable for token
export GITHUB_TOKEN="ghp_xxxxxxxxxxxx"
./ipv6perftest --wait --submit-api --gh-repo myuser/ipv6-results
```

#### Multiple Submission Methods

You can combine multiple submission methods in a single run:

```bash
./ipv6perftest --wait \
  --submit-gh --gh-repo myuser/ipv6-results \
  --submit-api --gh-repo myorg/central-results --gh-token ghp_xxx
```

### Cron Job Setup

Run tests automatically on a schedule:

```bash
# Daily at 6 AM UTC
0 6 * * * IPV6_ARMY_TOKEN="token" LOCATION="Amsterdam,NL" /path/to/ipv6perftest >> /var/log/ipv6-test.log 2>&1

# Every 4 hours with GitHub submission
0 */4 * * * IPV6_ARMY_TOKEN="token" LOCATION="NYC,US" /path/to/ipv6perftest --wait --submit-gh --gh-repo myuser/results >> /var/log/ipv6-test.log 2>&1

# Hourly during business hours (Mon-Fri, 9-17)
0 9-17 * * 1-5 IPV6_ARMY_TOKEN="token" /path/to/ipv6perftest --wait >> /var/log/ipv6-test.log 2>&1
```

### NLNOG RING Deployment

For NLNOG RING nodes:

```bash
# Create a wrapper script
cat > /usr/local/bin/ring-ipv6test << 'EOF'
#!/bin/bash
export IPV6_ARMY_TOKEN="your-token"
export LOCATION="$(cat /etc/ring/location 2>/dev/null || echo 'Unknown')"
/path/to/ipv6perftest --wait "$@"
EOF
chmod +x /usr/local/bin/ring-ipv6test
```

## Output

### Successful Test Trigger

```
IPv6.army Remote Test Point Trigger
====================================

Detecting test point information...
  Test Point: node01.example.com
  IPv4: 203.0.113.0/24 (obfuscated)
  IPv6: 2001:db8:1234::/48 (obfuscated)
  ASN: AS64496
  Location: Amsterdam,NL

Triggering test via API...
  API URL: https://ipv6.army/api/test/trigger

✓ Test triggered successfully

Response:
  "success":true
  "jobId":"abc123"
  "workflowUrl":"https://github.com/..."

View test execution: https://github.com/...
```

### With Results (--wait)

```
═══════════════════════════════════════════════════════════
TEST RESULTS
═══════════════════════════════════════════════════════════

  Score:        8 / 10
  IPv4:         Connected
  IPv6:         Connected
  Sites tested: 25
  Timestamp:    2024-01-15T10:30:00Z

═══════════════════════════════════════════════════════════

Full results: https://github.com/ipv6-logbot/ipv6.army-data/tree/main/test-runs
```

## Privacy

`ipv6perftest` automatically obfuscates IP addresses before transmission:

- **IPv4**: Only the /24 prefix is reported (e.g., `203.0.113.0`)
- **IPv6**: Only the /48 prefix is reported (e.g., `2001:db8:1234::`)

This provides useful network identification while protecting individual host addresses.

## Exit Codes

| Code | Meaning |
|------|---------|
| 0 | Success |
| 1 | Error (missing token, API failure, invalid options) |

## Troubleshooting

### Common Errors

**"IPV6_ARMY_TOKEN environment variable is required"**
```bash
export IPV6_ARMY_TOKEN="your-token-here"
```

**"GitHub CLI (gh) is required for --submit-gh"**
```bash
# Install GitHub CLI
# macOS
brew install gh

# Ubuntu/Debian
sudo apt install gh

# Then authenticate
gh auth login
```

**"HTTP 401/403 - Check that your IPV6_ARMY_TOKEN is correct"**
- Verify your token is valid and hasn't expired
- Ensure there are no extra spaces or quotes around the token

**"HTTP 429 - Rate limit exceeded"**
- Wait before retrying
- Consider reducing test frequency in cron jobs

### Debug Mode

For troubleshooting, run with bash debug output:

```bash
bash -x ./ipv6perftest --wait
```

## Contributing

Contributions are welcome! Please feel free to submit issues and pull requests.

## License

Apache 2.0 - see [LICENSE](LICENSE) for details.

## Related Links

- [ipv6.army](https://ipv6.army) - IPv6 connectivity testing platform
- [NLNOG RING](https://ring.nlnog.net/) - Network operators' looking glass ring
- [GitHub CLI](https://cli.github.com/) - GitHub's official command-line tool
