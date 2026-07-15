package handlers

import (
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"strings"

	"github.com/nodealchemy/powernode-system/agent/internal/runtime/tasks"
)

// moduleForgePackageBuildScript is module-forge-build.sh's sibling
// entrypoint for a MATERIALIZED PACKAGE build (campaign 019f6084 inc-D —
// the critical-path piece a provisioned builder was missing: without this
// handler, ci.package_build tasks dead-end at "unknown_command" and no
// package module can ever actually build). Unlike ci.module_build, a
// package module has no modules/<slug> tree / manifest.yaml to check out —
// System::PackageClosureBuildBridge threads the whole build recipe (apt
// repo coordinates, package name, mask, pinned snapshot) through the
// Task's options instead (see System::NativeModuleBuildOrchestrator
// #package_task_options). This handler's job is purely to translate those
// options into the script's env contract; every privileged step
// (mmdebstrap, dpkg-query, carve, mkfs.erofs, push) happens inside the
// script's own per-job /opt/buildenv chroot copy — this module's host-side
// package_spec is deliberately minimal (git/rsync/jq/ca-certificates/
// uuid-runtime; see modules/module-forge/manifest.yaml) and does NOT
// include mmdebstrap/erofs-utils/oras, so there is nothing for THIS
// process to exec directly. See the script's own header for the full
// rationale and env contract.
const moduleForgePackageBuildScript = "/usr/local/bin/module-forge-package-build.sh"

// PackageBuildHandler runs a native materialized-package build (campaign
// 019f6084 inc-D) on a leased module-forge builder — the package-build
// analog of ModuleBuildHandler. Reuses that handler's Execer contract
// (module-forge-build.sh's "zero CLI args, everything via env" style —
// see Execer's doc) UNCHANGED: module-forge-package-build.sh is invoked
// exactly the same way, by name + env, no argv. Reuses fetchBuildContext
// UNCHANGED too — the SAME GET config/ci_build_context call
// ModuleBuildHandler uses, since a leased module-forge builder's ORAS
// registry push credentials are identical for either build kind (there is
// no package-specific credential to fetch). This is deliberate: ONE push
// path (push.sh, invoked from inside module-forge-package-build.sh exactly
// as module-forge-build.sh invokes it) and ONE credential-fetch path, not
// a fork.
//
// No handler timeout (matches ModuleBuildHandler — the poll loop's
// processTask has none, and mmdebstrap + a full apt closure can run
// several minutes). Crash-recovery re-dispatch simply rebuilds + re-pushes
// the same content-addressed digest, which is safe.
type PackageBuildHandler struct {
	// HTTP is the typed platform transport — see ModuleBuildHandler.HTTP.
	HTTP tasks.HTTPClient
	// Exec runs the build entrypoint. Defaults to execRunner{} when nil —
	// the SAME Execer implementation ModuleBuildHandler uses.
	Exec Execer
}

// RegisterPackageBuild binds the ci.package_build command.
func RegisterPackageBuild(r *tasks.Registry, deps tasks.Dependencies) {
	r.Register("ci.package_build", &PackageBuildHandler{HTTP: deps.Transport, Exec: execRunner{}})
}

// packageBuildOptions is the parsed, validated view of task.Options for a
// ci.package_build task — set server-side by
// System::NativeModuleBuildOrchestrator#package_task_options (never by a
// human; a package batch's plan is fully computed at dispatch time by
// System::PackageClosureBuildBridge).
type packageBuildOptions struct {
	Module         string
	Sha            string // opaque repo-sync snapshot token (batch.head_sha) — NOT a git commit; see the script's SHA doc.
	OCIRef         string
	BatchID        string // log-correlation only; the platform correlates via the Task row's own options["batch_id"], already set before this handler runs.
	PackageName    string
	Architecture   string
	RepoKind       string
	RepoURL        string
	AptSuite       string
	AptComponents  string
	RPMReleasever  string
	AptSnapshot    string
	GPGKeyArmor    string
	Mask           string
	FileSpecSource string
}

