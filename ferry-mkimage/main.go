// ferry-mkimage writes a directory or a small Dockerfile into a one-layer
// darwin/arm64 OCI image layout, the format ferry's image store keys what it
// serves.
//
//	ferry-mkimage -name example.com/app-darwin:1 -out LAYOUT -dir ROOT [-entrypoint /bin/app]
//	ferry-mkimage -name example.com/app-darwin:1 -out LAYOUT -f Dockerfile -context DIR
//
// A darwin image holds only the workload's own files. The OS it links against
// -- dyld and the shared cache -- comes from the node, because Apple's signed
// binaries are trusted where the OS put them and killed anywhere else. So a
// darwin image is FROM macos plus COPY: the node is the base, nothing to run.
// An optional tag, FROM macos:26, pins the macOS major the image expects; with
// -node-macos set, a mismatch fails the build before any builder VM boots.
//
// There can still be a RUN, though: not run here (this is a plain Go binary;
// still no Darwin to run a Darwin binary on), but in a macOS VM cloned from
// the same golden bundle FERRY_MAC_IMAGE already points machines at. -golden
// and -macvm say where that VM and its driver come from; a Dockerfile with no
// RUN never starts one. See docs/RUNTIMES.md#building-the-image and
// experiments/40-mac-build-run/FINDINGS.md for how, and what it costs.
package main

import (
	"flag"
	"fmt"
	"log"
	"os"
)

func main() {
	log.SetFlags(0)
	name := flag.String("name", "", "full image reference, e.g. example.com/app-darwin:1")
	out := flag.String("out", "", "OCI layout directory to write")
	dir := flag.String("dir", "", "directory to package as the image's root (dir mode)")
	entrypoint := flag.String("entrypoint", "", "entrypoint, space separated (dir mode)")
	dockerfile := flag.String("f", "", "Dockerfile to build from (Dockerfile mode)")
	context := flag.String("context", ".", "build context the Dockerfile's COPY reads from")
	golden := flag.String("golden", "", "a macOS VM bundle RUN executes in, e.g. $FERRY_MAC_IMAGE (only needed if the Dockerfile has RUN)")
	macvmPath := flag.String("macvm", "", "path to the ferry-macvm binary (only needed if the Dockerfile has RUN)")
	nodeMacOS := flag.Int("node-macos", 0, "macOS major of the golden image, to check a `FROM macos:<major>` pin (0 = unknown, skip)")
	flag.Parse()

	if *name == "" || *out == "" || (*dir == "" && *dockerfile == "") {
		flag.Usage()
		os.Exit(2)
	}
	if *dir != "" && *dockerfile != "" {
		log.Fatal("give -dir or -f, not both")
	}

	img := &image{Name: *name}
	if *dir != "" {
		img.RootFS = *dir
		img.Entrypoint = fields(*entrypoint)
	} else {
		bc := builderConfig{golden: *golden, macvmPath: *macvmPath, nodeMacOS: *nodeMacOS}
		if err := buildFromDockerfile(img, *dockerfile, *context, bc); err != nil {
			log.Fatalf("%s: %v", *dockerfile, err)
		}
		defer os.RemoveAll(img.RootFS) // a staged copy of what COPY selected, and RUN built on
	}

	desc, err := writeLayout(img, *out)
	if err != nil {
		log.Fatal(err)
	}
	fmt.Printf("%s: darwin/arm64, layer %s (%d bytes), manifest %s\n",
		*name, desc.layer[:19], desc.size, desc.manifest[:19])
}
