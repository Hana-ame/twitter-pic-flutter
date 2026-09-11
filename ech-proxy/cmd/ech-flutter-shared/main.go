// cmd/ech-flutter-shared/main.go
// Flutter 版 ECH 代理 c-shared 库（合并版）。
//
// 本文件合并了两套导出：
//   - ECH 初始化/日志接口（来自 wintools/cmd/ech-shared）：
//       ECHSetDohURL / ECHInit / ECHInitWithBootstrap /
//       ECHInitReady / ECHInitLastError /
//       ECHGetLogCount / ECHGetLog / FreeCString
//   - 代理启停接口：
//       StartProxy / StopProxy / GetProxyPort / IsEchReady
//
// Flutter 侧 proxy_manager.dart 依赖以上全部符号，缺任何一个都会
// 导致加载或启动失败。
//
// 监听形态：**只提供明文 HTTP**，绑定 127.0.0.1（回环）。Dart 侧
// EchUrl.rewrite 生成 http://127.0.0.1:<port>，若这里改成 TLS，Go 会对
// 明文请求回 400 "Client sent an HTTP request to an HTTPS server"，表现为
// 媒体/头像全部加载失败。回环地址本就无需 TLS。
//
// 构建（Android arm64）：
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
	_ "embed"
	"fmt"
	"log"
	"net"
	"net/http"
	"os"
	"runtime/debug"
	"strconv"
	"strings"
	"sync"
	"sync/atomic"
	"time"
	"unsafe"

	cloudflare_ech "github.com/Hana-ame/wintools/pkg/ech"
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
	// proxyGen 每次 StartProxy 进入 / StopProxy 各递增一次。StartProxy 的 ECH
	// 探测要 25~35s 且不持锁（见 StartProxy 注释），期间 StopProxy 可能返回；
	// 靠这个代号在绑定端口前复查，避免"App 已退出但端口仍被绑上"。
	proxyGen uint64

	// 日志缓冲
	logMu       sync.RWMutex
	logBuffer   []string
	maxLogLines = 500
)

// hopByHop 逐跳头：只描述"上一跳到下一跳"的这条连接，绝不能转发给客户端连接。
// 原实现只在 echProxyHandler 里有一份，apiProxyHandler 直接全量转发 → 上游的
// Transfer-Encoding 会和 Go ResponseWriter 自己的分帧叠加，Connection/Keep-Alive
// 也会把上游连接的存活策略泄漏给客户端。两个 handler 现在共用这一份。
var hopByHop = map[string]bool{
	"Connection": true, "Keep-Alive": true, "Proxy-Authenticate": true,
	"Proxy-Authorization": true, "Te": true, "Trailer": true,
	"Transfer-Encoding": true, "Upgrade": true,
}

// logWriter 把 log 包输出重定向到内部缓冲，供 ECHGetLog* 读取。
type logWriter struct{}

