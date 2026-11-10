package main

import (
	"fmt"
	"os"

	"github.com/Code-Hex/vz/v3"
)

type machineSpec struct {
	kernel  string
	initrd  string
	cmdline string
	cpus    uint
	memory  uint64
	disks   []string
	console *os.File
	share   string
	// isRosetta shares Apple's Rosetta with the guest, which registers it for amd64 binaries.
	isRosetta bool
}

func newMachine(s machineSpec) (*vz.VirtualMachine, error) {
	boot, err := vz.NewLinuxBootLoader(s.kernel, vz.WithCommandLine(s.cmdline), vz.WithInitrd(s.initrd))
	if err != nil {
		return nil, fmt.Errorf("create boot loader: %w", err)
	}
	cfg, err := vz.NewVirtualMachineConfiguration(boot, s.cpus, s.memory)
	if err != nil {
		return nil, fmt.Errorf("create machine configuration: %w", err)
	}

	stdin, err := os.Open(os.DevNull)
	if err != nil {
		return nil, err
	}
	serial, err := vz.NewFileHandleSerialPortAttachment(stdin, s.console)
	if err != nil {
		return nil, fmt.Errorf("attach console: %w", err)
	}
	console, err := vz.NewVirtioConsoleDeviceSerialPortConfiguration(serial)
	if err != nil {
		return nil, err
	}
	cfg.SetSerialPortsVirtualMachineConfiguration([]*vz.VirtioConsoleDeviceSerialPortConfiguration{console})

	nat, err := vz.NewNATNetworkDeviceAttachment()
	if err != nil {
		return nil, err
	}
	nic, err := vz.NewVirtioNetworkDeviceConfiguration(nat)
	if err != nil {
		return nil, err
	}
	mac, err := vz.NewRandomLocallyAdministeredMACAddress()
	if err != nil {
		return nil, err
	}
	nic.SetMACAddress(mac)
	cfg.SetNetworkDevicesVirtualMachineConfiguration([]*vz.VirtioNetworkDeviceConfiguration{nic})

	entropy, err := vz.NewVirtioEntropyDeviceConfiguration()
	if err != nil {
		return nil, err
	}
	cfg.SetEntropyDevicesVirtualMachineConfiguration([]*vz.VirtioEntropyDeviceConfiguration{entropy})

	sock, err := vz.NewVirtioSocketDeviceConfiguration()
	if err != nil {
		return nil, err
	}
	cfg.SetSocketDevicesVirtualMachineConfiguration([]vz.SocketDeviceConfiguration{sock})

	balloon, err := vz.NewVirtioTraditionalMemoryBalloonDeviceConfiguration()
	if err != nil {
		return nil, err
	}
	cfg.SetMemoryBalloonDevicesVirtualMachineConfiguration([]vz.MemoryBalloonDeviceConfiguration{balloon})

	var storage []vz.StorageDeviceConfiguration
	for _, path := range s.disks {
		attachment, err := vz.NewDiskImageStorageDeviceAttachment(path, false)
		if err != nil {
			return nil, fmt.Errorf("attach disk %s: %w", path, err)
		}
		blk, err := vz.NewVirtioBlockDeviceConfiguration(attachment)
		if err != nil {
			return nil, err
		}
		storage = append(storage, blk)
	}
	cfg.SetStorageDevicesVirtualMachineConfiguration(storage)

	var shares []vz.DirectorySharingDeviceConfiguration
	if s.share != "" {
		dir, err := vz.NewSharedDirectory(s.share, false)
		if err != nil {
			return nil, err
		}
		single, err := vz.NewSingleDirectoryShare(dir)
		if err != nil {
			return nil, err
		}
		fs, err := directoryShare("crateyard", single)
		if err != nil {
			return nil, err
		}
		shares = append(shares, fs)
	}
	if s.isRosetta {
		rosetta, err := vz.NewLinuxRosettaDirectoryShare()
		if err != nil {
			return nil, fmt.Errorf("share Rosetta: %w", err)
		}
		fs, err := directoryShare("rosetta", rosetta)
		if err != nil {
			return nil, err
		}
		shares = append(shares, fs)
	}
	cfg.SetDirectorySharingDevicesVirtualMachineConfiguration(shares)

	if ok, err := cfg.Validate(); !ok {
		return nil, fmt.Errorf("machine configuration is invalid: %w", err)
	}
	return vz.NewVirtualMachine(cfg)
}

func directoryShare(tag string, share vz.DirectoryShare) (*vz.VirtioFileSystemDeviceConfiguration, error) {
	fs, err := vz.NewVirtioFileSystemDeviceConfiguration(tag)
	if err != nil {
		return nil, err
	}
	fs.SetDirectoryShare(share)
	return fs, nil
}

// rosettaAvailable reports whether Rosetta can be shared with the guest, which otherwise runs amd64 binaries through QEMU.
func rosettaAvailable() bool {
	switch vz.LinuxRosettaDirectoryShareAvailability() {
	case vz.LinuxRosettaAvailabilityInstalled:
		return true
	case vz.LinuxRosettaAvailabilityNotInstalled:
		fmt.Fprintln(os.Stderr, "crateyardd: Rosetta is not installed, so amd64 images run through QEMU, which is slower. Install it with: softwareupdate --install-rosetta --agree-to-license")
	}
	return false
}

// waitStopped blocks until the guest powers off or the VM fails.
func waitStopped(vm *vz.VirtualMachine) error {
	for state := range vm.StateChangedNotify() {
		switch state {
		case vz.VirtualMachineStateStopped:
			return nil
		case vz.VirtualMachineStateError:
			return fmt.Errorf("virtual machine entered the error state")
		}
	}
	return nil
}
