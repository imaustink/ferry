# Addons

Manifests ferry can apply on request. `ferry addons enable <name>` applies one,
`disable` removes it, `list` says which are on.

An addon is a directory holding YAML and, optionally, a `NOTES` file printed
after it is enabled. Nothing here is special to ferry — these are ordinary
Kubernetes manifests, kept in the repo so a laptop cluster can have the two or
three things everybody wants without hunting for them.

`__CLUSTER_DNS__` and `__NODE_NAME__` are substituted when the addon is applied.
