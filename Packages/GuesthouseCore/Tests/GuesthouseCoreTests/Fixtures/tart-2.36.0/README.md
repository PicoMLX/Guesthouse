# Tart 2.36.0 output fixtures

Captured from the official 2.36.0 release binary (`tart.tar.gz`, SHA-256
`c72a8ab8d78a6498a1e42688b1a1ec6c512ce46ca35a3a3be130c3de1440c7e8`, signed by Cirrus Labs, Inc.,
Team ID `9M2P8L4D89`, bundle identifier `com.github.cirruslabs.tart`) run on the host with an empty
`TART_HOME`:

- `version.txt`: `tart --version`
- `list-empty.json`: `tart list --format json` with no VMs
- `vm-does-not-exist.txt`: stderr of `tart ip does-not-exist` (exit status 2); `tart stop` prints the same text

The rest are hand-authored from the 2.36.0 sources, because every one of them needs a created VM
that an empty `TART_HOME` does not have. They are not compatibility evidence; gate #35 replaces
them with real captures.

- `list.json`: from `Sources/tart/Commands/List.swift`
- `ip.txt`: a private address in the range Tart's NAT hands out, the shape `Commands/IP.swift` prints
- `ip-error.txt`: the `noIPAddress` message in `Commands/IP.swift`
