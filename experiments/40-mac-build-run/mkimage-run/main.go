// mkimage-run proves RUN can work for a `ferry image build --os darwin`
// image: it accepts the same Dockerfile subset as ferry-mkimage plus RUN,
// executing RUN (and shipping COPY) inside a real macOS VM through
// experiments/40-mac-build-run/macvm.swift's `build` mode, then packages the
// result as the same OCI layout ferry-mkimage writes (oci.go is an unmodified
// copy of it).
//
//	mkimage-run -name example.com/app-darwin:1 -out LAYOUT -f Dockerfile \
//	            -context DIR -golden BUNDLE [-macvm PATH]
//
// See FINDINGS.md for what this found and what would need to change in
// ferry-mkimage to ship this for real.
package main

import (
	"flag"
	"fmt"
	"log"
	"os"
	"strings"
)

func main() {
	log.SetFlags(0)
	name := flag.String("name", "", "full image reference, e.g. example.com/app-darwin:1")
	out := flag.String("out", "", "OCI layout directory to write")
	dockerfile := flag.String("f", "", "Dockerfile to build from")
	context := flag.String("context", ".", "build context COPY reads from")
	golden := flag.String("golden", "", "path to a golden macOS VM bundle (see experiments/39-macos-pods)")
	macvmPath := flag.String("macvm", "./build/macvm", "path to the macvm binary (this experiment's build/macvm)")
	flag.Parse()

	if *name == "" || *out == "" || *dockerfile == "" {
		flag.Usage()
		os.Exit(2)
	}

	img := &image{Name: *name}
	if err := buildFromDockerfile(img, *dockerfile, *context, *macvmPath, *golden); err != nil {
		log.Fatalf("%s: %v", *dockerfile, err)
	}
	defer os.RemoveAll(img.RootFS)

	desc, err := writeLayout(img, *out)
	if err != nil {
		log.Fatal(err)
	}
	fmt.Printf("%s: darwin/arm64, layer %s (%d bytes), manifest %s\n",
		*name, desc.layer[:19], desc.size, desc.manifest[:19])
}

// buildFromDockerfile walks df.steps in order -- the difference from
// ferry-mkimage's version of this function -- starting the builder VM lazily,
// on the first COPY or RUN, and only ever asking it for the whole build root
// once, at the end (pullRoot), after the last step has run.
func buildFromDockerfile(img *image, dockerfilePath, context, macvmPath, golden string) error {
	content, err := os.ReadFile(dockerfilePath)
	if err != nil {
		return err
	}
	df, err := parseDockerfile(string(content))
	if err != nil {
		return err
	}

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
		if golden == "" {
			return nil, fmt.Errorf("this Dockerfile needs a builder VM (COPY or RUN present) but -golden was not given")
		}
		nb, err := startMacBuilder(macvmPath, golden)
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
	for _, s := range df.steps {
		switch s.kind {
		case "copy":
			bd, err := ensure()
			if err != nil {
				return err
			}
			if err := pushCopy(bd, context, s.copy); err != nil {
				return fmt.Errorf("COPY %s: %w", strings.Join(append(append([]string{}, s.copy.srcs...), s.copy.dest), " "), err)
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

	root, err := os.MkdirTemp("", "mkimage-run-root-*")
	if err != nil {
		return err
	}
	img.RootFS = root
	if b != nil {
		if err := pullRoot(b, root); err != nil {
			return err
		}
	}

	img.Entrypoint = df.entrypoint
	img.Cmd = df.cmd
	img.Env = envList
	img.WorkingDir = workdir
	img.Labels = df.labels
	return nil
}
