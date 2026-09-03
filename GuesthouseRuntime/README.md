# GuesthouseRuntime

The embedded XPC service that performs host operations for the sandboxed Guesthouse app. It is intentionally not sandboxed (direct distribution) and runs with Hardened Runtime. See `MVP-PLAN.md` §3, "Sandbox and XPC boundary".

## Who may connect

- The listener is created with `XPCPeerRequirement.isFromSameTeam(andMatchesSigningIdentifier: "com.starlingprotocol.Guesthouse")`, so a session is accepted only from a process signed by this Team ID with exactly the app's signing identifier. Development-signed and Developer ID builds of the app both satisfy it.
- Every message is checked again with `senderSatisfies` before it is decoded. A failing message gets `unauthorizedCaller` and the session is cancelled.
- Every envelope carries the protocol version. A mismatch is answered with `protocolMismatch` and the session is cancelled; the peer is a different build and must be reinstalled together with the app.
- At most 8 requests may be in flight per session; more are refused with `invalidRequest`.
- Payload sizes (bookmarks, display names, option ranges) are bounded by `RequestValidator` in `GuesthouseCore`. The XPC transport itself bounds message size; there is no client-supplied path, executable, or flag in any request.

## Manual check for gate #34 (unauthorized caller)

An XPC service embedded in an app bundle is reachable only by that bundle's processes, so a separate unsigned tool cannot even look it up. The meaningful negative test is a copy of the app whose signature no longer satisfies the requirement:

1. Build the app, then duplicate `Guesthouse Codex VM.app` to a scratch folder.
2. Re-sign the copy's main executable with an ad-hoc identity (`codesign -f -s - "…/Guesthouse Codex VM.app"`) so the outer app no longer carries the team.
3. Launch the copy from Finder and choose Debug ▸ Runtime Version. Expected: the listener rejects the session, the GUI reports a connection interruption, and the service log shows the rejection. The unmodified build must still succeed.
4. Repeat with a copy re-signed with the correct team but a different signing identifier; expected: rejected.

Record the result in `docs/phase0/host-boundary.md`.
