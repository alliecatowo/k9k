package main

import (
	"bytes"
	"encoding/json"
	"os"
	"os/exec"
	"strings"
	"testing"
	"time"
)

// TestMain lets the test binary double as the k9k-core executable: when the
// marker variable is set it runs main() instead of the tests, so the process
// contract (stdin/stdout JSON, exit status, stderr diagnostics) is exercised
// exactly as the macOS app sees it.
func TestMain(m *testing.M) {
	if os.Getenv("K9K_CORE_TEST_RUN_MAIN") == "1" {
		main()
		return
	}
	os.Exit(m.Run())
}

func runCore(t *testing.T, stdin string) (stdout, stderr string, err error) {
	t.Helper()
	exe, exeErr := os.Executable()
	if exeErr != nil {
		t.Fatal(exeErr)
	}
	cmd := exec.Command(exe)
	// An empty, isolated kubeconfig: k9k-core must still start and answer.
	cmd.Env = append(os.Environ(),
		"K9K_CORE_TEST_RUN_MAIN=1",
		"KUBECONFIG="+t.TempDir()+"/missing-kubeconfig",
	)
	cmd.Stdin = strings.NewReader(stdin)
	var out, errOut bytes.Buffer
	cmd.Stdout, cmd.Stderr = &out, &errOut

	done := make(chan error, 1)
	if startErr := cmd.Start(); startErr != nil {
		t.Fatal(startErr)
	}
	go func() { done <- cmd.Wait() }()
	select {
	case err = <-done:
	case <-time.After(20 * time.Second):
		_ = cmd.Process.Kill()
		t.Fatal("k9k-core did not exit after stdin closed")
	}
	return out.String(), errOut.String(), err
}

func TestHealthPingWithoutUsableKubeconfig(t *testing.T) {
	stdout, stderr, err := runCore(t, `{"version":1,"id":"t1","operation":"health.ping"}`+"\n")
	if err != nil {
		t.Fatalf("k9k-core exited with %v (stderr: %s)", err, stderr)
	}
	line := strings.TrimSpace(strings.SplitN(stdout, "\n", 2)[0])
	var reply struct {
		ID     string `json:"id"`
		Type   string `json:"type"`
		Result struct {
			Status string `json:"status"`
		} `json:"result"`
	}
	if err := json.Unmarshal([]byte(line), &reply); err != nil {
		t.Fatalf("stdout is not newline-delimited JSON: %q: %v", stdout, err)
	}
	if reply.ID != "t1" || reply.Type != "response" || reply.Result.Status != "ok" {
		t.Fatalf("unexpected reply %+v", reply)
	}
}

func TestStdoutCarriesOnlyProtocolFrames(t *testing.T) {
	stdout, _, err := runCore(t, `{"version":1,"id":"a","operation":"health.ping"}`+"\n"+`{"version":1,"id":"b","operation":"health.ping"}`+"\n")
	if err != nil {
		t.Fatal(err)
	}
	lines := strings.Split(strings.TrimSpace(stdout), "\n")
	if len(lines) != 2 {
		t.Fatalf("expected one frame per request, got %d: %q", len(lines), stdout)
	}
	for _, line := range lines {
		if !json.Valid([]byte(line)) {
			t.Fatalf("non-JSON on stdout: %q", line)
		}
	}
}
