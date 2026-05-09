// Package main is the entry point for powernode-agent, the on-node runtime for
// Powernode-managed instances. Replaces the legacy bash `ipn` script
// (~/Drive/Projects/powernode-bootstrap/scripts/ipn).
//
// Subcommand surface mirrors the legacy ipn flags + adds boot/service for
// the initramfs handoff path:
//
//	powernode-agent boot          run during initramfs init-bottom; sets up union mount + switch_root
//	powernode-agent service       long-lived loop: heartbeat + task lease + cert rotation
//	powernode-agent enroll        token → mTLS cert exchange (used by boot but also operator-callable)
//	powernode-agent verify        verifies cosign signature + fs-verity hash on a local module
//	powernode-agent introspect    prints the agent's view of itself (identity, modules, certs)
//	powernode-agent attach <id>   mount a module into the union (legacy `ipn -a`)
//	powernode-agent detach <id>   unmount a module (legacy `ipn -d`)
//	powernode-agent update        pull current assignments from /node_api/modules
//	powernode-agent commit <id>   capture live delta + push as new module version
//	powernode-agent status        print current attach/detach state
//	powernode-agent exec <id>     fetch + run a NodeScript (legacy `ipn -e`)
//	powernode-agent sync          one reconcile cycle (legacy `ipn -S`)
//	powernode-agent init <id>     run a module's init action (start|stop|restart)
//	powernode-agent volume-setup  partition disks per node policy (legacy `ipn -X`)
//	powernode-agent puppet apply  run Puppet against fetched manifest (legacy `ipn -p`)
//
// Reference: Golden Eclipse plan M2 — Go agent v0; project_golden_eclipse.md.
package main

import (
	"errors"
	"fmt"
	"os"

	"github.com/spf13/cobra"

	"github.com/nodealchemy/powernode-system/agent/cmd/powernode-agent/internal/cli"
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
		Use:   "powernode-agent",
		Short: "Powernode on-node runtime agent",
		Long: `powernode-agent runs on Powernode-managed instances. It enrolls the instance
via mTLS, mounts assigned modules as a composefs+overlayfs union, and
maintains a heartbeat + task-lease loop with the Powernode control plane.

See https://docs.powernode.org/agent for full documentation.`,
		SilenceUsage: true,
	}

	root.AddCommand(
		bootCmd(),
		serviceCmd(),
		prepareRootCmd(),
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
		fmt.Fprintln(os.Stderr, "powernode-agent:", err)
		// Honor structured exit codes from cli.CommandError. Lets
		// shell scripts branch on specific failure classes (verify
		// failed = 2, mount failed = 3, etc.). Falls back to 1.
		var ce *cli.CommandError
		if errors.As(err, &ce) && ce.Code != 0 {
			os.Exit(ce.Code)
		}
		os.Exit(1)
	}
}

func versionCmd() *cobra.Command {
	return &cobra.Command{
		Use:   "version",
		Short: "Print agent version + build info",
		Run: func(cmd *cobra.Command, args []string) {
			fmt.Printf("powernode-agent %s\n", Version)
			fmt.Printf("commit:    %s\n", GitCommit)
			fmt.Printf("built:     %s\n", BuildDate)
		},
	}
}
