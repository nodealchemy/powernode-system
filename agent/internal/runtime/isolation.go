package runtime

import (
	"encoding/json"
	"io"
	"net"
	"net/http"
)

// a2aAdvertiseAddrs combines the node's reachable overlay address with the A2A
// listen port into a single advertised address for peer discovery. Returns nil
// when the overlay isn't up yet (the announce still carries the offered skills;
// the reachable address fills in on a later tick once SDWAN populates it).
func a2aAdvertiseAddrs(overlay, listenAddr string) []string {
	if overlay == "" {
		return nil
	}
	_, port, err := net.SplitHostPort(listenAddr)
	if err != nil || port == "" {
		return nil
	}
	return []string{net.JoinHostPort(overlay, port)}
}

// runtimesFetcher is satisfied by *transport.Client (GetJSON).
type runtimesFetcher interface {
	GetJSON(path string) (*http.Response, error)
}

// isolationRuntimesPath is the node_api endpoint advertising the isolation
// runtimes this node must provision (substrate L0).
const isolationRuntimesPath = "/api/v1/system/node_api/isolation/runtimes"

// isolationConfig is the platform's per-node isolation contract: the runtimes
// to provision plus (F2-01) the OCI runtime the daemon should default to so
// the instance's recorded tier is actually enforced at container-create.
type isolationConfig struct {
	Runtimes       []string
	DefaultRuntime string
}

// fetchIsolationConfig asks the platform which isolation runtimes this node
// should provision on its Docker daemon (e.g. ["gvisor"]) and which runtime
// is the daemon default. Best-effort: any error yields the zero value (the
// node simply provisions nothing extra and keeps the runc default).
func fetchIsolationConfig(f runtimesFetcher) isolationConfig {
	resp, err := f.GetJSON(isolationRuntimesPath)
	if err != nil {
		return isolationConfig{}
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return isolationConfig{}
	}
	raw, _ := io.ReadAll(resp.Body)

	var body struct {
		Data struct {
			Runtimes       []string `json:"runtimes"`
			DefaultRuntime string   `json:"default_runtime"`
		} `json:"data"`
	}
	if err := json.Unmarshal(raw, &body); err != nil {
		return isolationConfig{}
	}
	return isolationConfig{Runtimes: body.Data.Runtimes, DefaultRuntime: body.Data.DefaultRuntime}
}
