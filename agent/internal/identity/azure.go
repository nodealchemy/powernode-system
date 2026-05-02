package identity

import (
	"context"
	"encoding/base64"
	"net/http"
)

// AzureMetadataClient hits Azure's IMDS endpoint. Azure requires the
// Metadata: true header. User data is base64-encoded (when set via the
// Azure-side userData property), so we decode after fetch.
//
//	GET http://169.254.169.254/metadata/instance/compute/userData
//	    ?api-version=2021-01-01&format=text
//	Header: Metadata: true
type AzureMetadataClient struct {
	BaseURL    string
	APIVersion string
}

func (c *AzureMetadataClient) Name() string { return "azure" }

func (c *AzureMetadataClient) baseURL() string {
	if c.BaseURL != "" {
		return c.BaseURL
	}
	return "http://169.254.169.254"
}

func (c *AzureMetadataClient) apiVersion() string {
	if c.APIVersion != "" {
		return c.APIVersion
	}
	return "2021-01-01"
}

func (c *AzureMetadataClient) Detect(ctx context.Context) bool {
	url := c.baseURL() + "/metadata/instance?api-version=" + c.apiVersion() + "&format=text"
	_, err := httpDo(ctx, http.MethodGet, url, map[string]string{"Metadata": "true"})
	return err == nil
}

func (c *AzureMetadataClient) UserData(ctx context.Context) (string, error) {
	url := c.baseURL() + "/metadata/instance/compute/userData?api-version=" + c.apiVersion() + "&format=text"
	body, err := httpDo(ctx, http.MethodGet, url, map[string]string{"Metadata": "true"})
	if err != nil {
		return "", err
	}
	// Azure base64-encodes user data on the API side. Decode if it looks
	// base64-shaped; pass through if decode fails (caller might have
	// configured raw text via the older user-data field).
	decoded, derr := base64.StdEncoding.DecodeString(body)
	if derr == nil && len(decoded) > 0 {
		return string(decoded), nil
	}
	return body, nil
}
