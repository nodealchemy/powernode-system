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
//
// Hardening (security review of D7):
//   - the scan is skipped entirely once the node is enrolled (usable PKI) and
//     the Resolver never runs it after a pinless hit, so media can neither veto
//     nor re-pin a node that already has an identity;
//   - before mounting, the block device itself is made read-only (BLKROSET) so
//     even a journal replay cannot write to a disk; ext4 also gets "noload";
//   - ALL per-device I/O (BLKROSET, signature sniff, mount, file read, unmount)
//     runs in one goroutine that the scan abandons at the budget. The goroutine
//     cleans up after itself (MNT_DETACH) when the kernel finally returns, so a
//     wedged device cannot hold up boot beyond the budget nor stay mounted;
//   - valid documents that disagree on server or ca_fingerprint are never
//     arbitrated by issued_at or a known id: non-removable sources (cidata,
//     optical, internal disks) win over removable USB, and a remaining
//     disagreement is refused. This is trust-on-first-use of whatever
//     physical media the operator attached, bounded by that rule.
//
// The ~10 s Budget covers udev settle, the enumeration wait and the probe of
// every candidate as seen by the caller of Discover. It does NOT cover work the
// kernel has already started and cannot interrupt (a mount or read stuck in
// D-state): that is abandoned, finishes in the background and is detached.

import (
	"bytes"
	"context"
	"crypto/tls"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"os"
	"os/exec"
	"path/filepath"
	"sort"
	"strings"
	"time"
)

const (
	mediaMountOpts    = "ro,nosuid,nodev,noexec"
	mediaProvisioner  = "media-scan"
	mediaFileRoot     = "powernode-provision.cfg"
	mediaFileFallback = "powernode/provision.cfg"
)

// enrolledPKIDirs mirror enroll.PKIDirInitramfs / enroll.PKIDirFHS (the enroll
// package imports this one, so the paths are repeated here).
var enrolledPKIDirs = []string{"/persist/var/lib/powernode/pki", "/var/lib/powernode/pki"}

// pkiEnrolled reports whether any dir holds a usable node.crt + node.key pair.
func pkiEnrolled(dirs []string) bool {
	for _, d := range dirs {
		if _, err := tls.LoadX509KeyPair(filepath.Join(d, "node.crt"), filepath.Join(d, "node.key")); err == nil {
			return true
		}
	}
	return false
}

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
	// Mount mounts src at target. opts is always the fixed
	// "ro,nosuid,nodev,noexec"; data is the fs-specific mount data ("noload" for ext4).
	Mount func(ctx context.Context, src, target, fstype, opts, data string) error
	// Unmount unmounts target; detach selects MNT_DETACH.
	Unmount func(target string, detach bool) error
	// SetReadOnly makes the block device itself read-only (BLKROSET) before it is mounted.
	SetReadOnly func(devPath string) error
	// Sniff returns the filesystem type ("vfat","exfat","iso9660","ext4") from the
	// on-disk signature, or "" when it is none of them.
	Sniff func(devPath string) string
	// Read reads the provisioning file below a mounted tree; (nil,false,nil) = none.
	Read func(mount string) ([]byte, bool, error)
	// Enrolled reports a usable enrolled PKI; the scan is skipped when true.
	Enrolled func() bool
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
	if c.SetReadOnly == nil {
		c.SetReadOnly = sysSetReadOnly
	}
	if c.Sniff == nil {
		c.Sniff = sniffDevice
	}
	if c.Read == nil {
		c.Read = readMediaFile
	}
	if c.Enrolled == nil {
		c.Enrolled = func() bool { return pkiEnrolled(enrolledPKIDirs) }
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
	tier   int
	id     *Identity
	issued time.Time
	raw    []byte
}

