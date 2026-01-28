// ipv6perftest - IPv6 Performance Test Tool
//
// A Go application for testing IPv4/IPv6 connectivity from remote test points.
// Supports compile-time configuration via ldflags with runtime environment overrides.
//
// Build with embedded defaults:
//
//	go build -ldflags "-X main.defaultAPIToken=your-token -X main.defaultGHRepo=user/repo" -o ipv6perftest
//
// Apache 2.0 licensed https://www.apache.org/licenses/LICENSE-2.0.txt

package main

import (
	"bytes"
	"context"
	"encoding/json"
	"flag"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"os/exec"
	"path/filepath"
	"strings"
	"time"
)

// Version information (set via ldflags)
var (
	version   = "dev"
	buildTime = "unknown"
)

// Compile-time defaults (set via ldflags: -X main.defaultAPIToken=xxx)
var (
	defaultAPIToken   string
	defaultAPIURL     string
	defaultGHToken    string
	defaultGHRepo     string
	defaultGHMethod   string
	defaultGitRepo    string
	defaultGitBranch  string
	defaultLocation   string
	defaultLocalTest  string // Set to "true" to make local tests the default
)

// Config holds all configuration values
type Config struct {
	// API settings
	APIToken string
	APIURL   string

	// Test point info
	TestPointID string
	Location    string

	// Behavior
	Wait         bool
	LocalTest    bool // Run local connectivity tests instead of API trigger
	MaxWaitTime  time.Duration
	PollInterval time.Duration
	Timeout      time.Duration // Per-site test timeout

	// GitHub submission
	SubmitGH  bool
	SubmitGit bool
	SubmitAPI bool
	GHRepo    string
	GHMethod  string // "issue" or "pr"
	GHToken   string
	GitRepo   string
	GitBranch string

	// Display
	NoColor bool
	Verbose bool
}

// SiteTest represents a single site connectivity test
type SiteTest struct {
	Name        string `json:"name"`
	URL         string `json:"url"`
	IPv4Success bool   `json:"ipv4Success"`
	IPv6Success bool   `json:"ipv6Success"`
	IPv4Latency int64  `json:"ipv4LatencyMs,omitempty"`
	IPv6Latency int64  `json:"ipv6LatencyMs,omitempty"`
	IPv4Error   string `json:"ipv4Error,omitempty"`
	IPv6Error   string `json:"ipv6Error,omitempty"`
}

// Sites to test - matches ipv6.army test sites
var testSites = []struct {
	Name string
	URL  string
}{
	{"Wikipedia", "https://www.wikipedia.org"},
	{"Google", "https://www.google.com"},
	{"Facebook", "https://www.facebook.com"},
	{"YouTube", "https://www.youtube.com"},
	{"Netflix", "https://www.netflix.com"},
	{"GitHub", "https://github.com"},
	{"Cloudflare", "https://www.cloudflare.com"},
	{"Akamai", "https://www.akamai.com"},
	{"Microsoft", "https://www.microsoft.com"},
	{"Apple", "https://www.apple.com"},
	{"Amazon", "https://www.amazon.com"},
	{"Reddit", "https://www.reddit.com"},
	{"Twitter/X", "https://www.x.com"},
	{"Cisco", "https://www.cisco.com"},
	{"Yahoo", "https://www.yahoo.com"},
	{"Yandex", "https://www.yandex.com"},
	{"Zoom", "https://zoom.us"},
	{"CNN", "https://www.cnn.com"},
	{"ESPN", "https://www.espn.com"},
	{"Spotify", "https://www.spotify.com"},
	{"Gitlab", "https://gitlab.com"},
	{"Codeberg", "https://codeberg.org"},
	{"Dockerhub", "https://hub.docker.com"},
}

// TestPointInfo holds auto-detected network information
type TestPointInfo struct {
	TestPointID    string `json:"testPointId"`
	Location       string `json:"location"`
	IPv4           string `json:"ipv4,omitempty"`
	IPv4Obfuscated string `json:"ipv4Prefix,omitempty"`
	IPv6           string `json:"ipv6,omitempty"`
	IPv6Obfuscated string `json:"ipv6Prefix,omitempty"`
	ASN            string `json:"asn,omitempty"`
}

// TestResult holds the test results
type TestResult struct {
	TestPointID   string `json:"testPointId"`
	Location      string `json:"location"`
	Timestamp     string `json:"timestamp"`
	Score         int    `json:"score"`
	IPv4Success   bool   `json:"ipv4Success"`
	IPv6Success   bool   `json:"ipv6Success"`
	SiteTestCount int    `json:"siteTestCount"`
	ASN           string `json:"asn,omitempty"`
	IPv4Prefix    string `json:"ipv4Prefix,omitempty"`
	IPv6Prefix    string `json:"ipv6Prefix,omitempty"`
}

// APIResponse represents the API response
type APIResponse struct {
	Success     bool   `json:"success"`
	JobID       string `json:"jobId"`
	Message     string `json:"message"`
	WorkflowURL string `json:"workflowUrl"`
}

// ANSI color codes
type colors struct {
	Red    string
	Green  string
	Yellow string
	Blue   string
	Cyan   string
	Reset  string
}

var c colors

func initColors(noColor bool) {
	if noColor || os.Getenv("NO_COLOR") != "" {
		c = colors{}
		return
	}
	// Check if stdout is a terminal
	if fileInfo, _ := os.Stdout.Stat(); (fileInfo.Mode() & os.ModeCharDevice) == 0 {
		c = colors{}
		return
	}
	c = colors{
		Red:    "\033[0;31m",
		Green:  "\033[0;32m",
		Yellow: "\033[1;33m",
		Blue:   "\033[0;34m",
		Cyan:   "\033[0;36m",
		Reset:  "\033[0m",
	}
}

