// Local HTTP/2 and gRPC wire-format fixture. This executable has no third-party dependencies.
package main

import (
	"bufio"
	"bytes"
	"context"
	"crypto/sha1"
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
	var wsCancelled atomic.Bool
	mux := http.NewServeMux()
	mux.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		connection := r.Context().Value(connKey{}).(int64)
		w.Header().Set("X-Fixture-Protocol", r.Proto)
		w.Header().Set("X-Fixture-Connection", strconv.FormatInt(connection, 10))
		switch r.URL.Path {
		case "/rfc8441", "/rfc8441-cancel":
			serveWebSocket(w, r, &wsCancelled)
		case "/rfc8441-cancel-status":
			for i := 0; i < 100 && !wsCancelled.Load(); i++ {
				time.Sleep(10 * time.Millisecond)
			}
			fmt.Fprint(w, wsCancelled.Load())
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
	if scenario == "rfc8441" {
		result, err := extendedConnectClient(proxyAddress, ca, origin)
		if err != nil {
			result = map[string]observation{"rfc8441": {Error: err.Error()}}
		}
		json.NewEncoder(os.Stdout).Encode(result)
		return
	}
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

// RFC8441 fixture uses literal HPACK fields and raw HTTP/2 frames so it remains
// independent of Go's HTTP/2 client (which doesn't expose extended CONNECT).
func serveWebSocket(w http.ResponseWriter, r *http.Request, cancelled *atomic.Bool) {
	if r.Method != "GET" || r.Header.Get("Upgrade") != "websocket" || r.Header.Get("Sec-WebSocket-Key") == "" {
		http.Error(w, "invalid WebSocket handshake", 400)
		return
	}
	connection, buffered, err := w.(http.Hijacker).Hijack()
	if err != nil {
		return
	}
	defer connection.Close()
	connection.SetDeadline(time.Now().Add(15 * time.Second))
	digest := sha1.Sum([]byte(r.Header.Get("Sec-WebSocket-Key") + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))
	fmt.Fprintf(buffered, "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: %s\r\n\r\n", base64.StdEncoding.EncodeToString(digest[:]))
	buffered.Flush()
	for {
		head := make([]byte, 2)
		if _, err := io.ReadFull(buffered, head); err != nil {
			if r.URL.Path == "/rfc8441-cancel" {
				cancelled.Store(true)
			}
			return
		}
		size := uint64(head[1] & 127)
		if size == 126 {
			extended := make([]byte, 2)
			if _, err := io.ReadFull(buffered, extended); err != nil {
				return
			}
			size = uint64(binary.BigEndian.Uint16(extended))
		} else if size == 127 {
			extended := make([]byte, 8)
			if _, err := io.ReadFull(buffered, extended); err != nil {
				return
			}
			size = binary.BigEndian.Uint64(extended)
		}
		if head[1]&128 == 0 || size > 2*1024*1024 {
			return
		}
		mask := make([]byte, 4)
		if _, err := io.ReadFull(buffered, mask); err != nil {
			return
		}
		payload := make([]byte, int(size))
		if _, err := io.ReadFull(buffered, payload); err != nil {
			return
		}
		for i := range payload {
			payload[i] ^= mask[i%4]
		}
		connection.Write(webSocketWire(head[0]&15, payload, false))
		if head[0]&15 == 8 {
			return
		}
	}
}

func webSocketWire(opcode byte, payload []byte, masked bool) []byte {
	out := []byte{0x80 | opcode}
	flag := byte(0)
	if masked {
		flag = 128
	}
	if len(payload) < 126 {
		out = append(out, flag|byte(len(payload)))
	} else if len(payload) <= 65535 {
		out = append(out, flag|126, byte(len(payload)>>8), byte(len(payload)))
	} else {
		out = append(out, flag|127)
		size := make([]byte, 8)
		binary.BigEndian.PutUint64(size, uint64(len(payload)))
		out = append(out, size...)
	}
	if masked {
		mask := []byte{0x11, 0x22, 0x33, 0x44}
		out = append(out, mask...)
		for i, value := range payload {
			out = append(out, value^mask[i%4])
		}
	} else {
		out = append(out, payload...)
	}
	return out
}

type h2WireFrame struct {
	kind, flags byte
	stream      uint32
	payload     []byte
}

func writeH2Frame(c net.Conn, kind, flags byte, stream uint32, payload []byte) error {
	head := make([]byte, 9)
	head[0], head[1], head[2], head[3], head[4] = byte(len(payload)>>16), byte(len(payload)>>8), byte(len(payload)), kind, flags
	binary.BigEndian.PutUint32(head[5:], stream)
	if _, err := c.Write(head); err != nil {
		return err
	}
	_, err := c.Write(payload)
	return err
}
func readH2Frame(c net.Conn) (h2WireFrame, error) {
	head := make([]byte, 9)
	if _, err := io.ReadFull(c, head); err != nil {
		return h2WireFrame{}, err
	}
	size := int(head[0])<<16 | int(head[1])<<8 | int(head[2])
	if size > 1024*1024 {
		return h2WireFrame{}, fmt.Errorf("fixture frame too large: %d", size)
	}
	f := h2WireFrame{kind: head[3], flags: head[4], stream: binary.BigEndian.Uint32(head[5:]) & 0x7fffffff, payload: make([]byte, size)}
	_, err := io.ReadFull(c, f.payload)
	return f, err
}
func fixtureMin(a, b int) int {
	if a < b {
		return a
	}
	return b
}

func hpackString(value string) []byte {
	size := len(value)
	out := []byte{}
	if size < 127 {
		out = append(out, byte(size))
	} else {
		out = append(out, 127)
		size -= 127
		for size >= 128 {
			out = append(out, byte(size%128)|128)
			size >>= 7
		}
		out = append(out, byte(size))
	}
	return append(out, []byte(value)...)
}
func literalHeaders(fields [][2]string) []byte {
	out := []byte{}
	for _, field := range fields {
		out = append(out, 0)
		out = append(out, hpackString(field[0])...)
		out = append(out, hpackString(field[1])...)
	}
	return out
}
func connectHeaders(authority, path string) []byte {
	return literalHeaders([][2]string{{":method", "CONNECT"}, {":protocol", "websocket"}, {":scheme", "https"}, {":authority", authority}, {":path", path}, {"sec-websocket-version", "13"}})
}
func regularHeaders(authority, path string) []byte {
	return literalHeaders([][2]string{{":method", "GET"}, {":scheme", "https"}, {":authority", authority}, {":path", path}})
}
func extendedConnectClient(proxyAddress, ca, origin string) (map[string]observation, error) {
	proxy, err := url.Parse(proxyAddress)
	if err != nil {
		return nil, err
	}
	transport, err := net.DialTimeout("tcp", proxy.Host, 5*time.Second)
	if err != nil {
		return nil, err
	}
	defer transport.Close()
	transport.SetDeadline(time.Now().Add(20 * time.Second))
	authority := "allowed.pm.test:" + origin
	fmt.Fprintf(transport, "CONNECT %s HTTP/1.1\r\nHost: %s\r\n\r\n", authority, authority)
	response, err := http.ReadResponse(bufio.NewReader(transport), &http.Request{Method: "CONNECT"})
	if err != nil {
		return nil, err
	}
	if response.StatusCode != 200 {
		return nil, fmt.Errorf("CONNECT: %s", response.Status)
	}
	pem, err := os.ReadFile(ca)
	if err != nil {
		return nil, err
	}
	roots := x509.NewCertPool()
	if !roots.AppendCertsFromPEM(pem) {
		return nil, fmt.Errorf("invalid CA")
	}
	secured := tls.Client(transport, &tls.Config{RootCAs: roots, ServerName: "allowed.pm.test", NextProtos: []string{"h2"}, MinVersion: tls.VersionTLS12})
	if err := secured.Handshake(); err != nil {
		return nil, err
	}
	if secured.ConnectionState().NegotiatedProtocol != "h2" {
		return nil, fmt.Errorf("proxy did not negotiate h2")
	}
	if _, err := io.WriteString(secured, "PRI * HTTP/2.0\r\n\r\nSM\r\n\r\n"); err != nil {
		return nil, err
	}
	// Disable dynamic header indexing and enlarge the receive window. The raw
	// fixture only needs status 200's mandatory HPACK static-table index (0x88).
	settings := []byte{0, 1, 0, 0, 0, 0, 0, 4, 0, 0x10, 0, 0}
	if err := writeH2Frame(secured, 4, 0, 0, settings); err != nil {
		return nil, err
	}
	connWindow, streamWindow := 65535, 65535
	enabled := false
	statuses := map[uint32]int{}
	bodies := map[uint32][]byte{}
	ended := map[uint32]bool{}
	read := func() error {
		frame, err := readH2Frame(secured)
		if err != nil {
			return err
		}
		switch frame.kind {
		case 4:
			if frame.flags&1 == 0 {
				for i := 0; i+6 <= len(frame.payload); i += 6 {
					name, value := binary.BigEndian.Uint16(frame.payload[i:]), binary.BigEndian.Uint32(frame.payload[i+2:])
					if name == 8 && value == 1 {
						enabled = true
					}
					if name == 4 {
						streamWindow += int(value) - 65535
					}
				}
				return writeH2Frame(secured, 4, 1, 0, nil)
			}
		case 6:
			if frame.flags&1 == 0 {
				return writeH2Frame(secured, 6, 1, 0, frame.payload)
			}
		case 8:
			if len(frame.payload) == 4 {
				value := int(binary.BigEndian.Uint32(frame.payload) & 0x7fffffff)
				if frame.stream == 0 {
					connWindow += value
				}
				if frame.stream == 1 {
					streamWindow += value
				}
			}
		case 1:
			block := frame.payload
			// HPACK may start with a dynamic-table size update after our
			// SETTINGS_HEADER_TABLE_SIZE=0. Skip those before the status index.
			for len(block) > 0 && block[0]&0xe0 == 0x20 {
				first := block[0] & 31
				block = block[1:]
				if first == 31 {
					for len(block) > 0 {
						b := block[0]
						block = block[1:]
						if b&128 == 0 {
							break
						}
					}
				}
			}
			if len(block) == 0 || block[0] != 0x88 {
				return fmt.Errorf("unexpected response header block on stream %d: %x", frame.stream, frame.payload)
			}
			statuses[frame.stream] = 200
			ended[frame.stream] = frame.flags&1 != 0
		case 0:
			bodies[frame.stream] = append(bodies[frame.stream], frame.payload...)
			if frame.flags&1 != 0 {
				ended[frame.stream] = true
			}
			if len(frame.payload) > 0 {
				update := make([]byte, 4)
				binary.BigEndian.PutUint32(update, uint32(len(frame.payload)))
				if err := writeH2Frame(secured, 8, 0, 0, update); err != nil {
					return err
				}
				if err := writeH2Frame(secured, 8, 0, frame.stream, update); err != nil {
					return err
				}
			}
		case 3:
			if frame.stream != 5 {
				return fmt.Errorf("unexpected RST_STREAM %d: %x", frame.stream, frame.payload)
			}
		case 7:
			return fmt.Errorf("unexpected GOAWAY: %x", frame.payload)
		}
		return nil
	}
	for !enabled {
		if err := read(); err != nil {
			return nil, err
		}
	}
	if err := writeH2Frame(secured, 1, 4, 1, connectHeaders(authority, "/rfc8441")); err != nil {
		return nil, err
	}
	if err := writeH2Frame(secured, 1, 5, 3, regularHeaders(authority, "/rfc8441-sibling")); err != nil {
		return nil, err
	}
	for statuses[1] != 200 {
		if err := read(); err != nil {
			return nil, err
		}
	}
	payload := bytes.Repeat([]byte("rfc8441-flow"), 16384)
	wire := append(webSocketWire(1, []byte("before"), true), webSocketWire(2, payload, true)...)
	wire = append(wire, webSocketWire(8, []byte{3, 232}, true)...)
	for offset := 0; offset < len(wire); {
		count := len(wire) - offset
		if count > 16384 {
			count = 16384
		}
		if count > connWindow {
			count = connWindow
		}
		if count > streamWindow {
			count = streamWindow
		}
		if count == 0 {
			if err := read(); err != nil {
				return nil, err
			}
			continue
		}
		flags := byte(0)
		if offset+count == len(wire) {
			flags = 1
		}
		if err := writeH2Frame(secured, 0, flags, 1, wire[offset:offset+count]); err != nil {
			return nil, err
		}
		offset += count
		connWindow -= count
		streamWindow -= count
	}
	for !ended[1] || !ended[3] {
		if err := read(); err != nil {
			return nil, err
		}
	}
	raw := bodies[1]
	if len(raw) < 7 || !bytes.Equal(raw[:7], append([]byte{0x81, 5}, []byte("after")...)) {
		return nil, fmt.Errorf("RFC8441 frame script was not applied before END_STREAM")
	}
	raw = raw[7:]
	if len(raw) < 10 || raw[0] != 0x82 || raw[1] != 127 {
		return nil, fmt.Errorf("missing echoed binary WS frame: %x", raw[:fixtureMin(len(raw), 20)])
	}
	size := int(binary.BigEndian.Uint64(raw[2:10]))
	if size != len(payload) || len(raw) < 10+size+4 || !bytes.Equal(raw[10:10+size], payload) {
		return nil, fmt.Errorf("flow-controlled WS payload was changed or truncated")
	}
	if !bytes.Equal(raw[10+size:], []byte{0x88, 2, 3, 232}) {
		return nil, fmt.Errorf("missing WS close frame before END_STREAM")
	}
	if string(bodies[3]) != "/rfc8441-sibling" {
		return nil, fmt.Errorf("sibling HTTP stream failed")
	}
	if err := writeH2Frame(secured, 1, 4, 5, connectHeaders(authority, "/rfc8441-cancel")); err != nil {
		return nil, err
	}
	for statuses[5] != 200 {
		if err := read(); err != nil {
			return nil, err
		}
	}
	if err := writeH2Frame(secured, 3, 0, 5, []byte{0, 0, 0, 8}); err != nil {
		return nil, err
	}
	if err := writeH2Frame(secured, 1, 5, 7, regularHeaders(authority, "/rfc8441-cancel-status")); err != nil {
		return nil, err
	}
	for !ended[7] {
		if err := read(); err != nil {
			return nil, err
		}
	}
	if string(bodies[7]) != "true" {
		return nil, fmt.Errorf("stream reset did not cancel the origin WS connection")
	}
	return map[string]observation{
		"rfc8441": {Protocol: "HTTP/2.0", Origin: "HTTP/1.1", Status: statuses[1], Body: []byte("after"), BodySize: len(payload), BodySHA256: fmt.Sprintf("%x", sha256.Sum256(payload)), RuleResult: "enable-connect=1"},
		"sibling": {Protocol: "HTTP/2.0", Body: bodies[3], Status: statuses[3]},
		"cancel":  {Protocol: "HTTP/2.0", Body: bodies[7], Status: statuses[7]},
	}, nil
}

func main() {
	switch os.Args[1] {
	case "server":
		serve(os.Args[2], os.Args[3])
	case "client":
		client(os.Args[2], os.Args[3], os.Args[4], os.Args[5], os.Args[6])
	}
}
