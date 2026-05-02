package identity

import (
	"context"
	"net/http"
)

// DigitalOceanMetadataClient hits DigitalOcean's plain-text metadata
// service (no auth header required, no token exchange).
//
//	GET http://169.254.169.254/metadata/v1/user-data
//
// DigitalOcean droplets serve user-data verbatim — easiest of the four
// cloud paths to integrate.
type DigitalOceanMetadataClient struct {
	BaseURL string
}

func (c *DigitalOceanMetadataClient) Name() string { return "digitalocean" }

func (c *DigitalOceanMetadataClient) baseURL() string {
	if c.BaseURL != "" {
		return c.BaseURL
	}
	return "http://169.254.169.254"
}

func (c *DigitalOceanMetadataClient) Detect(ctx context.Context) bool {
	// DO publishes /metadata/v1/id (the droplet ID); cheap probe.
	_, err := httpDo(ctx, http.MethodGet, c.baseURL()+"/metadata/v1/id", nil)
	return err == nil
}

func (c *DigitalOceanMetadataClient) UserData(ctx context.Context) (string, error) {
	return httpDo(ctx, http.MethodGet, c.baseURL()+"/metadata/v1/user-data", nil)
}
