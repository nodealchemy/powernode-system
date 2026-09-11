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
//
// IMP-01a08b79: a second rule. Eleven internal packages carried TWO package
// comments, one in doc.go and one on a sibling file, and go doc prints every
// package comment it finds, in file order. In five of them the two disagreed
// about the code: manifest's cache path, migration's subject, systemd's API,
// identity's strategy names, and which package verifies a module signature.
// A reader saw both and could not tell which was stale. Every package under
// internal/ now has exactly one package comment.
package docs_test

import (
	"fmt"
	"go/ast"
	"go/parser"
	"go/token"
	"io/fs"
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

func TestEachInternalPackageHasOnePackageComment(t *testing.T) {
	root := filepath.Join("..", "..", "internal")

	checked := 0
	err := filepath.WalkDir(root, func(dir string, d fs.DirEntry, err error) error {
		if err != nil {
			return err
		}
		if !d.IsDir() {
			return nil
		}
		// The go tool ignores testdata, so a .go fixture there is not a package.
		if d.Name() == "testdata" {
			return filepath.SkipDir
		}

		paths, err := filepath.Glob(filepath.Join(dir, "*.go"))
		if err != nil {
			return err
		}

		fset := token.NewFileSet()
		sources := 0
		var carriers []string
		for _, path := range paths {
			if strings.HasSuffix(path, "_test.go") {
				continue
			}
			sources++
			// A package comment is the comment group immediately above the
			// package clause; a blank line in between makes it a file comment.
			file, err := parser.ParseFile(fset, path, nil, parser.PackageClauseOnly|parser.ParseComments)
			if err != nil {
				return fmt.Errorf("parse %s: %w", path, err)
			}
			if file.Doc != nil {
				carriers = append(carriers, filepath.Base(path))
			}
		}
		if sources == 0 {
			return nil
		}
		checked++

		if len(carriers) != 1 {
			rel, _ := filepath.Rel(root, dir)
			t.Errorf("internal/%s has %d package comments (%s); keep exactly one, in doc.go, "+
				"and turn the rest into file comments (a blank line before `package`)",
				rel, len(carriers), strings.Join(carriers, ", "))
		}
		return nil
	})
	if err != nil {
		t.Fatalf("walk %s: %v", root, err)
	}

	// Non-vacuity: a wrong root walks nothing and every package "passes".
	if checked < 30 {
		t.Fatalf("only %d internal package(s) found under %s; the guard is looking in the wrong place",
			checked, root)
	}
}
