package identity

// MediaScanStrategy finds a powernode-provision v1 document on attached
// drives: USB sticks, NoCloud/cidata seed disks and CD-ROMs, extra disks.
//
// Why a Go strategy in the agent rather than an initramfs unit (the shape of
// powernode-cidata-payload.sh): the decision is not "copy the first file". It
// needs the strict v1 parser (D5), the already-known instance ids from
// cmdline/fw-cfg/BOOT identity.cfg for the tie-break, issued_at comparison and
// a terminal refusal that the Resolver understands. Doing that in POSIX sh
// would duplicate the parser (the one place a laxer copy must not exist) and
// could not be unit-tested against injected sysfs/dev/mount seams. The agent
// also runs after udev has coldplugged, which the unit has to wait for.
//
// Probe order: (1) removable non-optical block devices, (2) LABEL=cidata /
// CIDATA devices and then /dev/sr*, (3) the remaining non-root disks. A disk
// that backs any current mount (the root disk, /boot, /persist, ...) and the
// image's own LABEL=BOOT partition are never probed. Every mount is
// "ro,nosuid,nodev,noexec"; nothing on the media is executed; symlinks on the
// media are never followed; the medium is unmounted straight after reading.
//
// Selection among valid documents: a known instance id wins; else the newest
// issued_at; else (still ambiguous) refuse with ErrProvisionRefused. A
// document that fails the strict parse is a TERMINAL refusal too. Logging is
// restricted to device names; contents and the key are never logged.

import (
	"bytes"
	"context"
	"encoding/json"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"syscall"
	"time"
)

const (
	mediaMountOpts    = "ro,nosuid,nodev,noexec"
	mediaProvisioner  = "media-scan"
	mediaFileRoot     = "powernode-provision.cfg"
	mediaFileFallback = "powernode/provision.cfg"
)

var mediaFSTypes = []string{"vfat", "exfat", "iso9660", "ext4"}

// MediaScanStrategy: see the file comment. Zero values give production
// defaults; every field is an injection seam for tests.
type MediaScanStrategy struct {
	SysBlock  string // default /sys/block
	DevRoot   string // default /dev
	MountInfo string // default /proc/self/mountinfo
	MountRoot string // parent of the temporary mount points, default /run/powernode/media
	StagePath string // default /run/powernode/identity.cfg

	Budget        time.Duration // total scan budget, default 10s
	SettleTimeout time.Duration // udev settle bound, default 3s
	EnumWait      time.Duration // extra wait for a first device to enumerate, default 2s (<0: none)
	EnumPoll      time.Duration // poll interval for EnumWait, default 250ms

	// KnownIDs returns instance ids already known from other sources. Default:
	// kernel cmdline, fw-cfg and /boot/identity.cfg.
	KnownIDs func(ctx context.Context) []string
	Settle   func(ctx context.Context, timeout time.Duration)
	Mount    func(ctx context.Context, src, target, fstype, opts string) error
	Unmount  func(target string) error
	// Logf receives device-name-only messages. Default: stderr.
	Logf func(format string, args ...any)
}

func (s *MediaScanStrategy) Name() string { return "media-scan" }

func (s *MediaScanStrategy) cfg() MediaScanStrategy {
	c := *s
	def := func(p *string, v string) {
		if *p == "" {
			*p = v
		}
	}
	def(&c.SysBlock, "/sys/block")
	def(&c.DevRoot, "/dev")
	def(&c.MountInfo, "/proc/self/mountinfo")
	def(&c.MountRoot, "/run/powernode/media")
	def(&c.StagePath, "/run/powernode/identity.cfg")
	if c.Budget <= 0 {
		c.Budget = 10 * time.Second
	}
	if c.SettleTimeout <= 0 {
		c.SettleTimeout = 3 * time.Second
	}
	if c.EnumPoll <= 0 {
		c.EnumPoll = 250 * time.Millisecond
	}
	if c.EnumWait == 0 {
		c.EnumWait = 2 * time.Second // negative disables the wait
	}
	if c.KnownIDs == nil {
		c.KnownIDs = defaultKnownIDs
	}
	if c.Settle == nil {
		c.Settle = udevSettle
	}
	if c.Mount == nil {
		c.Mount = sysMount
	}
	if c.Unmount == nil {
		c.Unmount = sysUnmount
	}
	if c.Logf == nil {
		c.Logf = func(f string, a ...any) { fmt.Fprintf(os.Stderr, "[MediaScan] "+f+"\n", a...) }
	}
	return c
}

