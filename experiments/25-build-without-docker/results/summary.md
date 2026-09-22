
### tiny

| | ferry (2 cpu, 512 MiB) | ferry (8 cpu, 4 GiB) | Docker Desktop | colima |
|:--|--:|--:|--:|--:|
| cold build | 1.70 s | 1.92 s | 1.91 s | 1.67 s |
| export | 0.37 s | 0.28 s | 0.33 s | 0.27 s |
| load | 0.13 s | 0.09 s | 0.10 s | 0.10 s |
| incremental build | 0.30 s | 0.26 s | 0.30 s | 0.24 s |
| export | 0.27 s | 0.29 s | 0.28 s | 0.31 s |
| load | 0.09 s | 0.09 s | 0.11 s | 0.09 s |
| no-op rebuild | 0.28 s | 0.29 s | 0.23 s | 0.27 s |
| **cold, end to end** | 2.20 s | 2.29 s | 2.35 s | 2.03 s |
| **incremental, end to end** | 0.66 s | 0.65 s | 0.68 s | 0.64 s |

### node

| | ferry (2 cpu, 512 MiB) | ferry (8 cpu, 4 GiB) | Docker Desktop | colima |
|:--|--:|--:|--:|--:|
| cold build | 16.78 s | 7.59 s | 7.98 s | 7.77 s |
| export | 1.82 s | 1.83 s | 1.85 s | 1.90 s |
| load | 0.97 s | 0.17 s | 0.33 s | 0.18 s |
| incremental build | 0.28 s | 0.25 s | 0.32 s | 0.32 s |
| export | 0.43 s | 0.45 s | 0.36 s | 0.48 s |
| load | 0.13 s | 0.16 s | 0.21 s | 0.17 s |
| no-op rebuild | 0.26 s | 0.39 s | 0.40 s | 0.31 s |
| **cold, end to end** | 19.58 s | 9.59 s | 10.16 s | 9.86 s |
| **incremental, end to end** | 0.84 s | 0.86 s | 0.90 s | 0.96 s |

### fat

| | ferry (2 cpu, 512 MiB) | ferry (8 cpu, 4 GiB) | Docker Desktop | colima |
|:--|--:|--:|--:|--:|
| cold build | 23.31 s | 19.96 s | 18.93 s | 18.70 s |
| export | 3.93 s | 3.52 s | 3.51 s | 3.89 s |
| load | 4.61 s | 0.51 s | 0.76 s | 0.52 s |
| incremental build | 0.22 s | 0.23 s | 0.21 s | 0.19 s |
| export | 1.16 s | 0.84 s | 0.78 s | 1.24 s |
| load | 0.53 s | 0.43 s | 0.58 s | 0.43 s |
| no-op rebuild | 0.22 s | 0.28 s | 0.21 s | 0.18 s |
| **cold, end to end** | 31.85 s | 23.99 s | 23.20 s | 23.11 s |
| **incremental, end to end** | 1.90 s | 1.50 s | 1.57 s | 1.87 s |

### What it costs to keep a builder available

| | host MiB | in-guest MiB |
|:--|--:|--:|
| ferry, a buildkitd pod | 329.9 | - |
| Docker Desktop's VM | 1740.8 | 606 |
| colima's VM | 1024.0 | 261 |
