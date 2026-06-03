// client.go — outbound A2A MCP client. Invokes skills on peer instances over
// mTLS, presenting a platform-minted capability token. The caller is expected
// to have discovered the peer (address) + minted the token already.

package a2a

import (
	"bytes"
	"crypto/tls"
	"crypto/x509"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// Client invokes skills on peer A2A MCP servers.
type Client struct {
	httpClient *http.Client
}

// NewClient wraps an *http.Client (which should carry the node's mTLS client
// cert via ClientTLSConfig). A nil client gets a 30s-timeout default.
func NewClient(httpClient *http.Client) *Client {
	if httpClient == nil {
		httpClient = &http.Client{Timeout: 30 * time.Second}
	}
	return &Client{httpClient: httpClient}
}

// Initialize performs the MCP initialize handshake; returns the raw result
// (serverInfo + capabilities).
func (c *Client) Initialize(baseURL string, token *Token) (json.RawMessage, error) {
	params, _ := json.Marshal(map[string]any{
		"protocolVersion": ProtocolVersion,
		"capabilities":    map[string]any{},
		"clientInfo":      map[string]any{"name": "powernode-agent-a2a-client", "version": "1"},
	})
	resp, err := c.rpc(baseURL, token, "initialize", params)
	if err != nil {
		return nil, err
	}
	if resp.Error != nil {
		return nil, fmt.Errorf("initialize error %d: %s", resp.Error.Code, resp.Error.Message)
	}
	return mustJSON(resp.Result), nil
}

// ListTools fetches the peer's offered skills.
func (c *Client) ListTools(baseURL string, token *Token) ([]ToolSpec, error) {
	resp, err := c.rpc(baseURL, token, "tools/list", json.RawMessage(`{}`))
	if err != nil {
		return nil, err
	}
	if resp.Error != nil {
		return nil, fmt.Errorf("tools/list error %d: %s", resp.Error.Code, resp.Error.Message)
	}
	var res struct {
		Tools []ToolSpec `json:"tools"`
	}
	if err := json.Unmarshal(mustJSON(resp.Result), &res); err != nil {
		return nil, fmt.Errorf("decode tools/list: %w", err)
	}
	return res.Tools, nil
}

// CallSkill invokes `skill` on the peer, presenting `token` as the capability.
// Returns the structured result of the skill.
func (c *Client) CallSkill(baseURL string, token *Token, skill string, args any) (json.RawMessage, error) {
	argsRaw, err := json.Marshal(args)
	if err != nil {
		return nil, fmt.Errorf("marshal args: %w", err)
	}
	params, _ := json.Marshal(map[string]any{"name": skill, "arguments": json.RawMessage(argsRaw)})
	resp, err := c.rpc(baseURL, token, "tools/call", params)
	if err != nil {
		return nil, err
	}
	if resp.Error != nil {
		return nil, fmt.Errorf("peer rpc error %d: %s", resp.Error.Code, resp.Error.Message)
	}

	var res struct {
		IsError           bool            `json:"isError"`
		StructuredContent json.RawMessage `json:"structuredContent"`
		Content           []struct {
			Type string `json:"type"`
			Text string `json:"text"`
		} `json:"content"`
	}
	if err := json.Unmarshal(mustJSON(resp.Result), &res); err != nil {
		return nil, fmt.Errorf("decode tools/call result: %w", err)
	}
	if res.IsError {
		msg := "skill error"
		if len(res.Content) > 0 {
			msg = res.Content[0].Text
		}
		return nil, fmt.Errorf("%s", msg)
	}
	return res.StructuredContent, nil
}

func (c *Client) rpc(baseURL string, token *Token, method string, params json.RawMessage) (*rpcResponse, error) {
	body, _ := json.Marshal(rpcRequest{JSONRPC: "2.0", ID: json.RawMessage(`1`), Method: method, Params: params})
	req, err := http.NewRequest(http.MethodPost, strings.TrimRight(baseURL, "/")+"/", bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	if token != nil {
		req.Header.Set("Authorization", EncodeTokenHeader(token))
	}
	resp, err := c.httpClient.Do(req)
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	var rr rpcResponse
	if err := json.Unmarshal(raw, &rr); err != nil {
		return nil, fmt.Errorf("decode response (status %d): %w", resp.StatusCode, err)
	}
	return &rr, nil
}

func mustJSON(v any) []byte {
	b, _ := json.Marshal(v)
	return b
}

// ClientTLSConfig builds the outbound mTLS config: present the node's client
// cert (CN = this instance id) and verify the peer's server cert CHAINS to the
// platform CA — but NOT against a hostname. A2A peers are reached by overlay
// IP/handle while their identity is the CA-signed cert CN, so default hostname
// verification doesn't apply; we verify the chain manually and let the
// capability token's `aud` bind which instance we intended to reach.
func ClientTLSConfig(clientCert tls.Certificate, rootCAs *x509.CertPool) *tls.Config {
	return &tls.Config{
		Certificates:       []tls.Certificate{clientCert},
		MinVersion:         tls.VersionTLS13,
		InsecureSkipVerify: true, //nolint:gosec // chain verified in VerifyPeerCertificate; identity is the CA-signed CN, not the hostname
		VerifyPeerCertificate: func(rawCerts [][]byte, _ [][]*x509.Certificate) error {
			return verifyChainToCA(rawCerts, rootCAs)
		},
	}
}

// verifyChainToCA verifies the peer's leaf cert chains to one of the trusted
// roots (hostname-independent).
func verifyChainToCA(rawCerts [][]byte, roots *x509.CertPool) error {
	if len(rawCerts) == 0 {
		return errors.New("no peer certificate presented")
	}
	leaf, err := x509.ParseCertificate(rawCerts[0])
	if err != nil {
		return fmt.Errorf("parse peer certificate: %w", err)
	}
	intermediates := x509.NewCertPool()
	for _, raw := range rawCerts[1:] {
		if c, err := x509.ParseCertificate(raw); err == nil {
			intermediates.AddCert(c)
		}
	}
	_, err = leaf.Verify(x509.VerifyOptions{Roots: roots, Intermediates: intermediates})
	return err
}
