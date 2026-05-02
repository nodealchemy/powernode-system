// Package main is the entry point for ipn-agent, the on-node runtime for
// Powernode-managed instances. Replaces the legacy bash `ipn` script
// (~/Drive/Projects/powernode-bootstrap/scripts/ipn).
//
// Subcommand surface mirrors the legacy ipn flags + adds boot/service for
// the initramfs handoff path:
//
//	ipn-agent boot          run during initramfs init-bottom; sets up union mount + switch_root
//	ipn-agent service       long-lived loop: heartbeat + task lease + cert rotation
//	ipn-agent enroll        token → mTLS cert exchange (used by boot but also operator-callable)
//	ipn-agent verify        verifies cosign signature + fs-verity hash on a local module
//	ipn-agent introspect    prints the agent's view of itself (identity, modules, certs)
//	ipn-agent attach <id>   mount a module into the union (legacy `ipn -a`)
//	ipn-agent detach <id>   unmount a module (legacy `ipn -d`)
//	ipn-agent update        pull current assignments from /node_api/modules
//	ipn-agent commit <id>   capture live delta + push as new module version
//	ipn-agent status        print current attach/detach state
//	ipn-agent exec <id>     fetch + run a NodeScript (legacy `ipn -e`)
//	ipn-agent sync          one reconcile cycle (legacy `ipn -S`)
//	ipn-agent init <id>     run a module's init action (start|stop|restart)
//	ipn-agent volume-setup  partition disks per node policy (legacy `ipn -X`)
//	ipn-agent puppet apply  run Puppet against fetched manifest (legacy `ipn -p`)
//
// Reference: Golden Eclipse plan M2 — Go agent v0; project_golden_eclipse.md.
package main

import (
	"fmt"
	"os"

	"github.com/spf13/cobra"
)

// Version is set at build time via -ldflags. The Gitea Actions workflow
// stamps the SHA + tag automatically.
var (
	Version   = "dev"
	GitCommit = "unknown"
	BuildDate = "unknown"
)

func main() {
	root := &cobra.Command{
		Use:   "ipn-agent",
		Short: "Powernode on-node runtime agent",
		Long: `ipn-agent runs on Powernode-managed instances. It enrolls the instance
via mTLS, mounts assigned modules as a composefs+overlayfs union, and
maintains a heartbeat + task-lease loop with the Powernode control plane.

See https://docs.powernode.org/agent for full documentation.`,
		SilenceUsage: true,
	}

	root.AddCommand(
		bootCmd(),
		serviceCmd(),
		enrollCmd(),
		verifyCmd(),
		introspectCmd(),
		attachCmd(),
		detachCmd(),
		updateCmd(),
		commitCmd(),
		statusCmd(),
		execCmd(),
		syncCmd(),
		initCmd(),
		volumeSetupCmd(),
		puppetCmd(),
		versionCmd(),
	)

	if err := root.Execute(); err != nil {
		fmt.Fprintln(os.Stderr, "ipn-agent:", err)
		os.Exit(1)
	}
}

func versionCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "version",
		Short: "Print agent version + build info",
		Run: func(cmd *cobra.Command, args []string) {
			fmt.Printf("ipn-agent %s\n", Version)
			fmt.Printf("commit:    %s\n", GitCommit)
			fmt.Printf("built:     %s\n", BuildDate)
		},
	}
}