func main() {
	cfg := parseFlags()
	initColors(cfg.NoColor)

	if err := run(cfg); err != nil {
		fmt.Fprintf(os.Stderr, "%sError: %v%s\n", c.Red, err, c.Reset)
		os.Exit(1)
	}
}

func parseFlags() *Config {
	cfg := &Config{
		MaxWaitTime:  5 * time.Minute,
		PollInterval: 10 * time.Second,
		Timeout:      10 * time.Second,
	}

	// Define flags
	flag.BoolVar(&cfg.LocalTest, "local", false, "Run local connectivity tests (no API required)")
	flag.BoolVar(&cfg.LocalTest, "l", false, "Run local connectivity tests (shorthand)")
	flag.BoolVar(&cfg.Wait, "wait", false, "Wait for test results and display them (API mode only)")
	flag.BoolVar(&cfg.Wait, "w", false, "Wait for test results (shorthand)")

	flag.BoolVar(&cfg.SubmitGH, "submit-gh", false, "Submit results via GitHub CLI (gh)")
	flag.BoolVar(&cfg.SubmitGit, "submit-git", false, "Submit results via direct git push")
	flag.BoolVar(&cfg.SubmitAPI, "submit-api", false, "Submit results via GitHub REST API")

	flag.StringVar(&cfg.GHRepo, "gh-repo", "", "Target GitHub repo (owner/repo)")
	flag.StringVar(&cfg.GHMethod, "gh-method", "issue", "GitHub CLI method: 'issue' or 'pr'")
	flag.StringVar(&cfg.GHToken, "gh-token", "", "GitHub PAT for API submission")
	flag.StringVar(&cfg.GitRepo, "git-repo", "", "Git repository URL for direct push")
	flag.StringVar(&cfg.GitBranch, "git-branch", "main", "Git branch to push to")

	flag.StringVar(&cfg.TestPointID, "test-point-id", "", "Custom test point identifier")
	flag.StringVar(&cfg.Location, "location", "", "Geographic location")
	flag.StringVar(&cfg.APIURL, "api-url", "", "Override API endpoint")
	flag.StringVar(&cfg.APIToken, "api-token", "", "API authentication token")

	flag.BoolVar(&cfg.NoColor, "no-color", false, "Disable colored output")
	flag.BoolVar(&cfg.Verbose, "verbose", false, "Enable verbose output")

	showVersion := flag.Bool("version", false, "Show version information")

	flag.Usage = func() {
		fmt.Fprintf(os.Stderr, "ipv6perftest - IPv6 Performance Test Tool\n\n")
		fmt.Fprintf(os.Stderr, "Usage: %s [OPTIONS]\n\n", os.Args[0])
		fmt.Fprintf(os.Stderr, "Modes:\n")
		fmt.Fprintf(os.Stderr, "  --local, -l      Run local connectivity tests (no API required)\n")
		fmt.Fprintf(os.Stderr, "  (default)        Trigger test via API (requires IPV6_ARMY_TOKEN)\n\n")
		fmt.Fprintf(os.Stderr, "Options:\n")
		flag.PrintDefaults()
		fmt.Fprintf(os.Stderr, "\nEnvironment variables:\n")
		fmt.Fprintf(os.Stderr, "  IPV6_ARMY_TOKEN  API authentication token (not needed with --local)\n")
		fmt.Fprintf(os.Stderr, "  LOCATION         Geographic location\n")
		fmt.Fprintf(os.Stderr, "  TEST_POINT_ID    Custom test point identifier\n")
		fmt.Fprintf(os.Stderr, "  API_URL          Override API endpoint\n")
		fmt.Fprintf(os.Stderr, "  GITHUB_TOKEN     GitHub PAT for --submit-api\n")
		fmt.Fprintf(os.Stderr, "  GH_REPO          Default repo for GitHub submissions\n")
		fmt.Fprintf(os.Stderr, "  GIT_REPO         Default repo URL for --submit-git\n")
		fmt.Fprintf(os.Stderr, "  GIT_BRANCH       Default branch for --submit-git\n")
		fmt.Fprintf(os.Stderr, "\nExamples:\n")
		fmt.Fprintf(os.Stderr, "  %s --local                     # Run local tests, no API needed\n", os.Args[0])
		fmt.Fprintf(os.Stderr, "  %s --local --submit-gh --gh-repo user/repo\n", os.Args[0])
		fmt.Fprintf(os.Stderr, "  %s --wait                      # Trigger API and wait for results\n", os.Args[0])
	}

	flag.Parse()

	if *showVersion {
		fmt.Printf("ipv6perftest %s (built %s)\n", version, buildTime)
		os.Exit(0)
	}

	// Apply local test default if compiled in (accepts: true, yes, 1, on)
	if !cfg.LocalTest && isTruthy(defaultLocalTest) {
		cfg.LocalTest = true
	}

	// Apply configuration precedence: flag > env > compiled default
	cfg.APIToken = getConfigValue(cfg.APIToken, "IPV6_ARMY_TOKEN", defaultAPIToken)
	cfg.APIURL = getConfigValue(cfg.APIURL, "API_URL", orDefault(defaultAPIURL, "https://ipv6.army/api/test/trigger"))
	cfg.Location = getConfigValue(cfg.Location, "LOCATION", defaultLocation)
	cfg.TestPointID = getConfigValue(cfg.TestPointID, "TEST_POINT_ID", "")
	cfg.GHToken = getConfigValue(cfg.GHToken, "GITHUB_TOKEN", defaultGHToken)
	cfg.GHRepo = getConfigValue(cfg.GHRepo, "GH_REPO", defaultGHRepo)
	cfg.GHMethod = getConfigValue(cfg.GHMethod, "GH_METHOD", orDefault(defaultGHMethod, "issue"))
	cfg.GitRepo = getConfigValue(cfg.GitRepo, "GIT_REPO", defaultGitRepo)
	cfg.GitBranch = getConfigValue(cfg.GitBranch, "GIT_BRANCH", orDefault(defaultGitBranch, "main"))

	return cfg
}

