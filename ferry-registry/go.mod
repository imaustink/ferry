module github.com/imaustink/ferry/ferry-registry

go 1.26.0

require github.com/imaustink/ferry/nodeauth v0.0.0

// Shared with ferry-netpol, in this repository rather than published.
replace github.com/imaustink/ferry/nodeauth => ../nodeauth
