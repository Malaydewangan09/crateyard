package main

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"crypto/sha256"
	_ "embed"
	"encoding/binary"
	"encoding/hex"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"path/filepath"
	"strconv"
	"strings"
	"time"
)

const (
	alpineBranch = "v3.24"
	// alpineRelease pins the netboot kernel and initramfs, so their hashes below stay valid.
	alpineRelease = "3.24.4"
	// defaultMirror is Alpine's CDN. CRATEYARD_ALPINE_MIRROR overrides it when the CDN is slow or unreachable from your network.
	defaultMirror = "https://dl-cdn.alpinelinux.org/alpine"
	rootDiskSize  = 4 << 30
	dataDiskSize  = 64 << 30
	outDiskSize   = 128 << 20
	setupTimeout  = 20 * time.Minute
)

// netbootSHA256 holds the hashes of Alpine's netboot files for alpineRelease, taken over HTTPS from dl-cdn.
// They are the root of trust: the initramfs carries the apk and modloop signing keys the guest then checks packages with.
var netbootSHA256 = map[string]string{
	"vmlinuz-virt":   "cd05fed9e617b5df93dc62ece9b78c422fd94e9b432a2f7c092714b139d5eef4",
	"initramfs-virt": "189402937646965374ef2df5d37f76467135179ae168c88175df2fe3e264a0b0",
}

//go:embed provision.sh
var provisionScript []byte

// buildImage boots a RAM-only Alpine that installs the root disk, then copies its kernel out.
// It keeps an existing data disk, since that holds every image, volume and container.
func buildImage(dir string) error {
	mirror, err := alpineMirror()
	if err != nil {
		return err
	}
	repo := mirror + "/" + alpineBranch
	netbootURL := repo + "/releases/aarch64/netboot-" + alpineRelease
	cache := filepath.Join(dir, "cache", alpineRelease)
	if err := os.MkdirAll(cache, 0o700); err != nil {
		return err
	}
	for name, sum := range netbootSHA256 {
		if err := download(netbootURL+"/"+name, filepath.Join(cache, name), sum); err != nil {
			return err
		}
	}
	// Removing the kernel first means a failed setup leaves no half-installed engine that run would try to boot.
	if err := os.Remove(filepath.Join(dir, "Image")); err != nil && !errors.Is(err, os.ErrNotExist) {
		return err
	}

	netbootKernel := filepath.Join(cache, "Image-netboot")
	if err := writeKernel(filepath.Join(cache, "vmlinuz-virt"), netbootKernel); err != nil {
		return err
	}
	rootDisk := filepath.Join(dir, "root.img")
	dataDisk := filepath.Join(dir, "data.img")
	outDisk := filepath.Join(cache, "out.img")
	_, statErr := os.Stat(dataDisk)
	isNewDataDisk := errors.Is(statErr, os.ErrNotExist)
	disks := map[string]int64{rootDisk: rootDiskSize, outDisk: outDiskSize}
	if isNewDataDisk {
		disks[dataDisk] = dataDiskSize
	}
	for path, size := range disks {
		if err := sparseFile(path, size); err != nil {
			return err
		}
	}
	setupInitrd := filepath.Join(cache, "initramfs-setup")
	if err := writeSetupInitrd(filepath.Join(cache, "initramfs-virt"), setupInitrd, repo, isNewDataDisk); err != nil {
		return err
	}

	cmdline := strings.Join([]string{
		"console=hvc0",
		"ip=dhcp",
		"alpine_repo=" + repo + "/main",
		"modloop=" + netbootURL + "/modloop-virt",
		"modules=loop,squashfs,virtio_net",
		"apkovl=/crateyard.apkovl.tar.gz",
	}, " ")
	vm, err := newMachine(machineSpec{
		kernel:  netbootKernel,
		initrd:  setupInitrd,
		cmdline: cmdline,
		cpus:    2,
		memory:  2 << 30,
		disks:   []string{rootDisk, dataDisk, outDisk},
		console: os.Stdout,
	})
	if err != nil {
		return err
	}
	if err := vm.Start(); err != nil {
		return fmt.Errorf("start setup machine: %w", err)
	}
	stopped := make(chan error, 1)
	go func() { stopped <- waitStopped(vm) }()
	select {
	case err := <-stopped:
		if err != nil {
			return err
		}
	case <-time.After(setupTimeout):
		_ = vm.Stop()
		return fmt.Errorf("setup did not finish within %v, check your network and run it again", setupTimeout)
	}
	return extractBootFiles(outDisk, dir)
}

