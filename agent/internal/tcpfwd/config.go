package tcpfwd

import (
	"encoding/json"
	"fmt"
	"os"
)

// Forward is one (listen, backend) pair the forwarder manages.
// SubscriptionID correlates connection audit logs back to the
// ServiceSubscription row that produced this forward rule.
type Forward struct {
	Listen         string `json:"listen"`          // local bind address, typically "127.0.0.1:<port>"
	Backend        string `json:"backend"`         // remote address: "host:port" or "[v6]:port"
	Protocol       string `json:"protocol"`        // v1: only "tcp" supported
	SubscriptionID string `json:"subscription_id"` // UUID of the originating subscription
}

// Config is the complete set of forwards loaded from disk.
type Config struct {
	Forwards []Forward `json:"forwards"`
}

// Validate enforces the v1 constraints on every Forward. Returns
// the first error encountered with the index baked in so the
// operator can find the bad entry quickly.
func (c *Config) Validate() error {
	for i, f := range c.Forwards {
		if f.Listen == "" {
			return fmt.Errorf("forwards[%d]: listen must be set", i)
		}
		if f.Backend == "" {
			return fmt.Errorf("forwards[%d]: backend must be set", i)
		}
		if f.Protocol != "tcp" {
			return fmt.Errorf("forwards[%d]: only protocol=\"tcp\" supported in v1, got %q",
				i, f.Protocol)
		}
	}
	return nil
}

// LoadConfig reads a JSON config file from disk and validates it.
// Returns the parsed config on success, or an error if the file is
// missing, malformed, or fails validation.
func LoadConfig(path string) (*Config, error) {
	data, err := os.ReadFile(path)
	if err != nil {
		return nil, fmt.Errorf("read config %q: %w", path, err)
	}
	var cfg Config
	if err := json.Unmarshal(data, &cfg); err != nil {
		return nil, fmt.Errorf("parse config %q: %w", path, err)
	}
	if err := cfg.Validate(); err != nil {
		return nil, fmt.Errorf("invalid config: %w", err)
	}
	return &cfg, nil
}
