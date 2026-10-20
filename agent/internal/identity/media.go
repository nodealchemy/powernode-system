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

	Settle func(ctx context.Context, timeout time.Duration)
	// Mount mounts src at target. opts is always the fixed
	// "ro,nosuid,nodev,noexec"; data is the fs-specific mount data ("noload" for ext4).
	Mount func(ctx context.Context, src, target, fstype, opts, data string) error
	// Unmount unmounts target; detach selects MNT_DETACH.
	Unmount func(target string, detach bool) error
	// SetReadOnly makes the block device itself read-only (BLKROSET) before it is
	// mounted and returns a restore func that puts back the previous state
	// (BLKROGET) -- called only after a clean, non-detached unmount.
	SetReadOnly func(devPath string) (restore func() error, err error)
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
	dev  string
	tier int
	id   *Identity
	raw  []byte
}

func (s *MediaScanStrategy) Discover(ctx context.Context) (*Identity, error) {
	c := s.cfg()
	if c.Enrolled() {
		return nil, ErrNotFound // never let media veto or re-pin an enrolled node
	}
	ctx, cancel := context.WithTimeout(ctx, c.Budget)
	defer cancel()

	c.Settle(ctx, c.SettleTimeout)
	// Wait the FULL EnumWait (inside the budget) before deciding: a USB device
	// that shows up early says nothing about a fixed disk still enumerating.
	cands, err := c.enumerate()
	for deadline := time.Now().Add(c.EnumWait); err == nil && c.EnumWait > 0 && ctx.Err() == nil; {
		left := time.Until(deadline)
		if left <= 0 {
			break
		}
		select {
		case <-ctx.Done():
		case <-time.After(min(c.EnumPoll, left)):
		}
		cands, err = c.enumerate()
	}
	if err != nil {
		// Without the mount table the root/boot/data disks cannot be told apart
		// from spare media: fail closed.
		c.Logf("mount table unreadable, media scan aborted")
		return nil, ErrNotFound
	}
	if len(cands) == 0 {
		return nil, ErrNotFound
	}

	// Fixed media is probed first and USB last (enumerate orders them), so a
	// stick cannot starve the budget away from the real seed disk. If any
	// candidate went unprobed or was abandoned, a removable document is never
	// selected (the missing candidate might have contradicted it), and neither
	// is anything while a fixed candidate is missing.
	var docs []mediaDoc
	missingFixed, missingAny := false, false
	for _, cand := range cands {
		c.Logf("probing %s", cand.name)
		if ctx.Err() != nil {
			c.Logf("scan budget exhausted before probing %s", cand.name)
			missingAny = true
			if cand.tier > 1 {
				missingFixed = true
			}
			continue
		}
		doc, incomplete, err := c.probe(ctx, cand)
		if err != nil {
			if errors.Is(err, errRemovableRefused) {
				// A bad stick must not be able to block enrolment (physical
				// DoS): fall through to the next source. Fixed media stays terminal.
				return nil, ErrNotFound
			}
			return nil, err
		}
		if doc != nil {
			docs = append(docs, *doc)
		}
		if incomplete || (doc == nil && ctx.Err() != nil) {
			missingAny = true // abandoned, or did not finish cleanly after the sniff
			if cand.tier > 1 {
				missingFixed = true
			}
		}
	}
	if len(docs) == 0 {
		return nil, ErrNotFound
	}

	chosen, err := pickMediaDoc(docs)
	if err != nil {
		c.Logf("%v", err)
		return nil, err
	}
	if missingFixed || (missingAny && chosen.tier == 1) {
		c.Logf("incomplete scan, not using the file from %s", chosen.dev)
		return nil, ErrNotFound
	}
	c.Logf("using provisioning file from %s", chosen.dev)
	if err := c.stage(chosen.raw); err != nil {
		c.Logf("could not stage identity from %s", chosen.dev)
	}
	id := *chosen.id
	id.CloudProvider = mediaProvisioner
	return &id, nil
}