func (w *logWriter) Write(p []byte) (int, error) {
	line := strings.TrimRight(string(p), "\n")
	// 同时透到 stderr：这个环形缓冲是**内存态**，进程一旦 abort（fatal error、
	// 或未被 recover 的 goroutine panic —— recover 抓不到 fatal error）就随进程
	// 一起消失，事后什么也查不到。stderr 至少在桌面端/CI 可见，Android 上也有
	// 机会进 logcat。Dart 侧另有一份落盘（lib/services/log_service.dart）。
	fmt.Fprintln(os.Stderr, line)
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

// guardPanic 把 panic 转成日志。所有 cgo 导出入口都必须包一层：Go panic
// 无法被 C/Dart 侧捕获，会直接 abort 整个进程（表现为"启动时概率闪退"）。
// 配合命名返回值使用——panic 回滚时未赋值的命名结果即为零值。
func guardPanic(where string) {
	if r := recover(); r != nil {
		log.Printf("PANIC in %s: %v\n%s", where, r, debug.Stack())
	}
}

// ─── ECH 初始化接口（Flutter proxy_manager 依赖）──────────────────────────

//export ECHSetDohURL
func ECHSetDohURL(url *C.char) {
	defer guardPanic("ECHSetDohURL")
	cloudflare_ech.SetDohURL(C.GoString(url))
}

//export ECHInit
func ECHInit() {
	defer guardPanic("ECHInit")
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
		// 独立 recover：子协程里的 panic 不会被上面的 defer 捕获，
		// 会直接终止进程。InitDefault 走网络/解析，最容易出问题。
		defer func() {
			if r := recover(); r != nil {
				log.Printf("PANIC in ECHInit goroutine: %v\n%s", r, debug.Stack())
				initErr.Store(fmt.Sprintf("panic: %v", r))
				initMu.Lock()
				initing = false
				initMu.Unlock()
			}
		}()
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
	defer guardPanic("ECHInitWithBootstrap")
	host := C.GoString(cHost)
	ip := C.GoString(cIP)
	if host != "" {
		cloudflare_ech.SetDoHConfig(host, ip)
	}
	ECHInit()
}

//export ECHInitReady
func ECHInitReady() (ret C.int) {
	defer guardPanic("ECHInitReady")
	if initDone.Load() {
		return 1
	}
	if v := initErr.Load(); v != nil {
		if s, ok := v.(string); ok && s != "" {
			return -1
		}
	}
	return 0
}

//export ECHInitLastError
func ECHInitLastError() (out *C.char) {
	defer guardPanic("ECHInitLastError")
	if v := initErr.Load(); v != nil {
		s, ok := v.(string)
		if !ok || s == "" {
			return nil
		}
		return C.CString(s)
	}
	return nil
}

// ─── 日志接口 ────────────────────────────────────────────────────────────────

//export ECHGetLogCount
func ECHGetLogCount() (ret C.int) {
	defer guardPanic("ECHGetLogCount")
	logMu.RLock()
	n := len(logBuffer)
	logMu.RUnlock()
	return C.int(n)
}

//export ECHGetLog
func ECHGetLog(i C.int) (out *C.char) {
	defer guardPanic("ECHGetLog")
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
	defer guardPanic("FreeCString")
	if s == nil {
		return
	}
	C.free(unsafe.Pointer(s))
}

// ─── 代理启停接口 ────────────────────────────────────────────────────────────

//export StartProxy
func StartProxy(bootstrapIP *C.char) (port uint16) {
	// panic 兜底：返回 0 表示启动失败，Dart 侧显示错误页而不是闪退。
	defer func() {
		if r := recover(); r != nil {
			log.Printf("PANIC in StartProxy: %v\n%s", r, debug.Stack())
			port = 0
		}
	}()

	// ── 阶段 0：清状态 + 领本代号（持锁，瞬时）──────────────────────────
	// ECH 探测要 25~35s。原来整段锁在 proxyMu 里，而 StopProxy / GetProxyPort
	// 抢同一把锁 —— Dart 的 stop() 是**同步**调用（proxy_manager.dart 的
	// stop/dispose/restart 都走它），恰在探测期被调就把 isolate 冻住 20~35s。
	// 现在只在改状态时短暂持锁，网络探测放在锁外。
	proxyMu.Lock()
	proxyGen++
	myGen := proxyGen

	// logWriter 在 logMu 保护下并发追加；这里清空也必须持锁，否则 slice
	// header 被撕裂读会让 ECHGetLog 拿到越界的 len 而 panic。
	logMu.Lock()
	logBuffer = nil
	logMu.Unlock()
	log.Printf("=== Starting proxy ===")

	if proxyServer != nil {
		proxyServer.Close()
		proxyServer = nil
	}
	// 先清成"未就绪"：探测失败直接 return 0，echReady/proxyPort 就保持
	// false/0。原来失败路径不清，上次成功的 echReady=true / proxyPort=8443 会
	// 残留 —— IsEchReady 谎报就绪，GetProxyPort 返回一个没人监听的端口。
	echReady = false
	proxyPort = 0
	proxyMu.Unlock()

	// ── 阶段 1：ECH 探测（不持锁，25~35s）────────────────────────────────
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
	log.Printf("ECH ready")

	// ── 阶段 2：绑定端口 + 启动（持锁，瞬时）─────────────────────────────
	proxyMu.Lock()
	defer proxyMu.Unlock()
	if proxyGen != myGen {
		// 探测期间 StopProxy（或一次新的 StartProxy）来过，App 已经不打算要
		// 这个代理了 —— 别再把端口绑上去，否则会在一个即将退出的进程里留下
		// 一个没人管的监听。
		log.Printf("StartProxy aborted: stopped mid-probe")
		return 0
	}

	// 注意：本库只提供**明文 HTTP**监听，不提供 TLS。Dart 侧
	// EchUrl.rewrite 永远生成 http://127.0.0.1:<port>；若这里优先包上 TLS，
	// Go 会对明文请求直接回 400 "Client sent an HTTP request to an HTTPS
	// server"，表现为"从来没成功访问过"。回环地址本就无需 TLS，也省掉启动
	// 期 3 次证书网络往返。

	// 3. 监听端口（优先 8443，失败则随机）
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

	// 4. 配置 HTTP 服务器
	mux := http.NewServeMux()
	mux.HandleFunc("/", router)

	proxyServer = &http.Server{
		Handler:           mux,
		ReadHeaderTimeout: 10 * time.Second,
		IdleTimeout:       120 * time.Second,
	}

	// 5. 明文 HTTP 监听
	go func() {
		defer guardPanic("Serve")
		if err := proxyServer.Serve(ln); err != nil && err != http.ErrServerClosed {
			log.Printf("server error: %v", err)
		}
	}()

	// echReady 放到监听真正起来之后：这样"就绪"与"端口有人在听"同时成立。
	echReady = true
	log.Printf("Proxy started on port %d", proxyPort)
	return proxyPort
}

//export StopProxy
func StopProxy() {
	defer guardPanic("StopProxy")
	proxyMu.Lock()
	defer proxyMu.Unlock()

	// 递增代号：无条件的，即使 proxyServer 已经是 nil。那样正在探测中的
	// StartProxy 能在绑定端口前发现"已经有人停过我了"。
	proxyGen++

	if proxyServer != nil {
		proxyServer.Close()
		proxyServer = nil
		proxyPort = 0
		echReady = false
		log.Printf("Proxy stopped")
	}
}

//export GetProxyPort
func GetProxyPort() (port uint16) {
	defer guardPanic("GetProxyPort")
	proxyMu.Lock()
	defer proxyMu.Unlock()
	return proxyPort
}

//export IsEchReady
func IsEchReady() (ret C.int) {
	defer guardPanic("IsEchReady")
	// echReady 由 StartProxy / StopProxy 在 proxyMu 下写，这里必须同样持锁读，
	// 否则 go test -race 会标记（写方持锁、读方裸读）。
	proxyMu.Lock()
	defer proxyMu.Unlock()
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

	// Go 侧调试日志（Web UI 面板 / curl 排障用）。必须在媒体分支之前，
	// 否则会被当成媒体路径转发到 video-cf.twimg.com/logs。
	if path == "/logs" {
		logMu.RLock()
		logs := strings.Join(logBuffer, "\n")
		logMu.RUnlock()
		w.Header().Set("Content-Type", "text/plain; charset=utf-8")
		fmt.Fprint(w, logs)
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

	// 必须绑定 r.Context()：原来用 http.NewRequest（context 是 Background），
	// 客户端断连后 r.Context() 被取消但上游毫不知情。wintools 的 Client 又是
	// Timeout:0（防砍断长视频），所以只要上游 Read 卡住（墙内常态），这个
	// goroutine 永远走不到 w.Write 失败的分支，resp.Body.Close() 也不执行 →
	// goroutine + TCP 连接双重泄漏，列表滚动时越积越多。
	// http.Client.Do 内部会 context.WithCancel(req.Context()) 派生传输上下文，
	// 所以只要这里绑上 r.Context()，客户端一断上游请求就被中止。
	req, err := http.NewRequestWithContext(r.Context(), r.Method, targetURL, nil)
	if err != nil {
		http.Error(w, "invalid request: "+err.Error(), http.StatusBadRequest)
		return
	}
	req.Header.Set("Referer", "https://x.com")
	req.Header.Set("User-Agent", "Mozilla/5.0 (TwitterPic)")
	// 强制 identity：不显式声明时 Go 的 transport 会自己加 Accept-Encoding: gzip
	// 并透明解压，顺手删掉上游的 Content-Length/Content-Encoding —— 视频/图片
	// 一旦没有 Content-Length，ExoPlayer 无法估算长度与分段，直接不放。
	req.Header.Set("Accept-Encoding", "identity")
	// 透传 Range：MP4 的 moov 常在文件尾，ExoPlayer 必须先分段拿到它才能解析。
	// 不透传则上游回整包 200，视频永远停在"加载中"→ 表现为看不到 Media。
	if rng := r.Header.Get("Range"); rng != "" {
		req.Header.Set("Range", rng)
	}

	resp, err := cloudflare_ech.Do(req)
	if err != nil {
		log.Printf("ECH error: %v", err)
		http.Error(w, "ECH fetch failed: "+err.Error(), http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()

	// 客户端要了分段、上游却回 200 全量：这不是错误状态码，但播放器（ExoPlayer
	// 的 DefaultHttpDataSource）会从头读并**丢弃**到目标的偏移量，在墙内这条慢
	// 链路上表现为"拖完进度条长时间卡住/黑屏"。200 本身在日志里毫无异常，
	// 所以必须显式记一条，否则这条路径永远查不出来。
	if rng := r.Header.Get("Range"); rng != "" && resp.StatusCode == http.StatusOK {
		log.Printf("! Range 未生效：请求 %q，上游回 200 全量（播放器会丢弃前置字节）", rng)
	}

	// 逐跳头不转发（见包级 hopByHop 注释）。
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
	// 明确告知可分段，播放器才会走 seek；上游没给时补一个。
	if w.Header().Get("Accept-Ranges") == "" {
		w.Header().Set("Accept-Ranges", "bytes")
	}

	w.WriteHeader(resp.StatusCode)
	flusher, _ := w.(http.Flusher)
	buf := make([]byte, 64*1024)
	var sent int64
	for {
		n, err := resp.Body.Read(buf)
		if n > 0 {
			if _, werr := w.Write(buf[:n]); werr != nil {
				// 客户端提前断开（列表滚出屏幕、播放器换源）属正常，不算错误。
				log.Printf("← %d %s (%d B, client closed)", resp.StatusCode, targetURL, sent)
				return
			}
			sent += int64(n)
			// 及时下发：否则首包要等 Go 的写缓冲填满，视频起播明显变慢。
			if flusher != nil {
				flusher.Flush()
			}
		}
		if err != nil {
			// 带上状态码：日志里能直接看出这条媒体到底取到没有（404/403 vs 200）。
			log.Printf("← %d %s (%d B)", resp.StatusCode, targetURL, sent)
			return
		}
	}
}

// apiProxyHandler 转发 JSON/API 到 x.moonchan.xyz。
//
// 仅供内嵌的 demo Web UI（index.html）使用：Flutter 侧的 API 请求是
// **直连** x.moonchan.xyz 的（见 lib/api/twitter_api.dart kApiBase），
// 经本代理转发时上游返回 400，故不要把 App 的 API 流量接到这里。
func apiProxyHandler(w http.ResponseWriter, r *http.Request, targetHost, path string) {
	targetURL := withQuery("https://"+targetHost+normalizePath(path), r)
	log.Printf("→ %s (from %s)", targetURL, r.RemoteAddr)

	// 透传请求体：POST /api/twitter/<username> 保存标签依赖 body。
	// 同样绑 r.Context()：客户端断连就中止上游，别白占连接。
	req, err := http.NewRequestWithContext(r.Context(), r.Method, targetURL, r.Body)
	if err != nil {
		http.Error(w, "invalid request: "+err.Error(), http.StatusBadRequest)
		return
	}
	req.Header.Set("User-Agent", "Mozilla/5.0 (TwitterPic)")
	if ct := r.Header.Get("Content-Type"); ct != "" {
		req.Header.Set("Content-Type", ct)
	}
	// 请求体长度要用 req.ContentLength 表达：手动设 Content-Length header
	// 会被 http.Client 忽略，流式 body 退化成 chunked。
	if cl := r.Header.Get("Content-Length"); cl != "" {
		if n, err := strconv.ParseInt(cl, 10, 64); err == nil {
			req.ContentLength = n
		}
	}

	client := &http.Client{Timeout: 30 * time.Second}
	resp, err := client.Do(req)
	if err != nil {
		log.Printf("API error: %v", err)
		http.Error(w, "API fetch failed: "+err.Error(), http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()

	// 逐跳头必须过滤（见包级 hopByHop 注释）：原来这里全量转发，上游的
	// Transfer-Encoding 会和 Go ResponseWriter 自己的分帧叠加。
	for k, vs := range resp.Header {
		if hopByHop[k] {
			continue
		}
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
