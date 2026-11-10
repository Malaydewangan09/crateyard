vz v3.8.0 with one fix: newVirtioSocketConnection closed a descriptor the framework owns, so every vsock
connection was closed twice and the second close hit whatever reused the number. Upstream fixed it after
v3.8.0 (https://github.com/Code-Hex/vz/issues/268). Delete this copy and the replace in go.mod once a
release includes that fix.
