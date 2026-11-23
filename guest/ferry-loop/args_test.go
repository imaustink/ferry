package main

import "testing"

func TestParseCommand(t *testing.T) {
	for _, c := range []struct {
		args []string
		ok   bool
		want command
	}{
		{[]string{"/a.ext4", "/mnt", "ro"}, true, command{op: "mount", file: "/a.ext4", target: "/mnt", readOnly: true}},
		{[]string{"/a.ext4", "/mnt", "rw"}, true, command{op: "mount", file: "/a.ext4", target: "/mnt"}},
		{[]string{"/a.ext4", "/mnt"}, false, command{}},
		{[]string{"/a.ext4", "/mnt", "rx"}, false, command{}},
		{[]string{"", "/mnt", "ro"}, false, command{}},
		{[]string{"/a.ext4", "/mnt", "ro", "extra"}, false, command{}},

		{[]string{"attach", "/a.ext4", "rw", "512"}, true, command{op: "attach", file: "/a.ext4", device: 512}},
		{[]string{"attach", "/a.ext4", "ro", "0"}, true, command{op: "attach", file: "/a.ext4", readOnly: true}},
		{[]string{"attach", "/a.ext4", "rw", "-1"}, false, command{}},
		{[]string{"attach", "/a.ext4", "rw", "x"}, false, command{}},
		{[]string{"attach", "/a.ext4", "rw"}, false, command{}},
		{[]string{"attach", "", "rw", "1"}, false, command{}},

		{[]string{"rm", "/run/volumes/scratch/3"}, true, command{op: "rm", target: "/run/volumes/scratch/3"}},
		{[]string{"rm", "/run/volumes/"}, false, command{}},
		{[]string{"rm", "/run/volumes"}, false, command{}},
		{[]string{"rm", "/run/volumes/../container"}, false, command{}},
		{[]string{"rm", "/run/volumes//x"}, false, command{}},
		{[]string{"rm", "/run/volumes/x/"}, false, command{}},
		{[]string{"rm", "/etc"}, false, command{}},
		{[]string{"rm", "run/volumes/x"}, false, command{}},
		{[]string{"rm"}, false, command{}},
	} {
		got, err := parseCommand(c.args)
		if (err == nil) != c.ok {
			t.Errorf("%q: err = %v, want ok=%v", c.args, err, c.ok)
			continue
		}
		if c.ok && got != c.want {
			t.Errorf("%q: got %+v, want %+v", c.args, got, c.want)
		}
	}
}