// pickMediaDoc requires every candidate document to be byte-identical (trimmed),
// whatever the tier or source: any difference at all, in any field, is
// ambiguous and REFUSES. Classification then only matters for probe order and
// for what an incomplete scan may use. Identical copies on fixed and removable
// media resolve to the fixed one.
func pickMediaDoc(docs []mediaDoc) (*mediaDoc, error) {
	for _, d := range docs[1:] {
		if !bytes.Equal(bytes.TrimSpace(d.raw), bytes.TrimSpace(docs[0].raw)) {
			var devs []string
			for _, x := range docs {
				devs = append(devs, x.dev)
			}
			return nil, refuse("provisioning files on %s differ", strings.Join(devs, ", "))
		}
	}
	for i := range docs {
		if docs[i].tier > 1 {
			return &docs[i], nil
		}
	}
	return &docs[0], nil
}

type probeResult struct {
	doc        *mediaDoc
	incomplete bool
	err        error
}

// errRemovableRefused marks a refused document on removable media: the scan
// falls through (ErrNotFound) instead of terminating the Resolver.
var errRemovableRefused = errors.New("document on removable media refused")

// probe runs the whole per-device sequence in ONE goroutine and abandons it at
// ctx.Done. The goroutine owns its cleanup: whenever the kernel returns it
// unmounts (MNT_DETACH if the budget is gone), so a late mount never lingers.
// incomplete reports a candidate that passed the sniff but did not finish
// cleanly (BLKROSET or mount failure, budget, abandonment).
func (c *MediaScanStrategy) probe(ctx context.Context, cand mediaCandidate) (*mediaDoc, bool, error) {
	done := make(chan probeResult, 1)
	go func() {
		doc, inc, err := c.probeDevice(ctx, cand)
		done <- probeResult{doc, inc, err}
	}()
	select {
	case r := <-done:
		return r.doc, r.incomplete, r.err
	case <-ctx.Done():
		c.Logf("%s: probe abandoned at the scan budget", cand.name)
		return nil, true, nil
	}
}

func (c *MediaScanStrategy) probeDevice(ctx context.Context, cand mediaCandidate) (*mediaDoc, bool, error) {
	name := cand.name
	src := filepath.Join(c.DevRoot, name)

	fs := c.Sniff(src)
	if fs == "" {
		return nil, false, nil // no supported filesystem signature: never mount
	}
	restore, err := c.SetReadOnly(src)
	if err != nil {
		c.Logf("%s: cannot make the device read-only, not mounting", name)
		return nil, true, nil
	}
	cleanlyDone := false // set only after a clean, non-detached unmount (or no mount)
	defer func() {
		if cleanlyDone && restore != nil && ctx.Err() == nil {
			_ = restore()
		}
	}()
	if err := os.MkdirAll(c.MountRoot, 0o700); err != nil {
		c.Logf("%s: no mount root", name)
		cleanlyDone = true // nothing mounted: restore like the other early exits
		return nil, true, nil
	}
	target, err := os.MkdirTemp(c.MountRoot, "m-")
	if err != nil {
		cleanlyDone = true
		return nil, true, nil
	}
	defer os.Remove(target)

	data := ""
	if fs == "ext4" {
		data = "noload" // do not replay the journal: a replay would write
	}
	if err := c.Mount(ctx, src, target, fs, mediaMountOpts, data); err != nil {
		c.Logf("%s: not mountable", name)
		cleanlyDone = true // nothing was mounted
		return nil, true, nil
	}
	defer func() { cleanlyDone = c.unmount(ctx, target) }()
	if ctx.Err() != nil {
		return nil, true, nil // mounted late: only the deferred detach remains
	}

	// refused turns a refusal into a terminal one for fixed media, and into a
	// fall-through for removable media (a stick must not be able to block
	// enrolment of an unenrolled node).
	refused := func(format string, a ...any) (*mediaDoc, bool, error) {
		c.Logf("%s: provisioning file refused", name)
		if cand.tier == 1 {
			return nil, true, errRemovableRefused
		}
		return nil, true, refuse(format, a...)
	}
	raw, found, rerr := c.Read(target)
	if rerr != nil {
		return refused("provisioning file on %s is not acceptable (too large)", name)
	}
	if !found {
		return nil, false, nil
	}
	if ctx.Err() != nil {
		return nil, true, nil
	}
	id, perr := ParseProvisionDocument(raw)
	if perr != nil {
		// Parser text may echo document field names; keep only the device.
		return refused("provisioning file on %s is not a valid powernode-provision v1 document", name)
	}
	return &mediaDoc{dev: name, tier: cand.tier, id: id, raw: raw}, false, nil
}

