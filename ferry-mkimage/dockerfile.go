package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// buildFromDockerfile parses a small subset of Dockerfile syntax, applies its
// COPY/ADD into a fresh staging root, and fills img's runtime configuration.
// It sets img.RootFS to a temp directory the caller removes.
func buildFromDockerfile(img *image, dockerfile, context string) error {
	content, err := os.ReadFile(dockerfile)
	if err != nil {
		return err
	}
	df, err := parseDockerfile(string(content))
	if err != nil {
		return err
	}

	root, err := os.MkdirTemp("", "ferry-mkimage-root-*")
	if err != nil {
		return err
	}
	img.RootFS = root
	for _, c := range df.copies {
		if err := applyCopy(context, root, c); err != nil {
			return fmt.Errorf("COPY %s: %w", strings.Join(append(c.srcs, c.dest), " "), err)
		}
	}
	img.Entrypoint = df.entrypoint
	img.Cmd = df.cmd
	img.Env = df.env
	img.WorkingDir = df.workingDir
	img.Labels = df.labels
	return nil
}

type copyOp struct {
	srcs []string
	dest string
}

type dockerfile struct {
	copies     []copyOp
	entrypoint []string
	cmd        []string
	env        []string
	workingDir string
	labels     map[string]string
}

// parseDockerfile reads the instructions a darwin image can honour and refuses
// the ones it cannot -- chiefly RUN, which would need to execute a Darwin
// binary on a builder that has no Darwin to run it.
func parseDockerfile(content string) (*dockerfile, error) {
	df := &dockerfile{}
	sawFrom := false
	for _, line := range logicalLines(content) {
		instr, rest := split2(line)
		switch strings.ToUpper(instr) {
		case "FROM":
			base := strings.Fields(rest)
			if len(base) == 0 || !strings.EqualFold(base[0], "scratch") {
				return nil, fmt.Errorf("a darwin image must be `FROM scratch` (the OS comes from the node), not %q", rest)
			}
			sawFrom = true
		case "COPY", "ADD":
			c, err := parseCopy(rest)
			if err != nil {
				return nil, err
			}
			df.copies = append(df.copies, c)
		case "ENTRYPOINT":
			df.entrypoint = parseExecOrShell(rest)
		case "CMD":
			df.cmd = parseExecOrShell(rest)
		case "ENV":
			kv, err := parseEnv(rest)
			if err != nil {
				return nil, err
			}
			df.env = append(df.env, kv...)
		case "WORKDIR":
			df.workingDir = joinWorkdir(df.workingDir, strings.TrimSpace(rest))
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
		case "RUN":
			return nil, fmt.Errorf("RUN is not supported for a darwin image: a Linux builder cannot execute Darwin binaries. Build on the host and COPY the result in")
		case "ARG":
			return nil, fmt.Errorf("ARG is not supported for a darwin image yet")
		case "USER", "EXPOSE", "VOLUME", "STOPSIGNAL", "HEALTHCHECK", "SHELL", "MAINTAINER":
			// Recorded by neither ferry-darwin nor this format; ignore quietly.
		default:
			return nil, fmt.Errorf("unsupported instruction %q", instr)
		}
	}
	if !sawFrom {
		return nil, fmt.Errorf("no FROM: a darwin image must start with `FROM scratch`")
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

// parseEnv reads `ENV k=v k2=v2` and the legacy `ENV k v`, returning k=v
// strings.
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
	return strings.Fields(rest), nil
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

// fields splits a space-separated flag value, for -entrypoint in dir mode.
func fields(s string) []string { return strings.Fields(s) }
