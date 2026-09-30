package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strconv"
	"strings"
)

// buildFromDockerfile parses a small subset of Dockerfile syntax, applies its
// instructions, and fills img's runtime configuration. It sets img.RootFS to
// a temp directory the caller removes.
//
// A Dockerfile with no RUN never touches a builder VM at all: every COPY
// applies straight to a host temp directory, the same fast, dependency-free
// path this had before RUN existed. One with RUN needs a builder (see
// builder.go) because a COPY before a RUN must land where that RUN can see
// it, and everything after the last RUN must reflect what RUN left behind --
// so once a builder is needed, every COPY goes through it too, and the image
// root is read back once, at the end, from the guest's own disk.
func buildFromDockerfile(img *image, dockerfile, context string, bc builderConfig) error {
	content, err := os.ReadFile(dockerfile)
	if err != nil {
		return err
	}
	df, err := parseDockerfile(string(content))
	if err != nil {
		return err
	}

	// Checked before a builder ever boots: a `FROM macos:26` against a macOS 25
	// golden image should fail at once, not after minutes of VM work. The
	// golden image and every machine cloned from it are the same macOS, so its
	// version is the node's -- known here from what `ferry mac-image bake`
	// recorded. An unknown node version (bc.nodeMacOS == 0) cannot say either
	// way, so it does not block.
	if df.requireMacOS != 0 && bc.nodeMacOS != 0 && df.requireMacOS != bc.nodeMacOS {
		return fmt.Errorf("image is `FROM macos:%d` but this Mac's golden image is macOS %d -- rebake the image or change the tag",
			df.requireMacOS, bc.nodeMacOS)
	}

	hasRun := false
	for _, s := range df.steps {
		if s.kind == "run" {
			hasRun = true
			break
		}
	}

	root, err := os.MkdirTemp("", "ferry-mkimage-root-*")
	if err != nil {
		return err
	}
	img.RootFS = root

	if hasRun {
		if err := runSteps(df.steps, context, bc, root); err != nil {
			return err
		}
	} else {
		for _, s := range df.steps {
			if s.kind != "copy" {
				continue
			}
			if err := applyCopy(context, root, s.copy); err != nil {
				return fmt.Errorf("COPY %s: %w", copyOpString(s.copy), err)
			}
		}
	}

	var envList []string
	workdir := ""
	for _, s := range df.steps {
		switch s.kind {
		case "env":
			envList = append(envList, s.env...)
		case "workdir":
			workdir = joinWorkdir(workdir, s.workdir)
		}
	}

	img.Entrypoint = df.entrypoint
	img.Cmd = df.cmd
	img.Env = envList
	img.WorkingDir = workdir
	img.Labels = df.labels
	// Record the macOS major the author pinned, so the built image carries the
	// version it was made for (and a later runtime check could read it back).
	if df.requireMacOS != 0 {
		if img.Labels == nil {
			img.Labels = map[string]string{}
		}
		img.Labels["dev.ferry.macos.major"] = strconv.Itoa(df.requireMacOS)
	}
	return nil
}

// runSteps drives a builder VM through df's ordered steps, starting it lazily
// on the first COPY or RUN, and reads the whole build root back once, into
// root, after the last one.
func runSteps(steps []step, context string, bc builderConfig, root string) error {
	var b *macBuilder
	defer func() {
		if b != nil {
			b.close()
		}
	}()
	ensure := func() (*macBuilder, error) {
		if b != nil {
			return b, nil
		}
		if bc.macvmPath == "" || bc.golden == "" {
			return nil, fmt.Errorf("RUN needs a macOS builder VM, but no golden image is available (bake one with `ferry mac-image bake`) or bin/ferry-macvm is missing -- see docs/RUNTIMES.md#building-the-image")
		}
		nb, err := startMacBuilder(bc.macvmPath, bc.golden)
		if err != nil {
			return nil, fmt.Errorf("starting the builder: %w", err)
		}
		if _, code, err := nb.run([]string{"/bin/mkdir", "-p", guestRoot}, nil, ""); err != nil {
			return nil, fmt.Errorf("builder setup: %w", err)
		} else if code != 0 {
			return nil, fmt.Errorf("builder setup: mkdir exited %d", code)
		}
		b = nb
		return b, nil
	}

	var envList []string
	workdir := ""
	for _, s := range steps {
		switch s.kind {
		case "copy":
			bd, err := ensure()
			if err != nil {
				return err
			}
			if err := pushCopy(bd, context, s.copy); err != nil {
				return fmt.Errorf("COPY %s: %w", copyOpString(s.copy), err)
			}
		case "env":
			envList = append(envList, s.env...)
		case "workdir":
			workdir = joinWorkdir(workdir, s.workdir)
		case "run":
			bd, err := ensure()
			if err != nil {
				return err
			}
			envMap := map[string]string{}
			for _, kv := range envList {
				k, v := split2eq(kv)
				envMap[k] = v
			}
			cwd := guestRoot
			if workdir != "" {
				cwd = guestRoot + "/" + strings.TrimPrefix(workdir, "/")
			}
			stdout, code, err := bd.run(s.run, envMap, cwd)
			os.Stdout.Write(stdout)
			if err != nil {
				return fmt.Errorf("RUN %s: %w", strings.Join(s.run, " "), err)
			}
			if code != 0 {
				return fmt.Errorf("RUN %s: exit %d", strings.Join(s.run, " "), code)
			}
		}
	}

	bd, err := ensure() // a Dockerfile with RUN but no COPY still needs the root read back
	if err != nil {
		return err
	}
	return pullRoot(bd, root)
}

