package identity

import (
	"context"
	"net/http"
	"time"
)

// AwsMetadataClient implements IMDS v2 (token-based, default since 2019).
// IMDS v1 (no token) is intentionally not supported — too easy to SSRF
// from a compromised application on the same instance.
//
// Flow:
//  1. PUT http://169.254.169.254/latest/api/token
//     header X-aws-ec2-metadata-token-ttl-seconds: 21600 → token
//  2. GET http://169.254.169.254/latest/user-data
//     header X-aws-ec2-metadata-token: <token> → user data
type AwsMetadataClient struct {
	BaseURL string // override for tests; defaults to http://169.254.169.254
	TokenTTLSeconds int
}

func (c *AwsMetadataClient) Name() string { return "aws" }

func (c *AwsMetadataClient) baseURL() string {
	if c.BaseURL != "" {
		return c.BaseURL
	}
	return "http://169.254.169.254"
}

func (c *AwsMetadataClient) tokenTTL() int {
	if c.TokenTTLSeconds > 0 {
		return c.TokenTTLSeconds
	}
	return 60 // 60s is plenty for one user-data fetch
}

func (c *AwsMetadataClient) Detect(ctx context.Context) bool {
	_, err := c.fetchToken(ctx)
	return err == nil
}

func (c *AwsMetadataClient) UserData(ctx context.Context) (string, error) {
	tok, err := c.fetchToken(ctx)
	if err != nil {
		return "", err
	}
	return httpDo(ctx, http.MethodGet, c.baseURL()+"/latest/user-data",
		map[string]string{"X-aws-ec2-metadata-token": tok})
}

func (c *AwsMetadataClient) fetchToken(ctx context.Context) (string, error) {
	// IMDS v2 requires PUT (with TTL header) to obtain a token.
	client := &http.Client{Timeout: 1500 * time.Millisecond}
	req, err := http.NewRequestWithContext(
		ctx, http.MethodPut, c.baseURL()+"/latest/api/token", http.NoBody)
	if err != nil {
		return "", err
	}
	req.Header.Set("X-aws-ec2-metadata-token-ttl-seconds", itoa(c.tokenTTL()))
	resp, err := client.Do(req)
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return "", errBadStatus
	}
	buf := make([]byte, 0, 256)
	tmp := make([]byte, 256)
	for {
		n, err := resp.Body.Read(tmp)
		if n > 0 {
			buf = append(buf, tmp[:n]...)
			if len(buf) > 64*1024 {
				break
			}
		}
		if err != nil {
			break
		}
	}
	return string(buf), nil
}

// itoa is a tiny strconv.Itoa replacement that avoids importing strconv
// solely for this single call (keeps the cloud package's import surface
// tight; matters in the static-binary size budget).
func itoa(n int) string {
	if n == 0 {
		return "0"
	}
	neg := n < 0
	if neg {
		n = -n
	}
	var buf [20]byte
	i := len(buf)
	for n > 0 {
		i--
		buf[i] = byte('0' + n%10)
		n /= 10
	}
	if neg {
		i--
		buf[i] = '-'
	}
	return string(buf[i:])
}