// download fetches url to dest unless a file with the expected SHA-256 is already there, and rejects any other content.
func download(url, dest, sum string) error {
	if fileSHA256(dest) == sum {
		return nil
	}
	client := http.Client{Timeout: 5 * time.Minute}
	resp, err := client.Get(url)
	if err != nil {
		return fmt.Errorf("download %s: %w", url, err)
	}
	defer resp.Body.Close()
	if resp.StatusCode != http.StatusOK {
		return fmt.Errorf("download %s: server returned %s", url, resp.Status)
	}
	tmp := dest + ".part"
	f, err := os.Create(tmp)
	if err != nil {
		return err
	}
	defer os.Remove(tmp)
	h := sha256.New()
	if _, err := io.Copy(io.MultiWriter(f, h), resp.Body); err != nil {
		f.Close()
		return fmt.Errorf("download %s: %w", url, err)
	}
	if err := f.Close(); err != nil {
		return err
	}
	if got := hex.EncodeToString(h.Sum(nil)); got != sum {
		return fmt.Errorf("download %s: SHA-256 is %s, expected %s. The mirror served a different file, try another mirror", url, got, sum)
	}
	return os.Rename(tmp, dest)
}

func fileSHA256(path string) string {
	f, err := os.Open(path)
	if err != nil {
		return ""
	}
	defer f.Close()
	h := sha256.New()
	if _, err := io.Copy(h, f); err != nil {
		return ""
	}
	return hex.EncodeToString(h.Sum(nil))
}

func sparseFile(path string, size int64) error {
	f, err := os.OpenFile(path, os.O_RDWR|os.O_CREATE|os.O_TRUNC, 0o600)
	if err != nil {
		return err
	}
	defer f.Close()
	return f.Truncate(size)
}

// writeKernel unpacks an arm64 EFI zboot image, because VZLinuxBootLoader only boots a raw Image.
func writeKernel(src, dest string) error {
	raw, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	image, err := unpackZboot(raw)
	if err != nil {
		return fmt.Errorf("unpack kernel %s: %w", src, err)
	}
	return os.WriteFile(dest, image, 0o644)
}

func unpackZboot(raw []byte) ([]byte, error) {
	if len(raw) < 64 || string(raw[4:8]) != "zimg" {
		return raw, nil
	}
	offset := binary.LittleEndian.Uint32(raw[8:12])
	size := binary.LittleEndian.Uint32(raw[12:16])
	compression := strings.TrimRight(string(raw[24:32]), "\x00")
	if compression != "gzip" {
		return nil, fmt.Errorf("kernel payload uses %q compression, only gzip is supported", compression)
	}
	if uint64(offset)+uint64(size) > uint64(len(raw)) {
		return nil, errors.New("kernel payload extends past the end of the file")
	}
	zr, err := gzip.NewReader(bytes.NewReader(raw[offset : offset+size]))
	if err != nil {
		return nil, err
	}
	return io.ReadAll(zr)
}

// writeSetupInitrd appends a second initramfs archive holding the apkovl, which Alpine's init loads via apkovl=/path.
func writeSetupInitrd(src, dest, repo string, shouldFormatData bool) error {
	base, err := os.ReadFile(src)
	if err != nil {
		return err
	}
	ovl, err := apkovl(repo, shouldFormatData)
	if err != nil {
		return err
	}
	var archive bytes.Buffer
	zw := gzip.NewWriter(&archive)
	if err := writeCpio(zw, "crateyard.apkovl.tar.gz", ovl); err != nil {
		return err
	}
	if err := zw.Close(); err != nil {
		return err
	}
	return os.WriteFile(dest, append(base, archive.Bytes()...), 0o644)
}

