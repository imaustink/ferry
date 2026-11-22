package main

import "testing"

func TestParseArgs(t *testing.T) {
	for _, c := range []struct {
		args   []string
		ok, ro bool
	}{
		{[]string{"/a.ext4", "/mnt", "ro"}, true, true},
		{[]string{"/a.ext4", "/mnt", "rw"}, true, false},
		{[]string{"/a.ext4", "/mnt"}, false, false},
		{[]string{"/a.ext4", "/mnt", "rx"}, false, false},
		{[]string{"", "/mnt", "ro"}, false, false},
		{[]string{"/a.ext4", "/mnt", "ro", "extra"}, false, false},
	} {
		file, mountpoint, ro, err := parseArgs(c.args)
		if (err == nil) != c.ok {
			t.Errorf("%v: err = %v, want ok=%v", c.args, err, c.ok)
			continue
		}
		if c.ok && (file != c.args[0] || mountpoint != c.args[1] || ro != c.ro) {
			t.Errorf("%v: got %q %q ro=%v", c.args, file, mountpoint, ro)
		}
	}
}
