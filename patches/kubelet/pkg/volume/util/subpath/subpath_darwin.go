//go:build darwin

/*
Copyright 2014 The Kubernetes Authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

// subPath support on macOS.
//
// On Linux a subPath is a bind mount: the kubelet binds one path inside a
// volume onto the container's mount point, and has to unpick those mounts when
// the pod is finished. ferry has no bind mounts to make. A volume reaches a pod
// as a virtiofs share of a host directory, so a subPath is nothing more than a
// path within that directory, and the guest mounts it under its own name.
//
// That makes PrepareSafeSubpath a containment check rather than a mount, and
// CleanSubPaths genuinely empty -- there is nothing to take apart. Upstream's
// !linux && !windows fallback returns an error from every one of these, and the
// one that matters is CleanSubPaths: it is called on the teardown path, and a
// pod whose volumes never finish unmounting stays Terminating forever.
package subpath

import (
	"fmt"
	"os"
	"path/filepath"
	"strings"

	"k8s.io/mount-utils"
)

type subpath struct{}

// New returns a subpath.Interface for the current system.
func New(mount.Interface) Interface {
	return &subpath{}
}

// PrepareSafeSubpath resolves the subPath and refuses it if it leaves the
// volume. Nothing is mounted, so there is no cleanup to run afterwards.
//
// The containment check is the point of the "safe" in the name: the contents of
// a volume are under the user's control, so a symlink inside it must not be
// able to hand the container a path outside it.
func (sp *subpath) PrepareSafeSubpath(subPath Subpath) (newHostPath string, cleanupAction func(), err error) {
	resolved, err := containedPath(subPath.Path, subPath.VolumePath)
	if err != nil {
		return "", nil, err
	}
	return resolved, nil, nil
}

// CleanSubPaths has nothing to undo, because PrepareSafeSubpath mounted
// nothing. Returning nil is what lets a pod with a subPath finish terminating.
func (sp *subpath) CleanSubPaths(podDir string, volumeName string) error {
	return nil
}

// SafeMakeDir creates a directory, provided it lands inside base.
func (sp *subpath) SafeMakeDir(pathname string, base string, perm os.FileMode) error {
	if _, err := containedPath(pathname, base); err != nil {
		// A path that does not exist yet cannot escape by symlink at its final
		// component; check the deepest parent that does exist instead.
		if !os.IsNotExist(err) {
			return err
		}
	}
	if err := os.MkdirAll(pathname, perm); err != nil {
		return err
	}
	_, err := containedPath(pathname, base)
	return err
}

// containedPath resolves path and verifies it is base or lies beneath it, with
// every symlink already followed on both sides so neither can be used to point
// somewhere else.
func containedPath(path, base string) (string, error) {
	resolvedBase, err := filepath.EvalSymlinks(base)
	if err != nil {
		return "", fmt.Errorf("resolving volume path %q: %w", base, err)
	}

	resolved, err := filepath.EvalSymlinks(path)
	if err != nil {
		if !os.IsNotExist(err) {
			return "", fmt.Errorf("resolving subpath %q: %w", path, err)
		}
		// The leaf may not exist yet. Resolve as far as it does exist and check
		// that, so a symlinked parent still cannot escape.
		parent, resolveErr := deepestExisting(filepath.Dir(path))
		if resolveErr != nil {
			return "", resolveErr
		}
		if !within(parent, resolvedBase) {
			return "", fmt.Errorf("subpath %q escapes volume %q", path, base)
		}
		return path, err
	}

	if !within(resolved, resolvedBase) {
		return "", fmt.Errorf("subpath %q resolves to %q, outside volume %q", path, resolved, base)
	}
	return resolved, nil
}

// deepestExisting walks up until it finds a directory that exists and resolves
// that, so a path being created can still be checked for containment.
func deepestExisting(dir string) (string, error) {
	for {
		resolved, err := filepath.EvalSymlinks(dir)
		if err == nil {
			return resolved, nil
		}
		if !os.IsNotExist(err) {
			return "", err
		}
		parent := filepath.Dir(dir)
		if parent == dir {
			return "", fmt.Errorf("no existing parent of %q", dir)
		}
		dir = parent
	}
}

func within(path, base string) bool {
	return path == base || strings.HasPrefix(path, base+string(os.PathSeparator))
}
