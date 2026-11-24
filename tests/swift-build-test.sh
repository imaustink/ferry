#!/usr/bin/env bash
# Tests for lib/swift-build.sh, against a stand-in for swift.
#
# Swift 6.4 with the Command Line Tools plans each build with one of two
# TOOLCHAINS values, at random, and a build that drew the other value from last
# time recompiles everything (swiftlang/swift-build#1861). ferry_swift_build
# interrupts such a build before its first task and asks again. The stand-in
# plans the way swift-build does -- it records a build description in
# prior-build-descriptions.txt when it differs from the last one, then starts
# its tasks -- and draws its TOOLCHAINS from a script, so each case is exact.
#
#   ./tests/swift-build-test.sh
set -uo pipefail

here="$(cd "$(dirname "$0")" && pwd)"
repo="$(cd "$here/.." && pwd)"

pass=0; fail=0
ok()   { pass=$((pass + 1)); printf '  \033[32m✓\033[0m %s\n' "$1"; }
bad()  { fail=$((fail + 1)); printf '  \033[31m✗\033[0m %s\n' "$1"; }
is() { # description actual expected
  if [ "$2" = "$3" ]; then ok "$1"; else bad "$1"; echo "      got:  '$2'"; echo "      want: '$3'"; fi
}
contains() { # description haystack needle
  case "$2" in *"$3"*) ok "$1" ;; *) bad "$1"; echo "      '$2' does not contain '$3'" ;; esac
}
lacks() { # description haystack needle
  case "$2" in *"$3"*) bad "$1"; echo "      '$2' contains '$3'" ;; *) ok "$1" ;; esac
}
bold() { printf '\033[1m%s\033[0m\n' "$1"; }

sandbox="$(mktemp -d)"
trap 'rm -rf "$sandbox"' EXIT

# The stand-in. Perl, not bash: a build ferry_swift_build starts runs in the
# background, where a shell ignores SIGINT and cannot be made to take it back;
# swift installs its own handler, and so does this.
cat > "$sandbox/swift" <<'STUB'
#!/usr/bin/perl
use strict; use warnings; use Time::HiRes qw(sleep);
my ($draws, $log) = ($ENV{STUB_DRAWS}, $ENV{STUB_LOG});
open(my $fh, '<', $draws) or die; my @d = <$fh>; close $fh;
my $draw = shift @d; chomp $draw;
open($fh, '>', $draws) or die; print $fh @d; close $fh;
my $data = '.build/out/Intermediates.noindex/XCBuildData';
system('mkdir', '-p', "$data/$draw.xcbuilddata");
open($fh, '>', "$data/$draw.xcbuilddata/build-request.json") or die;
print $fh qq({"parameters":{"overrides":{"synthesized":{"table":{"TOOLCHAINS":"$draw \$(inherited)"}}}}});
close $fh;
sub note { open(my $l, '>>', $log) or die; print $l "$_[0]\n"; close $l; }
$SIG{INT} = sub { note("interrupted $draw"); exit 130 };
$| = 1;
sleep 0.2;                                   # planning
my $last = '';
if (open($fh, '<', "$data/prior-build-descriptions.txt")) { while (<$fh>) { chomp; $last = $_ } close $fh }
if ($last ne $draw) { open($fh, '>>', "$data/prior-build-descriptions.txt") or die; print $fh "$draw\n"; close $fh }
sleep 0.2;                                   # the description is recorded before any task
print "Building for production...\n";
print "[1\x{e2}\x{80}\x{af}/\x{e2}\x{80}\x{af}2] Compiling\n";
sleep 0.4;
print "x: ld: warning: search path '/Library/Developer/CommandLineTools/Developer/usr/lib' not found\n";
if (($ENV{STUB_FAIL} // '') eq '1') { note("failed $draw"); print "error: boom\n"; exit 1 }
note("built $draw");
print "Build complete!\n";
STUB
chmod +x "$sandbox/swift"

# shellcheck source=../lib/swift-build.sh
. "$repo/lib/swift-build.sh"

# build <draws...>: one ferry_swift_build in the package, the stand-in drawing
# each TOOLCHAINS in turn. Sets $out, $rc and $log.
pkg="$sandbox/pkg"; mkdir -p "$pkg"
build() {
  printf '%s\n' "$@" > "$sandbox/draws"; : > "$sandbox/log"
  out="$(cd "$pkg" && SWIFT="$sandbox/swift" STUB_DRAWS="$sandbox/draws" STUB_LOG="$sandbox/log" \
    ferry_swift_build 2>&1)"; rc=$?
  log="$(tr '\n' ' ' < "$sandbox/log" | sed 's/ $//')"
}
marker() { cat "$pkg/.build/ferry-toolchains" 2>/dev/null; }
newest() { tail -1 "$pkg/.build/out/Intermediates.noindex/XCBuildData/prior-build-descriptions.txt"; }

bold "the first build has nothing to keep to, and records what it drew"
build A
is "it built, with A"            "$rc $log"   "0 built A"
is "A is what later builds keep" "$(marker)"  'A $(inherited)'
contains "its output is passed on" "$out" "Build complete!"
lacks "without the linker's noise" "$out" "ld: warning: search path"

bold "a build that draws the same is left alone"
build A
is "built once, with A" "$rc $log" "0 built A"
lacks "nothing is retried" "$out" "asking again"

bold "a build that draws the other one is stopped before it compiles, and asked again"
build B B A
is "B twice interrupted, then built with A" "$rc $log" "0 interrupted B interrupted B built A"
contains "says why"                           "$out" "TOOLCHAINS=B \$(inherited), not A \$(inherited)"
is "the expectation stays A"                  "$(marker)" 'A $(inherited)'
is "the interrupted draws' records are taken back" "$(newest)" "A"
is "so the description log ends where it began" \
  "$(tr '\n' ' ' < "$pkg/.build/out/Intermediates.noindex/XCBuildData/prior-build-descriptions.txt")" "A "

bold "after enough tries it builds with what it gets, and keeps to that"
FERRY_SWIFT_BUILD_TRIES=3 build B B B
is "two interrupted, the third built with B" "$rc $log" "0 interrupted B interrupted B built B"
is "B is now what later builds keep" "$(marker)" 'B $(inherited)'
build B
is "and the next B is left alone" "$rc $log" "0 built B"

bold "a failing build fails, with its output"
STUB_FAIL=1 build B
is "the failure comes back" "$rc $log" "1 failed B"
contains "with what the compiler said" "$out" "error: boom"

bold "the four Swift build scripts build through it"
for script in ferry-cri/build.sh ferry-macvm/build.sh ferry-gpud/build.sh experiments/18-node-image/rebuild-tool.sh; do
  if grep -q '^ferry_swift_build$' "$repo/$script" && ! grep -q '"\$SWIFT" build -c release 2>&1' "$repo/$script"; then
    ok "$script"
  else
    bad "$script still runs swift build itself"
  fi
done

echo
if [ "$fail" -eq 0 ]; then printf '\033[1m%s\033[0m\n' "$pass passed"
else printf '\033[1m%s\033[0m\n' "$fail of $((pass + fail)) failed"; exit 1; fi
