package main

import (
	"archive/tar"
	"compress/gzip"
	"encoding/json"
	"io"
	"os"
	"path/filepath"
	"testing"
)

// readImage decodes the OCI layout writeLayout produced: the manifest, the
// config, and the set of paths in the single layer.
type readImage struct {
	os         string
	arch       string
	entrypoint []string
	cmd        []string
	env        []string
	workingDir string
	layerPaths map[string]bool
}

func loadLayout(t *testing.T, out string) readImage {
	t.Helper()
	indexRaw, err := os.ReadFile(filepath.Join(out, "index.json"))
	if err != nil {
		t.Fatalf("index.json: %v", err)
	}
	var index struct {
		Manifests []descriptor `json:"manifests"`
	}
	if err := json.Unmarshal(indexRaw, &index); err != nil {
		t.Fatalf("index: %v", err)
	}
	if len(index.Manifests) != 1 {
		t.Fatalf("want 1 manifest, got %d", len(index.Manifests))
	}
	if p := index.Manifests[0].Platform["os"]; p != "darwin" {
		t.Errorf("index platform os = %q, want darwin", p)
	}

	var manifest struct {
		Config descriptor   `json:"config"`
		Layers []descriptor `json:"layers"`
	}
	readBlob(t, out, index.Manifests[0].Digest, &manifest)
	if len(manifest.Layers) != 1 {
		t.Fatalf("want 1 layer, got %d", len(manifest.Layers))
	}

	var cfg struct {
		OS           string `json:"os"`
		Architecture string `json:"architecture"`
		Config       struct {
			Entrypoint []string `json:"Entrypoint"`
			Cmd        []string `json:"Cmd"`
			Env        []string `json:"Env"`
			WorkingDir string   `json:"WorkingDir"`
		} `json:"config"`
	}
	readBlob(t, out, manifest.Config.Digest, &cfg)

	return readImage{
		os:         cfg.OS,
		arch:       cfg.Architecture,
		entrypoint: cfg.Config.Entrypoint,
		cmd:        cfg.Config.Cmd,
		env:        cfg.Config.Env,
		workingDir: cfg.Config.WorkingDir,
		layerPaths: layerPaths(t, out, manifest.Layers[0].Digest),
	}
}

func readBlob(t *testing.T, out, digest string, v any) {
	t.Helper()
	raw, err := os.ReadFile(blobPath(out, digest))
	if err != nil {
		t.Fatalf("blob %s: %v", digest, err)
	}
	if err := json.Unmarshal(raw, v); err != nil {
		t.Fatalf("decode %s: %v", digest, err)
	}
}

func layerPaths(t *testing.T, out, digest string) map[string]bool {
	t.Helper()
	f, err := os.Open(blobPath(out, digest))
	if err != nil {
		t.Fatalf("layer: %v", err)
	}
	defer f.Close()
	zr, err := gzip.NewReader(f)
	if err != nil {
		t.Fatalf("gzip: %v", err)
	}
	paths := map[string]bool{}
	tr := tar.NewReader(zr)
	for {
		hdr, err := tr.Next()
		if err == io.EOF {
			break
		}
		if err != nil {
			t.Fatalf("tar: %v", err)
		}
		paths[hdr.Name] = true
		if hdr.Uname != "root" || hdr.Gname != "wheel" {
			t.Errorf("%s owned by %s:%s, want root:wheel", hdr.Name, hdr.Uname, hdr.Gname)
		}
	}
	return paths
}

func blobPath(out, digest string) string {
	return filepath.Join(out, "blobs", "sha256", digest[len("sha256:"):])
}

func writeCtx(t *testing.T, files map[string]string) string {
	t.Helper()
	dir := t.TempDir()
	for name, body := range files {
		full := filepath.Join(dir, name)
		if err := os.MkdirAll(filepath.Dir(full), 0o755); err != nil {
			t.Fatal(err)
		}
		if err := os.WriteFile(full, []byte(body), 0o755); err != nil {
			t.Fatal(err)
		}
	}
	return dir
}

