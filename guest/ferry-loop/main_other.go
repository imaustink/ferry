//go:build !linux

package main

import (
	"fmt"
	"os"
)

// ferry-loop runs inside a pod VM. Built for anything else, it only says so.
func main() {
	fmt.Fprintln(os.Stderr, "ferry-loop runs inside a linux pod VM; build it with GOOS=linux GOARCH=arm64")
	os.Exit(1)
}