// getConfigValue returns the first non-empty value from: flag, env, default
func getConfigValue(flagVal, envKey, defaultVal string) string {
	if flagVal != "" {
		return flagVal
	}
	if envVal := os.Getenv(envKey); envVal != "" {
		return envVal
	}
	return defaultVal
}

func orDefault(val, def string) string {
	if val != "" {
		return val
	}
	return def
}

// isTruthy returns true for common truthy string values
func isTruthy(val string) bool {
	switch strings.ToLower(val) {
	case "true", "yes", "1", "on":
		return true
	}
	return false
}

func run(cfg *Config) error {
	// Validate GitHub submission options
	if err := validateGitHubOptions(cfg); err != nil {
		return err
	}

	// Local test mode
	if cfg.LocalTest {
		return runLocalTests(cfg)
	}

	// API mode - requires token
	if cfg.APIToken == "" {
		return fmt.Errorf("API token is required. Set IPV6_ARMY_TOKEN environment variable, use --api-token flag, or use --local for local tests")
	}

	fmt.Println("IPv6.army Remote Test Point Trigger")
	fmt.Println("====================================")
	fmt.Println()

	// Auto-detect test point information
	fmt.Printf("%sDetecting test point information...%s\n", c.Yellow, c.Reset)

	info, err := detectTestPointInfo(cfg)
	if err != nil {
		return fmt.Errorf("failed to detect test point info: %w", err)
	}

	printTestPointInfo(info, cfg)

	// Trigger the test
	fmt.Println()
	fmt.Printf("%sTriggering test via API...%s\n", c.Yellow, c.Reset)
	fmt.Printf("  API URL: %s\n", cfg.APIURL)
	fmt.Println()

	resp, err := triggerTest(cfg, info)
	if err != nil {
		return err
	}

	fmt.Printf("%s✓ Test triggered successfully%s\n", c.Green, c.Reset)
	fmt.Println()
	fmt.Println("Response:")
	if resp.JobID != "" {
		fmt.Printf("  jobId: %s\n", resp.JobID)
	}
	if resp.Message != "" {
		fmt.Printf("  message: %s\n", resp.Message)
	}
	if resp.WorkflowURL != "" {
		fmt.Println()
		fmt.Printf("View test execution: %s\n", resp.WorkflowURL)
	}

	// Wait for results if requested
	if cfg.Wait {
		result, err := waitForResults(cfg, info, resp)
		if err != nil {
			fmt.Println()
			fmt.Printf("%s⏱ %v%s\n", c.Yellow, err, c.Reset)
			fmt.Println("The test may still be running. Check results at:")
			if resp.WorkflowURL != "" {
				fmt.Printf("  %s\n", resp.WorkflowURL)
			}
			fmt.Println("  https://github.com/ipv6-logbot/ipv6.army-data/tree/main/test-runs")
			return nil
		}

		printResults(result)

		// Submit results if enabled
		if cfg.SubmitGH || cfg.SubmitGit || cfg.SubmitAPI {
			fmt.Println()
			runSubmissions(cfg, result)
		}
	} else {
		// Submit trigger info if enabled (no results yet)
		if cfg.SubmitGH || cfg.SubmitGit || cfg.SubmitAPI {
			fmt.Println()
			fmt.Printf("%sNote: Submitting trigger info only (use --wait to submit full results)%s\n", c.Yellow, c.Reset)
			result := &TestResult{
				TestPointID: info.TestPointID,
				Location:    info.Location,
				Timestamp:   time.Now().UTC().Format(time.RFC3339),
				ASN:         info.ASN,
				IPv4Prefix:  info.IPv4Obfuscated,
				IPv6Prefix:  info.IPv6Obfuscated,
			}
			runSubmissions(cfg, result)
		}
	}

	return nil
}

