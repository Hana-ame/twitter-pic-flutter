package main

import (
	"C"
	"fmt"
	"io"
	"net"
	"net/http"
	"os"
	"strings"

	cloudflare_ech "github.com/Hana-ame/wintools/pkg/ech"
)

//export StartProxy
func StartProxy() int {
	port := 8443
	logf("Starting ECH proxy on port %d", port)

	// Configure DoH with bootstrap IP
	cloudflare_ech.SetDoHConfig("cloudflare-ech.com", "162.159.36.1")

	// Create ECH client
	echClient, err := cloudflare_ech.New()
	if err != nil {
		logf("Failed to create ECH client: %v", err)
		return 0
	}
	logf("ECH client created")

	// Start HTTP server
	mux := http.NewServeMux()
	mux.HandleFunc("/", handleRequest(echClient))

	addr := fmt.Sprintf("127.0.0.1:%d", port)
	ln, err := net.Listen("tcp", addr)
	if err != nil {
		logf("Failed to listen: %v", err)
		return 0
	}

	go func() {
		logf("Server listening on %s", addr)
		if err := http.Serve(ln, mux); err != nil {
			logf("Server error: %v", err)
		}
	}()

	return port
}

//export StopProxy
func StopProxy() {
	logf("Stopping ECH proxy")
	os.Exit(0)
}

//export GetProxyPort
func GetProxyPort() int {
	return 8443
}

func handleRequest(echClient *cloudflare_ech.Client) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		path := r.URL.Path

		// Serve web UI
		if path == "/" || path == "/index.html" {
			w.Header().Set("Content-Type", "text/html; charset=utf-8")
			w.Write([]byte(`<!DOCTYPE html>
<html>
<head><title>Twitter Pic</title></head>
<body>
<h1>Twitter Pic - ECH Proxy</h1>
<p>Proxy is running.</p>
</body>
</html>`))
			return
		}

		// Proxy Twitter CDN requests
		if strings.HasPrefix(path, "/pbs.twimg.com") ||
			strings.HasPrefix(path, "/video.twimg.com") ||
			strings.HasPrefix(path, "/abs.twimg.com") {

			targetHost := path[strings.Index(path, "/")+1 : strings.LastIndex(path, "/")]
			targetPath := path[strings.LastIndex(path, "/"):]

			targetURL := fmt.Sprintf("https://%s%s", targetHost, targetPath)
			logf("Proxying: %s -> %s", path, targetURL)

			// Create HTTP request
			req, err := http.NewRequest("GET", targetURL, nil)
			if err != nil {
				logf("Failed to create request: %v", err)
				http.Error(w, "Bad request", http.StatusBadRequest)
				return
			}

			// Make request through ECH client
			resp, err := echClient.Do(req)
			if err != nil {
				logf("ECH error: %v", err)
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

			// Stream response
			io.Copy(w, resp.Body)
			return
		}

		http.NotFound(w, r)
	}
}

func logf(format string, args ...interface{}) {
	fmt.Fprintf(os.Stdout, "[ech-proxy] "+format+"\n", args...)
}

func main() {}
