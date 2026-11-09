# Crateyard plan

Open-source Docker Desktop replacement for macOS. Same `docker` commands, less RAM and disk. Status: boots in 2.8 to 4.2 s, `docker run`, port forwarding and the menu bar app work, releases install with `install.sh`. An idle VM costs macOS about 0.6 GB, and after 5 minutes with nothing running the VM sleeps and returns all of it. Open problem: memory Linux used while containers run is not returned until the VM sleeps.

## Why

On this Mac (M4 Air, 24 GB, macOS 15.5, Docker Desktop 4.50.0):

- `Docker.raw` is 494 GB apparent, 117 GB actually allocated on disk.
- Docker Desktop is usually kept off because it is heavy.
- Colima was installed as an escape (3.2 GB in `~/.colima`).

Docker Desktop is cross-platform, carries Kubernetes, extensions, Scout and AI features, and is built for enterprise sales. A Mac-only engine built on Apple's Virtualization.framework can be lighter. OrbStack proves it, but is closed source and paid for companies.

## Architecture

```
macOS
+---------------------------------------------------------------+
|  Crateyard.app  (Swift, SwiftUI)          later, not in MVP       |
|    menu bar + window                                           |
|    talks to crateyardd over ~/.crateyard/crateyardd.sock                   |
|    talks to Docker over ~/.crateyard/docker.sock                   |
+---------------------------------------------------------------+
|  crateyardd  (Go, Code-Hex/vz, user LaunchAgent, no root)          |
|    - creates and owns the VM                                   |
|    - ~/.crateyard/docker.sock  <-->  vsock  <-->  VM               |
|    - port forwarding  127.0.0.1:N  -->  VM                     |
|    - memory balloon target, clock resync after sleep           |
+-------------------------------+-------------------------------+
                                | virtio: vsock, virtiofs, net,
                                |         balloon, 2 disks
+-------------------------------v-------------------------------+
|  Linux VM  (small arm64 kernel + Alpine rootfs)                |
|    crateyard-agent  (Go, static)       later, not in MVP           |
|      - docker.sock <--> vsock                                  |
|      - reports published ports and real memory use             |
|      - runs fstrim so freed disk can shrink                    |
|    dockerd + containerd  (stock, unchanged)                    |
|    /Users mounted via virtiofs at the same path                |
|    disk 1: OS (replaceable)   disk 2: images and volumes       |
+---------------------------------------------------------------+
```

### Who runs where

| Piece | Runs on | Language | Job |
|---|---|---|---|
| Crateyard.app | macOS | Swift | Viewer and controls. Closing it does not stop containers. |
| crateyardd | macOS | Go | Owns the VM, connects the Mac to Docker inside it. |
| crateyard-agent | Linux VM | Go | Bridge to dockerd, reports what the Mac cannot see. |
| dockerd | Linux VM | stock | Runs containers. Not modified. |

The Mac cannot see inside the VM (memory, ports, free blocks), and the VM cannot touch the Mac (sockets, ports, RAM size). That is why there is one backend on each side.

### Request path for `docker ps`

```
docker ps (Mac)
  -> ~/.crateyard/docker.sock
  -> crateyardd
  -> vsock
  -> crateyard-agent            (MVP: dockerd listens on the VM address directly)
  -> /var/run/docker.sock
  -> dockerd
```

### Decisions

- **Own engine, not a UI over Lima or Colima.** Lima boots a full Ubuntu cloud image with cloud-init and forwards over SSH. That is the weight we are trying to remove. Lima's code is the reference for edge cases (sleep, clock drift, signing).
- **Backend in Go.** Code-Hex/vz is used by Lima in production. gvisor-tap-vsock (VPN-safe networking) and Docker's client libraries are Go.
- **UI in Swift.** Only SwiftUI gives a native Mac app.
- **Networking.** Apple NAT for the MVP. gvisor-tap-vsock before public release, because NAT breaks on some corporate VPNs.
- **Two disks.** OS updates replace disk 1 and never touch images on disk 2.

## MVP

Only enough to measure. No UI, no agent, no port forwarding.

1. Linux image: arm64 kernel, initramfs and an Alpine rootfs with dockerd.
2. `crateyardd` boots it with Code-Hex/vz: 4 CPU, memory balloon, NAT, virtiofs for `/Users`.
3. dockerd listens on the VM address. A `crateyard` docker context points at it.
4. `docker run hello-world` works from the Mac.

## Benchmark: Crateyard MVP vs Docker Desktop 4.50.0

Same settings for both: 4 CPU, 8 GB memory limit, Docker Desktop's Resource Saver left at its default. Only one engine runs at a time.

| # | Metric | How |
|---|---|---|
| 1 | Cold start | Time from start command until `docker info` succeeds. 3 runs, median. |
| 2 | Idle RAM | Memory footprint of the VM process (`com.apple.Virtualization.VirtualMachine`) 2 min after start, no containers. |
| 3 | RAM under load | Kestra + Postgres compose running, 5 min after `up`. |
| 4 | RAM given back | 5 min after `docker compose down`. |
| 5 | Disk grow | Allocated size (`du`) of the engine's disk image before and after pulling the same images. |
| 6 | Disk shrink | Allocated size after `docker rmi` + `docker system prune -af`. |
| 7 | Bind mount read | Time to read a fixed folder tree (`find` + `cat`) from a mounted `/Users` path inside a container. |

Run order: Docker Desktop first with its current data as is, then a fresh Docker Desktop reset for a fair disk test, then Crateyard.

### Pass or stop

Continue only if Crateyard wins clearly on at least two of:

- idle RAM at least 50% lower
- RAM returned after `down` (Docker Desktop keeps it)
- disk image shrinks after prune (Docker Desktop's does not)
- cold start under 5 s

If Docker Desktop 4.50 is within 20% on all of them, stop. The gap is not worth a product.

## Unknowns the MVP must answer

- Does an ad-hoc signed Go binary get `com.apple.security.virtualization` without a paid Apple account? Lima says yes. Blocker if no.
- Does Virtualization.framework pass TRIM through to a sparse raw image on APFS? If not, disk shrink needs offline compaction.
- How fast does the balloon return RAM to macOS in practice?
- Can the Linux image be built without Docker running on this Mac? Plan: build it in GitHub Actions, download the artifact.

## Not in v1

Kubernetes, full Linux machines, `*.crateyard.local` domains, Intel Macs, Windows and Linux hosts, team features.

## Milestones

1. MVP boots and passes `docker run hello-world`.
2. Benchmark table filled. Continue or stop.
3. Agent, port forwarding, Kestra compose runs unchanged.
4. Memory and disk reclaim.
5. Crateyard.app: menu bar, containers, logs, disk screen.
6. Two weeks of daily use for Kestra work.
7. Public release.

## Open

- Name "Crateyard" not checked for collisions.
- Pricing: open source first. A $5 signed build or a team license is decided after milestone 6.