// runLocalTests executes local connectivity tests to common sites
func runLocalTests(cfg *Config) error {
	fmt.Println("IPv6 Connectivity Test Tool")
	fmt.Println("===========================")
	fmt.Println()

	// Auto-detect test point information
	fmt.Printf("%sDetecting test point information...%s\n", c.Yellow, c.Reset)

	info, err := detectTestPointInfo(cfg)
	if err != nil {
		return fmt.Errorf("failed to detect test point info: %w", err)
	}

	printTestPointInfo(info, cfg)

	fmt.Println()
	fmt.Printf("%sTesting connectivity to %d sites...%s\n", c.Yellow, len(testSites), c.Reset)
	fmt.Println()

	// Run tests
	siteResults := make([]SiteTest, 0, len(testSites))
	var ipv4Successes, ipv6Successes int

	for i, site := range testSites {
		fmt.Printf("\r  Testing %d/%d: %-20s", i+1, len(testSites), site.Name)

		result := testSiteConnectivity(cfg, site.Name, site.URL)
		siteResults = append(siteResults, result)

		if result.IPv4Success {
			ipv4Successes++
		}
		if result.IPv6Success {
			ipv6Successes++
		}
	}

	fmt.Printf("\r%s\r", strings.Repeat(" ", 60)) // Clear line

	// Calculate score (weighted: IPv6 worth more)
	totalSites := len(testSites)
	ipv4Pct := float64(ipv4Successes) / float64(totalSites)
	ipv6Pct := float64(ipv6Successes) / float64(totalSites)
	// Score: 40% IPv4 + 60% IPv6 (IPv6 weighted higher)
	score := int((ipv4Pct*0.4 + ipv6Pct*0.6) * 10)

	// Build result
	result := &TestResult{
		TestPointID:   info.TestPointID,
		Location:      info.Location,
		Timestamp:     time.Now().UTC().Format(time.RFC3339),
		Score:         score,
		IPv4Success:   ipv4Successes > 0,
		IPv6Success:   ipv6Successes > 0,
		SiteTestCount: totalSites,
		ASN:           info.ASN,
		IPv4Prefix:    info.IPv4Obfuscated,
		IPv6Prefix:    info.IPv6Obfuscated,
	}

	// Print detailed results
	printLocalResults(result, siteResults, ipv4Successes, ipv6Successes, cfg.Verbose)

	// Submit results if enabled
	if cfg.SubmitGH || cfg.SubmitGit || cfg.SubmitAPI {
		fmt.Println()
		runSubmissions(cfg, result)
	}

	return nil
}

// testSiteConnectivity tests both IPv4 and IPv6 connectivity to a site
func testSiteConnectivity(cfg *Config, name, url string) SiteTest {
	result := SiteTest{
		Name: name,
		URL:  url,
	}

	// Test IPv4
	start := time.Now()
	err := testConnectivity("tcp4", url, cfg.Timeout)
	if err == nil {
		result.IPv4Success = true
		result.IPv4Latency = time.Since(start).Milliseconds()
	} else {
		result.IPv4Error = err.Error()
	}

	// Test IPv6
	start = time.Now()
	err = testConnectivity("tcp6", url, cfg.Timeout)
	if err == nil {
		result.IPv6Success = true
		result.IPv6Latency = time.Since(start).Milliseconds()
	} else {
		result.IPv6Error = err.Error()
	}

	return result
}

// testConnectivity tests HTTP connectivity over a specific network
func testConnectivity(network, url string, timeout time.Duration) error {
	dialer := &net.Dialer{Timeout: timeout}
	transport := &http.Transport{
		DialContext: func(ctx context.Context, _, addr string) (net.Conn, error) {
			return dialer.DialContext(ctx, network, addr)
		},
		DisableKeepAlives: true,
	}
	client := &http.Client{
		Transport: transport,
		Timeout:   timeout,
		CheckRedirect: func(req *http.Request, via []*http.Request) error {
			if len(via) >= 3 {
				return fmt.Errorf("too many redirects")
			}
			return nil
		},
	}

	resp, err := client.Get(url)
	if err != nil {
		return err
	}
	defer resp.Body.Close()

	// Read a small amount to ensure connection works
	buf := make([]byte, 1024)
	_, _ = resp.Body.Read(buf)

	return nil
}

// printLocalResults displays the local test results
func printLocalResults(result *TestResult, siteResults []SiteTest, ipv4Success, ipv6Success int, verbose bool) {
	fmt.Println()
	fmt.Printf("%s✓ Tests completed!%s\n", c.Green, c.Reset)
	fmt.Println()
	fmt.Println("═══════════════════════════════════════════════════════════")
	fmt.Printf("%sTEST RESULTS%s\n", c.Cyan, c.Reset)
	fmt.Println("═══════════════════════════════════════════════════════════")
	fmt.Println()

	fmt.Printf("  %sScore:%s        %d / 10\n", c.Blue, c.Reset, result.Score)

	// IPv4 status
	ipv4Status := fmt.Sprintf("%sNo connectivity%s", c.Red, c.Reset)
	if result.IPv4Success {
		ipv4Status = fmt.Sprintf("%s%d/%d sites reachable%s", c.Green, ipv4Success, result.SiteTestCount, c.Reset)
	}
	fmt.Printf("  %sIPv4:%s         %s\n", c.Blue, c.Reset, ipv4Status)

	// IPv6 status
	ipv6Status := fmt.Sprintf("%sNo connectivity%s", c.Red, c.Reset)
	if result.IPv6Success {
		ipv6Status = fmt.Sprintf("%s%d/%d sites reachable%s", c.Green, ipv6Success, result.SiteTestCount, c.Reset)
	}
	fmt.Printf("  %sIPv6:%s         %s\n", c.Blue, c.Reset, ipv6Status)

	fmt.Printf("  %sSites tested:%s %d\n", c.Blue, c.Reset, result.SiteTestCount)
	fmt.Printf("  %sTimestamp:%s    %s\n", c.Blue, c.Reset, result.Timestamp)

	// Verbose output: show per-site results
	if verbose {
		fmt.Println()
		fmt.Println("─────────────────────────────────────────────────────────────")
		fmt.Printf("%sPer-site Results:%s\n", c.Cyan, c.Reset)
		fmt.Println("─────────────────────────────────────────────────────────────")
		fmt.Println()
		fmt.Printf("  %-20s %s  %s\n", "Site", "IPv4", "IPv6")
		fmt.Printf("  %-20s %s  %s\n", "────", "────", "────")

		for _, site := range siteResults {
			ipv4 := fmt.Sprintf("%s✗%s", c.Red, c.Reset)
			if site.IPv4Success {
				ipv4 = fmt.Sprintf("%s✓%s %4dms", c.Green, c.Reset, site.IPv4Latency)
			}

			ipv6 := fmt.Sprintf("%s✗%s", c.Red, c.Reset)
			if site.IPv6Success {
				ipv6 = fmt.Sprintf("%s✓%s %4dms", c.Green, c.Reset, site.IPv6Latency)
			}

			fmt.Printf("  %-20s %s  %s\n", site.Name, ipv4, ipv6)
		}
	}

	fmt.Println()
	fmt.Println("═══════════════════════════════════════════════════════════")

	// Summary
	fmt.Println()
	if ipv6Success == 0 && ipv4Success > 0 {
		fmt.Printf("%s⚠ No IPv6 connectivity detected. Your network may be IPv4-only.%s\n", c.Yellow, c.Reset)
	} else if ipv6Success > 0 && ipv6Success < ipv4Success {
		fmt.Printf("%s⚠ Partial IPv6 connectivity. Some sites may not have IPv6 or your connection is unstable.%s\n", c.Yellow, c.Reset)
	} else if ipv6Success >= ipv4Success && ipv6Success > 0 {
		fmt.Printf("%s✓ Good IPv6 connectivity!%s\n", c.Green, c.Reset)
	}
}

