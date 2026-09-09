// cmd/ech-flutter-shared/main.go
// Flutter 版 ECH 代理 c-shared 库（合并版）。
//
// 本文件合并了两套导出：
//   - ECH 初始化/日志接口（来自 wintools/cmd/ech-shared）：
//       ECHSetDohURL / ECHInit / ECHInitWithBootstrap /
//       ECHInitReady / ECHInitLastError /
//       ECHGetLogCount / ECHGetLog / FreeCString
//   - 代理启停接口（来自 cmd/ech-proxy-android）：
//       StartProxy / StopProxy / GetProxyPort / IsEchReady
//
// Flutter 侧 proxy_manager.dart 依赖以上全部符号，缺任何一个都会
// 导致加载或启动失败。构建（Android arm64）：
//
//	CGO_ENABLED=1 GOOS=android GOARCH=arm64 \
//	  CC=aarch64-linux-android21-clang \
//	  go build -buildmode=c-shared -ldflags="-s -w" \
//	  -o libechproxy.so ./cmd/ech-flutter-shared/
//
// Windows amd64：
//
//	CGO_ENABLED=1 GOOS=windows GOARCH=amd64 \
//	  go build -buildmode=c-shared -ldflags="-s -w" \
//	  -o echproxy.dll ./cmd/ech-flutter-shared/

package main

/*
#include <stdlib.h>
*/
import "C"

import (
	"crypto/tls"
	_ "embed"
	"fmt"
	"log"
	"net"
	"net/http"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unsafe"

	cloudflare_ech "github.com/Hana-ame/wintools/pkg/ech"
	echproxy "github.com/Hana-ame/wintools/pkg/echproxy"
)

//go:embed web/index.html
var indexHTML string

const cdnHost = "video-cf.twimg.com"
const apiHost = "x.moonchan.xyz"

// ─── 状态 ────────────────────────────────────────────────────────────────────

var (
	// ECH 初始化状态
	initMu   sync.Mutex
	initing  bool
	initDone atomic.Bool
	initErr  atomic.Value

	// 代理状态
	proxyMu     sync.Mutex
	proxyServer *http.Server
	proxyPort   uint16
	echReady    bool

	// 日志缓冲
	logMu       sync.RWMutex
	logBuffer   []string
	maxLogLines = 500
)

// logWriter 把 log 包输出重定向到内部缓冲，供 ECHGetLog* 读取。
type logWriter struct{}

func (w *logWriter) Write(p []byte) (int, error) {
	line := strings.TrimRight(string(p), "\n")
	logMu.Lock()
	logBuffer = append(logBuffer, line)
	if len(logBuffer) > maxLogLines {
		logBuffer = logBuffer[len(logBuffer)-maxLogLines:]
	}
	logMu.Unlock()
	return len(p), nil
}

func init() {
	log.SetOutput(&logWriter{})
	log.SetFlags(log.Ltime | log.Lmicroseconds)
}

// ─── ECH 初始化接口（Flutter proxy_manager 依赖）──────────────────────────

//export ECHSetDohURL
func ECHSetDohURL(url *C.char) {
	cloudflare_ech.SetDohURL(C.GoString(url))
}

//export ECHInit
func ECHInit() {
	if initDone.Load() {
		return
	}
	initMu.Lock()
	if initDone.Load() || initing {
		initMu.Unlock()
		return
	}
	initing = true
	initMu.Unlock()

	log.Printf("ECHInit: starting goroutine")
	go func() {
		if err := cloudflare_ech.InitDefault(); err != nil {
			log.Printf("ECHInit error: %v", err)
			initErr.Store(err.Error())
			initMu.Lock()
			initing = false
			initMu.Unlock()
			return
		}
		initErr.Store("")
		initDone.Store(true)
		log.Printf("ECHInit: success")
	}()
}

//export ECHInitWithBootstrap
func ECHInitWithBootstrap(cHost, cIP *C.char) {
	host := C.GoString(cHost)
	ip := C.GoString(cIP)
	if host != "" {
		cloudflare_ech.SetDoHConfig(host, ip)
	}
	ECHInit()
}

//export ECHInitReady
func ECHInitReady() C.int {
	if initDone.Load() {
		return 1
	}
	if v := initErr.Load(); v != nil && v.(string) != "" {
		return -1
	}
	return 0
}

//export ECHInitLastError
func ECHInitLastError() *C.char {
	if v := initErr.Load(); v != nil {
		s := v.(string)
		if s == "" {
			return nil
		}
		return C.CString(s)
	}
	return nil
}

// ─── 日志接口 ────────────────────────────────────────────────────────────────

