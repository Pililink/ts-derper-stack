package main

import (
	"encoding/json"
	"log"
	"net/http"
	"os"
	"strings"
)

type verifyRequest struct {
	NodePublic string `json:"NodePublic"`
}

type verifyResponse struct {
	Allow bool `json:"Allow"`
}

func main() {
	addr := envOrDefault("VERIFY_LISTEN_ADDR", ":8080")
	mode := envOrDefault("VERIFY_ALLOW_MODE", "allow-all")
	allowedKeys := parseAllowedKeys(os.Getenv("VERIFY_ALLOWED_KEYS"))

	mux := http.NewServeMux()
	mux.HandleFunc("/healthz", func(w http.ResponseWriter, _ *http.Request) {
		w.WriteHeader(http.StatusOK)
		_, _ = w.Write([]byte("ok"))
	})
	mux.HandleFunc("/verify", func(w http.ResponseWriter, r *http.Request) {
		if r.Method != http.MethodPost {
			http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
			return
		}

		var req verifyRequest
		if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
			http.Error(w, "bad request", http.StatusBadRequest)
			return
		}

		allow := shouldAllow(mode, req.NodePublic, allowedKeys)
		w.Header().Set("Content-Type", "application/json")
		if err := json.NewEncoder(w).Encode(verifyResponse{Allow: allow}); err != nil {
			http.Error(w, "encode error", http.StatusInternalServerError)
			return
		}
	})

	log.Printf("verify mock listening on %s in %s mode", addr, mode)
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatal(err)
	}
}

func envOrDefault(name, fallback string) string {
	if value := strings.TrimSpace(os.Getenv(name)); value != "" {
		return value
	}
	return fallback
}

func parseAllowedKeys(raw string) map[string]struct{} {
	keys := make(map[string]struct{})
	for _, item := range strings.Split(raw, ",") {
		value := strings.TrimSpace(item)
		if value == "" {
			continue
		}
		keys[value] = struct{}{}
	}
	return keys
}

func shouldAllow(mode, nodeKey string, allowedKeys map[string]struct{}) bool {
	switch mode {
	case "deny-all":
		return false
	case "allow-listed":
		_, ok := allowedKeys[nodeKey]
		return ok
	default:
		return true
	}
}

