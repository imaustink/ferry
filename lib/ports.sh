#!/usr/bin/env bash
# Which ports an added node holds.
#
# Sourced by ferry and by tests/ports-test.sh, which is the point: the
# allocation is arithmetic, and arithmetic that lives inline in a five-thousand
# line script is arithmetic nobody checks. Before this file the added-node
# ports were three bases advancing at three different strides, and all three
# collided with something:
#
#   kubelet  10250 + shift + index        node 7 asked for 10257, which is
#                                         kube-controller-manager's, on a
#                                         default profile with no second
#                                         checkout anywhere near
#   healthz  10248 + shift + index * 100  a hundred a node, so node 8 was
#                                         already inside the next profile's
#                                         thousand and node 10's port was that
#                                         profile's own healthz
#   stream   10350 + index                no shift at all, so every profile's
#                                         node 1 asked for 10351 and the second
#                                         checkout to start a node lost
#
# A profile is a thousand ports -- everything ferry binds is some base plus
# PROFILE_INDEX * 1000 -- so the question for any allocation is which residues
# of that thousand it takes. ferry up's own take 248, 250, 257, 259 and 350;
# etcd and the API server take 379, 380 and 443; the pod switch takes 472
# through 672, one per node; the machine switch takes 700. The largest run left
# is 701 through 999.
#
# Three consecutive ports a node out of that run is ninety-nine nodes, which is
# where FERRY_MAX_NODES comes from. It is arithmetic rather than a guess at
# what a Mac will carry, and it is the first honest number here: the limit it
# replaces was two hundred, which the kubelet port had already broken at seven.

# shellcheck disable=SC2034 # read by ferry, which sources this file
# The most added nodes one profile has room for.
FERRY_MAX_NODES=99

# Scans go wider than the cap deliberately. A cluster started before the cap
# came down can hold a higher index, and walking past one of its kubelets
# without stopping it is worse than a hundred stats that find nothing.
# shellcheck disable=SC2034 # read by ferry, which sources this file
FERRY_MAX_NODE_SCAN=200

# The bottom of the run. Node 1 takes 10701-10703, node 99 ends at 10997.
FERRY_NODE_PORT_BASE=10701

# ferry_node_ports <port-shift> <index> -- prints "kubelet healthz streamer".
#
# One block of three rather than three numbers from three formulas, so that
# "does node N fit inside its profile" is answered by looking at node N alone.
ferry_node_ports() {
  local base=$(( FERRY_NODE_PORT_BASE + $1 + ($2 - 1) * 3 ))
  echo "$base $(( base + 1 )) $(( base + 2 ))"
}