// unmount tries a normal unmount and falls back to MNT_DETACH on error or when
// the budget is already gone.
func (c *MediaScanStrategy) unmount(ctx context.Context, target string) (clean bool) {
	if ctx.Err() == nil && c.Unmount(target, false) == nil {
		return true
	}
	_ = c.Unmount(target, true)
	return false
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

// externalBus reports whether the disk is attached through an external bus,
// whatever its removable flag, label or type claim: a usbN or firewire path
// segment, a sysfs ancestor whose "removable" attribute says "removable"
// (Thunderbolt / external PCI ports), or a native SD card (mmcblk with
// device/type SD).
func (c *MediaScanStrategy) externalBus(disk string) bool {
	if strings.HasPrefix(disk, "mmcblk") {
		if b, err := os.ReadFile(filepath.Join(c.SysBlock, disk, "device", "type")); err == nil && strings.TrimSpace(string(b)) == "SD" {
			return true
		}
	}
	real, err := filepath.EvalSymlinks(filepath.Join(c.SysBlock, disk))
	if err != nil {
		return false
	}
	segs := strings.Split(real, "/")
	for _, seg := range segs {
		if isNumbered(seg, "usb") || isNumbered(seg, "fw") || seg == "firewire" {
			return true
		}
	}
	// Walk the ancestors up to the sysfs "devices" root.
	devices := -1
	for i, seg := range segs {
		if seg == "devices" {
			devices = i
		}
	}
	if devices >= 0 {
		for dir := filepath.Dir(real); len(strings.Split(dir, "/")) > devices+1; dir = filepath.Dir(dir) {
			if b, err := os.ReadFile(filepath.Join(dir, "removable")); err == nil && strings.TrimSpace(string(b)) == "removable" {
				return true
			}
		}
	}
	return false
}

// isNumbered matches prefix followed by digits only (usb1, fw0).
func isNumbered(seg, prefix string) bool {
	return len(seg) > len(prefix) && strings.HasPrefix(seg, prefix) && strings.Trim(seg[len(prefix):], "0123456789") == ""
}

// enumerate returns the candidates in probe order: fixed media first (cidata
// labelled, then optical, then the remaining disks), removable/USB media LAST.
// "Removable" is decided by the bus (USB) or, for non-optical disks, the
// removable flag -- never by a label or the device type, which a stick controls.
// An optical drive is fixed unless it hangs off USB (internal CD-ROMs report
// removable=1). It fails closed (error) when the mount table is unreadable.
func (c *MediaScanStrategy) enumerate() ([]mediaCandidate, error) {
	entries, err := os.ReadDir(c.SysBlock)
	if err != nil {
		return nil, nil
	}
	busy, err := c.busyDisks(entries)
	if err != nil {
		return nil, err
	}
	bootDev := c.labelTarget("BOOT")

	cidata := map[string]bool{}
	for _, l := range []string{"cidata", "CIDATA"} {
		if d := c.labelTarget(l); d != "" {
			cidata[d] = true
		}
	}
	var removable, fixedCidata, fixedSR, fixedOther []mediaCandidate
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
		isSR := strings.HasPrefix(disk, "sr")
		isRemovable := c.externalBus(disk) || (!isSR && c.readFlag(disk, "removable"))
		for _, dev := range devs {
			if dev == bootDev || !c.devExists(dev) {
				continue
			}
			switch {
			case isRemovable:
				removable = append(removable, mediaCandidate{dev, 1})
			case cidata[dev]:
				fixedCidata = append(fixedCidata, mediaCandidate{dev, 2})
			case isSR:
				fixedSR = append(fixedSR, mediaCandidate{dev, 2})
			default:
				fixedOther = append(fixedOther, mediaCandidate{dev, 3})
			}
		}
	}
	sort.Slice(fixedCidata, func(i, j int) bool { return fixedCidata[i].name < fixedCidata[j].name })
	out := append(append(append(fixedCidata, fixedSR...), fixedOther...), removable...)
	return out, nil
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
func (c *MediaScanStrategy) busyDisks(disks []os.DirEntry) (map[string]bool, error) {
	busy := map[string]bool{}
	raw, err := os.ReadFile(c.MountInfo)
	if err != nil {
		return nil, err
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
	return busy, nil
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
