#!/usr/bin/env bash
# `swift build -c release` for ferry's Swift packages, without the full rebuilds.
#
# Sourced by ferry-cri/build.sh, ferry-macvm/build.sh, ferry-gpud/build.sh and
# experiments/18-node-image/rebuild-tool.sh. Run from the package directory:
#
#   ferry_swift_build      # what "$SWIFT" build -c release did, minus the noise
#
# Swift 6.4 with the Command Line Tools recompiles an unchanged package from
# scratch on about one build in three: two minutes for ferry-cri, every time.
# swift-build registers the Command Line Tools twice, as
# com.apple.dt.toolchain.XcodeDefault and as a synthesized
# org.swift.CommandLineTools, and SwiftPM's lookup of "the toolchain at this
# path" returns whichever an unordered Set yields first. The answer becomes the
# build's TOOLCHAINS setting, TOOLCHAINS is hashed into the SDK stat cache path
# every compile command names, and a changed command line reruns every task.
# Same compiler, same SDK, same sources. swiftlang/swift-build#1861, fixed in
# swift-build#1872 for 6.4.x; this is for every toolchain before that ships.
#
# Both answers are cached as separate build descriptions, and a build records
# the one it chose in prior-build-descriptions.txt before it runs a single task.
# So: remember the TOOLCHAINS of the last build that finished, and when a new
# build plans with the other one, interrupt it before it compiles and ask again.
# A wrong draw costs about a second instead of minutes. Nothing here changes
# what is built or how; with a toolchain that always answers the same, the first
# build records the answer and every later one is a plain swift build.

# The two "search path not found" linker warnings the Command Line Tools produce
# on every link (they have no Developer/usr/lib or Developer/Library/Frameworks,
# and SwiftPM passes both anyway). Only those two go.
ferry_swift_build_filter() {
  grep -v "ld: warning: search path '/Library/Developer/CommandLineTools/Developer/[^']*' not found$" || true
}

ferry_swift_build_descriptions=.build/out/Intermediates.noindex/XCBuildData/prior-build-descriptions.txt

# TOOLCHAINS of the newest build description in this package's .build, or
# nothing when there is none (a first build, or a build system without them).
ferry_swift_build_toolchains() {
  local id
  id="$(tail -1 "$ferry_swift_build_descriptions" 2>/dev/null)" || return 0
  [ -n "$id" ] || return 0
  plutil -extract parameters.overrides.synthesized.table.TOOLCHAINS raw -o - \
    "${ferry_swift_build_descriptions%/*}/$id.xcbuilddata/build-request.json" 2>/dev/null || true
}

# Pass the accepted build's output on while it runs: every complete line of
# $1 as it appears, through the filter, then whatever is left once $2 exits.
# Whole lines only, so the filter never sees one in two pieces. (bash 3.2 and
# BSD tail: no tail --pid, so poll.)
ferry_swift_build_stream() { # output-file pid
  local done=0 n
  while kill -0 "$2" 2>/dev/null; do
    n="$(wc -l < "$1" | tr -d ' ')"
    if [ "$n" -gt "$done" ]; then
      sed -n "$((done + 1)),${n}p" "$1" | ferry_swift_build_filter
      done="$n"
    fi
    sleep 0.1
  done
  sed -n "$((done + 1)),\$p" "$1" | ferry_swift_build_filter
}

ferry_swift_build_lines() {
  if [ -f "$ferry_swift_build_descriptions" ]; then wc -l < "$ferry_swift_build_descriptions" | tr -d ' '; else echo 0; fi
}

ferry_swift_build() { # [extra swift build arguments...]
  local swift="${SWIFT:-swift}" marker=.build/ferry-toolchains
  local want="" got out pid rc=0 attempt=1 tries="${FERRY_SWIFT_BUILD_TRIES:-12}" lines
  want="$(cat "$marker" 2>/dev/null || true)"
  out="$(mktemp "${TMPDIR:-/tmp}/ferry-swift-build.XXXXXX")" || return 1

  while :; do
    lines="$(ferry_swift_build_lines)"
    "$swift" build -c release "$@" > "$out" 2>&1 &
    pid=$!
    # A build that plans with a description other than the last one appends it
    # to prior-build-descriptions.txt, a fifth of a second before its first
    # task. One that reuses the last description appends nothing and goes on to
    # print its first "[n / m]" (spaced with a Unicode thin space, so only the
    # opening is matched). Whichever comes first, the build's TOOLCHAINS is then
    # the newest description's. With no expectation yet there is nothing to
    # check, so the build just runs.
    got=""
    if [ -n "$want" ]; then
      while kill -0 "$pid" 2>/dev/null; do
        if [ "$(ferry_swift_build_lines)" != "$lines" ] || LC_ALL=C grep -q '^\[[0-9]' "$out"; then
          got="$(ferry_swift_build_toolchains)"
          break
        fi
        sleep 0.01
      done
    fi
    if [ -n "$got" ] && [ "$got" != "$want" ] && [ "$attempt" -lt "$tries" ] \
        && kill -INT "$pid" 2>/dev/null; then
      # SwiftPM stops on SIGINT, as for Ctrl-C. Give it ten seconds to.
      local waited=0
      while kill -0 "$pid" 2>/dev/null && [ "$waited" -lt 1000 ]; do sleep 0.01; waited=$((waited + 1)); done
      kill -TERM "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      # Take back the line the interrupted build appended, so the next attempt
      # drawing the same wrong answer appends it again and is caught as early.
      if [ "$(ferry_swift_build_lines)" -gt "$lines" ]; then
        head -n "$lines" "$ferry_swift_build_descriptions" > "$out" \
          && cat "$out" > "$ferry_swift_build_descriptions"
      fi
      echo "  (swift build planned with TOOLCHAINS=$got, not $want, which recompiles everything: asking again; swift-build#1861)"
      attempt=$((attempt + 1))
      continue
    fi
    # Accepted: what it printed while planning, and the rest as it comes.
    ferry_swift_build_stream "$out" "$pid"
    rc=0; wait "$pid" || rc=$?
    break
  done

  rm -f "$out"
  if [ "$rc" = 0 ]; then
    got="$(ferry_swift_build_toolchains)"
    [ -z "$got" ] || [ "$got" = "$want" ] || printf '%s\n' "$got" > "$marker"
  fi
  return "$rc"
}
