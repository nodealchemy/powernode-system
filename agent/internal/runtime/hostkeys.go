package runtime

import (
	"bytes"
	"encoding/base64"
	"encoding/binary"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
)

// IMP-190834701b0a — the node's SSH host PUBLIC keys, reported on every
// heartbeat so the platform can verify it is talking to THIS host when it
// connects over SSH. Until now every platform SSH connection skipped host
// verification, and VMID/IP reuse means a different host can answer at a
// recorded address. The platform stores the keys on the NodeInstance and
// writes them into a per-connection known_hosts file.
//
// PRIVATE KEYS ARE NEVER OPENED. The reader globs only ssh_host_*_key.pub. It
// refuses anything that is not a regular file: a symlinked .pub could point
// at the private key beside it, so the open uses O_NOFOLLOW and re-checks the
// opened descriptor. It caps the bytes read, and it refuses content shaped
// like a private key. An error never echoes file content, only the path and
// the reason.

// DefaultSSHHostKeyDir is where sshd keeps its host keys.
const DefaultSSHHostKeyDir = "/etc/ssh"

const (
	// hostKeyMaxFileBytes bounds a .pub file. A 16384-bit RSA public key,
	// the largest OpenSSH generates, is about 2.8 KB.
	hostKeyMaxFileBytes = 8 * 1024
	// hostKeyMaxKeyChars bounds the base64 key field, matching the platform
	// (System::SshHostKeys::MAX_KEY_CHARS).
	hostKeyMaxKeyChars = 4096
	// hostKeyMaxKeys bounds how many keys ride one heartbeat.
	hostKeyMaxKeys = 8
)

// hostKeyTypes is the accepted algorithm set, in preference order (ed25519
// first). It must match System::SshHostKeys::ALLOWED_TYPES on the platform.
var hostKeyTypes = []string{
	"ssh-ed25519",
	"ecdsa-sha2-nistp256",
	"ecdsa-sha2-nistp384",
	"ecdsa-sha2-nistp521",
	"sk-ssh-ed25519@openssh.com",
	"sk-ecdsa-sha2-nistp256@openssh.com",
	"ssh-rsa",
}

var errPrivateKeyShaped = errors.New("content is shaped like a private key; refusing to read it as a public key")

// HostKey is one SSH host public key as it rides the heartbeat: the algorithm
// name and the base64 key blob. The comment is dropped, because it is usually
// root@<hostname> and the platform has no use for it.
type HostKey struct {
	Type string `json:"type"`
	Key  string `json:"key"`
}

// hostKeyOpen is the test seam for "which files did the reader open". It opens
// read-only and never follows a final-component symlink.
var hostKeyOpen = func(path string) (*os.File, error) {
	return os.OpenFile(path, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
}

// ReadHostKeys returns the valid host public keys under dir, ed25519 first,
// de-duplicated and capped. It also returns one error per refused file, each
// naming only the path and the reason. The key list is nil when nothing
// valid is found, so the heartbeat omits the block (NOT MEASURED) rather than
// sending an empty list.
func ReadHostKeys(dir string) ([]HostKey, []error) {
	matches, err := filepath.Glob(filepath.Join(dir, "ssh_host_*_key.pub"))
	if err != nil {
		return nil, []error{fmt.Errorf("ssh host keys: glob %s: %w", dir, err)}
	}
	sort.Strings(matches)

	var keys []HostKey
	var errs []error
	seen := map[string]bool{}
	for _, path := range matches {
		key, err := readHostKeyFile(path)
		if err != nil {
			errs = append(errs, fmt.Errorf("ssh host key %s: %w", path, err))
			continue
		}
		if seen[key.Key] {
			continue
		}
		seen[key.Key] = true
		keys = append(keys, key)
	}
	sort.SliceStable(keys, func(i, j int) bool {
		return hostKeyTypeRank(keys[i].Type) < hostKeyTypeRank(keys[j].Type)
	})
	if len(keys) > hostKeyMaxKeys {
		keys = keys[:hostKeyMaxKeys]
	}
	return keys, errs
}

func readHostKeyFile(path string) (HostKey, error) {
	// Belt and braces around the glob: only a *.pub name is ever opened.
	if !strings.HasSuffix(path, ".pub") {
		return HostKey{}, errors.New("not a .pub file")
	}
	info, err := os.Lstat(path)
	if err != nil {
		return HostKey{}, err
	}
	if !info.Mode().IsRegular() {
		return HostKey{}, errors.New("not a regular file (a symlink is never followed)")
	}
	if info.Size() > hostKeyMaxFileBytes {
		return HostKey{}, fmt.Errorf("file exceeds %d bytes", hostKeyMaxFileBytes)
	}

	f, err := hostKeyOpen(path)
	if err != nil {
		return HostKey{}, err
	}
	defer f.Close()
	// Re-check the descriptor actually opened. The path could have been
	// swapped between the Lstat and the open.
	if fi, err := f.Stat(); err != nil || !fi.Mode().IsRegular() {
		return HostKey{}, errors.New("not a regular file")
	}
	content, err := io.ReadAll(io.LimitReader(f, hostKeyMaxFileBytes+1))
	if err != nil {
		return HostKey{}, err
	}
	if len(content) > hostKeyMaxFileBytes {
		return HostKey{}, fmt.Errorf("file exceeds %d bytes", hostKeyMaxFileBytes)
	}
	return parseHostKeyLine(content)
}

// parseHostKeyLine validates one OpenSSH public key line, "<type> <base64>
// [comment]", with an optional trailing newline. It refuses a second line,
// any control character, an unknown type, bad base64, an oversized key, and a
// blob whose embedded algorithm name disagrees with the declared type.
func parseHostKeyLine(content []byte) (HostKey, error) {
	if bytes.Contains(content, []byte("PRIVATE KEY")) || bytes.Contains(content, []byte("-----BEGIN")) {
		return HostKey{}, errPrivateKeyShaped
	}
	line := strings.TrimSuffix(string(content), "\n")
	for _, r := range line {
		if r < 0x20 || r == 0x7f {
			return HostKey{}, errors.New("not a single line of printable text")
		}
	}
	fields := strings.Fields(line)
	if len(fields) < 2 {
		return HostKey{}, errors.New("want \"<type> <base64-key> [comment]\"")
	}
	keyType, key := fields[0], fields[1]
	if hostKeyTypeRank(keyType) == len(hostKeyTypes) {
		return HostKey{}, fmt.Errorf("unsupported key type %q", keyType)
	}
	if len(key) > hostKeyMaxKeyChars {
		return HostKey{}, fmt.Errorf("key exceeds %d characters", hostKeyMaxKeyChars)
	}
	blob, err := base64.StdEncoding.Strict().DecodeString(key)
	if err != nil {
		return HostKey{}, errors.New("key is not valid base64")
	}
	if embeddedKeyType(blob) != keyType {
		return HostKey{}, errors.New("key blob does not match its declared type")
	}
	return HostKey{Type: keyType, Key: key}, nil
}

// embeddedKeyType reads the algorithm name an OpenSSH wire-format key blob
// opens with (uint32 length + string).
func embeddedKeyType(blob []byte) string {
	if len(blob) < 4 {
		return ""
	}
	n := binary.BigEndian.Uint32(blob[:4])
	if n == 0 || n > 64 || uint32(len(blob)-4) < n {
		return ""
	}
	return string(blob[4 : 4+n])
}

func hostKeyTypeRank(keyType string) int {
	for i, t := range hostKeyTypes {
		if t == keyType {
			return i
		}
	}
	return len(hostKeyTypes)
}
