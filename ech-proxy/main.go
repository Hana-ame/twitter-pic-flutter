package main

import (
	"embed"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"strings"
	"time"

	cloudflare_ech "github.com/Hana-ame/wintools/pkg/ech"
)

//go:embed web/index.html
var webFS embed.FS

var (
	proxyPort   int
	echClient   *cloudflare_ech.Client
)

func main() {
	port := getPort()
	bootstrapIP := getBootstrapIP()

	log.Printf("[ech-proxy] Starting ECH proxy on port %d", port)
	log.Printf("[ech-proxy] Bootstrap IP: %s", bootstrapIP)

	// Initialize ECH client
	var err error
	echClient, err = cloudflare_ech.NewClient(cloudflare_ech.ClientConfig{
		BootstrapIP: bootstrapIP,
		Timeout:     30 * time.Second,
	})
	if err != nil {
		log.Fatalf("[ech-proxy] Failed to create ECH client: %v", err)
	}

	// Start HTTP server
	mux := http.NewServeMux()
	mux.HandleFunc("/", handleRequest)

	addr := fmt.Sprintf("127.0.0.1:%d", port)
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		log.Fatalf("[ech-proxy] Failed to listen on %s: %v", addr, err)
	}

	log.Printf("[ech-proxy] Server listening on %s", addr)
	if err := http.Serve(ln, mux); err != nil {
		log.Fatalf("[ech-proxy] Server error: %v", err)
	}
}

func handleRequest(w http.ResponseWriter, r *http.Request) {
	path := r.URL.Path

	// Serve web UI
	if path == "/" || path == "/index.html" {
		data, err := webFS.ReadFile("web/index.html")
		if err != nil {
			http.Error(w, "Internal server error", http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.Write(data)
		return
	}

	// Proxy Twitter CDN requests
	if strings.HasPrefix(path, "/pbs.twimg.com") ||
		strings.HasPrefix(path, "/video.twimg.com") ||
		strings.HasPrefix(path, "/abs.twimg.com") {

		targetHost := path[strings.Index(path, "/")+1 : strings.LastIndex(path, "/")]
		targetPath := path[strings.LastIndex(path, "/"):]

		targetURL := fmt.Sprintf("https://%s%s", targetHost, targetPath)
		log.Printf("[ech-proxy] Proxying: %s -> %s", path, targetURL)

		resp, err := echClient.Get(targetURL)
		if err != nil {
			log.Printf("[ech-proxy] Error: %v", err)
			http.Error(w, "Proxy error", http.StatusBadGateway)
			return
		}
		defer resp.Body.Close()

		// Copy headers
		for key, values := range resp.Header {
			for _, value := range values {
				w.Header().Add(key, value)
			}
		}

		w.WriteHeader(resp.StatusCode)
		buf := make([]byte, 32*1024)
		for {
			n, err := resp.Body.Read(buf)
			if n > 0 {
				w.Write(buf[:n])
			}
			if err != nil {
				break
			}
		}
		return
	}

	http.NotFound(w, r)
}

func getPort() int {
	if p := os.Getenv("PROXY_PORT"); p != "" {
		port := 8443
		fmt.Sscanf(p, "%d", &port)
		return port
	}
	return 8443
}

func getBootstrapIP() string {
	if ip := os.Getenv("BOOTSTRAP_IP"); ip != "" {
		return ip
	}
	return "162.159.36.1" // Cloudflare ECH bootstrap IP
}
