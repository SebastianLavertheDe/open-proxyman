// Local HTTP/2 and gRPC wire-format fixture. This executable has no third-party dependencies.
package main

import (
	"bytes"
	"context"
	"crypto/sha256"
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/binary"
	"encoding/json"
	"fmt"
	"io"
	"net"
	"net/http"
	"net/url"
	"os"
	"strconv"
	"sync"
	"sync/atomic"
	"time"
)

type connKey struct{}

func grpcWebEcho(w http.ResponseWriter, r *http.Request) {
	body, err := io.ReadAll(r.Body)
	if err != nil {
		http.Error(w, err.Error(), http.StatusBadRequest)
		return
	}

	text := r.Header.Get("Content-Type") == "application/grpc-web-text+proto"
	if text {
		body, err = base64.StdEncoding.DecodeString(string(body))
		if err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		if len(body) < 5 {
			http.Error(w, "missing gRPC-Web frame", http.StatusBadRequest)
			return
		}
	}
	w.Header().Set("Content-Type", r.Header.Get("Content-Type"))
	trailers := []byte("grpc-status: 7\r\ngrpc-message: fixture%20denied\r\nx-fixture-trailer: grpc-web\r\n")
	frame := make([]byte, 5+len(trailers))
	frame[0] = 0x80
	binary.BigEndian.PutUint32(frame[1:5], uint32(len(trailers)))
	copy(frame[5:], trailers)

	if text {
		// Flush inside the first frame. The first chunk ends with Base64 padding.
		fmt.Fprint(w, base64.StdEncoding.EncodeToString(body[:4]))
		w.(http.Flusher).Flush()
		fmt.Fprint(w, base64.StdEncoding.EncodeToString(append(body[4:], frame...)))
	} else {
		w.Write(body)
		w.Write(frame)
	}
}

