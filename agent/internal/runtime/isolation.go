package runtime

import (
	"encoding/json"
	"io"
	"net/http"
)

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
