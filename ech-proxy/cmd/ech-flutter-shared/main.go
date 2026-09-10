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

// DoH 服务器地址：服务的固有配置，硬编码。
// bootstrapIP（连接 DoH 用的目标 IP）不在此处硬编码，由调用方通过
// StartProxy(bootstrapIP) 传入，来源是运行时 DNS 解析 moonchan.xyz。
const defaultDohHost = "moonchan.xyz"
const defaultDohURL = "https://moonchan.xyz/doh"

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

	// 1. 配置 ECH：DoH 域名硬编码（服务固有配置），bootstrapIP 由调用方
	//    传入（运行时解析 moonchan.xyz 得到，不可硬编码）。
	bootstrap := C.GoString(bootstrapIP)
	if bootstrap != "" {
		log.Printf("ECH: DoH=%s/doh, bootstrapIP=%s", defaultDohHost, bootstrap)
		cloudflare_ech.SetDoHConfig(defaultDohHost, bootstrap)
	} else {
		log.Printf("ECH: DoH=%s", defaultDohURL)
		cloudflare_ech.SetDohURL(defaultDohURL)
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

// normalizePath 统一 path 的前导斜杠，兼容调用方传入的两种形式：
//   - "/media/a.png" → "/media/a.png"（已有前导斜杠，保持，不会变 //media）
//   - "media/a.png"  → "/media/a.png"（缺前导斜杠，补上）
//   - ""             → "/"
//
// 拼接 targetURL 时用 host + normalizePath(path)，避免调用方写法差异产生
// "https://host//media" 双斜杠（Cloudflare WAF 可能返回 403）。
func normalizePath(path string) string {
	if path == "" {
		return "/"
	}
	if !strings.HasPrefix(path, "/") {
		path = "/" + path
	}
	return path
}

// ─── 路由 ────────────────────────────────────────────────────────────────────

// 上游媒体 host：EchUrl.rewrite 会丢弃原始域名（pbs.twimg.com /
// video.twimg.com 等），代理统一改写为 video-cf.twimg.com 后经 ECH
// 访问（已验证 video-cf 完整支持 media 与 profile_images 路径）。
const defaultUpstreamHost = "video-cf.twimg.com"

func router(w http.ResponseWriter, r *http.Request) {
	path := r.URL.Path

	if path == "/" || path == "" {
		w.Header().Set("Content-Type", "text/html; charset=utf-8")
		w.WriteHeader(http.StatusOK)
		fmt.Fprint(w, indexHTML)
		return
	}

	// /api/... → x.moonchan.xyz（保留完整前缀：后端真实挂载点为 /api/twitter）
	if strings.HasPrefix(path, "/api/") {
		apiProxyHandler(w, r, apiHost, path)
		return
	}

	// 其余请求 → video-cf.twimg.com + ECH。
	// EchUrl.rewrite 已把原始域名（pbs.twimg.com / video.twimg.com 等）丢弃，
	// 路径原样转发（见 defaultUpstreamHost 注释）。
	echProxyHandler(w, r, defaultUpstreamHost, path)
}

// withQuery 把原始请求的 query 附加到上游 URL。
// 真实 media URL 形如 /media/x.jpg?format=jpg&name=large，丢 query 上游必 404。
func withQuery(base string, r *http.Request) string {
	if r.URL.RawQuery == "" {
		return base
	}
	return base + "?" + r.URL.RawQuery
}

func echProxyHandler(w http.ResponseWriter, r *http.Request, targetHost, path string) {
	if r.Method != http.MethodGet && r.Method != http.MethodHead {
		http.Error(w, "method not allowed", http.StatusMethodNotAllowed)
		return
	}

	targetURL := withQuery("https://"+targetHost+normalizePath(path), r)
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
	targetURL := withQuery("https://"+targetHost+normalizePath(path), r)
	log.Printf("→ %s (from %s)", targetURL, r.RemoteAddr)

	// 透传请求体：POST /api/twitter/<username> 保存标签依赖 body。
	req, err := http.NewRequest(r.Method, targetURL, r.Body)
	if err != nil {
		http.Error(w, "invalid request: "+err.Error(), http.StatusBadRequest)
		return
	}
	req.Header.Set("User-Agent", "Mozilla/5.0 (TwitterPic)")
	if ct := r.Header.Get("Content-Type"); ct != "" {
		req.Header.Set("Content-Type", ct)
	}
	if cl := r.Header.Get("Content-Length"); cl != "" {
		req.Header.Set("Content-Length", cl)
	}

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
