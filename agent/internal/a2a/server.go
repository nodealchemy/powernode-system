// server.go — the on-node MCP JSON-RPC 2.0 server. Peers POST JSON-RPC over
// mTLS; this dispatches initialize / tools/list / tools/call. tools/call is
// capability-gated: the caller's mTLS client-cert CN must equal the token's
// `sub`, the token `aud` must equal this instance, and the token `skill` must
// equal the tool being invoked.

package a2a

import (
	"crypto/tls"
	"crypto/x509"
	"encoding/base64"
	"encoding/json"
	"errors"
	"net/http"
	"strings"
	"time"
)

var (
	errMissingAuth   = errors.New("missing Authorization header")
	errBadAuthScheme = errors.New("expected Bearer capability token")
)

// ProtocolVersion is the MCP protocol revision this server speaks.
const ProtocolVersion = "2025-06-18"

// JSON-RPC error codes (standard + A2A-specific).
const (
	codeParseError     = -32700
	codeInvalidRequest = -32600
	codeMethodNotFound = -32601
	codeInvalidParams  = -32602
	codeUnauthorized   = -32001 // capability token missing/denied
)

// ServerInfo is returned in the initialize handshake.
type ServerInfo struct {
	Name    string `json:"name"`
	Version string `json:"version"`
}

// Server is the A2A MCP server for one instance.
type Server struct {
	SelfInstanceID string
	Verifier       *Verifier
	Registry       *Registry
	Info           ServerInfo
	Now            func() time.Time // injectable clock (tests)
}

// NewServer builds a server for selfInstanceID offering registry's skills,
// verifying capability tokens with verifier.
func NewServer(selfInstanceID string, verifier *Verifier, registry *Registry) *Server {
	return &Server{
		SelfInstanceID: selfInstanceID,
		Verifier:       verifier,
		Registry:       registry,
		Info:           ServerInfo{Name: "powernode-agent-a2a", Version: "1"},
		Now:            time.Now,
	}
}

type rpcRequest struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Method  string          `json:"method"`
	Params  json.RawMessage `json:"params,omitempty"`
}

type rpcError struct {
	Code    int    `json:"code"`
	Message string `json:"message"`
	Data    any    `json:"data,omitempty"`
}

type rpcResponse struct {
	JSONRPC string          `json:"jsonrpc"`
	ID      json.RawMessage `json:"id,omitempty"`
	Result  any             `json:"result,omitempty"`
	Error   *rpcError       `json:"error,omitempty"`
}

// Handler returns the JSON-RPC endpoint (POST /).
func (s *Server) Handler() http.Handler {
	mux := http.NewServeMux()
	mux.HandleFunc("/", s.handleRPC)
	return mux
}

func (s *Server) handleRPC(w http.ResponseWriter, r *http.Request) {
	w.Header().Set("Content-Type", "application/json")
	if r.Method != http.MethodPost {
		writeRPCError(w, nil, codeInvalidRequest, "only POST is supported")
		return
	}
	var req rpcRequest
	if err := json.NewDecoder(r.Body).Decode(&req); err != nil {
		writeRPCError(w, nil, codeParseError, "parse error: "+err.Error())
		return
	}
	callerCN := clientCN(r)

	switch req.Method {
	case "initialize":
		writeRPCResult(w, req.ID, map[string]any{
			"protocolVersion": ProtocolVersion,
			"capabilities":    map[string]any{"tools": map[string]any{}},
			"serverInfo":      s.Info,
		})
	case "notifications/initialized", "ping":
		// notifications carry no id; ack empty result.
		writeRPCResult(w, req.ID, map[string]any{})
	case "tools/list":
		writeRPCResult(w, req.ID, map[string]any{"tools": s.Registry.List()})
	case "tools/call":
		s.handleToolsCall(w, r, &req, callerCN)
	default:
		writeRPCError(w, req.ID, codeMethodNotFound, "method not found: "+req.Method)
	}
}

