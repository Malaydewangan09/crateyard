package main

/*
#include <libproc.h>
#include <sys/resource.h>

// Private but exported by libsystem. Every VM runs in the same Virtualization XPC binary,
// so this is how crateyardd tells its own VM apart from Docker Desktop's or Colima's.
extern pid_t responsibility_get_pid_responsible_for_pid(pid_t);

static unsigned long long footprint(int pid) {
	struct rusage_info_v4 ri;
	if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&ri) != 0) return 0;
	return ri.ri_phys_footprint;
}
*/
import "C"

import (
	"os"
	"path/filepath"
	"unsafe"
)

const vmServiceName = "com.apple.Virtualization.VirtualMachine"

// vmFootprint is the physical memory macOS charges for this crateyardd's VM, the number Activity Monitor shows. It returns 0 if the VM process is not found.
func vmFootprint() uint64 {
	self := C.responsibility_get_pid_responsible_for_pid(C.pid_t(os.Getpid()))
	n := C.proc_listallpids(nil, 0)
	if n <= 0 {
		return 0
	}
	pids := make([]C.int, int(n)+64)
	n = C.proc_listallpids(unsafe.Pointer(&pids[0]), C.int(len(pids))*C.int(unsafe.Sizeof(pids[0])))
	var total uint64
	path := make([]byte, C.PROC_PIDPATHINFO_MAXSIZE)
	for _, pid := range pids[:max(n, 0)] {
		if pid <= 0 {
			continue
		}
		size := C.proc_pidpath(pid, unsafe.Pointer(&path[0]), C.uint32_t(len(path)))
		if size <= 0 || filepath.Base(string(path[:size])) != vmServiceName {
			continue
		}
		if C.responsibility_get_pid_responsible_for_pid(C.pid_t(pid)) == self {
			total += uint64(C.footprint(pid))
		}
	}
	return total
}
