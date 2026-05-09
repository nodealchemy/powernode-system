package cli

import "github.com/spf13/cobra"

// CommonFlags collects the flag values that nearly every command
// accepts. AddCommonFlags installs them on a cobra.Command and binds
// them to this struct.
type CommonFlags struct {
	PlatformURL string
	PKIDir      string
	JSON        bool
	DryRun      bool
}

// AddCommonFlags installs --platform-url, --pki-dir, --json, --dry-run
// on c. Pass the same *CommonFlags to multiple commands when you want
// shared defaults; each cobra.Command should still own its own struct
// instance so flag values don't bleed across commands.
func AddCommonFlags(c *cobra.Command, f *CommonFlags) {
	c.Flags().StringVar(&f.PlatformURL, "platform-url", "", "platform base URL (defaults to identity-discovered URL)")
	c.Flags().StringVar(&f.PKIDir, "pki-dir", "", "agent PKI directory (defaults to /persist/var/lib/powernode/pki)")
	c.Flags().BoolVar(&f.JSON, "json", false, "emit JSON output instead of human-readable lines")
	c.Flags().BoolVar(&f.DryRun, "dry-run", false, "print planned actions without executing them")
}

// OutputMode returns the OutputMode implied by f.JSON.
func (f *CommonFlags) OutputMode() OutputMode {
	if f.JSON {
		return OutputJSON
	}
	return OutputHuman
}