func TestDockerfileImage(t *testing.T) {
	ctx := writeCtx(t, map[string]string{
		"Dockerfile": `# a darwin workload
FROM macos
COPY bin/app /bin/app
COPY assets/ /assets/
ENV FOO=bar BAZ=qux
WORKDIR /work
ENTRYPOINT ["/bin/app", "serve"]
CMD ["--port", "8080"]
`,
		"bin/app":         "binary",
		"assets/logo.txt": "logo",
	})
	out := filepath.Join(t.TempDir(), "layout")

	img := &image{Name: "example.com/app-darwin:1"}
	if err := buildFromDockerfile(img, filepath.Join(ctx, "Dockerfile"), ctx, builderConfig{}); err != nil {
		t.Fatalf("build: %v", err)
	}
	defer os.RemoveAll(img.RootFS)
	if _, err := writeLayout(img, out); err != nil {
		t.Fatalf("writeLayout: %v", err)
	}

	got := loadLayout(t, out)
	if got.os != "darwin" || got.arch != "arm64" {
		t.Errorf("platform = %s/%s, want darwin/arm64", got.os, got.arch)
	}
	if want := []string{"/bin/app", "serve"}; !eq(got.entrypoint, want) {
		t.Errorf("entrypoint = %v, want %v", got.entrypoint, want)
	}
	if want := []string{"--port", "8080"}; !eq(got.cmd, want) {
		t.Errorf("cmd = %v, want %v", got.cmd, want)
	}
	if want := []string{"FOO=bar", "BAZ=qux"}; !eq(got.env, want) {
		t.Errorf("env = %v, want %v", got.env, want)
	}
	if got.workingDir != "/work" {
		t.Errorf("workingDir = %q, want /work", got.workingDir)
	}
	for _, p := range []string{"bin/app", "assets/logo.txt"} {
		if !got.layerPaths[p] {
			t.Errorf("layer missing %q; has %v", p, keys(got.layerPaths))
		}
	}
}

func TestShellFormEntrypoint(t *testing.T) {
	ctx := writeCtx(t, map[string]string{
		"Dockerfile": "FROM macos\nCOPY app /app\nENTRYPOINT /app --serve\n",
		"app":        "x",
	})
	img := &image{Name: "example.com/app-darwin:1"}
	if err := buildFromDockerfile(img, filepath.Join(ctx, "Dockerfile"), ctx, builderConfig{}); err != nil {
		t.Fatalf("build: %v", err)
	}
	defer os.RemoveAll(img.RootFS)
	want := []string{"/bin/sh", "-c", "/app --serve"}
	if !eq(img.Entrypoint, want) {
		t.Errorf("entrypoint = %v, want %v", img.Entrypoint, want)
	}
}

func TestRunIsAccepted(t *testing.T) {
	df, err := parseDockerfile("FROM macos\nRUN make\n")
	if err != nil {
		t.Fatalf("RUN should parse: %v", err)
	}
	if len(df.steps) != 1 || df.steps[0].kind != "run" {
		t.Fatalf("steps = %+v, want one run step", df.steps)
	}
	want := []string{"/bin/sh", "-c", "make"}
	if got := df.steps[0].run; !eq(got, want) {
		t.Errorf("RUN argv = %v, want %v", got, want)
	}
}

func TestRunExecForm(t *testing.T) {
	df, err := parseDockerfile("FROM macos\nRUN [\"/bin/echo\", \"hi\"]\n")
	if err != nil {
		t.Fatal(err)
	}
	if want := []string{"/bin/echo", "hi"}; !eq(df.steps[0].run, want) {
		t.Errorf("argv = %v, want %v", df.steps[0].run, want)
	}
}

