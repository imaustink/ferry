package main

import (
	"encoding/json"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
)

// This is ferry-mkimage's Dockerfile subset (see ../../ferry-mkimage/dockerfile.go)
// with one difference: RUN is accepted, and instructions are kept in the
// order they appear instead of being sorted into separate slices, because a
// COPY after a RUN must only see that RUN's output, and a RUN after a COPY
// must see it. Everything else -- ENTRYPOINT/CMD/LABEL as final-state fields,
// the same COPY semantics, the same exec/shell-form parsing -- is unchanged.

type copyOp struct {
	srcs []string
	dest string
}

// step is one instruction that can affect the filesystem or the environment a
// later RUN sees: copy, run, env or workdir. FROM/ENTRYPOINT/CMD/LABEL do not
// interleave with anything, so they stay as plain final-state fields below.
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
}

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
		return nil, fmt.Errorf("no FROM: a darwin image must start with `FROM scratch`")
	}
	return df, nil
}

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
			continue
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

// applyCopy copies each source (relative to context) into root at dest, the
// same rules ferry-mkimage uses.
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