type copyOp struct {
	srcs []string
	dest string
}

// step is one instruction that can affect the filesystem or the environment a
// later RUN sees: copy, run, env or workdir, kept in the order they appear so
// a COPY after a RUN sees only that RUN's output, and a RUN after a COPY sees
// it. ENTRYPOINT/CMD/LABEL do not interleave with anything and stay as
// dockerfile's own final-state fields.
type step struct {
	kind    string // "copy", "run", "env", "workdir"
	copy    copyOp
	run     []string
	env     []string
	workdir string
}

type dockerfile struct {
	steps      []step
	entrypoint []string
	cmd        []string
	labels     map[string]string
	// requireMacOS is the macOS major from `FROM macos:<major>`, or 0 when the
	// tag was omitted (`FROM macos`, run against whatever the node happens to be).
	requireMacOS int
}

// parseDockerfile reads the instructions a darwin image can honour: COPY/ADD,
// RUN (run in a builder VM -- see runSteps), ENTRYPOINT, CMD, ENV, WORKDIR
// and LABEL.
func parseDockerfile(content string) (*dockerfile, error) {
	df := &dockerfile{}
	sawFrom := false
	for _, line := range logicalLines(content) {
		instr, rest := split2(line)
		switch strings.ToUpper(instr) {
		case "FROM":
			base := strings.Fields(rest)
			if len(base) == 0 {
				return nil, fmt.Errorf("FROM needs an image: a darwin image is `FROM macos` (the OS comes from the node)")
			}
			name, tag := split2colon(base[0])
			if strings.EqualFold(name, "scratch") {
				return nil, fmt.Errorf("`FROM scratch` is no longer used -- a darwin image is `FROM macos` (the OS comes from the node)")
			}
			if !strings.EqualFold(name, "macos") {
				return nil, fmt.Errorf("a darwin image must be `FROM macos` (the OS comes from the node), not %q", rest)
			}
			if tag != "" {
				major, err := strconv.Atoi(tag)
				if err != nil || major <= 0 {
					return nil, fmt.Errorf("FROM macos:%s -- the tag must be a macOS major version, e.g. `macos:26`", tag)
				}
				df.requireMacOS = major
			}
			sawFrom = true
		case "COPY", "ADD":
			c, err := parseCopy(rest)
			if err != nil {
				return nil, err
			}
			df.steps = append(df.steps, step{kind: "copy", copy: c})
		case "RUN":
			argv := parseExecOrShell(rest)
			if len(argv) == 0 {
				return nil, fmt.Errorf("RUN needs a command")
			}
			df.steps = append(df.steps, step{kind: "run", run: argv})
		case "ENTRYPOINT":
			df.entrypoint = parseExecOrShell(rest)
		case "CMD":
			df.cmd = parseExecOrShell(rest)
		case "ENV":
			kv, err := parseEnv(rest)
			if err != nil {
				return nil, err
			}
			df.steps = append(df.steps, step{kind: "env", env: kv})
		case "WORKDIR":
			df.steps = append(df.steps, step{kind: "workdir", workdir: strings.TrimSpace(rest)})
		case "LABEL":
			kv, err := parseEnv(rest)
			if err != nil {
				return nil, err
			}
			if df.labels == nil {
				df.labels = map[string]string{}
			}
			for _, e := range kv {
				k, v := split2eq(e)
				df.labels[k] = v
			}
		case "ARG":
			return nil, fmt.Errorf("ARG is not supported for a darwin image yet")
		case "USER", "EXPOSE", "VOLUME", "STOPSIGNAL", "HEALTHCHECK", "SHELL", "MAINTAINER":
			// Recorded by neither ferry-darwin nor this format; ignore quietly.
		default:
			return nil, fmt.Errorf("unsupported instruction %q", instr)
		}
	}
	if !sawFrom {
		return nil, fmt.Errorf("no FROM: a darwin image must start with `FROM macos`")
	}
	return df, nil
}