func defaultKnownIDs(ctx context.Context) []string {
	var ids []string
	for _, st := range []Strategy{&CmdlineStrategy{}, &FwCfgStrategy{}, &BootIdentityStrategy{}} {
		if id, err := st.Discover(ctx); err == nil && id != nil && id.InstanceUUID != "" {
			ids = append(ids, id.InstanceUUID)
		}
	}
	return ids
}

func udevSettle(ctx context.Context, timeout time.Duration) {
	bin, err := exec.LookPath("udevadm")
	if err != nil {
		return
	}
	cctx, cancel := context.WithTimeout(ctx, timeout+time.Second)
	defer cancel()
	_ = exec.CommandContext(cctx, bin, "settle", fmt.Sprintf("--timeout=%d", int(timeout.Seconds()))).Run()
}

type mediaCandidate struct {
	name string // device name, e.g. sdb1
	tier int
}

type mediaDoc struct {
	dev    string
	id     *Identity
	issued time.Time
	raw    []byte
}

func (s *MediaScanStrategy) Discover(ctx context.Context) (*Identity, error) {
	c := s.cfg()
	ctx, cancel := context.WithTimeout(ctx, c.Budget)
	defer cancel()

	c.Settle(ctx, c.SettleTimeout)
	cands := c.enumerate()
	for waited := time.Duration(0); len(cands) == 0 && waited < c.EnumWait && ctx.Err() == nil; waited += c.EnumPoll {
		time.Sleep(c.EnumPoll)
		cands = c.enumerate()
	}
	if len(cands) == 0 {
		return nil, ErrNotFound
	}

	known := map[string]bool{}
	for _, k := range c.KnownIDs(ctx) {
		known[strings.ToLower(k)] = true
	}

	var docs []mediaDoc
	for _, cand := range cands {
		if ctx.Err() != nil {
			c.Logf("scan budget exhausted before probing %s", cand.name)
			break
		}
		doc, err := c.probe(ctx, cand.name)
		if err != nil {
			return nil, err
		}
		if doc == nil {
			continue
		}
		docs = append(docs, *doc)
		if known[strings.ToLower(doc.id.InstanceUUID)] {
			break // best possible match; do not touch further drives
		}
	}
	if len(docs) == 0 {
		return nil, ErrNotFound
	}

	chosen, err := pickMediaDoc(docs, known)
	if err != nil {
		c.Logf("%v", err)
		return nil, err
	}
	c.Logf("using provisioning file from %s", chosen.dev)
	if err := c.stage(chosen.raw); err != nil {
		c.Logf("could not stage identity from %s", chosen.dev)
	}
	id := *chosen.id
	id.CloudProvider = mediaProvisioner
	return &id, nil
}

// pickMediaDoc applies the tie-break: known id, then newest issued_at, then
// refuse. Documents with byte-identical content are one candidate.
func pickMediaDoc(docs []mediaDoc, known map[string]bool) (*mediaDoc, error) {
	pool := docs
	var matched []mediaDoc
	for _, d := range docs {
		if known[strings.ToLower(d.id.InstanceUUID)] {
			matched = append(matched, d)
		}
	}
	if len(matched) > 0 {
		pool = matched
	}
	newest := pool[0].issued
	for _, d := range pool {
		if d.issued.After(newest) {
			newest = d.issued
		}
	}
	var top []mediaDoc
	for _, d := range pool {
		if d.issued.Equal(newest) {
			top = append(top, d)
		}
	}
	for _, d := range top[1:] {
		if !bytes.Equal(bytes.TrimSpace(d.raw), bytes.TrimSpace(top[0].raw)) {
			var devs []string
			for _, t := range top {
				devs = append(devs, t.dev)
			}
			return nil, refuse("ambiguous provisioning files on %s", strings.Join(devs, ", "))
		}
	}
	return &top[0], nil
}