// TestStepOrderPreserved is the change RUN needed: a COPY after a RUN and a
// RUN after a COPY must stay in the order they were written, not be sorted
// into "all copies, then everything else".
func TestStepOrderPreserved(t *testing.T) {
	df, err := parseDockerfile(`FROM macos
COPY a.txt a.txt
RUN echo one
COPY b.txt b.txt
RUN echo two
`)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"copy", "run", "copy", "run"}
	if len(df.steps) != len(want) {
		t.Fatalf("got %d steps, want %d: %+v", len(df.steps), len(want), df.steps)
	}
	for i, kind := range want {
		if df.steps[i].kind != kind {
			t.Errorf("step %d kind = %q, want %q", i, df.steps[i].kind, kind)
		}
	}
}

func TestRunWithoutBuilderIsRejected(t *testing.T) {
	ctx := writeCtx(t, map[string]string{"Dockerfile": "FROM macos\nRUN make\n"})
	img := &image{Name: "x:1"}
	err := buildFromDockerfile(img, filepath.Join(ctx, "Dockerfile"), ctx, builderConfig{})
	if img.RootFS != "" {
		defer os.RemoveAll(img.RootFS)
	}
	if err == nil {
		t.Fatal("RUN with no builder configured should be rejected")
	}
}

func TestFromMustBeMacos(t *testing.T) {
	if _, err := parseDockerfile("FROM alpine:3\n"); err == nil {
		t.Fatal("non-macos FROM should be rejected")
	}
	if _, err := parseDockerfile("FROM scratch\n"); err == nil {
		t.Fatal("FROM scratch is no longer accepted")
	}
	if _, err := parseDockerfile("COPY a b\n"); err == nil {
		t.Fatal("missing FROM should be rejected")
	}
	if df, err := parseDockerfile("FROM macos\nCOPY a b\n"); err != nil {
		t.Fatalf("FROM macos should parse: %v", err)
	} else if df.requireMacOS != 0 {
		t.Errorf("bare FROM macos should not pin a version, got %d", df.requireMacOS)
	}
}

func TestFromMacosVersionTag(t *testing.T) {
	df, err := parseDockerfile("FROM macos:26\nCOPY a b\n")
	if err != nil {
		t.Fatalf("FROM macos:26 should parse: %v", err)
	}
	if df.requireMacOS != 26 {
		t.Errorf("requireMacOS = %d, want 26", df.requireMacOS)
	}
	if _, err := parseDockerfile("FROM macos:sequoia\n"); err == nil {
		t.Fatal("a non-integer macos tag should be rejected")
	}
}

// A `FROM macos:<major>` pin is checked against the golden image's major when
// one is known (builderConfig.nodeMacOS); a mismatch fails before any build,
// a match builds and stamps the major as a label.
func TestFromMacosVersionCheck(t *testing.T) {
	ctx := writeCtx(t, map[string]string{
		"Dockerfile": "FROM macos:26\nCOPY app /app\n",
		"app":        "x",
	})
	df := filepath.Join(ctx, "Dockerfile")

	img := &image{Name: "x:1"}
	if err := buildFromDockerfile(img, df, ctx, builderConfig{nodeMacOS: 25}); err == nil {
		if img.RootFS != "" {
			os.RemoveAll(img.RootFS)
		}
		t.Fatal("FROM macos:26 against a macOS 25 image should fail")
	}

	img = &image{Name: "x:1"}
	if err := buildFromDockerfile(img, df, ctx, builderConfig{nodeMacOS: 26}); err != nil {
		t.Fatalf("FROM macos:26 against a macOS 26 image should build: %v", err)
	}
	defer os.RemoveAll(img.RootFS)
	if got := img.Labels["dev.ferry.macos.major"]; got != "26" {
		t.Errorf("label dev.ferry.macos.major = %q, want 26", got)
	}

	// Unknown node version does not block.
	img = &image{Name: "x:1"}
	if err := buildFromDockerfile(img, df, ctx, builderConfig{nodeMacOS: 0}); err != nil {
		t.Fatalf("unknown node macOS should not block: %v", err)
	}
	defer os.RemoveAll(img.RootFS)
}