//export ECHGetLogCount
func ECHGetLogCount() C.int {
	logMu.RLock()
	n := len(logBuffer)
	logMu.RUnlock()
	return C.int(n)
}

//export ECHGetLog
func ECHGetLog(i C.int) *C.char {
	logMu.RLock()
	defer logMu.RUnlock()
	n := int(i)
	if n < 0 || n >= len(logBuffer) {
		return nil
	}
	return C.CString(logBuffer[n])
}

//export FreeCString
func FreeCString(s *C.char) {
	C.free(unsafe.Pointer(s))
}

// ─── 代理启停接口 ────────────────────────────────────────────────────────────

//export StartProxy
func StartProxy(bootstrapIP *C.char) uint16 {
	proxyMu.Lock()
	defer proxyMu.Unlock()

	logBuffer = nil
	log.Printf("=== Starting proxy ===")

	if proxyServer != nil {
		proxyServer.Close()
		proxyServer = nil
	}

	// 1. 配置 ECH
	bootstrap := C.GoString(bootstrapIP)
	if bootstrap != "" {
		log.Printf("ECH: DoH=moonchan.xyz, bootstrapIP=%s", bootstrap)
		cloudflare_ech.SetDoHConfig("moonchan.xyz", bootstrap)
	} else {
		log.Printf("ECH: DoH=https://moonchan.xyz/doh")
		cloudflare_ech.SetDohURL("https://moonchan.xyz/doh")
	}

	// 2. 初始化 ECH
	log.Printf("Initializing ECH client...")
	req, _ := http.NewRequest("HEAD", "https://video-cf.twimg.com/favicon.ico", nil)
	resp, err := cloudflare_ech.Do(req)
	if err != nil {
		log.Printf("ECH init failed: %v", err)
		return 0
	}
	resp.Body.Close()
	echReady = true
	log.Printf("ECH ready")

	// 3. 获取 TLS 证书（失败则回退 HTTP 模式）
	proxyBase := "https://proxy.moonchan.xyz/Hana-ame/wintools/refs/heads/main/%s?proxy_host=raw.githubusercontent.com"
	upstreamConfigURL := fmt.Sprintf(proxyBase, "certs/l.moonchan.xyz/upstream.json")

	log.Printf("Loading upstream config: %s", upstreamConfigURL)
	cfg, err := echproxy.LoadConfig(upstreamConfigURL)
	if err != nil {
		log.Printf("Failed to load config (fallback to HTTP): %v", err)
		cfg = nil
	}

	var tlsCert *tls.Certificate
	if cfg != nil && cfg.CertPath != "" && cfg.KeyPath != "" {
		log.Printf("Fetching certificate: %s", cfg.CertPath)
		certPEM, err := echproxy.FetchBytes(cfg.CertPath)
		if err != nil {
			log.Printf("Failed to fetch cert (fallback to HTTP): %v", err)
		} else {
			log.Printf("Fetching key: %s", cfg.KeyPath)
			keyPEM, err := echproxy.FetchBytes(cfg.KeyPath)
			if err != nil {
				log.Printf("Failed to fetch key (fallback to HTTP): %v", err)
			} else {
				cert, err := tls.X509KeyPair(certPEM, keyPEM)
				if err != nil {
					log.Printf("Failed to parse cert (fallback to HTTP): %v", err)
				} else {
					tlsCert = &cert
					log.Printf("Certificate loaded (*.l.moonchan.xyz)")
				}
			}
		}
	}

	// 4. 监听端口（优先 8443，失败则随机）
	ln, err := net.Listen("tcp4", "127.0.0.1:8443")
	if err != nil {
		log.Printf("Port 8443 in use, trying random port...")
		ln, err = net.Listen("tcp4", "127.0.0.1:0")
		if err != nil {
			log.Printf("listen failed: %v", err)
			return 0
		}
	}
	proxyPort = uint16(ln.Addr().(*net.TCPAddr).Port)

	// 5. 配置 HTTP 服务器
	mux := http.NewServeMux()
	mux.HandleFunc("/", router)

	proxyServer = &http.Server{
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       120 * time.Second,
	}

	// 6. 启动 HTTPS 或 HTTP
	if tlsCert != nil {
		log.Printf("Listening HTTPS on 127.0.0.1:%d", proxyPort)
		log.Printf("Access: https://twimg.l.moonchan.xyz:%d/", proxyPort)
		proxyServer.TLSConfig = &tls.Config{
			Certificates: []tls.Certificate{*tlsCert},
			MinVersion:   tls.VersionTLS12,
		}
		tlsLn := tls.NewListener(ln, proxyServer.TLSConfig)
		go func() {
			if err := proxyServer.Serve(tlsLn); err != nil && err != http.ErrServerClosed {
				log.Printf("server error: %v", err)
			}
		}()
	} else {
		log.Printf("Listening HTTP on 127.0.0.1:%d", proxyPort)
		log.Printf("Access: http://127.0.0.1:%d/", proxyPort)
		go func() {
			if err := proxyServer.Serve(ln); err != nil && err != http.ErrServerClosed {
				log.Printf("server error: %v", err)
			}
		}()
	}

	log.Printf("Proxy started on port %d", proxyPort)
	return proxyPort
}