// probe mounts one device, reads its provisioning file (if any), unmounts.
// (nil, nil) means "nothing usable here"; a non-nil error is terminal.
func (c *MediaScanStrategy) probe(ctx context.Context, name string) (*mediaDoc, error) {
	if err := os.MkdirAll(c.MountRoot, 0o700); err != nil {
		c.Logf("%s: no mount root", name)
		return nil, nil
	}
	target, err := os.MkdirTemp(c.MountRoot, "m-")
	if err != nil {
		return nil, nil
	}
	defer os.Remove(target)

	src := filepath.Join(c.DevRoot, name)
	mounted := false
	for _, fs := range mediaFSTypes {
		if ctx.Err() != nil {
			return nil, nil
		}
		if c.mountBounded(ctx, src, target, fs) {
			mounted = true
			break
		}
	}
	if !mounted {
		c.Logf("%s: not mountable", name)
		return nil, nil
	}
	defer func() { _ = c.Unmount(target) }()

	raw, found := readMediaFile(target)
	if !found {
		return nil, nil
	}
	id, perr := ParseProvisionDocument(raw)
	if perr != nil {
		// Parser text may echo document field names; keep only the device.
		c.Logf("%s: provisioning file refused", name)
		return nil, refuse("provisioning file on %s is not a valid powernode-provision v1 document", name)
	}
	var meta struct {
		IssuedAt string `json:"issued_at"`
	}
	_ = json.Unmarshal(raw, &meta)
	issued, _ := time.Parse(time.RFC3339, meta.IssuedAt) // validated by the parser
	return &mediaDoc{dev: name, id: id, issued: issued, raw: raw}, nil
}

// mountBounded runs the mount so a wedged device cannot outlive the budget; a
// mount that completes after the budget is unmounted again.
func (c *MediaScanStrategy) mountBounded(ctx context.Context, src, target, fs string) bool {
	done := make(chan error, 1)
	go func() { done <- c.Mount(ctx, src, target, fs, mediaMountOpts) }()
	select {
	case err := <-done:
		return err == nil
	case <-ctx.Done():
		go func() {
			if err := <-done; err == nil {
				_ = c.Unmount(target)
			}
		}()
		return false
	}
}

// readMediaFile returns the file's bytes. Symlinks (file or the powernode
// directory) are never followed: a link on untrusted media would otherwise
// resolve against the host filesystem.
func readMediaFile(mount string) ([]byte, bool) {
	for _, rel := range []string{mediaFileRoot, mediaFileFallback} {
		p := filepath.Join(mount, rel)
		if dir := filepath.Dir(p); dir != mount {
			if st, err := os.Lstat(dir); err != nil || !st.IsDir() {
				continue
			}
		}
		st, err := os.Lstat(p)
		if err != nil || !st.Mode().IsRegular() {
			continue
		}
		f, err := os.OpenFile(p, os.O_RDONLY|syscall.O_NOFOLLOW|syscall.O_NONBLOCK, 0)
		if err != nil {
			continue
		}
		raw, err := io.ReadAll(io.LimitReader(f, provisionMaxDocBytes+1))
		f.Close()
		if err != nil {
			continue
		}
		return bytes.TrimSpace(raw), true
	}
	return nil, false
}

// stage writes the validated document 0600 so an agent restart finds it via
// the early /run/powernode/identity.cfg source.
func (c *MediaScanStrategy) stage(raw []byte) error {
	if err := stageGuard(c.StagePath); err != nil {
		return err
	}
	if err := os.MkdirAll(filepath.Dir(c.StagePath), 0o700); err != nil {
		return err
	}
	tmp, err := os.CreateTemp(filepath.Dir(c.StagePath), ".identity-")
	if err != nil {
		return err
	}
	defer os.Remove(tmp.Name())
	if err := tmp.Chmod(0o600); err != nil {
		tmp.Close()
		return err
	}
	if _, err := tmp.Write(append(append([]byte{}, raw...), '\n')); err != nil {
		tmp.Close()
		return err
	}
	if err := tmp.Close(); err != nil {
		return err
	}
	return os.Rename(tmp.Name(), c.StagePath)
}

// ---- enumeration ----