// parsePackageBuildOptions validates task.Options. Pure (no I/O) so the
// validation logic is unit-testable without an HTTP client or exec —
// mirrors parseModuleBuildOptions.
func parsePackageBuildOptions(task *tasks.Task) (packageBuildOptions, error) {
	str := func(key string) string {
		v, _ := task.Options[key].(string)
		return v
	}

	opts := packageBuildOptions{
		Module:         str("module"),
		Sha:            str("sha"),
		OCIRef:         str("oci_ref"),
		BatchID:        str("batch_id"),
		PackageName:    str("package_name"),
		Architecture:   str("architecture"),
		RepoKind:       str("package_repo_kind"),
		RepoURL:        str("package_repo_url"),
		AptSuite:       str("apt_suite"),
		AptComponents:  str("apt_components"),
		RPMReleasever:  str("rpm_releasever"),
		AptSnapshot:    str("apt_snapshot"),
		GPGKeyArmor:    str("gpg_key_armor"),
		Mask:           str("mask"),
		FileSpecSource: str("file_spec_source"),
	}

	if opts.Module == "" {
		return packageBuildOptions{}, errors.New("ci.package_build: options.module is required")
	}
	if opts.OCIRef == "" {
		return packageBuildOptions{}, errors.New("ci.package_build: options.oci_ref is required")
	}
	if opts.PackageName == "" {
		return packageBuildOptions{}, errors.New("ci.package_build: options.package_name is required")
	}
	if opts.Architecture == "" {
		return packageBuildOptions{}, errors.New("ci.package_build: options.architecture is required")
	}
	if opts.RepoURL == "" {
		return packageBuildOptions{}, errors.New("ci.package_build: options.package_repo_url is required")
	}

	switch opts.RepoKind {
	case "":
		return packageBuildOptions{}, errors.New("ci.package_build: options.package_repo_kind is required")
	case "apt":
		if opts.AptSuite == "" {
			return packageBuildOptions{}, errors.New("ci.package_build: options.apt_suite is required for apt repos")
		}
		if opts.AptComponents == "" {
			return packageBuildOptions{}, errors.New("ci.package_build: options.apt_components is required for apt repos")
		}
	case "rpm", "dnf":
		if opts.RPMReleasever == "" {
			return packageBuildOptions{}, errors.New("ci.package_build: options.rpm_releasever is required for rpm/dnf repos")
		}
	default:
		return packageBuildOptions{}, fmt.Errorf("ci.package_build: unknown package_repo_kind %q", opts.RepoKind)
	}

	return opts, nil
}

// packageBuildResult is module-forge-package-build.sh's emitted result
// JSON (the last non-empty stdout line) — the platform-module four-key
// contract (see moduleBuildResult) PLUS file_spec: the full dpkg -L owned-
// file list, unmasked (see the script's RESULT JSON doc for why file_spec
// stays unmasked while the shipped erofs blob is carved by MASK).
type packageBuildResult struct {
	OCIDigest    string      `json:"oci_digest"`
	FsverityRoot string      `json:"fsverity_root"`
	Size         json.Number `json:"size"`
	BuiltFromSHA string      `json:"built_from_sha"`
	FileSpec     []string    `json:"file_spec"`
}

func (h *PackageBuildHandler) Execute(ctx context.Context, task *tasks.Task) (tasks.Result, error) {
	opts, err := parsePackageBuildOptions(task)
	if err != nil {
		return nil, err
	}

	// rpm/dnf bootstrap tooling has no precedent anywhere in this
	// pipeline yet (every existing stage script — stage1-rootfs.sh,
	// module-forge-build.sh — is mmdebstrap/apt-only): fail clean here,
	// BEFORE any HTTP/exec call, rather than let module-forge-package-
	// build.sh (apt-only) fail deep into a build it was never going to
	// complete. PARKED — see that script's file header.
	if opts.RepoKind != "apt" {
		return nil, fmt.Errorf("ci.package_build %s: repo kind %q not yet supported (only apt) — parked pending rpm/dnf bootstrap tooling", opts.Module, opts.RepoKind)
	}

	if h.HTTP == nil {
		return nil, errors.New("ci.package_build: no platform transport")
	}

	// SAME ci_build_context fetch ModuleBuildHandler uses — a leased
	// module-forge builder's ORAS push credentials, regardless of build
	// kind. See this type's doc for why this is not forked.
	bctx, err := fetchBuildContext(h.HTTP, opts.Module)
	if err != nil {
		return nil, fmt.Errorf("ci.package_build %s: fetch build context: %w", opts.Module, err)
	}

	env := buildPackageEnv(opts, bctx)

	execer := h.Exec
	if execer == nil {
		execer = execRunner{}
	}
	stdout, stderr, runErr := execer.Run(ctx, moduleForgePackageBuildScript, env)
	tail := logTail(stdout, stderr)
	if runErr != nil {
		return nil, fmt.Errorf("ci.package_build %s: %w (log_tail: %s)", opts.Module, runErr, tail)
	}

	parsed, err := parsePackageBuildResult(stdout)
	if err != nil {
		return nil, fmt.Errorf("ci.package_build %s: %w (log_tail: %s)", opts.Module, err, tail)
	}

	result := tasks.Result{
		"oci_digest":     parsed.OCIDigest,
		"fsverity_root":  parsed.FsverityRoot,
		"built_from_sha": parsed.BuiltFromSHA,
		"file_spec":      parsed.FileSpec,
		"log_tail":       tail,
	}
	if n, convErr := parsed.Size.Int64(); convErr == nil {
		result["size"] = n
	} else if parsed.Size != "" {
		result["size"] = parsed.Size.String()
	}
	return result, nil
}