func validateGitHubOptions(cfg *Config) error {
	if cfg.SubmitGH {
		if cfg.GHRepo == "" {
			return fmt.Errorf("--gh-repo is required when using --submit-gh")
		}
		if _, err := exec.LookPath("gh"); err != nil {
			return fmt.Errorf("GitHub CLI (gh) is required for --submit-gh. Install from: https://cli.github.com/")
		}
		if cfg.GHMethod != "issue" && cfg.GHMethod != "pr" {
			return fmt.Errorf("--gh-method must be 'issue' or 'pr'")
		}
	}

	if cfg.SubmitGit {
		if cfg.GitRepo == "" {
			return fmt.Errorf("--git-repo is required when using --submit-git")
		}
		if _, err := exec.LookPath("git"); err != nil {
			return fmt.Errorf("git is required for --submit-git")
		}
	}

	if cfg.SubmitAPI {
		if cfg.GHRepo == "" {
			return fmt.Errorf("--gh-repo is required when using --submit-api")
		}
		if cfg.GHToken == "" {
			return fmt.Errorf("--gh-token or GITHUB_TOKEN env var is required for --submit-api")
		}
	}

	return nil
}

func detectTestPointInfo(cfg *Config) (*TestPointInfo, error) {
	info := &TestPointInfo{
		Location: cfg.Location,
	}

	// Get hostname
	if cfg.TestPointID != "" {
		info.TestPointID = cfg.TestPointID
	} else {
		hostname, err := os.Hostname()
		if err != nil {
			hostname = "unknown"
		}
		info.TestPointID = hostname
	}

	// Detect IPs and ASN concurrently
	type ipResult struct {
		ip  string
		err error
	}

	ctx, cancel := context.WithTimeout(context.Background(), 10*time.Second)
	defer cancel()

	ipv4Ch := make(chan ipResult, 1)
	ipv6Ch := make(chan ipResult, 1)
	asnCh := make(chan string, 1)

	// Detect IPv4
	go func() {
		ip, err := detectIP(ctx, "tcp4", "https://api.ipify.org")
		ipv4Ch <- ipResult{ip, err}
	}()

	// Detect IPv6
	go func() {
		ip, err := detectIP(ctx, "tcp6", "https://api64.ipify.org")
		ipv6Ch <- ipResult{ip, err}
	}()

	// Wait for IPv4 first (needed for ASN lookup)
	ipv4Result := <-ipv4Ch
	if ipv4Result.err == nil && ipv4Result.ip != "" {
		info.IPv4 = ipv4Result.ip
		info.IPv4Obfuscated = obfuscateIPv4(ipv4Result.ip)

		// Detect ASN based on IPv4
		go func() {
			asn, _ := detectASN(ctx, ipv4Result.ip)
			asnCh <- asn
		}()
	} else {
		close(asnCh)
	}

	// Wait for IPv6
	ipv6Result := <-ipv6Ch
	if ipv6Result.err == nil && ipv6Result.ip != "" {
		info.IPv6 = ipv6Result.ip
		info.IPv6Obfuscated = obfuscateIPv6(ipv6Result.ip)
	}

	// Wait for ASN
	select {
	case asn := <-asnCh:
		info.ASN = asn
	case <-ctx.Done():
	}

	// Default location if not set
	if info.Location == "" {
		info.Location = "unknown"
	}

	return info, nil
}

func detectIP(ctx context.Context, network, url string) (string, error) {
	dialer := &net.Dialer{Timeout: 5 * time.Second}
	transport := &http.Transport{
		DialContext: func(ctx context.Context, _, addr string) (net.Conn, error) {
			return dialer.DialContext(ctx, network, addr)
		},
	}
	client := &http.Client{Transport: transport, Timeout: 5 * time.Second}

	req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
	if err != nil {
		return "", err
	}

	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", err
	}

	return strings.TrimSpace(string(body)), nil
}