func (s *MediaScanStrategy) Discover(ctx context.Context) (*Identity, error) {
	c := s.cfg()
	if c.Enrolled() {
		return nil, ErrNotFound // never let media veto or re-pin an enrolled node
	}
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
		doc, err := c.probe(ctx, cand)
		if err != nil {
			return nil, err
		}
		if doc != nil {
			docs = append(docs, *doc)
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

func conflicting(docs []mediaDoc) bool {
	for _, d := range docs[1:] {
		if d.id.PlatformURL != docs[0].id.PlatformURL || d.id.CAFingerprint != docs[0].id.CAFingerprint {
			return true
		}
	}
	return false
}

// pickMediaDoc applies the tie-break: known id, then newest issued_at, then
// refuse. Documents with byte-identical content are one candidate.
func pickMediaDoc(docs []mediaDoc, known map[string]bool) (*mediaDoc, error) {
	if conflicting(docs) {
		// Disagreement is never arbitrated by issued_at or a known id: a
		// non-removable source wins over removable USB; what is still in
		// conflict after that is refused.
		var fixed []mediaDoc
		for _, d := range docs {
			if d.tier > 1 {
				fixed = append(fixed, d)
			}
		}
		if len(fixed) == 0 || len(fixed) == len(docs) || conflicting(fixed) {
			var devs []string
			for _, d := range docs {
				devs = append(devs, d.dev)
			}
			return nil, refuse("provisioning files on %s disagree on server or CA pin", strings.Join(devs, ", "))
		}
		docs = fixed
	}
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

type probeResult struct {
	doc *mediaDoc
	err error
}

// probe runs the whole per-device sequence in ONE goroutine and abandons it at
// ctx.Done. The goroutine owns its cleanup: whenever the kernel returns it
// unmounts (MNT_DETACH if the budget is gone), so a late mount never lingers.
func (c *MediaScanStrategy) probe(ctx context.Context, cand mediaCandidate) (*mediaDoc, error) {
	done := make(chan probeResult, 1)
	go func() {
		doc, err := c.probeDevice(ctx, cand)
		done <- probeResult{doc, err}
	}()
	select {
	case r := <-done:
		return r.doc, r.err
	case <-ctx.Done():
		c.Logf("%s: probe abandoned at the scan budget", cand.name)
		return nil, nil
	}
}

func (c *MediaScanStrategy) probeDevice(ctx context.Context, cand mediaCandidate) (*mediaDoc, error) {
	name := cand.name
	src := filepath.Join(c.DevRoot, name)

	fs := c.Sniff(src)
	if fs == "" {
		return nil, nil // no supported filesystem signature: never mount
	}
	if err := c.SetReadOnly(src); err != nil {
		c.Logf("%s: cannot make the device read-only, not mounting", name)
		return nil, nil
	}
	if err := os.MkdirAll(c.MountRoot, 0o700); err != nil {
		c.Logf("%s: no mount root", name)
		return nil, nil
	}
	target, err := os.MkdirTemp(c.MountRoot, "m-")
	if err != nil {
		return nil, nil
	}
	defer os.Remove(target)

	data := ""
	if fs == "ext4" {
		data = "noload" // do not replay the journal: a replay would write
	}
	if err := c.Mount(ctx, src, target, fs, mediaMountOpts, data); err != nil {
		c.Logf("%s: not mountable", name)
		return nil, nil
	}
	defer c.unmount(ctx, target)
	if ctx.Err() != nil {
		return nil, nil // mounted late: only the deferred detach remains
	}

	raw, found, rerr := c.Read(target)
	if rerr != nil {
		c.Logf("%s: provisioning file refused", name)
		return nil, refuse("provisioning file on %s is not acceptable (too large)", name)
	}
	if !found || ctx.Err() != nil {
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
	return &mediaDoc{dev: name, tier: cand.tier, id: id, issued: issued, raw: raw}, nil
}

// unmount tries a normal unmount and falls back to MNT_DETACH on error or when
// the budget is already gone.
func (c *MediaScanStrategy) unmount(ctx context.Context, target string) {
	if ctx.Err() == nil && c.Unmount(target, false) == nil {
		return
	}
	_ = c.Unmount(target, true)
}

// readCapped reads at most provisionMaxDocBytes and refuses anything larger,
// never trusting a stat size and never reading more than cap+1 bytes.
func readCapped(r io.Reader) ([]byte, error) {
	raw, err := io.ReadAll(io.LimitReader(r, provisionMaxDocBytes+1))
	if err != nil {
		return nil, err
	}
	if len(raw) > provisionMaxDocBytes {
		return nil, errors.New("provisioning file too large")
	}
	return raw, nil
}

// readMediaFile opens the document by walking each path component with
// O_NOFOLLOW below the mount (symlinks on untrusted media would otherwise
// resolve against the host), requires a regular file and refuses anything
// over the parser's size cap, whitespace padding included.
func readMediaFile(mount string) ([]byte, bool, error) {
	for _, rel := range []string{mediaFileRoot, mediaFileFallback} {
		f, err := openBeneath(mount, rel)
		if err != nil {
			continue
		}
		st, err := f.Stat()
		if err != nil || !st.Mode().IsRegular() {
			f.Close()
			continue
		}
		if st.Size() > provisionMaxDocBytes {
			f.Close()
			return nil, false, errors.New("provisioning file too large")
		}
		raw, err := readCapped(f)
		f.Close()
		if err != nil {
			if strings.Contains(err.Error(), "too large") {
				return nil, false, err
			}
			continue
		}
		return bytes.TrimSpace(raw), true, nil
	}
	return nil, false, nil
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
// Sources are resolved under DevRoot; "/dev/root" and anything that does not
// resolve fall back to the mount's major:minor via <sys>/dev/block.
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
	sysDevBlock := filepath.Join(filepath.Dir(c.SysBlock), "dev", "block")
	for _, line := range strings.Split(string(raw), "\n") {
		before, after, ok := strings.Cut(line, " - ")
		if !ok {
			continue
		}
		f := strings.Fields(after)
		if len(f) < 2 || !strings.HasPrefix(f[1], "/dev/") {
			continue
		}
		name := ""
		if f[1] != "/dev/root" {
			if r, err := filepath.EvalSymlinks(filepath.Join(c.DevRoot, strings.TrimPrefix(f[1], "/dev/"))); err == nil {
				name = filepath.Base(r)
			}
		}
		if name == "" {
			if bf := strings.Fields(before); len(bf) >= 3 {
				if r, err := filepath.EvalSymlinks(filepath.Join(sysDevBlock, bf[2])); err == nil {
					name = filepath.Base(r)
				}
			}
		}
		if name == "" {
			name = filepath.Base(f[1])
		}
		mark(name, 0)
	}
	return busy
}

// sniffFSType identifies vfat, exfat, iso9660 and ext2/3/4 (all mounted with
// the ext4 driver) from superblock magics in a device header; "" otherwise.
// iso9660 needs the first 0x8006 bytes; shorter headers still match the others.
func sniffFSType(h []byte) string {
	at := func(off int, s string) bool { return len(h) >= off+len(s) && string(h[off:off+len(s)]) == s }
	if at(0x8001, "CD001") {
		return "iso9660"
	}
	if len(h) >= 512 && h[510] == 0x55 && h[511] == 0xAA {
		if at(3, "EXFAT   ") {
			return "exfat"
		}
		if at(82, "FAT32   ") || at(54, "FAT16   ") || at(54, "FAT12   ") {
			return "vfat"
		}
	}
	if len(h) >= 1082 && h[1080] == 0x53 && h[1081] == 0xEF {
		return "ext4"
	}
	return ""
}

// sniffDevice reads the header of a block device and classifies it.
func sniffDevice(path string) string {
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()
	buf := make([]byte, 0x8006)
	n, _ := io.ReadFull(f, buf)
	return sniffFSType(buf[:n])
}
