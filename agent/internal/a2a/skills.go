// skills.go — the built-in A2A skills an instance offers to peers, beyond the
// liveness `ping`:
//
//   describe           — peer self-description (id, os/arch, offered skills)
//   inference.generate — LLM text generation via the node's local inference
//                        runtime (ollama). Realizes the substrate's core idea:
//                        a GPU-bearing instance offers inference to peers over
//                        A2A, so CPU-only agents offload generation to it.
//   inference.embed    — text embedding via the same runtime.
//
// RegisterStandardSkills wires these onto a Registry based on what the node can
// offer (inference skills only when an inference endpoint is configured).

package a2a

import (
	"bytes"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"strings"
	"time"
)

// NodeDescriptor is returned by the "describe" skill — a peer's self-description
// for capability discovery over A2A.
type NodeDescriptor struct {
	InstanceID string         `json:"instance_id"`
	OS         string         `json:"os"`
	Arch       string         `json:"arch"`
	Kernel     string         `json:"kernel,omitempty"`
	Skills     []string       `json:"skills"`
	Extra      map[string]any `json:"extra,omitempty"`
}

// StandardSkillOptions selects which built-in skills to register.
type StandardSkillOptions struct {
	// Descriptor builds the describe response; it receives the live offered
	// skill names. Nil disables the describe skill.
	Descriptor func(offeredSkills []string) NodeDescriptor
	// InferenceEndpoint (e.g. http://127.0.0.1:11434) enables the inference.*
	// skills, proxying to that ollama-compatible runtime. Empty disables them.
	InferenceEndpoint string
}

// RegisterStandardSkills installs ping + describe (+ inference.* when an
// endpoint is configured) onto reg.
func RegisterStandardSkills(reg *Registry, opts StandardSkillOptions) {
	reg.RegisterPing()
	if opts.Descriptor != nil {
		RegisterDescribe(reg, func() NodeDescriptor { return opts.Descriptor(reg.Names()) })
	}
	if strings.TrimSpace(opts.InferenceEndpoint) != "" {
		NewInferenceProxy(opts.InferenceEndpoint).Register(reg)
	}
}

// RegisterDescribe installs the "describe" skill, returning a fresh descriptor
// per call so Skills reflects the live registry.
func RegisterDescribe(reg *Registry, build func() NodeDescriptor) {
	reg.Register("describe", "Return this instance's self-description (id, os/arch, offered skills).",
		map[string]any{"type": "object"},
		func(_ json.RawMessage) (any, error) { return build(), nil })
}

// InferenceProxy forwards inference skills to a local ollama-compatible runtime.
type InferenceProxy struct {
	Endpoint   string
	HTTPClient *http.Client
}

// NewInferenceProxy targets endpoint (trailing slash trimmed) with a 120s timeout.
func NewInferenceProxy(endpoint string) *InferenceProxy {
	return &InferenceProxy{
		Endpoint:   strings.TrimRight(endpoint, "/"),
		HTTPClient: &http.Client{Timeout: 120 * time.Second},
	}
}

// Register installs inference.generate + inference.embed onto reg.
func (p *InferenceProxy) Register(reg *Registry) {
	reg.Register("inference.generate",
		"LLM text generation via this node's local inference runtime (ollama). Args: {model, prompt}.",
		map[string]any{
			"type": "object",
			"properties": map[string]any{
				"model":  map[string]any{"type": "string"},
				"prompt": map[string]any{"type": "string"},
			},
			"required": []string{"model", "prompt"},
		}, p.generate)

	reg.Register("inference.embed",
		"Text embedding via this node's local inference runtime (ollama). Args: {model, input}.",
		map[string]any{
			"type": "object",
			"properties": map[string]any{
				"model": map[string]any{"type": "string"},
				"input": map[string]any{"type": "string"},
			},
			"required": []string{"model", "input"},
		}, p.embed)
}

func (p *InferenceProxy) generate(args json.RawMessage) (any, error) {
	var a struct {
		Model  string `json:"model"`
		Prompt string `json:"prompt"`
	}
	if err := json.Unmarshal(args, &a); err != nil {
		return nil, fmt.Errorf("bad args: %w", err)
	}
	if a.Model == "" || a.Prompt == "" {
		return nil, fmt.Errorf("model and prompt are required")
	}
	body, _ := json.Marshal(map[string]any{"model": a.Model, "prompt": a.Prompt, "stream": false})
	raw, err := p.post("/api/generate", body)
	if err != nil {
		return nil, err
	}
	var res struct {
		Response string `json:"response"`
		Model    string `json:"model"`
	}
	if err := json.Unmarshal(raw, &res); err != nil {
		return nil, fmt.Errorf("decode inference response: %w", err)
	}
	return map[string]any{"response": res.Response, "model": res.Model}, nil
}

func (p *InferenceProxy) embed(args json.RawMessage) (any, error) {
	var a struct {
		Model string `json:"model"`
		Input string `json:"input"`
	}
	if err := json.Unmarshal(args, &a); err != nil {
		return nil, fmt.Errorf("bad args: %w", err)
	}
	if a.Model == "" || a.Input == "" {
		return nil, fmt.Errorf("model and input are required")
	}
	// ollama /api/embeddings takes {model, prompt}.
	body, _ := json.Marshal(map[string]any{"model": a.Model, "prompt": a.Input})
	raw, err := p.post("/api/embeddings", body)
	if err != nil {
		return nil, err
	}
	var res struct {
		Embedding []float64 `json:"embedding"`
	}
	if err := json.Unmarshal(raw, &res); err != nil {
		return nil, fmt.Errorf("decode embedding response: %w", err)
	}
	return map[string]any{"embedding": res.Embedding, "dims": len(res.Embedding)}, nil
}

func (p *InferenceProxy) post(path string, body []byte) ([]byte, error) {
	req, err := http.NewRequest(http.MethodPost, p.Endpoint+path, bytes.NewReader(body))
	if err != nil {
		return nil, err
	}
	req.Header.Set("Content-Type", "application/json")
	resp, err := p.HTTPClient.Do(req)
	if err != nil {
		return nil, fmt.Errorf("inference call: %w", err)
	}
	defer resp.Body.Close()
	raw, _ := io.ReadAll(resp.Body)
	if resp.StatusCode != http.StatusOK {
		return nil, fmt.Errorf("inference runtime status %d: %s", resp.StatusCode, strings.TrimSpace(string(raw)))
	}
	return raw, nil
}