type toolsCallParams struct {
	Name      string          `json:"name"`
	Arguments json.RawMessage `json:"arguments"`
}

func (s *Server) handleToolsCall(w http.ResponseWriter, r *http.Request, req *rpcRequest, callerCN string) {
	var p toolsCallParams
	if err := json.Unmarshal(req.Params, &p); err != nil {
		writeRPCError(w, req.ID, codeInvalidParams, "invalid params: "+err.Error())
		return
	}
	if strings.TrimSpace(p.Name) == "" {
		writeRPCError(w, req.ID, codeInvalidParams, "tool name required")
		return
	}

	// Capability gate — verify the token authorizes (callerCN, self, name).
	tok, err := decodeTokenHeader(r.Header.Get("Authorization"))
	if err != nil {
		writeRPCError(w, req.ID, codeUnauthorized, "capability token required: "+err.Error())
		return
	}
	if _, err := s.Verifier.Verify(tok, s.SelfInstanceID, callerCN, p.Name, s.Now()); err != nil {
		writeRPCError(w, req.ID, codeUnauthorized, "capability denied: "+err.Error())
		return
	}

	if !s.Registry.Has(p.Name) {
		writeRPCError(w, req.ID, codeMethodNotFound, "unknown skill: "+p.Name)
		return
	}

	result, err := s.Registry.Call(p.Name, p.Arguments)
	if err != nil {
		// MCP convention: tool execution errors are a result with isError:true.
		writeRPCResult(w, req.ID, map[string]any{
			"content": []map[string]any{{"type": "text", "text": err.Error()}},
			"isError": true,
		})
		return
	}
	payload, _ := json.Marshal(result)
	writeRPCResult(w, req.ID, map[string]any{
		"content":           []map[string]any{{"type": "text", "text": string(payload)}},
		"isError":           false,
		"structuredContent": result,
	})
}

// clientCN extracts the verified mTLS client-cert CN (= caller instance id).
func clientCN(r *http.Request) string {
	if r.TLS == nil || len(r.TLS.PeerCertificates) == 0 {
		return ""
	}
	return r.TLS.PeerCertificates[0].Subject.CommonName
}

func writeRPCResult(w http.ResponseWriter, id json.RawMessage, result any) {
	_ = json.NewEncoder(w).Encode(rpcResponse{JSONRPC: "2.0", ID: id, Result: result})
}

func writeRPCError(w http.ResponseWriter, id json.RawMessage, code int, msg string) {
	_ = json.NewEncoder(w).Encode(rpcResponse{JSONRPC: "2.0", ID: id, Error: &rpcError{Code: code, Message: msg}})
}

// EncodeTokenHeader renders a capability token for the Authorization header:
// "Bearer <base64(json{envelope,signature})>".
func EncodeTokenHeader(tok *Token) string {
	b, _ := json.Marshal(tok)
	return "Bearer " + base64.StdEncoding.EncodeToString(b)
}

func decodeTokenHeader(h string) (*Token, error) {
	h = strings.TrimSpace(h)
	if h == "" {
		return nil, errMissingAuth
	}
	if !strings.HasPrefix(h, "Bearer ") {
		return nil, errBadAuthScheme
	}
	raw, err := base64.StdEncoding.DecodeString(strings.TrimPrefix(h, "Bearer "))
	if err != nil {
		return nil, err
	}
	var tok Token
	if err := json.Unmarshal(raw, &tok); err != nil {
		return nil, err
	}
	return &tok, nil
}

// ServerTLSConfig builds the inbound mTLS config: present serverCert and
// REQUIRE + verify a client cert signed by the platform CA. The client cert's
// CN is the calling instance id (matched against the token `sub`).
func ServerTLSConfig(serverCert tls.Certificate, clientCAs *x509.CertPool) *tls.Config {
	return &tls.Config{
		Certificates: []tls.Certificate{serverCert},
		ClientAuth:   tls.RequireAndVerifyClientCert,
		ClientCAs:    clientCAs,
		MinVersion:   tls.VersionTLS13,
	}
}
