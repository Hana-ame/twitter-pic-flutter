package main

import (
	"embed"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"os"
	"strconv"
	"strings"

	cloudflare_ech "github.com/Hana-ame/wintools/pkg/ech"
)

// 独立调试代理（**不参与发布**）。CI 只构建 ./cmd/ech-flutter-shared 的
// c-shared 库，本文件是本地手工调试用的：起一个 http://127.0.0.1:8443 的
// 代理，浏览器里就能用 web/index.html 验证 ECH 转发。
//
// 运行：
//
//	PROXY_PORT=8443 BOOTSTRAP_IP=162.159.36.1 go run .

//go:embed web/index.html
var webFS embed.FS

const (
	// 上游固定，与 c-shared 库里的 defaultUpstreamHost 保持一致。
	// 旧版本这里用 strings.Index/LastIndex 去切 path 来"解析"主机名，
	// 对 "/video-cf.twimg.com/media/x.jpg" 切出来是 "video-cf.twimg.com/media"
	// （多切了一段），path 恰好等于前缀时更会 path[1:0] 直接 panic。
	// 现在直接用字面量前缀，主机名就是常量，不再有切片运算。
	upstreamHost = "video-cf.twimg.com"
	prefixPath   = "/" + upstreamHost
	dohHost      = "moonchan.xyz"
)

func main() {
	port := getPort()
	bootstrapIP := getBootstrapIP()

	log.Printf("[ech-proxy] Starting ECH proxy on port %d", port)
	log.Printf("[ech-proxy] Bootstrap IP: %s", bootstrapIP)

	// 初始化 ECH：DoH 域名是服务固有配置，bootstrapIP（DoH 域名的解析结果）
	// 由环境变量传入。必须先于第一次 cloudflare_ech.Do 调用，因为 wintools 的
	// 默认客户端是首次 Do 时惰性创建的。
	cloudflare_ech.SetDoHConfig(dohHost, bootstrapIP)

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

	// Proxy Twitter CDN requests (all via video-cf.twimg.com)
	if rest, ok := strings.CutPrefix(path, prefixPath); ok {
		targetPath := rest
		if targetPath == "" {
			targetPath = "/"
		}
		targetURL := fmt.Sprintf("https://%s%s", upstreamHost, targetPath)
		log.Printf("[ech-proxy] Proxying: %s -> %s", path, targetURL)

		req, err := http.NewRequestWithContext(r.Context(), r.Method, targetURL, nil)
		if err != nil {
			http.Error(w, "invalid request", http.StatusBadRequest)
			return
		}
		resp, err := cloudflare_ech.Do(req)
		if err != nil {
			log.Printf("[ech-proxy] Error: %v", err)
			http.Error(w, "Proxy error", http.StatusBadGateway)
			return
		}
		defer resp.Body.Close()

		// Copy headers（跳过逐跳头，否则上游的 Transfer-Encoding 会和
		// ResponseWriter 自己的分帧叠加）
		for key, values := range resp.Header {
			if isHopByHop(key) {
				continue
			}
			for _, value := range values {
				w.Header().Add(key, value)
			}
		}

		w.WriteHeader(resp.StatusCode)
		io.Copy(w, resp.Body)
		return
	}

	http.NotFound(w, r)
}

// isHopByHop 逐跳头，见 ./cmd/ech-flutter-shared/main.go 里 hopByHop 的注释。
func isHopByHop(key string) bool {
	switch key {
	case "Connection", "Keep-Alive", "Proxy-Authenticate", "Proxy-Authorization",
		"Te", "Trailer", "Transfer-Encoding", "Upgrade":
		return true
	}
	return false
}

func getPort() int {
	if p := os.Getenv("PROXY_PORT"); p != "" {
		port, err := strconv.Atoi(p)
		if err != nil {
			// 旧版本用 fmt.Sscanf 且忽略返回值，PROXY_PORT=abc 会静默落到 8443，
			// 调试时会一脸懵"我明明改了端口"。现在明确报错退出。
			log.Fatalf("[ech-proxy] PROXY_PORT=%q is not an integer: %v", p, err)
		}
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