//export StopProxy
func StopProxy() {
	proxyMu.Lock()
	defer proxyMu.Unlock()

	if proxyServer != nil {
		proxyServer.Close()
		proxyServer = nil
		proxyPort = 0
		echReady = false
		log.Printf("Proxy stopped")
	}
}

//export GetProxyPort
func GetProxyPort() uint16 {
	proxyMu.Lock()
	defer proxyMu.Unlock()
	return proxyPort
}

//export IsEchReady
func IsEchReady() C.int {
	if echReady {
		return 1
	}
	return 0
}

// ─── 路由 ────────────────────────────────────────────────────────────────────

func router(w http.ResponseWriter, r *http.Request) {
	path := r.URL.Path

	if path == "/" || path == "" {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		fmt.Fprint(w, indexHTML)
		return
	}

	if strings.HasPrefix(path, "/api/") {
		apiProxyHandler(w, r, apiHost, strings.TrimPrefix(path, "/api"))
		return
	}

	// 所有其他请求 → video-cf.twimg.com（路径保持不变）
	// 例：/media/ABC123.png → https://video-cf.twimg.com/media/ABC123.png
	echProxyHandler(w, r, "video-cf.twimg.com", path)
}

func echProxyHandler(w http.ResponseWriter, r *http.Request, targetHost, path string) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	targetURL := "https://" + targetHost + "/" + path
	log.Printf("→ %s (from %s)", targetURL, r.RemoteAddr)

	req, err := http.NewRequest(r.Method, targetURL, nil)
	if err != nil {
		http.Error(w, "invalid request: "+err.Error(), http.StatusBadRequest)
		return
	}
	req.Header.Set("Referer", "https://x.com")
	req.Header.Set("User-Agent", "Mozilla/5.0 (TwitterPic)")

	resp, err := cloudflare_ech.Do(req)
	if err != nil {
		log.Printf("ECH error: %v", err)
		http.Error(w, "ECH fetch failed: "+err.Error(), http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()

	hopByHop := map[string]bool{
		"Connection": true, "Keep-Alive": true, "Proxy-Authenticate": true,
		"Proxy-Authorization": true, "Te": true, "Trailer": true,
		"Transfer-Encoding": true, "Upgrade": true,
	}
	for k, vs := range resp.Header {
		if hopByHop[k] {
			continue
		}
		for _, v := range vs {
			w.Header().Add(k, v)
		}
	}

	if cl := resp.Header.Get("Content-Length"); cl != "" {
		w.Header().Set("Content-Length", cl)
	}

	w.WriteHeader(resp.StatusCode)
	buf := make([]byte, 64*1024)
	for {
		n, err := resp.Body.Read(buf)
		if n > 0 {
			if _, werr := w.Write(buf[:n]); werr != nil {
				return
			}
		}
		if err != nil {
			return
		}
	}
}

func apiProxyHandler(w http.ResponseWriter, r *http.Request, targetHost, path string) {
	targetURL := "https://" + targetHost + path
	log.Printf("→ %s (from %s)", targetURL, r.RemoteAddr)

	req, err := http.NewRequest(r.Method, targetURL, nil)
	if err != nil {
		http.Error(w, "invalid request: "+err.Error(), http.StatusBadRequest)
		return
	}
	req.Header.Set("User-Agent", "Mozilla/5.0 (TwitterPic)")

	client := &http.Client{Timeout: 30 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		log.Printf("API error: %v", err)
		http.Error(w, "API fetch failed: "+err.Error(), http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()

	for k, vs := range resp.Header {
		for _, v := range vs {
			w.Header().Add(k, v)
		}
	}
	w.WriteHeader(resp.StatusCode)
	buf := make([]byte, 64*1024)
	for {
		n, err := resp.Body.Read(buf)
		if n > 0 {
			if _, werr := w.Write(buf[:n]); werr != nil {
				return
			}
		}
		if err != nil {
			return
		}
	}
}

func main() {}