func TestCopyEscapeRejected(t *testing.T) {
	ctx := writeCtx(t, map[string]string{"Dockerfile": "FROM macos\nCOPY ../secret /x\n"})
	img := &image{Name: "x:1"}
	err := buildFromDockerfile(img, filepath.Join(ctx, "Dockerfile"), ctx, builderConfig{})
	if img.RootFS != "" {
		defer os.RemoveAll(img.RootFS)
	}
	if err == nil {
		t.Fatal("COPY escaping the context should be rejected")
	}
}

// A quoted value with spaces used to come back as several near-empty
// variables (splitQuotedFields, below, is the fix): strings.Fields split
// `NAME="John Doe" ROLE=admin` on every space, so NAME ended up `"John` and
// three more entries -- Doe", ROLE=admin -- came back with no way to tell
// they were never meant to be their own variables.
func TestEnvQuotedValue(t *testing.T) {
	df, err := parseDockerfile("FROM macos\nENV NAME=\"John Doe\" ROLE=admin\n")
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	got := df.steps[0].env
	want := []string{"NAME=John Doe", "ROLE=admin"}
	if !eq(got, want) {
		t.Errorf("env = %#v, want %#v", got, want)
	}
}

func TestEnvSingleQuotedValue(t *testing.T) {
	df, err := parseDockerfile(`FROM macos
ENV NAME='John "the man" Doe'
`)
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	want := []string{`NAME=John "the man" Doe`}
	if !eq(df.steps[0].env, want) {
		t.Errorf("env = %#v, want %#v", df.steps[0].env, want)
	}
}

// LABEL shares parseEnv with ENV, so the same quoting applies to it.
func TestLabelQuotedValue(t *testing.T) {
	df, err := parseDockerfile("FROM macos\nLABEL description=\"a demo, with a comma\"\n")
	if err != nil {
		t.Fatalf("parse: %v", err)
	}
	if got, want := df.labels["description"], "a demo, with a comma"; got != want {
		t.Errorf("labels[description] = %q, want %q", got, want)
	}
}

func TestEnvUnclosedQuoteRejected(t *testing.T) {
	if _, err := parseDockerfile("FROM macos\nENV NAME=\"unclosed\n"); err == nil {
		t.Fatal("an unclosed quote should be rejected")
	}
}

func TestSplitQuotedFields(t *testing.T) {
	cases := []struct {
		in   string
		want []string
	}{
		{"FOO=bar BAZ=qux", []string{"FOO=bar", "BAZ=qux"}},
		{`NAME="John Doe" ROLE=admin`, []string{"NAME=John Doe", "ROLE=admin"}},
		{`NAME='John Doe'`, []string{"NAME=John Doe"}},
		{`GREETING="hi \"there\""`, []string{`GREETING=hi "there"`}},
		{`EMPTY=""`, []string{"EMPTY="}},
		{"A=1   B=2", []string{"A=1", "B=2"}},
		{`MID=a"b c"d`, []string{"MID=ab cd"}},
	}
	for _, c := range cases {
		got, err := splitQuotedFields(c.in)
		if err != nil {
			t.Errorf("splitQuotedFields(%q): %v", c.in, err)
			continue
		}
		if !eq(got, c.want) {
			t.Errorf("splitQuotedFields(%q) = %#v, want %#v", c.in, got, c.want)
		}
	}
}

func eq(a, b []string) bool {
	if len(a) != len(b) {
		return false
	}
	for i := range a {
		if a[i] != b[i] {
			return false
		}
	}
	return true
}

func keys(m map[string]bool) []string {
	var out []string
	for k := range m {
		out = append(out, k)
	}
	return out
}