func serve(cert, key string) {
	var next atomic.Int64
	var inflight atomic.Int32
	var cancelled atomic.Bool
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		connection := r.Context().Value(connKey{}).(int64)
		w.Header().Set("X-Fixture-Protocol", r.Proto)
		w.Header().Set("X-Fixture-Connection", strconv.FormatInt(connection, 10))
		switch r.URL.Path {
		case "/left", "/right":
			inflight.Add(1)
			defer inflight.Add(-1)
			time.Sleep(150 * time.Millisecond)
			w.Header().Set("X-Fixture-Overlap", strconv.FormatBool(inflight.Load() > 1))
			w.Header().Set("Trailer", "X-Fixture-Trailer")
			fmt.Fprint(w, r.URL.Path)
			w.Header().Set("X-Fixture-Trailer", r.URL.Path)
		case "/cancel":
			fmt.Fprint(w, "started")
			w.(http.Flusher).Flush()
			<-r.Context().Done()
			cancelled.Store(true)
		case "/keep":
			time.Sleep(125 * time.Millisecond)
			fmt.Fprint(w, "survived")
		case "/cancel-status":
			for i := 0; i < 30 && !cancelled.Load(); i++ {
				time.Sleep(10 * time.Millisecond)
			}
			fmt.Fprint(w, cancelled.Load())
		case "/intercept-request":
			body, err := io.ReadAll(r.Body)
			if err != nil {
				http.Error(w, err.Error(), 400)
				return
			}
			w.Header().Set("X-Request-Trailer", r.Trailer.Get("X-Request-Check"))
			w.Header().Set("Trailer", "X-Fixture-Trailer")
			fmt.Fprintf(w, "%s:%s", r.Header.Get("X-Manual"), body)
			w.Header().Set("X-Fixture-Trailer", "still-here")
		case "/intercept-graphql":
			io.Copy(io.Discard, r.Body)
			w.Header().Set("Content-Length", "5")
			fmt.Fprint(w, "plain")
		case "/pm.Echo/Echo":
			body, err := io.ReadAll(r.Body)
			if err != nil {
				http.Error(w, err.Error(), 400)
				return
			}
			w.Header().Set("Content-Type", "application/grpc")
			w.Header().Set("Trailer", "Grpc-Status, Grpc-Message, X-Fixture-Trailer")
			w.Header().Set("X-Request-Trailer", r.Trailer.Get("X-Request-Check"))
			w.Write(body)
			w.Header().Set("Grpc-Status", "0")
			w.Header().Set("Grpc-Message", "fixture%20ok")
			w.Header().Set("X-Fixture-Trailer", "grpc-fixture")
		case "/pm.Web/Binary", "/pm.Web/Text":
			grpcWebEcho(w, r)
		case "/large", "/paced":
			w.Header().Set("Content-Type", "application/octet-stream")
			io.Copy(w, r.Body)
		default:
			fmt.Fprint(w, r.URL.Path)
		}
	})

	ports := make([]int, 0, 2)
	for _, h2 := range []bool{true, false} {
		l, err := net.Listen("tcp4", "127.0.0.1:0")
		if err != nil {
			panic(err)
		}
		server := &http.Server{
			Handler: mux,
			ConnContext: func(ctx context.Context, c net.Conn) context.Context {
				return context.WithValue(ctx, connKey{}, next.Add(1))
			},
			ReadHeaderTimeout: 5 * time.Second,
		}
		if !h2 {
			server.TLSNextProto = make(map[string]func(*http.Server, *tls.Conn, http.Handler))
		}
		ports = append(ports, l.Addr().(*net.TCPAddr).Port)
		go func() {
			if err := server.ServeTLS(l, cert, key); err != nil {
				panic(err)
			}
		}()
	}
	proxy, err := net.Listen("tcp4", "127.0.0.1:0")
	if err != nil {
		panic(err)
	}
	go http.Serve(proxy, http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		target := r.Host
		if r.Method != http.MethodConnect || (target != fmt.Sprintf("127.0.0.1:%d", ports[0]) &&
			target != fmt.Sprintf("127.0.0.1:%d", ports[1])) {
			http.Error(w, "fixture target only", 403)
			return
		}
		remote, err := net.DialTimeout("tcp4", target, time.Second)
		if err != nil {
			http.Error(w, "fixture connection failed", 502)
			return
		}
		local, buffered, err := w.(http.Hijacker).Hijack()
		if err != nil {
			remote.Close()
			return
		}
		buffered.WriteString("HTTP/1.1 200 Connection Established\r\n\r\n")
		buffered.Flush()
		go func() {
			io.Copy(remote, buffered)
			remote.Close()
		}()
		io.Copy(local, remote)
		local.Close()
	}))
	fmt.Println(ports[0], ports[1], proxy.Addr().(*net.TCPAddr).Port)
	select {}
}

type observation struct {
	Protocol    string `json:"protocol"`
	Origin      string `json:"origin"`
	Connection  string `json:"connection"`
	Overlap     string `json:"overlap"`
	Body        []byte `json:"body"`
	Trailer     string `json:"trailer"`
	GRPCStatus  string `json:"grpcStatus"`
	SentTrailer string `json:"sentTrailer"`
	Status      int    `json:"status"`
	BodySize    int    `json:"bodySize"`
	Length      int64  `json:"length"`
	BodySHA256  string `json:"bodySHA256"`
	RuleResult  string `json:"ruleResult"`
	Error       string `json:"error,omitempty"`
}

func request(c *http.Client, r *http.Request) observation {
	response, err := c.Do(r)
	if err != nil {
		return observation{Error: err.Error()}
	}
	defer response.Body.Close()
	body, err := io.ReadAll(response.Body)
	if err != nil {
		return observation{Error: err.Error()}
	}
	bodySize := len(body)
	digest := fmt.Sprintf("%x", sha256.Sum256(body))
	if bodySize > 8192 {
		body = nil
	}
	return observation{
		Protocol: response.Proto, Origin: response.Header.Get("X-Fixture-Protocol"),
		Connection: response.Header.Get("X-Fixture-Connection"), Overlap: response.Header.Get("X-Fixture-Overlap"),
		Body: body, Trailer: response.Trailer.Get("X-Fixture-Trailer"),
		GRPCStatus: response.Trailer.Get("Grpc-Status"), SentTrailer: response.Header.Get("X-Request-Trailer"),
		Status: response.StatusCode, BodySize: bodySize, Length: response.ContentLength, BodySHA256: digest,
		RuleResult: response.Header.Get("X-Rule-Result"),
	}
}

