// Nothing here has source of its own. This module exists to pin the version of
// the upstream CNI plugins ferry builds and ships, and to keep their transitive
// dependencies -- netlink, iptables, dhcp -- out of ferry-cni's own module
// graph, where none of them would ever be linked.
//
// The plugins are built from it by path; see build.sh.
module github.com/imaustink/ferry/ferry-cni/upstream

go 1.24.2

require github.com/containernetworking/plugins v1.9.1
