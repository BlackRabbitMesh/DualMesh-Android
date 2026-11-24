# DualMesh Android — rebuild status

The upstream MeshMapper Flutter app is retained. The target is the original
MeshMapper experience with two independent MeshCore BLE radios.

## Target radios
- USA/CA: BRR Mobile Node, MeshCore-4EF6615C, 910.525 MHz / BW 62.5 kHz / SF7 / CR4/5.
- Philly: BRL Mobile Node, MeshCore-5453396B, 919.500 MHz / BW 500 kHz / SF10 / CR4/5.

The app must read live radio settings rather than reprogramming either radio.

## Implemented on this branch
- Stable receiver slot identity and immutable observation source metadata.
- Registry rejects duplicate BLE device assignment.
- DualBleManager instantiates **two distinct MobileBluetoothService objects**.
- Independent connect/disconnect/write, status streams and source-tagged BLE
  frames. A frame is copied at reception to prevent later buffer mutation.
- GitHub Actions debug APK workflow and initial registry tests.

## Not yet integrated / must be completed before dual-radio release
- Refactor AppStateProvider into two independent MeshCoreConnection, PingService,
  UnifiedRxHandler, TxTracker, RxLogger, session, and API queue contexts.
- Wire DualBleManager into application startup and both connection controls.
  Currently the original UI and provider still use the single-radio path.
- Maintain distinct ping/echo matching, discovery windows, radio settings,
  reconnect logic, background service ownership and offline recovery.
- Store and upload observations with immutable receiver metadata; verify the
  upstream server's API contract before any combined upload.
- Preserve the original map and add Both / USA/CA / Philly filtering.
- Test real two-radio BLE and GPS tracking, disconnection, offline and
  background behavior on the actual Android phone.

**A debug APK from this branch is not yet a working dual-radio MeshMapper.**
Keep the upstream LICENSE and third-party notices.
