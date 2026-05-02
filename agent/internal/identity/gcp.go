package identity

import (
	"context"
	"net/http"
)

// GcpMetadataClient hits Google Cloud's metadata service. GCP requires the
// Metadata-Flavor: Google header; without it, the service returns 403.
//
// User data is read from instance attributes:
//
//	GET http://169.254.169.254/computeMetadata/v1/instance/attributes/user-data
//	Header: Metadata-Flavor: Google
type GcpMetadataClient struct {
	BaseURL string
}

func (c *GcpMetadataClient) Name() string { return "gcp" }

func (c *GcpMetadataClient) baseURL() string {
	if c.BaseURL != "" {
		return c.BaseURL
	}
	return "http://169.254.169.254"
}

func (c *GcpMetadataClient) Detect(ctx context.Context) bool {
	_, err := httpDo(ctx, http.MethodGet, c.baseURL()+"/computeMetadata/v1/",
		map[string]string{"Metadata-Flavor": "Google"})
	return err == nil
}

func (c *GcpMetadataClient) UserData(ctx context.Context) (string, error) {
	return httpDo(ctx, http.MethodGet,
		c.baseURL()+"/computeMetadata/v1/instance/attributes/user-data",
		map[string]string{"Metadata-Flavor": "Google"})
}
