package main

import "testing"

func TestRunIsAccepted(t *testing.T) {
	df, err := parseDockerfile("FROM scratch\nRUN make\n")
	if err != nil {
		t.Fatalf("RUN should be accepted here (unlike ferry-mkimage's darwin build): %v", err)
	}
	if len(df.steps) != 1 || df.steps[0].kind != "run" {
		t.Fatalf("steps = %+v, want one run step", df.steps)
	}
	if got := df.steps[0].run; len(got) != 3 || got[0] != "/bin/sh" || got[1] != "-c" || got[2] != "make" {
		t.Errorf("RUN argv = %v, want [/bin/sh -c make]", got)
	}
}

func TestRunExecForm(t *testing.T) {
	df, err := parseDockerfile(`FROM scratch
RUN ["/bin/echo", "hi"]
`)
	if err != nil {
		t.Fatal(err)
	}
	got := df.steps[0].run
	want := []string{"/bin/echo", "hi"}
	if len(got) != len(want) || got[0] != want[0] || got[1] != want[1] {
		t.Errorf("argv = %v, want %v", got, want)
	}
}

// TestStepOrderPreserved is the change that matters: a COPY after a RUN and a
// RUN after a COPY must stay in the order they were written, not be sorted
// into "all copies, then everything else" the way a single-slice-per-kind
// design would.
func TestStepOrderPreserved(t *testing.T) {
	df, err := parseDockerfile(`FROM scratch
COPY a.txt a.txt
RUN echo one
COPY b.txt b.txt
RUN echo two
`)
	if err != nil {
		t.Fatal(err)
	}
	want := []string{"copy", "run", "copy", "run"}
	if len(df.steps) != len(want) {
		t.Fatalf("got %d steps, want %d: %+v", len(df.steps), len(want), df.steps)
	}
	for i, kind := range want {
		if df.steps[i].kind != kind {
			t.Errorf("step %d kind = %q, want %q", i, df.steps[i].kind, kind)
		}
	}
}

func TestEnvAndWorkdirInterleave(t *testing.T) {
	df, err := parseDockerfile(`FROM scratch
ENV FOO=1
WORKDIR /app
RUN echo $FOO
ENV FOO=2
RUN echo $FOO
`)
	if err != nil {
		t.Fatal(err)
	}
	var kinds []string
	for _, s := range df.steps {
		kinds = append(kinds, s.kind)
	}
	want := []string{"env", "workdir", "run", "env", "run"}
	if len(kinds) != len(want) {
		t.Fatalf("kinds = %v, want %v", kinds, want)
	}
	for i := range want {
		if kinds[i] != want[i] {
			t.Errorf("step %d = %q, want %q", i, kinds[i], want[i])
		}
	}
}

func TestNonScratchFromRejected(t *testing.T) {
	if _, err := parseDockerfile("FROM alpine\n"); err == nil {
		t.Fatal("non-scratch FROM should be rejected")
	}
}

func TestArgStillRejected(t *testing.T) {
	if _, err := parseDockerfile("FROM scratch\nARG X=1\n"); err == nil {
		t.Fatal("ARG should still be rejected")
	}
}

func TestUnsupportedInstructionRejected(t *testing.T) {
	if _, err := parseDockerfile("FROM scratch\nNOTAREALINSTRUCTION x\n"); err == nil {
		t.Fatal("an unknown instruction should be rejected")
	}
}
