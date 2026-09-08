package main

import (
	"C"
	"fmt"
	"net"
	"net/http"
	"os"
	"strings"
	"time"

	cloudflare_ech "github.com/Hana-ame/wintools/pkg/ech"
)

//export StartProxy
func StartProxy() int {
	port := getPort()

	logf("Starting ECH proxy on port %d", port)

	// Initialize ECH client
	echClient, err := cloudflare_ech.NewClient(cloudflare_ech.ClientConfig{
		BootstrapIP: getBootstrapIP(),
		Timeout:     30 * time.Second,
	})
	if err != nil {
		logf("Failed to create ECH client: %v", err)
		return 0
	}

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
	// This is called from Java via JNI
	// The actual port is set by StartProxy
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
<p>Proxy is running. Use the Flutter app to browse Twitter images.</p>
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

			resp, err := echClient.Get(targetURL)
			if err != nil {
				logf("Error: %v", err)
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
}

func getPort() int {
	return 8443
}

func getBootstrapIP() string {
	return "162.159.36.1"
}

func logf(format string, args ...interface{}) {
	fmt.Fprintf(os.Stdout, "[ech-proxy] "+format+"\n", args...)
}

func main() {}