func detectASN(ctx context.Context, ip string) (string, error) {
	client := &http.Client{Timeout: 5 * time.Second}
	url := fmt.Sprintf("https://ipinfo.io/%s/org", ip)

	req, err := http.NewRequestWithContext(ctx, "GET", url, nil)
	if err != nil {
		return "", err
	}

	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return "", err
	}

	// Extract ASN (first word)
	parts := strings.Fields(strings.TrimSpace(string(body)))
	if len(parts) > 0 {
		return parts[0], nil
	}
	return "", nil
}

func obfuscateIPv4(ip string) string {
	parts := strings.Split(ip, ".")
	if len(parts) != 4 {
		return ip
	}
	return fmt.Sprintf("%s.%s.%s.0", parts[0], parts[1], parts[2])
}

func obfuscateIPv6(ip string) string {
	parts := strings.Split(ip, ":")
	if len(parts) < 3 {
		return ip
	}
	return fmt.Sprintf("%s:%s:%s::", parts[0], parts[1], parts[2])
}

func printTestPointInfo(info *TestPointInfo, cfg *Config) {
	fmt.Printf("  Test Point: %s\n", info.TestPointID)

	if info.IPv4Obfuscated != "" {
		fmt.Printf("  IPv4: %s/24 (obfuscated)\n", info.IPv4Obfuscated)
	} else {
		fmt.Println("  IPv4: Not detected")
	}

	if info.IPv6Obfuscated != "" {
		fmt.Printf("  IPv6: %s/48 (obfuscated)\n", info.IPv6Obfuscated)
	} else {
		fmt.Println("  IPv6: Not detected")
	}

	if info.ASN != "" {
		fmt.Printf("  ASN: %s\n", info.ASN)
	} else {
		fmt.Println("  ASN: Not detected")
	}

	fmt.Printf("  Location: %s\n", info.Location)

	// Show enabled submission methods
	if cfg.SubmitGH || cfg.SubmitGit || cfg.SubmitAPI {
		fmt.Println()
		fmt.Printf("%sGitHub submission enabled:%s\n", c.Cyan, c.Reset)
		if cfg.SubmitGH {
			fmt.Printf("  • GitHub CLI (%s) → %s\n", cfg.GHMethod, cfg.GHRepo)
		}
		if cfg.SubmitGit {
			fmt.Printf("  • Git push → %s (%s)\n", cfg.GitRepo, cfg.GitBranch)
		}
		if cfg.SubmitAPI {
			fmt.Printf("  • GitHub API → %s\n", cfg.GHRepo)
		}
	}
}

func triggerTest(cfg *Config, info *TestPointInfo) (*APIResponse, error) {
	payload := map[string]interface{}{
		"testPointId": info.TestPointID,
		"location":    info.Location,
	}
	if info.ASN != "" {
		payload["asn"] = info.ASN
	}
	if info.IPv4Obfuscated != "" {
		payload["ipv4"] = info.IPv4Obfuscated
	}
	if info.IPv6Obfuscated != "" {
		payload["ipv6"] = info.IPv6Obfuscated
	}

	jsonData, err := json.Marshal(payload)
	if err != nil {
		return nil, fmt.Errorf("failed to marshal payload: %w", err)
	}

	req, err := http.NewRequest("POST", cfg.APIURL, bytes.NewBuffer(jsonData))
	if err != nil {
		return nil, fmt.Errorf("failed to create request: %w", err)
	}

	req.Header.Set("Authorization", "Bearer "+cfg.APIToken)
	req.Header.Set("Content-Type", "application/json")

	client := &http.Client{Timeout: 30 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		return nil, fmt.Errorf("API request failed: %w", err)
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		return nil, fmt.Errorf("failed to read response: %w", err)
	}

	if resp.StatusCode != http.StatusOK {
		hint := ""
		switch resp.StatusCode {
		case 401, 403:
			hint = "\nHint: Check that your API token is correct"
		case 429:
			hint = "\nHint: Rate limit exceeded. Wait before retrying."
		case 500:
			hint = "\nHint: Server error. Try again later or contact support."
		}
		return nil, fmt.Errorf("API request failed (HTTP %d): %s%s", resp.StatusCode, string(body), hint)
	}

	var apiResp APIResponse
	if err := json.Unmarshal(body, &apiResp); err != nil {
		// Return partial response if JSON parsing fails
		return &APIResponse{Success: true}, nil
	}

	return &apiResp, nil
}

func waitForResults(cfg *Config, info *TestPointInfo, apiResp *APIResponse) (*TestResult, error) {
	fmt.Println()
	fmt.Printf("%sWaiting for test results...%s\n", c.Yellow, c.Reset)
	fmt.Println("(This may take 3-5 minutes. Press Ctrl+C to cancel.)")
	fmt.Println()

	today := time.Now().UTC().Format("2006-01-02")
	jsonlURL := fmt.Sprintf("https://raw.githubusercontent.com/ipv6-logbot/ipv6.army-data/main/test-runs/%s.jsonl", today)

	client := &http.Client{Timeout: 10 * time.Second}
	startTime := time.Now()

	for time.Since(startTime) < cfg.MaxWaitTime {
		elapsed := int(time.Since(startTime).Seconds())
		maxWait := int(cfg.MaxWaitTime.Seconds())
		fmt.Printf("\r  Waiting... %ds / %ds", elapsed, maxWait)

		resp, err := client.Get(jsonlURL)
		if err == nil {
			body, _ := io.ReadAll(resp.Body)
			resp.Body.Close()

			lines := strings.Split(string(body), "\n")
			for i := len(lines) - 1; i >= 0; i-- {
				line := strings.TrimSpace(lines[i])
				if line == "" {
					continue
				}
				if strings.Contains(line, fmt.Sprintf(`"testPointId":"%s"`, info.TestPointID)) {
					var result TestResult
					if err := json.Unmarshal([]byte(line), &result); err == nil {
						fmt.Println()
						return &result, nil
					}
				}
			}
		}

		time.Sleep(cfg.PollInterval)
	}

	fmt.Println()
	return nil, fmt.Errorf("timeout waiting for results")
}

