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

// fetchIsolationRuntimes asks the platform which isolation runtimes this node
// should provision on its Docker daemon (e.g. ["gvisor"]). Best-effort: any
// error yields an empty slice (the node simply provisions nothing extra).
func fetchIsolationRuntimes(f runtimesFetcher) []string {
	resp, err := f.GetJSON(isolationRuntimesPath)
	if err != nil {
		return nil
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return nil
	}
	raw, _ := io.ReadAll(resp.Body)

	var body struct {
		Data struct {
			Runtimes []string `json:"runtimes"`
		} `json:"data"`
	}
	if err := json.Unmarshal(raw, &body); err != nil {
		return nil
	}
	return body.Data.Runtimes
}
