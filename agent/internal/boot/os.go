package boot

import (
	"io/fs"
	"os"
)

// osStatReal is the production os.Stat passthrough. Separated so
// tests can swap osStat without pulling in the os package directly.
func osStatReal(path string) (fs.FileInfo, error) { return os.Stat(path) }
