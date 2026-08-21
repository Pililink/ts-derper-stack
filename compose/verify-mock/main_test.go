package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"path/filepath"
	"runtime"
	"strings"
	"testing"
)

func TestVerifyHandlerHealthz(t *testing.T) {
	response := httptest.NewRecorder()
	newHandler("allow-all", nil).ServeHTTP(response, httptest.NewRequest(http.MethodGet, "/healthz", nil))

	if response.Code != http.StatusOK {
		t.Fatalf("status = %d, want %d", response.Code, http.StatusOK)
	}
	if body := response.Body.String(); body != "ok" {
		t.Fatalf("body = %q, want %q", body, "ok")
	}
}

func TestVerifyHandlerRejectsUnsupportedMethodAndInvalidJSON(t *testing.T) {
	handler := newHandler("allow-all", nil)

	methodResponse := httptest.NewRecorder()
	handler.ServeHTTP(methodResponse, httptest.NewRequest(http.MethodGet, "/verify", nil))
	if methodResponse.Code != http.StatusMethodNotAllowed {
		t.Fatalf("GET /verify status = %d, want %d", methodResponse.Code, http.StatusMethodNotAllowed)
	}

	invalidJSONResponse := httptest.NewRecorder()
	invalidJSONResponseRequest := httptest.NewRequest(http.MethodPost, "/verify", strings.NewReader("{"))
	handler.ServeHTTP(invalidJSONResponse, invalidJSONResponseRequest)
	if invalidJSONResponse.Code != http.StatusBadRequest {
		t.Fatalf("invalid JSON status = %d, want %d", invalidJSONResponse.Code, http.StatusBadRequest)
	}
}

func TestVerifyHandlerAllowModes(t *testing.T) {
	tests := []struct {
		name        string
		mode        string
		allowedKeys map[string]struct{}
		nodeKey     string
		wantAllow   bool
	}{
		{
			name:      "allow all",
			mode:      "allow-all",
			nodeKey:   "nodekey:one",
			wantAllow: true,
		},
		{
			name:      "deny all",
			mode:      "deny-all",
			nodeKey:   "nodekey:one",
			wantAllow: false,
		},
		{
			name: "listed key",
			mode: "allow-listed",
			allowedKeys: map[string]struct{}{
				"nodekey:allowed": {},
			},
			nodeKey:   "nodekey:allowed",
			wantAllow: true,
		},
		{
			name: "unlisted key",
			mode: "allow-listed",
			allowedKeys: map[string]struct{}{
				"nodekey:allowed": {},
			},
			nodeKey:   "nodekey:denied",
			wantAllow: false,
		},
		{
			name:      "unknown mode preserves permissive development default",
			mode:      "unknown",
			nodeKey:   "nodekey:one",
			wantAllow: true,
		},
	}

	for _, test := range tests {
		t.Run(test.name, func(t *testing.T) {
			response := httptest.NewRecorder()
			request := httptest.NewRequest(http.MethodPost, "/verify", strings.NewReader(`{"NodePublic":"`+test.nodeKey+`"}`))
			newHandler(test.mode, test.allowedKeys).ServeHTTP(response, request)

			if response.Code != http.StatusOK {
				t.Fatalf("status = %d, want %d", response.Code, http.StatusOK)
			}
			if got := response.Header().Get("Content-Type"); got != "application/json" {
				t.Fatalf("Content-Type = %q, want application/json", got)
			}

			var body verifyResponse
			if err := json.NewDecoder(response.Body).Decode(&body); err != nil {
				t.Fatalf("decode response: %v", err)
			}
			if body.Allow != test.wantAllow {
				t.Fatalf("Allow = %t, want %t", body.Allow, test.wantAllow)
			}
		})
	}
}

func TestParseAllowedKeys(t *testing.T) {
	keys := parseAllowedKeys(" nodekey:one, ,nodekey:two,nodekey:one ")
	if len(keys) != 2 {
		t.Fatalf("key count = %d, want 2", len(keys))
	}
	for _, key := range []string{"nodekey:one", "nodekey:two"} {
		if _, ok := keys[key]; !ok {
			t.Errorf("missing parsed key %q", key)
		}
	}
}

func TestREADMEVerifyURLQuickStartIsComplete(t *testing.T) {
	readme := readRepositoryFile(t, "README.md")
	command := "DERP_AUTH_MODE=verify-client-url \\\nDERP_VERIFY_CLIENT_URL=http://verify-mock:8080/verify \\\nDERP_VERIFY_CLIENT_URL_FAIL_OPEN=false \\\ndocker compose --profile verify-url up --build -d"
	if !strings.Contains(readme, command) {
		t.Fatalf("README verify-client-url quick-start must set auth mode, URL, and fail-closed behavior:\n%s", command)
	}
}

func TestREADMEHostTailscaledRequiresExactRevision(t *testing.T) {
	readme := readRepositoryFile(t, "README.md")
	for _, required := range []string{
		"完全相同的 Tailscale Git revision",
		"仅相同的 release 版本号不够",
	} {
		if !strings.Contains(readme, required) {
			t.Errorf("README must state host tailscaled compatibility requirement: missing %q", required)
		}
	}
}

func TestREADMEEmbeddedTailscaledQuickStartKeepsEnvironmentOnComposeUp(t *testing.T) {
	readme := readRepositoryFile(t, "README.md")
	command := "DERP_AUTH_MODE=verify-clients \\\nTAILSCALED_RUN=auto \\\nTAILSCALE_AUTH_KEY=tskey-xxxxx \\\ndocker compose up -d derper"
	if !strings.Contains(readme, command) {
		t.Fatalf("README embedded tailscaled command must apply its environment to docker compose up:\n%s", command)
	}
}

func TestREADMEBuildDocumentsTheTrackedSourceLocks(t *testing.T) {
	readme := readRepositoryFile(t, "README.md")
	for _, required := range []string{
		"默认构建的 Tailscale 源码由 [`tailscale-version.txt`](tailscale-version.txt) 和 [`tailscale-commit.txt`](tailscale-commit.txt) 共同锁定",
		"防止上游 tag 被移动后静默改变源码",
	} {
		if !strings.Contains(readme, required) {
			t.Errorf("README must document the tracked source locks: missing %q", required)
		}
	}
}

func readRepositoryFile(t *testing.T, name string) string {
	t.Helper()
	_, testFile, _, ok := runtime.Caller(0)
	if !ok {
		t.Fatal("locate test file")
	}

	repositoryRoot := filepath.Clean(filepath.Join(filepath.Dir(testFile), "..", ".."))
	contents, err := os.ReadFile(filepath.Join(repositoryRoot, name))
	if err != nil {
		t.Fatalf("read %s: %v", name, err)
	}
	return string(contents)
}
