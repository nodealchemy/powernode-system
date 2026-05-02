package identity

import (
	"context"
	"encoding/base64"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"
)

func TestParseUserData_KernelStyle(t *testing.T) {
	id, err := parseUserData("powernode.instance_uuid=u-1 powernode.bootstrap_token=t-2 powernode.platform_url=https://p.example.com")
	if err != nil {
		t.Fatalf("parseUserData: %v", err)
	}
	if id.InstanceUUID != "u-1" || id.BootstrapToken != "t-2" || id.PlatformURL != "https://p.example.com" {
		t.Errorf("unexpected: %+v", id)
	}
}

func TestParseUserData_LegacyShellStyle(t *testing.T) {
	body := "ID=legacy-uuid\nKEY=legacy-token\nSERVER=https://p.legacy.example.com\n"
	id, err := parseUserData(body)
	if err != nil {
		t.Fatalf("parseUserData: %v", err)
	}
	if id.InstanceUUID != "legacy-uuid" {
		t.Errorf("InstanceUUID = %q", id.InstanceUUID)
	}
}

func TestParseUserData_JSON(t *testing.T) {
	body := `{"instance_uuid":"json-uuid","bootstrap_token":"json-tok","platform_url":"https://p.json.example.com"}`
	id, err := parseUserData(body)
	if err != nil {
		t.Fatalf("parseUserData: %v", err)
	}
	if id.InstanceUUID != "json-uuid" {
		t.Errorf("InstanceUUID = %q", id.InstanceUUID)
	}
}

func TestParseUserData_Empty(t *testing.T) {
	if _, err := parseUserData("   "); err == nil {
		t.Error("expected error on empty user data")
	}
}

func TestAwsMetadataClient(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodPut && r.URL.Path == "/latest/api/token":
			if r.Header.Get("X-aws-ec2-metadata-token-ttl-seconds") == "" {
				w.WriteHeader(http.StatusBadRequest)
				return
			}
			_, _ = w.Write([]byte("imds-token-xyz"))
		case r.Method == http.MethodGet && r.URL.Path == "/latest/user-data":
			if r.Header.Get("X-aws-ec2-metadata-token") != "imds-token-xyz" {
				w.WriteHeader(http.StatusUnauthorized)
				return
			}
			_, _ = w.Write([]byte("powernode.instance_uuid=aws-uuid powernode.platform_url=https://p.aws.example.com"))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer srv.Close()

	c := &AwsMetadataClient{BaseURL: srv.URL}
	if !c.Detect(context.Background()) {
		t.Fatal("expected Detect=true against fake AWS server")
	}
	body, err := c.UserData(context.Background())
	if err != nil {
		t.Fatalf("UserData: %v", err)
	}
	if !strings.Contains(body, "aws-uuid") {
		t.Errorf("UserData = %q", body)
	}
}

func TestGcpMetadataClient(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Metadata-Flavor") != "Google" {
			w.WriteHeader(http.StatusForbidden)
			return
		}
		switch r.URL.Path {
		case "/computeMetadata/v1/":
			_, _ = w.Write([]byte("v1/"))
		case "/computeMetadata/v1/instance/attributes/user-data":
			_, _ = w.Write([]byte(`{"instance_uuid":"gcp-uuid","platform_url":"https://p.gcp.example.com"}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer srv.Close()

	c := &GcpMetadataClient{BaseURL: srv.URL}
	if !c.Detect(context.Background()) {
		t.Fatal("expected Detect=true against fake GCP server")
	}
	body, _ := c.UserData(context.Background())
	if !strings.Contains(body, "gcp-uuid") {
		t.Errorf("UserData = %q", body)
	}
}

func TestAzureMetadataClient_DecodesBase64(t *testing.T) {
	plaintext := "powernode.instance_uuid=azure-uuid"
	encoded := base64.StdEncoding.EncodeToString([]byte(plaintext))
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Metadata") != "true" {
			w.WriteHeader(http.StatusBadRequest)
			return
		}
		switch {
		case strings.HasPrefix(r.URL.Path, "/metadata/instance/compute/userData"):
			_, _ = w.Write([]byte(encoded))
		case strings.HasPrefix(r.URL.Path, "/metadata/instance"):
			_, _ = w.Write([]byte(`{"compute":{"vmId":"azure-vm-id"}}`))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer srv.Close()

	c := &AzureMetadataClient{BaseURL: srv.URL}
	if !c.Detect(context.Background()) {
		t.Fatal("expected Detect=true against fake Azure server")
	}
	body, err := c.UserData(context.Background())
	if err != nil {
		t.Fatalf("UserData: %v", err)
	}
	if body != plaintext {
		t.Errorf("Azure UserData should be base64-decoded; got %q", body)
	}
}

func TestDigitalOceanMetadataClient(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch r.URL.Path {
		case "/metadata/v1/id":
			_, _ = w.Write([]byte("droplet-12345"))
		case "/metadata/v1/user-data":
			_, _ = w.Write([]byte("ID=do-uuid\nSERVER=https://p.do.example.com\n"))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer srv.Close()

	c := &DigitalOceanMetadataClient{BaseURL: srv.URL}
	if !c.Detect(context.Background()) {
		t.Fatal("expected Detect=true against fake DO server")
	}
	body, _ := c.UserData(context.Background())
	if !strings.Contains(body, "do-uuid") {
		t.Errorf("UserData = %q", body)
	}
}

func TestCloudStrategy_NotFoundOnFailedDetect(t *testing.T) {
	// AWS client pointing at a server that 404s the token endpoint
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusNotFound)
	}))
	defer srv.Close()

	s := &CloudStrategy{Client: &AwsMetadataClient{BaseURL: srv.URL}}
	_, err := s.Discover(context.Background())
	if err != ErrNotFound {
		t.Errorf("expected ErrNotFound, got %v", err)
	}
}

func TestCloudStrategy_DiscoversIdentity(t *testing.T) {
	srv := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		switch {
		case r.Method == http.MethodPut && r.URL.Path == "/latest/api/token":
			_, _ = w.Write([]byte("tok"))
		case r.URL.Path == "/latest/user-data":
			_, _ = w.Write([]byte("powernode.instance_uuid=cs-uuid"))
		default:
			w.WriteHeader(http.StatusNotFound)
		}
	}))
	defer srv.Close()

	s := &CloudStrategy{Client: &AwsMetadataClient{BaseURL: srv.URL}}
	id, err := s.Discover(context.Background())
	if err != nil {
		t.Fatalf("Discover: %v", err)
	}
	if id.InstanceUUID != "cs-uuid" {
		t.Errorf("InstanceUUID = %q", id.InstanceUUID)
	}
	if id.CloudProvider != "aws" {
		t.Errorf("CloudProvider = %q (expected aws)", id.CloudProvider)
	}
}
