# Security

Please report a vulnerability privately, through
[a GitHub security advisory](https://github.com/imaustink/ferry/security/advisories/new),
and not in a public issue.

Fixes go into the latest release. ferry is a local development cluster, and
its threat model is in the docs: what a pod can and cannot reach
([NETWORK-POLICY.md](docs/NETWORK-POLICY.md)), what a node may change
([GAPS.md](docs/GAPS.md#known-and-deliberate)), and the debug annotations
that remove a pod's isolation on purpose, which are ignored unless
`FERRY_NODE_MAC_DEBUG=1` ([INSTALL.md](docs/INSTALL.md)).