func printResults(result *TestResult) {
	fmt.Println()
	fmt.Printf("%s✓ Test results received!%s\n", c.Green, c.Reset)
	fmt.Println()
	fmt.Println("═══════════════════════════════════════════════════════════")
	fmt.Printf("%sTEST RESULTS%s\n", c.Cyan, c.Reset)
	fmt.Println("═══════════════════════════════════════════════════════════")
	fmt.Println()

	fmt.Printf("  %sScore:%s        %d / 10\n", c.Blue, c.Reset, result.Score)

	ipv4Status := fmt.Sprintf("%sNo connectivity%s", c.Red, c.Reset)
	if result.IPv4Success {
		ipv4Status = fmt.Sprintf("%sConnected%s", c.Green, c.Reset)
	}
	fmt.Printf("  %sIPv4:%s         %s\n", c.Blue, c.Reset, ipv4Status)

	ipv6Status := fmt.Sprintf("%sNo connectivity%s", c.Red, c.Reset)
	if result.IPv6Success {
		ipv6Status = fmt.Sprintf("%sConnected%s", c.Green, c.Reset)
	}
	fmt.Printf("  %sIPv6:%s         %s\n", c.Blue, c.Reset, ipv6Status)

	fmt.Printf("  %sSites tested:%s %d\n", c.Blue, c.Reset, result.SiteTestCount)
	fmt.Printf("  %sTimestamp:%s    %s\n", c.Blue, c.Reset, result.Timestamp)

	fmt.Println()
	fmt.Println("═══════════════════════════════════════════════════════════")
	fmt.Println()
	fmt.Println("Full results: https://github.com/ipv6-logbot/ipv6.army-data/tree/main/test-runs")
}

func runSubmissions(cfg *Config, result *TestResult) {
	if cfg.SubmitGH {
		submitViaGHCLI(cfg, result)
	}
	if cfg.SubmitGit {
		submitViaGitPush(cfg, result)
	}
	if cfg.SubmitAPI {
		submitViaGitHubAPI(cfg, result)
	}
}

func submitViaGHCLI(cfg *Config, result *TestResult) {
	fmt.Printf("%sSubmitting results via GitHub CLI...%s\n", c.Yellow, c.Reset)

	title := fmt.Sprintf("IPv6 Test Results: %s - %s", result.TestPointID, time.Now().UTC().Format("2006-01-02"))

	resultJSON, _ := json.MarshalIndent(result, "", "  ")
	body := fmt.Sprintf(`## IPv6 Connectivity Test Results

**Test Point:** %s
**Location:** %s
**Timestamp:** %s

### Results
`+"```json\n%s\n```"+`

---
*Submitted by ipv6perftest*`, result.TestPointID, result.Location, result.Timestamp, string(resultJSON))

	if cfg.GHMethod == "issue" {
		cmd := exec.Command("gh", "issue", "create", "--repo", cfg.GHRepo, "--title", title, "--body", body)
		if err := cmd.Run(); err != nil {
			fmt.Printf("%s✗ Failed to create GitHub issue: %v%s\n", c.Red, err, c.Reset)
			return
		}
		fmt.Printf("%s✓ Results submitted as GitHub issue%s\n", c.Green, c.Reset)
	} else if cfg.GHMethod == "pr" {
		// For PR, create temp dir, clone, branch, commit, push, PR
		tempDir, err := os.MkdirTemp("", "ipv6perftest-")
		if err != nil {
			fmt.Printf("%s✗ Failed to create temp directory: %v%s\n", c.Red, err, c.Reset)
			return
		}
		defer os.RemoveAll(tempDir)

		branchName := fmt.Sprintf("test-results-%s-%s", result.TestPointID, time.Now().UTC().Format("20060102150405"))
		filename := fmt.Sprintf("test-runs/individual/%s-%s.json", result.TestPointID, time.Now().UTC().Format("2006-01-02"))

		commands := [][]string{
			{"gh", "repo", "clone", cfg.GHRepo, ".", "--", "--depth", "1"},
			{"git", "checkout", "-b", branchName},
		}

		for _, args := range commands {
			cmd := exec.Command(args[0], args[1:]...)
			cmd.Dir = tempDir
			if err := cmd.Run(); err != nil {
				fmt.Printf("%s✗ Failed to create GitHub PR: %v%s\n", c.Red, err, c.Reset)
				return
			}
		}

		// Create directory and file
		filePath := filepath.Join(tempDir, filename)
		if err := os.MkdirAll(filepath.Dir(filePath), 0755); err != nil {
			fmt.Printf("%s✗ Failed to create directory: %v%s\n", c.Red, err, c.Reset)
			return
		}
		if err := os.WriteFile(filePath, resultJSON, 0644); err != nil {
			fmt.Printf("%s✗ Failed to write file: %v%s\n", c.Red, err, c.Reset)
			return
		}

		// Git add, commit, push
		gitCommands := [][]string{
			{"git", "add", filename},
			{"git", "commit", "-m", fmt.Sprintf("Add test results for %s", result.TestPointID)},
			{"git", "push", "origin", branchName},
		}

		for _, args := range gitCommands {
			cmd := exec.Command(args[0], args[1:]...)
			cmd.Dir = tempDir
			if err := cmd.Run(); err != nil {
				fmt.Printf("%s✗ Failed to create GitHub PR: %v%s\n", c.Red, err, c.Reset)
				return
			}
		}

		// Create PR
		cmd := exec.Command("gh", "pr", "create", "--repo", cfg.GHRepo, "--title", title, "--body", body, "--head", branchName)
		cmd.Dir = tempDir
		if err := cmd.Run(); err != nil {
			fmt.Printf("%s✗ Failed to create GitHub PR: %v%s\n", c.Red, err, c.Reset)
			return
		}
		fmt.Printf("%s✓ Results submitted as GitHub PR%s\n", c.Green, c.Reset)
	}
}

