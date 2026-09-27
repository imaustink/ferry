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
// darwin image is FROM scratch plus COPY: there is no base to run, and no RUN
// to run it -- build steps happen on the Mac, and the image only packages the
// result.
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
		if err := buildFromDockerfile(img, *dockerfile, *context); err != nil {
			log.Fatalf("%s: %v", *dockerfile, err)
		}
		defer os.RemoveAll(img.RootFS) // a staged copy of what COPY selected
	}

	desc, err := writeLayout(img, *out)
	if err != nil {
		log.Fatal(err)
	}
	fmt.Printf("%s: darwin/arm64, layer %s (%d bytes), manifest %s\n",
		*name, desc.layer[:19], desc.size, desc.manifest[:19])
}
