# Crateyard

Runs Docker on a Mac in a small Linux VM, using Apple's Virtualization framework. The `docker` CLI works unchanged. A menu bar app shows memory, containers, ports, images and volumes. Work in progress.

What it does today:

- Boots an Alpine VM with stock dockerd in 3 to 4 seconds (2.8 to 4.2 s measured on an M4 Air).
- Keeps an idle VM small: macOS charges it about 0.6 GB on an M4 Air, with a memory balloon sizing the guest to what Linux uses.
- Sleeps after 5 minutes with no running containers. The VM stops and macOS gets all of its memory back. The next `docker` command wakes it in about 3 s. Images, volumes and stopped containers stay on disk.
- Forwards the Docker socket over vsock to `~/.crateyard/docker.sock`, and switches the docker CLI to a `crateyard` context while it runs. Quitting Crateyard switches back to the context you had before.
- Forwards published container ports to the Mac (`docker run -p 8080:80` answers on `localhost:8080`).
- Mounts `/Users` into the VM at the same path, so bind mounts work.
- Runs `fstrim` hourly so the data disk shrinks after images are deleted.

## Install

Needs an Apple silicon Mac, macOS 14 or later, and the `docker` command. Crateyard runs the engine, not the CLI. If you have never installed Docker Desktop, or removed it (its `docker` goes with it), get the CLI from Homebrew:

```sh
brew install docker docker-compose
```

Homebrew then prints one line to add to `~/.docker/config.json` so that `docker compose` finds the plugin. Add it.

```sh
curl -fsSL https://raw.githubusercontent.com/Malaydewangan09/crateyard/main/install.sh | sh
open -a Crateyard
```

The script downloads `Crateyard.zip` from the latest release, checks it against the published SHA-256, and copies Crateyard.app to /Applications. With the GitHub CLI logged in, it also checks that the zip was built by this repo's release workflow. Read it first, it is about 50 lines. On first launch Crateyard builds the VM, which downloads about 200 MB from Alpine Linux and takes a few minutes. Then press Start, and `docker` talks to Crateyard.

There is also a `Crateyard.dmg` on the releases page. Crateyard is not notarized by Apple, so a downloaded DMG opens only after System Settings > Privacy & Security > Open Anyway.

## Build from source

Needs Go and the Xcode command line tools.

```sh
git clone https://github.com/Malaydewangan09/crateyard && cd crateyard
./app/scripts/bundle.sh    # builds app/dist/Crateyard.app, with crateyardd inside
./app/scripts/dmg.sh       # optional: app/dist/Crateyard.dmg
```

Or run the engine alone, without the app:

```sh
./build.sh                 # builds bin/crateyardd, ad-hoc signed with the virtualization entitlement
./bin/crateyardd image         # one time: downloads Alpine and builds the VM disks in ~/.crateyard
./bin/crateyardd run           # starts the VM and switches the docker context, Ctrl-C stops both
docker run --rm hello-world
```

If Alpine's CDN is slow from your network, pick another mirror. The app's setup screen has the same option. The kernel and initramfs are checked against pinned SHA-256 hashes, so a mirror cannot swap them.

```sh
CRATEYARD_ALPINE_MIRROR=https://mirror.leaseweb.com/alpine ./bin/crateyardd image
```

## Limits

- While containers run, memory Linux has used stays with the VM, even after Linux frees it. Apple's virtio balloon does not report free pages, so only sleep (or Stop) gives it back.
- Docker Desktop's window polls the active docker context every few seconds, so Crateyard cannot sleep while Docker Desktop is open. Quit it to get sleep.
- Linux in the VM runs with `init_on_alloc=0`. Alpine zeroes memory on allocation by default, a hardening option, but zeroing writes every page and makes macOS back the whole VM.
- TCP port forwarding only. No UDP.
- Ports published on 0.0.0.0 listen on every network interface of the Mac, as with Docker Desktop. Publish with `-p 127.0.0.1:8080:80` to keep a port local.
- Ad-hoc signed, not notarized.
- One VM with 4 CPUs and up to half the Mac's memory, capped at 8 GB.
- Containers stopped by a VM shutdown stay stopped on the next boot unless they have a restart policy.

## How it works

See [PLAN.md](PLAN.md) for the architecture, benchmark plan and milestones.

## License

MIT. See [LICENSE](LICENSE).