// logicalLines strips comments and blank lines and joins backslash
// continuations, the way a Dockerfile is read before any instruction is.
func logicalLines(content string) []string {
	var out []string
	var cur strings.Builder
	for _, raw := range strings.Split(content, "\n") {
		line := strings.TrimRight(raw, "\r")
		trimmed := strings.TrimSpace(line)
		if cur.Len() == 0 && (trimmed == "" || strings.HasPrefix(trimmed, "#")) {
			continue
		}
		if strings.HasSuffix(line, "\\") {
			cur.WriteString(strings.TrimSuffix(line, "\\"))
			continue
		}
		cur.WriteString(line)
		joined := strings.TrimSpace(cur.String())
		if joined != "" {
			out = append(out, joined)
		}
		cur.Reset()
	}
	if s := strings.TrimSpace(cur.String()); s != "" {
		out = append(out, s)
	}
	return out
}

// parseCopy reads `COPY [--flag ...] src... dest`, ignoring build-time flags
// like --chmod, and rejecting --from because there is no earlier stage.
func parseCopy(rest string) (copyOp, error) {
	if strings.HasPrefix(strings.TrimSpace(rest), "[") {
		var parts []string
		if err := json.Unmarshal([]byte(rest), &parts); err != nil {
			return copyOp{}, fmt.Errorf("malformed COPY JSON: %w", err)
		}
		return toCopyOp(parts)
	}
	var args []string
	for _, f := range strings.Fields(rest) {
		if strings.HasPrefix(f, "--from=") {
			return copyOp{}, fmt.Errorf("COPY --from is not supported (no build stages in a darwin image)")
		}
		if strings.HasPrefix(f, "--") {
			continue // --chown, --chmod, --link: nothing to honour here
		}
		args = append(args, f)
	}
	return toCopyOp(args)
}

func toCopyOp(args []string) (copyOp, error) {
	if len(args) < 2 {
		return copyOp{}, fmt.Errorf("COPY needs at least one source and a destination")
	}
	return copyOp{srcs: args[:len(args)-1], dest: args[len(args)-1]}, nil
}

// copyOpString renders a copyOp the way it was written, for error messages.
func copyOpString(c copyOp) string {
	return strings.Join(append(append([]string{}, c.srcs...), c.dest), " ")
}

// applyCopy copies each source (relative to context) into root at dest,
// following Docker's rules: a directory source copies its *contents* into dest;
// a file source lands at dest, or dest/basename when dest is a directory (it
// ends in "/", or there is more than one source). A leading "/" on dest is the
// image root.
func applyCopy(context, root string, c copyOp) error {
	destIsDir := strings.HasSuffix(c.dest, "/") || len(c.srcs) > 1
	destRel := filepath.FromSlash(strings.TrimPrefix(c.dest, "/"))
	for _, src := range c.srcs {
		abs := filepath.Join(context, src)
		if !within(context, abs) {
			return fmt.Errorf("source %q escapes the build context", src)
		}
		info, err := os.Stat(abs)
		if err != nil {
			return err
		}
		if info.IsDir() {
			if err := copyDirContents(abs, filepath.Join(root, destRel)); err != nil {
				return err
			}
			continue
		}
		target := filepath.Join(root, destRel)
		if destIsDir {
			target = filepath.Join(root, destRel, filepath.Base(src))
		}
		if err := copyPath(abs, target); err != nil {
			return err
		}
	}
	return nil
}

func copyDirContents(srcDir, dstDir string) error {
	entries, err := os.ReadDir(srcDir)
	if err != nil {
		return err
	}
	if err := os.MkdirAll(dstDir, 0o755); err != nil {
		return err
	}
	for _, e := range entries {
		if err := copyPath(filepath.Join(srcDir, e.Name()), filepath.Join(dstDir, e.Name())); err != nil {
			return err
		}
	}
	return nil
}

func copyPath(src, dst string) error {
	info, err := os.Lstat(src)
	if err != nil {
		return err
	}
	switch {
	case info.IsDir():
		entries, err := os.ReadDir(src)
		if err != nil {
			return err
		}
		if err := os.MkdirAll(dst, 0o755); err != nil {
			return err
		}
		for _, e := range entries {
			if err := copyPath(filepath.Join(src, e.Name()), filepath.Join(dst, e.Name())); err != nil {
				return err
			}
		}
		return nil
	case info.Mode()&os.ModeSymlink != 0:
		if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
			return err
		}
		link, err := os.Readlink(src)
		if err != nil {
			return err
		}
		_ = os.Remove(dst)
		return os.Symlink(link, dst)
	default:
		if err := os.MkdirAll(filepath.Dir(dst), 0o755); err != nil {
			return err
		}
		in, err := os.Open(src)
		if err != nil {
			return err
		}
		defer in.Close()
		out, err := os.OpenFile(dst, os.O_CREATE|os.O_WRONLY|os.O_TRUNC, info.Mode().Perm())
		if err != nil {
			return err
		}
		defer out.Close()
		_, err = io.Copy(out, in)
		return err
	}
}

