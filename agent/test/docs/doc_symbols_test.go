// Package docs_test guards the agent's package documentation against naming
// APIs that do not exist.
//
// IMP-01a05e01-d9a2: nine internal packages carried a "# Key types" block in
// doc.go listing 19 symbols that were never written — transport advertised an
// Mtls type, a PinnedCABundle operator control and a RetryClient, none of
// which appear anywhere in the package except in the comment asserting them;
// mount advertised Erofs, Overlayfs and BindHelper; sdwan advertised Config,
// Diff and Snapshot. Prose drifts silently because nothing compiles it, so
// this test compiles it.
//
// The rule: every capitalised identifier listed in a doc.go indented block
// must be an exported top-level declaration of that same package.
package docs_test

import (
	"go/ast"
	"go/parser"
	"go/token"
	"os"
	"path/filepath"
	"regexp"
	"sort"
	"strings"
	"testing"
)

// A documented symbol is a tab-indented, capitalised identifier inside a
// doc comment — the shape gofmt gives a code block under "# Key types".
var documentedSymbol = regexp.MustCompile(`^//\t+([A-Z][A-Za-z0-9_]*)[\s—-]`)

// exportedNames returns every exported top-level declaration in a package
// directory, ignoring _test.go files.
func exportedNames(t *testing.T, dir string) map[string]bool {
	t.Helper()

	names := map[string]bool{}
	entries, err := filepath.Glob(filepath.Join(dir, "*.go"))
	if err != nil {
		t.Fatalf("glob %s: %v", dir, err)
	}

	fset := token.NewFileSet()
	for _, path := range entries {
		if strings.HasSuffix(path, "_test.go") {
			continue
		}
		file, err := parser.ParseFile(fset, path, nil, parser.SkipObjectResolution)
		if err != nil {
			t.Fatalf("parse %s: %v", path, err)
		}
		for _, decl := range file.Decls {
			switch d := decl.(type) {
			case *ast.FuncDecl:
				// Methods are reached through their receiver type, which is
				// itself declared here; only top-level funcs are named.
				if d.Recv == nil && d.Name.IsExported() {
					names[d.Name.Name] = true
				}
			case *ast.GenDecl:
				for _, spec := range d.Specs {
					switch s := spec.(type) {
					case *ast.TypeSpec:
						if s.Name.IsExported() {
							names[s.Name.Name] = true
						}
					case *ast.ValueSpec:
						for _, id := range s.Names {
							if id.IsExported() {
								names[id.Name] = true
							}
						}
					}
				}
			}
		}
	}
	return names
}

func TestDocCommentsNameRealSymbols(t *testing.T) {
	docFiles, err := filepath.Glob(filepath.Join("..", "..", "internal", "*", "doc.go"))
	if err != nil {
		t.Fatalf("glob doc.go: %v", err)
	}
	if len(docFiles) == 0 {
		t.Fatal("no internal/*/doc.go files found — the guard is looking in the wrong place")
	}

	documenting := 0
	for _, docFile := range docFiles {
		dir := filepath.Dir(docFile)
		pkg := filepath.Base(dir)

		src, err := os.ReadFile(docFile)
		if err != nil {
			t.Fatalf("read %s: %v", docFile, err)
		}

		var claimed []string
		for _, line := range strings.Split(string(src), "\n") {
			if m := documentedSymbol.FindStringSubmatch(line); m != nil {
				claimed = append(claimed, m[1])
			}
		}
		if len(claimed) == 0 {
			continue
		}
		documenting++

		exported := exportedNames(t, dir)
		var missing []string
		for _, name := range claimed {
			if !exported[name] {
				missing = append(missing, name)
			}
		}
		if len(missing) > 0 {
			sort.Strings(missing)
			t.Errorf("%s/doc.go names %d symbol(s) the package does not export: %s",
				pkg, len(missing), strings.Join(missing, ", "))
		}
	}

	// Non-vacuity. If the block shape ever changes — a different indent, a
	// different heading — `claimed` goes empty everywhere and every package
	// passes while checking nothing. The guard must be looking at real text.
	if documenting < 5 {
		t.Fatalf("only %d package(s) had a documented-symbol block; the extraction "+
			"pattern has probably stopped matching the doc.go convention", documenting)
	}
}