func get(c *http.Client, target string) observation {
	r, err := http.NewRequest(http.MethodGet, target, nil)
	if err != nil {
		panic(err)
	}
	return request(c, r)
}

func client(proxyAddress, ca, origin, fallback, scenario string) {
	pem, err := os.ReadFile(ca)
	if err != nil {
		panic(err)
	}
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(pem) {
		panic("invalid fixture root")
	}
	proxy, err := url.Parse(proxyAddress)
	if err != nil {
		panic(err)
	}
	transport := &http.Transport{
		Proxy: http.ProxyURL(proxy), TLSClientConfig: &tls.Config{RootCAs: roots, MinVersion: tls.VersionTLS12},
		ForceAttemptHTTP2: true, MaxConnsPerHost: 1,
	}
	defer transport.CloseIdleConnections()
	c := &http.Client{Transport: transport, Timeout: 8 * time.Second}
	base := "https://allowed.pm.test:" + origin
	result := make(map[string]observation)
	if scenario == "map-local" {
		slow, err := c.Get(base + "/local-stream")
		if err != nil {
			result["slow"] = observation{Error: err.Error()}
		} else {
			prefix := make([]byte, 16)
			if _, err := io.ReadFull(slow.Body, prefix); err != nil {
				result["slow"] = observation{Error: err.Error()}
			} else {
				result["slow"] = observation{Protocol: slow.Proto, Body: prefix}
			}
			head, _ := http.NewRequest(http.MethodHead, base+"/local-stream", nil)
			result["head"] = request(c, head)
			slow.Body.Close()
		}
		result["body"] = get(c, base+"/local-stream")
		json.NewEncoder(os.Stdout).Encode(result)
		return
	}
	if scenario == "h1" {
		result["h1"] = get(c, base+"/h1")
		postGRPCWeb(c, "https://allowed.pm.test:"+fallback, result)
		json.NewEncoder(os.Stdout).Encode(result)
		return
	}
	if scenario == "external" || scenario == "bypass" || scenario == "h2c" || scenario == "pac" {
		result[scenario] = get(c, base+"/"+scenario)
		json.NewEncoder(os.Stdout).Encode(result)
		return
	}
	if scenario == "pool" {
		for i := 0; i < 40; i++ {
			name := fmt.Sprintf("pool-%02d", i)
			result[name] = get(c, base+"/"+name)
		}
		result["oldest-again"] = get(c, base+"/pool-00")
		result["newest-again"] = get(c, base+"/pool-39")
		json.NewEncoder(os.Stdout).Encode(result)
		return
	}
	if scenario == "paced" {
		payload := bytes.Repeat([]byte("pace"), 2048)
		post, _ := http.NewRequest(http.MethodPost, base+"/paced", bytes.NewReader(payload))
		result["paced"] = request(c, post)
		json.NewEncoder(os.Stdout).Encode(result)
		return
	}
	if scenario == "intercept" {
		result["warm"] = get(c, base+"/warm")
		var wg sync.WaitGroup
		var lock sync.Mutex
		for _, path := range []string{"intercept-request", "intercept-drop", "intercept-sibling"} {
			wg.Add(1)
			go func(path string) {
				defer wg.Done()
				var value observation
				if path == "intercept-request" {
					r, _ := http.NewRequest(http.MethodPost, base+"/"+path, bytes.NewReader([]byte("before")))
					r.Trailer = http.Header{"X-Request-Check": {"preserved"}}
					value = request(c, r)
				} else {
					value = get(c, base+"/"+path)
				}
				lock.Lock()
				result[path] = value
				lock.Unlock()
			}(path)
		}
		wg.Wait()
		body := []byte(`{"query":"query FindUser { user }","operationName":"FindUser"}`)
		r, _ := http.NewRequest(http.MethodPost, base+"/intercept-graphql", bytes.NewReader(body))
		r.Header.Set("Content-Type", "application/graphql+json")
		result["graphql"] = request(c, r)
		json.NewEncoder(os.Stdout).Encode(result)
		return
	}
	result["warm"] = get(c, base+"/warm")
	if result["warm"].Error != "" {
		json.NewEncoder(os.Stdout).Encode(result)
		return
	}
	var wg sync.WaitGroup
	var lock sync.Mutex
	for _, name := range []string{"left", "right"} {
		wg.Add(1)
		go func(name string) {
			defer wg.Done()
			value := get(c, base+"/"+name)
			lock.Lock()
			result[name] = value
			lock.Unlock()
		}(name)
	}
	wg.Wait()

	ctx, cancel := context.WithCancel(context.Background())
	r, _ := http.NewRequestWithContext(ctx, http.MethodGet, base+"/cancel", nil)
	started, err := c.Do(r)
	if err == nil {
		buf := make([]byte, 7)
		_, err = io.ReadFull(started.Body, buf)
		result["cancel"] = observation{Protocol: started.Proto, Body: buf}
		keep := make(chan observation, 1)
		go func() { keep <- get(c, base+"/keep") }()
		time.Sleep(25 * time.Millisecond)
		cancel()
		started.Body.Close()
		result["keep"] = <-keep
		result["cancel-status"] = get(c, base+"/cancel-status")
	}
	cancel()
	if err != nil {
		result["cancel"] = observation{Error: err.Error()}
	}

	payload := []byte{0, 0, 0, 0, 4, 0x0a, 2, 'o', 'k', 0, 0, 0, 0, 0}
	grpc, _ := http.NewRequest(http.MethodPost, base+"/pm.Echo/Echo", io.NopCloser(bytes.NewReader(payload)))
	grpc.Header.Set("Content-Type", "application/grpc")
	grpc.Header.Set("TE", "trailers")
	grpc.Trailer = http.Header{"X-Request-Check": {"present"}}
	result["grpc"] = request(c, grpc)
	postGRPCWeb(c, base, result)
	largeBody := bytes.Repeat([]byte("wire-flow"), 32*1024)
	large, _ := http.NewRequest(http.MethodPost, base+"/large", bytes.NewReader(largeBody))
	result["large"] = request(c, large)
	result["fallback"] = get(c, "https://allowed.pm.test:"+fallback+"/fallback")
	result["mapped"] = get(c, base+"/mapped")
	json.NewEncoder(os.Stdout).Encode(result)
}

func postGRPCWeb(c *http.Client, base string, result map[string]observation) {
	payload := []byte{0, 0, 0, 0, 4, 0x0a, 2, 'o', 'k', 0, 0, 0, 0, 0}
	binary, _ := http.NewRequest(http.MethodPost, base+"/pm.Web/Binary", bytes.NewReader(payload))
	binary.Header.Set("Content-Type", "application/grpc-web+proto")
	result["grpc-web-binary"] = request(c, binary)

	text, _ := http.NewRequest(http.MethodPost, base+"/pm.Web/Text",
		bytes.NewBufferString(base64.StdEncoding.EncodeToString(payload)))
	text.Header.Set("Content-Type", "application/grpc-web-text+proto")
	result["grpc-web-text"] = request(c, text)
}

func main() {
	switch os.Args[1] {
	case "server":
		serve(os.Args[2], os.Args[3])
	case "client":
		client(os.Args[2], os.Args[3], os.Args[4], os.Args[5], os.Args[6])
	}
}