// buildPackageEnv assembles the env slice module-forge-package-build.sh
// expects, matching its ENV CONTRACT exactly: required keys always
// present; optional keys (BATCH_ID/APT_SNAPSHOT/GPG_KEY_ARMOR/MASK/
// RPM_RELEASEVER/FILE_SPEC_SOURCE) only when the platform supplied a
// non-empty value — mirrors buildEnv's "omit rather than send empty"
// posture for optional module_build vars.
func buildPackageEnv(opts packageBuildOptions, bctx *ciBuildContext) []string {
	env := []string{
		"MODULE=" + opts.Module,
		"SHA=" + opts.Sha,
		"OCI_REF=" + opts.OCIRef,
		"PACKAGE_NAME=" + opts.PackageName,
		"ARCHITECTURE=" + opts.Architecture,
		"REPO_KIND=" + opts.RepoKind,
		"REPO_URL=" + opts.RepoURL,
		"APT_SUITE=" + opts.AptSuite,
		"APT_COMPONENTS=" + opts.AptComponents,
		"ORAS_REGISTRY=" + bctx.OrasRegistry,
		"ORAS_REGISTRY_USER=" + bctx.OrasUser,
		"ORAS_REGISTRY_PASSWORD=" + bctx.OrasPassword,
	}
	if opts.BatchID != "" {
		env = append(env, "BATCH_ID="+opts.BatchID)
	}
	if opts.RPMReleasever != "" {
		env = append(env, "RPM_RELEASEVER="+opts.RPMReleasever)
	}
	if opts.AptSnapshot != "" {
		env = append(env, "APT_SNAPSHOT="+opts.AptSnapshot)
	}
	if opts.GPGKeyArmor != "" {
		env = append(env, "GPG_KEY_ARMOR="+opts.GPGKeyArmor)
	}
	if opts.Mask != "" {
		env = append(env, "MASK="+opts.Mask)
	}
	if opts.FileSpecSource != "" {
		env = append(env, "FILE_SPEC_SOURCE="+opts.FileSpecSource)
	}
	return env
}

// parsePackageBuildResult scans stdout from the LAST line backward for the
// first non-empty line and decodes it as the result JSON — identical
// technique to parseBuildResult (module-forge-package-build.sh follows the
// same "stdout carries exactly the RESULT JSON, every diagnostic line goes
// to stderr" contract as module-forge-build.sh).
func parsePackageBuildResult(stdout []byte) (*packageBuildResult, error) {
	lines := strings.Split(strings.TrimRight(string(stdout), "\n"), "\n")
	for i := len(lines) - 1; i >= 0; i-- {
		line := strings.TrimSpace(lines[i])
		if line == "" {
			continue
		}
		dec := json.NewDecoder(strings.NewReader(line))
		dec.UseNumber()
		var r packageBuildResult
		if err := dec.Decode(&r); err != nil {
			return nil, fmt.Errorf("last non-empty stdout line is not valid result JSON: %w", err)
		}
		return &r, nil
	}
	return nil, errors.New("module-forge-package-build.sh produced no output")
}