func submitViaGitPush(cfg *Config, result *TestResult) {
	fmt.Printf("%sSubmitting results via git push...%s\n", c.Yellow, c.Reset)

	tempDir, err := os.MkdirTemp("", "ipv6perftest-")
	if err != nil {
		fmt.Printf("%s✗ Failed to create temp directory: %v%s\n", c.Red, err, c.Reset)
		return
	}
	defer os.RemoveAll(tempDir)

	filename := fmt.Sprintf("test-runs/individual/%s-%s.json", result.TestPointID, time.Now().UTC().Format("2006-01-02"))
	resultJSON, _ := json.MarshalIndent(result, "", "  ")

	// Clone
	cmd := exec.Command("git", "clone", "--depth", "1", "--branch", cfg.GitBranch, cfg.GitRepo, ".")
	cmd.Dir = tempDir
	if err := cmd.Run(); err != nil {
		fmt.Printf("%s✗ Failed to clone repository: %v%s\n", c.Red, err, c.Reset)
		return
	}

	// Create directory and file
	filePath := filepath.Join(tempDir, filename)
	if err := os.MkdirAll(filepath.Dir(filePath), 0755); err != nil {
		fmt.Printf("%s✗ Failed to create directory: %v%s\n", c.Red, err, c.Reset)
		return
	}
	if err := os.WriteFile(filePath, resultJSON, 0644); err != nil {
		fmt.Printf("%s✗ Failed to write file: %v%s\n", c.Red, err, c.Reset)
		return
	}

	// Git add, commit, push
	commands := [][]string{
		{"git", "add", filename},
		{"git", "commit", "-m", fmt.Sprintf("Add test results for %s - %s", result.TestPointID, time.Now().UTC().Format("2006-01-02"))},
		{"git", "push", "origin", cfg.GitBranch},
	}

	for _, args := range commands {
		cmd := exec.Command(args[0], args[1:]...)
		cmd.Dir = tempDir
		if err := cmd.Run(); err != nil {
			fmt.Printf("%s✗ Failed to push results: %v%s\n", c.Red, err, c.Reset)
			return
		}
	}

	fmt.Printf("%s✓ Results pushed to git repository%s\n", c.Green, c.Reset)
}

func submitViaGitHubAPI(cfg *Config, result *TestResult) {
	fmt.Printf("%sSubmitting results via GitHub API...%s\n", c.Yellow, c.Reset)

	title := fmt.Sprintf("IPv6 Test Results: %s - %s", result.TestPointID, time.Now().UTC().Format("2006-01-02"))

	resultJSON, _ := json.MarshalIndent(result, "", "  ")
	body := fmt.Sprintf(`## IPv6 Connectivity Test Results

**Test Point:** %s
**Location:** %s
**Timestamp:** %s

### Results
`+"```json\n%s\n```"+`

---
*Submitted by ipv6perftest*`, result.TestPointID, result.Location, result.Timestamp, string(resultJSON))

	payload := map[string]interface{}{
		"title":  title,
		"body":   body,
		"labels": []string{"test-results", "automated"},
	}

	jsonData, _ := json.Marshal(payload)

	url := fmt.Sprintf("https://api.github.com/repos/%s/issues", cfg.GHRepo)
	req, err := http.NewRequest("POST", url, bytes.NewBuffer(jsonData))
	if err != nil {
		fmt.Printf("%s✗ Failed to create request: %v%s\n", c.Red, err, c.Reset)
		return
	}

	req.Header.Set("Authorization", "token "+cfg.GHToken)
	req.Header.Set("Accept", "application/vnd.github.v3+json")
	req.Header.Set("Content-Type", "application/json")

	client := &http.Client{Timeout: 30 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		fmt.Printf("%s✗ Failed to create GitHub issue: %v%s\n", c.Red, err, c.Reset)
		return
	}
	defer resp.Body.Close()

	if resp.StatusCode != http.StatusCreated {
		body, _ := io.ReadAll(resp.Body)
		fmt.Printf("%s✗ Failed to create GitHub issue (HTTP %d): %s%s\n", c.Red, resp.StatusCode, string(body), c.Reset)
		return
	}

	// Extract issue URL from response
	var issueResp struct {
		HTMLURL string `json:"html_url"`
	}
	respBody, _ := io.ReadAll(resp.Body)
	if err := json.Unmarshal(respBody, &issueResp); err == nil && issueResp.HTMLURL != "" {
		fmt.Printf("%s✓ Results submitted as GitHub issue%s\n", c.Green, c.Reset)
		fmt.Printf("  Issue URL: %s\n", issueResp.HTMLURL)
	} else {
		fmt.Printf("%s✓ Results submitted as GitHub issue%s\n", c.Green, c.Reset)
	}
}
