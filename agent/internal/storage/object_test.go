package storage

import (
	"strings"
	"testing"
)

func planTask(recipeType, source, credID string) *MountTask {
	return &MountTask{
		Recipe:     MountRecipe{Type: recipeType, Source: source, Options: []string{"_netdev", "allow_other"}},
		Credential: CredentialRef{ID: credID},
	}
}

func optsContain(opts []string, v string) bool {
	for _, x := range opts {
		if x == v {
			return true
		}
	}
	return false
}

func TestObjectMountPlan_S3fs(t *testing.T) {
	payload := &CredentialPayload{AccessKeyID: "AKIA", SecretAccessKey: "secret"}
	plan, err := objectMountPlan(payload, planTask("s3fs", "mybucket/prefix", "cred-1"))
	if err != nil {
		t.Fatalf("unexpected err: %v", err)
	}
	if plan.fsType != "fuse.s3fs" {
		t.Errorf("fsType = %q, want fuse.s3fs", plan.fsType)
	}
	if plan.what != "mybucket/prefix" {
		t.Errorf("what = %q, want mybucket/prefix", plan.what)
	}
	if len(plan.files) != 1 || plan.files[0].mode != 0o600 {
		t.Fatalf("files = %+v", plan.files)
	}
	if plan.files[0].contents != "AKIA:secret\n" {
		t.Errorf("passwd contents = %q", plan.files[0].contents)
	}
	if !strings.HasSuffix(plan.files[0].path, "cred-1.passwd-s3fs") {
		t.Errorf("passwd path = %q", plan.files[0].path)
	}
	if !optsContain(plan.options, "passwd_file="+plan.files[0].path) {
		t.Errorf("options = %v, want passwd_file=", plan.options)
	}
}

func TestObjectMountPlan_S3fsMissingCreds(t *testing.T) {
	if _, err := objectMountPlan(&CredentialPayload{}, planTask("s3fs", "b", "c")); err == nil {
		t.Fatal("expected error for missing access/secret keys")
	}
}

func TestObjectMountPlan_Gcsfuse(t *testing.T) {
	payload := &CredentialPayload{CredentialsJSON: `{"type":"service_account"}`}
	plan, err := objectMountPlan(payload, planTask("gcsfuse", "mybucket", "cred-2"))
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if plan.fsType != "gcsfuse" || plan.what != "mybucket" {
		t.Errorf("plan = %+v", plan)
	}
	if plan.files[0].contents != `{"type":"service_account"}` {
		t.Errorf("key contents = %q", plan.files[0].contents)
	}
	if !strings.HasPrefix(plan.options[0], "key_file=") {
		t.Errorf("options = %v, want key_file=", plan.options)
	}
}

func TestObjectMountPlan_Rclone(t *testing.T) {
	payload := &CredentialPayload{AccountName: "acct", AccountKey: "key=="}
	plan, err := objectMountPlan(payload, planTask("rclone", "acct/container1", "cred-3"))
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if plan.fsType != "rclone" {
		t.Errorf("fsType = %q, want rclone", plan.fsType)
	}
	if plan.what != "powernode:container1" {
		t.Errorf("what = %q, want powernode:container1", plan.what)
	}
	c := plan.files[0].contents
	if !strings.Contains(c, "type = azureblob") || !strings.Contains(c, "account = acct") || !strings.Contains(c, "key = key==") {
		t.Errorf("rclone.conf = %q", c)
	}
	if !strings.HasPrefix(plan.options[0], "config=") {
		t.Errorf("options = %v, want config=", plan.options)
	}
}

func TestObjectMountPlan_Unsupported(t *testing.T) {
	if _, err := objectMountPlan(&CredentialPayload{}, planTask("davfs", "x", "c")); err == nil {
		t.Fatal("expected error for unsupported recipe type")
	}
}

// Guards the wire→struct contract: the credential endpoint exposes the
// object-storage material at the data level (see s3_storage#issue_node_credential).
func TestFetchCredential_ParsesObjectFields(t *testing.T) {
	body := `{"success":true,"data":{"kind":"sts_token","access_key_id":"AKIA","secret_access_key":"sk","session_token":"tok"}}`
	payload, _, err := FetchCredential(stubGetter{body: body}, "/cred")
	if err != nil {
		t.Fatalf("err: %v", err)
	}
	if payload.AccessKeyID != "AKIA" || payload.SecretAccessKey != "sk" || payload.SessionToken != "tok" {
		t.Errorf("payload = %+v", payload)
	}
}
