package a2a

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"testing"
)

func TestDescribeSkill(t *testing.T) {
	reg := NewRegistry()
	RegisterStandardSkills(reg, StandardSkillOptions{
		Descriptor: func(skills []string) NodeDescriptor {
			return NodeDescriptor{InstanceID: "instX", OS: "linux", Arch: "amd64", Skills: skills}
		},
	})
	if !reg.Has("describe") || !reg.Has("ping") {
		t.Fatal("expected ping + describe registered")
	}

	res, err := reg.Call("describe", json.RawMessage(`{}`))
	if err != nil {
		t.Fatal(err)
	}
	b, _ := json.Marshal(res)
	var d NodeDescriptor
	if err := json.Unmarshal(b, &d); err != nil {
		t.Fatal(err)
	}
	if d.InstanceID != "instX" || d.OS != "linux" || d.Arch != "amd64" {
		t.Fatalf("descriptor: %+v", d)
	}
	found := map[string]bool{}
	for _, s := range d.Skills {
		found[s] = true
	}
	if !found["ping"] || !found["describe"] {
		t.Fatalf("describe should list ping+describe, got %v", d.Skills)
	}
}

func TestInferenceGenerateSkill(t *testing.T) {
	ollama := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/generate" {
			t.Errorf("unexpected path %q", r.URL.Path)
		}
		var req map[string]any
		_ = json.NewDecoder(r.Body).Decode(&req)
		if req["model"] != "llama3" || req["stream"] != false {
			t.Errorf("unexpected request %v", req)
		}
		_, _ = w.Write([]byte(`{"response":"hello there","model":"llama3"}`))
	}))
	defer ollama.Close()

	reg := NewRegistry()
	RegisterStandardSkills(reg, StandardSkillOptions{InferenceEndpoint: ollama.URL})
	if !reg.Has("inference.generate") || !reg.Has("inference.embed") {
		t.Fatal("expected inference.* skills registered")
	}

	res, err := reg.Call("inference.generate", json.RawMessage(`{"model":"llama3","prompt":"hi"}`))
	if err != nil {
		t.Fatal(err)
	}
	b, _ := json.Marshal(res)
	var out struct {
		Response string `json:"response"`
		Model    string `json:"model"`
	}
	_ = json.Unmarshal(b, &out)
	if out.Response != "hello there" || out.Model != "llama3" {
		t.Fatalf("generate result: %+v", out)
	}
}

func TestInferenceEmbedSkill(t *testing.T) {
	ollama := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/embeddings" {
			t.Errorf("unexpected path %q", r.URL.Path)
		}
		_, _ = w.Write([]byte(`{"embedding":[0.1,0.2,0.3]}`))
	}))
	defer ollama.Close()

	reg := NewRegistry()
	RegisterStandardSkills(reg, StandardSkillOptions{InferenceEndpoint: ollama.URL})
	res, err := reg.Call("inference.embed", json.RawMessage(`{"model":"nomic","input":"text"}`))
	if err != nil {
		t.Fatal(err)
	}
	b, _ := json.Marshal(res)
	var out struct {
		Embedding []float64 `json:"embedding"`
		Dims      int       `json:"dims"`
	}
	_ = json.Unmarshal(b, &out)
	if out.Dims != 3 {
		t.Fatalf("expected 3 dims, got %d (%v)", out.Dims, out.Embedding)
	}
}

func TestInferenceModelsSkill(t *testing.T) {
	ollama := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.URL.Path != "/api/tags" {
			t.Errorf("unexpected path %q", r.URL.Path)
		}
		if r.Method != http.MethodGet {
			t.Errorf("expected GET, got %s", r.Method)
		}
		_, _ = w.Write([]byte(`{"models":[{"name":"llama3:latest"},{"name":"nomic-embed-text:latest"}]}`))
	}))
	defer ollama.Close()

	reg := NewRegistry()
	RegisterStandardSkills(reg, StandardSkillOptions{InferenceEndpoint: ollama.URL})
	if !reg.Has("inference.models") {
		t.Fatal("expected inference.models registered")
	}

	res, err := reg.Call("inference.models", json.RawMessage(`{}`))
	if err != nil {
		t.Fatal(err)
	}
	b, _ := json.Marshal(res)
	var out struct {
		Models []string `json:"models"`
		Count  int      `json:"count"`
	}
	_ = json.Unmarshal(b, &out)
	if out.Count != 2 || len(out.Models) != 2 || out.Models[0] != "llama3:latest" {
		t.Fatalf("models result: %+v", out)
	}
}

func TestInferenceErrorStatus(t *testing.T) {
	ollama := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusInternalServerError)
		_, _ = w.Write([]byte("boom"))
	}))
	defer ollama.Close()

	reg := NewRegistry()
	RegisterStandardSkills(reg, StandardSkillOptions{InferenceEndpoint: ollama.URL})
	if _, err := reg.Call("inference.generate", json.RawMessage(`{"model":"m","prompt":"p"}`)); err == nil {
		t.Fatal("expected error on inference 500")
	}
}

func TestInferenceSkillsAbsentWithoutEndpoint(t *testing.T) {
	reg := NewRegistry()
	RegisterStandardSkills(reg, StandardSkillOptions{}) // no endpoint, no descriptor
	if reg.Has("inference.generate") {
		t.Fatal("inference skills must not register without an endpoint")
	}
	if !reg.Has("ping") {
		t.Fatal("ping should always register")
	}
}