func (c *MediaScanStrategy) enumerate() []mediaCandidate {
	entries, err := os.ReadDir(c.SysBlock)
	if err != nil {
		return nil
	}
	busy := c.busyDisks(entries)
	bootDev := c.labelTarget("BOOT")

	var t1, t2cidata, t2sr, t3 []mediaCandidate
	cidata := map[string]bool{}
	for _, l := range []string{"cidata", "CIDATA"} {
		if d := c.labelTarget(l); d != "" {
			cidata[d] = true
		}
	}
	var cidataOrder []string
	var names []string
	for _, e := range entries {
		names = append(names, e.Name())
	}
	sort.Strings(names)
	for _, disk := range names {
		if skipDisk(disk) || busy[disk] {
			continue
		}
		parts := c.partitions(disk)
		devs := parts
		if len(devs) == 0 {
			devs = []string{disk}
		}
		removable := c.readFlag(disk, "removable")
		for _, dev := range devs {
			if dev == bootDev || !c.devExists(dev) {
				continue
			}
			switch {
			case strings.HasPrefix(disk, "sr"):
				t2sr = append(t2sr, mediaCandidate{dev, 2})
			case cidata[dev]:
				cidataOrder = append(cidataOrder, dev)
			case removable:
				t1 = append(t1, mediaCandidate{dev, 1})
			default:
				t3 = append(t3, mediaCandidate{dev, 3})
			}
		}
	}
	sort.Strings(cidataOrder)
	for _, d := range cidataOrder {
		t2cidata = append(t2cidata, mediaCandidate{d, 2})
	}
	out := append(append(append(t1, t2cidata...), t2sr...), t3...)
	return out
}

func skipDisk(name string) bool {
	for _, p := range []string{"loop", "ram", "zram", "dm-", "md", "nbd", "fd"} {
		if strings.HasPrefix(name, p) {
			return true
		}
	}
	return false
}

func (c *MediaScanStrategy) devExists(dev string) bool {
	_, err := os.Stat(filepath.Join(c.DevRoot, dev))
	return err == nil
}

func (c *MediaScanStrategy) readFlag(disk, flag string) bool {
	b, err := os.ReadFile(filepath.Join(c.SysBlock, disk, flag))
	return err == nil && strings.TrimSpace(string(b)) == "1"
}

func (c *MediaScanStrategy) partitions(disk string) []string {
	entries, err := os.ReadDir(filepath.Join(c.SysBlock, disk))
	if err != nil {
		return nil
	}
	var parts []string
	for _, e := range entries {
		if _, err := os.Stat(filepath.Join(c.SysBlock, disk, e.Name(), "partition")); err == nil {
			parts = append(parts, e.Name())
		}
	}
	sort.Strings(parts)
	return parts
}

// labelTarget resolves /dev/disk/by-label/<label> to a device name.
func (c *MediaScanStrategy) labelTarget(label string) string {
	p, err := filepath.EvalSymlinks(filepath.Join(c.DevRoot, "disk", "by-label", label))
	if err != nil {
		return ""
	}
	return filepath.Base(p)
}

// busyDisks is every disk that currently backs a mount from /dev (root, /boot,
// /persist, ...), following device-mapper slaves. These are never probed.
func (c *MediaScanStrategy) busyDisks(disks []os.DirEntry) map[string]bool {
	busy := map[string]bool{}
	raw, err := os.ReadFile(c.MountInfo)
	if err != nil {
		return busy
	}
	var mark func(name string, depth int)
	mark = func(name string, depth int) {
		if depth > 4 {
			return
		}
		for _, d := range disks {
			disk := d.Name()
			if disk == name {
				busy[disk] = true
			} else if _, err := os.Stat(filepath.Join(c.SysBlock, disk, name, "partition")); err == nil {
				busy[disk] = true
			}
		}
		if slaves, err := os.ReadDir(filepath.Join(c.SysBlock, name, "slaves")); err == nil {
			for _, sl := range slaves {
				mark(sl.Name(), depth+1)
			}
		}
	}
	for _, line := range strings.Split(string(raw), "\n") {
		_, after, ok := strings.Cut(line, " - ")
		if !ok {
			continue
		}
		f := strings.Fields(after)
		if len(f) < 2 || !strings.HasPrefix(f[1], "/dev/") {
			continue
		}
		src := f[1]
		if r, err := filepath.EvalSymlinks(src); err == nil {
			src = r
		}
		mark(filepath.Base(src), 0)
	}
	return busy
}