// parseExecOrShell turns an ENTRYPOINT/CMD argument into argv: a JSON array is
// exec form as written; anything else is shell form, wrapped in /bin/sh -c the
// way Docker does, which on a darwin node is the node's own shell.
func parseExecOrShell(rest string) []string {
	rest = strings.TrimSpace(rest)
	if strings.HasPrefix(rest, "[") {
		var parts []string
		if err := json.Unmarshal([]byte(rest), &parts); err == nil {
			return parts
		}
	}
	if rest == "" {
		return nil
	}
	return []string{"/bin/sh", "-c", rest}
}

// parseEnv reads `ENV k=v k2=v2` (each value may be shell-quoted, `k="v
// with spaces"`, the way Docker's own docs show it) and the legacy `ENV k v`,
// returning k=v strings. LABEL shares this same syntax and this function.
func parseEnv(rest string) ([]string, error) {
	rest = strings.TrimSpace(rest)
	if rest == "" {
		return nil, fmt.Errorf("ENV needs a key")
	}
	if !strings.Contains(rest, "=") {
		k, v := split2(rest)
		if v == "" {
			return nil, fmt.Errorf("ENV %q needs a value", k)
		}
		return []string{k + "=" + strings.TrimSpace(v)}, nil
	}
	pairs, err := splitQuotedFields(rest)
	if err != nil {
		return nil, fmt.Errorf("ENV %q: %w", rest, err)
	}
	for _, p := range pairs {
		if !strings.Contains(p, "=") {
			return nil, fmt.Errorf("ENV %q: %q is not key=value", rest, p)
		}
	}
	return pairs, nil
}

// splitQuotedFields splits s on whitespace the way a shell would: a
// single- or double-quoted run holds a space rather than ending the field,
// and the quote characters themselves are removed from the result. This is
// what lets `ENV NAME="John Doe" ROLE=admin` keep "John Doe" together --
// strings.Fields alone would split it into "NAME=\"John", "Doe\"" and
// "ROLE=admin", the bug this exists to fix.
func splitQuotedFields(s string) ([]string, error) {
	var fields []string
	var cur strings.Builder
	has := false // cur holds content even if empty, e.g. from KEY=""
	quote := byte(0)
	for i := 0; i < len(s); i++ {
		c := s[i]
		switch {
		case quote != 0:
			if c == quote {
				quote = 0
				continue
			}
			if quote == '"' && c == '\\' && i+1 < len(s) && (s[i+1] == '"' || s[i+1] == '\\') {
				i++
				c = s[i]
			}
			cur.WriteByte(c)
		case c == '"' || c == '\'':
			quote = c
			has = true
		case c == ' ' || c == '\t':
			if has {
				fields = append(fields, cur.String())
				cur.Reset()
				has = false
			}
		default:
			cur.WriteByte(c)
			has = true
		}
	}
	if quote != 0 {
		return nil, fmt.Errorf("unclosed %c", quote)
	}
	if has {
		fields = append(fields, cur.String())
	}
	return fields, nil
}

func within(base, p string) bool {
	rel, err := filepath.Rel(base, p)
	if err != nil {
		return false
	}
	return rel != ".." && !strings.HasPrefix(rel, ".."+string(os.PathSeparator))
}

func joinWorkdir(prev, next string) string {
	if strings.HasPrefix(next, "/") || prev == "" {
		return next
	}
	return prev + "/" + next
}

func split2(s string) (string, string) {
	s = strings.TrimSpace(s)
	if i := strings.IndexAny(s, " \t"); i >= 0 {
		return s[:i], strings.TrimSpace(s[i+1:])
	}
	return s, ""
}

func split2eq(s string) (string, string) {
	if i := strings.IndexByte(s, '='); i >= 0 {
		return s[:i], s[i+1:]
	}
	return s, ""
}

// split2colon splits an image reference into name and tag, e.g. "macos:26" ->
// ("macos", "26"). A bare name has an empty tag.
func split2colon(s string) (string, string) {
	if i := strings.IndexByte(s, ':'); i >= 0 {
		return s[:i], s[i+1:]
	}
	return s, ""
}

// fields splits a space-separated flag value, for -entrypoint in dir mode.
func fields(s string) []string { return strings.Fields(s) }