func apkovl(repo string, shouldFormatData bool) ([]byte, error) {
	var buf bytes.Buffer
	zw := gzip.NewWriter(&buf)
	tw := tar.NewWriter(zw)
	now := time.Now()

	dirs := []string{"etc", "etc/apk", "etc/network", "etc/local.d", "etc/runlevels", "etc/runlevels/boot", "etc/runlevels/default"}
	for _, d := range dirs {
		if err := tw.WriteHeader(&tar.Header{Name: d + "/", Typeflag: tar.TypeDir, Mode: 0o755, ModTime: now}); err != nil {
			return nil, err
		}
	}
	files := []struct {
		name string
		mode int64
		body string
	}{
		{"etc/hostname", 0o644, "crateyard-setup\n"},
		{"etc/.default_boot_services", 0o644, ""},
		{"etc/network/interfaces", 0o644, "auto lo\niface lo inet loopback\n\nauto eth0\niface eth0 inet dhcp\n"},
		{"etc/apk/repositories", 0o644, repo + "/main\n" + repo + "/community\n"},
		{"etc/apk/world", 0o644, "alpine-base\ne2fsprogs\n"},
		{"etc/local.d/crateyard.start", 0o755, strings.NewReplacer("@ALPINE_REPO@", repo, "@FORMAT_DATA@", strconv.FormatBool(shouldFormatData)).Replace(string(provisionScript))},
	}
	for _, f := range files {
		if err := tw.WriteHeader(&tar.Header{Name: f.name, Typeflag: tar.TypeReg, Mode: f.mode, Size: int64(len(f.body)), ModTime: now}); err != nil {
			return nil, err
		}
		if _, err := tw.Write([]byte(f.body)); err != nil {
			return nil, err
		}
	}
	links := map[string]string{
		"etc/runlevels/default/local":   "/etc/init.d/local",
		"etc/runlevels/boot/networking": "/etc/init.d/networking",
	}
	for name, target := range links {
		if err := tw.WriteHeader(&tar.Header{Name: name, Typeflag: tar.TypeSymlink, Linkname: target, Mode: 0o777, ModTime: now}); err != nil {
			return nil, err
		}
	}
	if err := tw.Close(); err != nil {
		return nil, err
	}
	if err := zw.Close(); err != nil {
		return nil, err
	}
	return buf.Bytes(), nil
}

// writeCpio writes a single-file newc archive, the format the Linux initramfs loader expects.
func writeCpio(w io.Writer, name string, body []byte) error {
	entry := func(ino int, mode uint32, name string, body []byte) error {
		header := fmt.Sprintf("070701%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X%08X",
			ino, mode, 0, 0, 1, 0, len(body), 0, 0, 0, 0, len(name)+1, 0)
		if _, err := io.WriteString(w, header+name+"\x00"); err != nil {
			return err
		}
		if err := pad(w, len(header)+len(name)+1); err != nil {
			return err
		}
		if _, err := w.Write(body); err != nil {
			return err
		}
		return pad(w, len(body))
	}
	if err := entry(1, 0o100644, name, body); err != nil {
		return err
	}
	return entry(0, 0, "TRAILER!!!", nil)
}

func pad(w io.Writer, n int) error {
	if rem := n % 4; rem != 0 {
		_, err := w.Write(make([]byte, 4-rem))
		return err
	}
	return nil
}

// extractBootFiles reads the kernel and initramfs the guest wrote to the out disk as a raw tar stream.
func extractBootFiles(outDisk, dir string) error {
	f, err := os.Open(outDisk)
	if err != nil {
		return err
	}
	defer f.Close()
	tr := tar.NewReader(f)
	var kernel, initramfs []byte
	for {
		h, err := tr.Next()
		if errors.Is(err, io.EOF) {
			break
		}
		if err != nil {
			return fmt.Errorf("read boot files from setup disk: %w", err)
		}
		body, err := io.ReadAll(tr)
		if err != nil {
			return err
		}
		switch h.Name {
		case "vmlinuz-virt":
			image, err := unpackZboot(body)
			if err != nil {
				return err
			}
			kernel = image
		case "initramfs-virt":
			initramfs = body
		}
	}
	if kernel == nil || initramfs == nil {
		return errors.New("setup did not finish: kernel or initramfs missing from the setup disk, check the console output above")
	}
	// The kernel goes last: run treats its presence as a finished install.
	if err := os.WriteFile(filepath.Join(dir, "initramfs"), initramfs, 0o644); err != nil {
		return err
	}
	return os.WriteFile(filepath.Join(dir, "Image"), kernel, 0o644)
}

// alpineMirror returns the Alpine mirror without a trailing slash. It goes into a kernel command line and a shell script, so only plain URLs pass.
func alpineMirror() (string, error) {
	m := strings.TrimRight(os.Getenv("CRATEYARD_ALPINE_MIRROR"), "/")
	if m == "" {
		return defaultMirror, nil
	}
	u, err := url.Parse(m)
	isSafe := strings.IndexFunc(m, func(r rune) bool {
		return !(r >= 'a' && r <= 'z' || r >= 'A' && r <= 'Z' || r >= '0' && r <= '9' || strings.ContainsRune("-._~:/%", r))
	}) < 0
	if err != nil || (u.Scheme != "http" && u.Scheme != "https") || u.Host == "" || !isSafe {
		return "", fmt.Errorf("CRATEYARD_ALPINE_MIRROR %q is not a plain http or https URL, use one like https://dl-cdn.alpinelinux.org/alpine", m)
	}
	return m, nil
}
