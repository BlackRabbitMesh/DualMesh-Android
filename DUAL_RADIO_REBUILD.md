# DualMesh Android — dual-radio rebuild

## Goal
Preserve the upstream MeshMapper Flutter application and its existing map,
wardriving, discovery, TX/RX processing, offline collection, and upload
behavior. The only user-facing functional addition is a second independent
MeshCore BLE companion.

## Radios
- USA/CA: BRR Mobile Node, BLE MeshCore-4EF6615C, 910.525 MHz, BW 62.5 kHz, SF7, CR 4/5.
- Philly: BRL Mobile Node, BLE MeshCore-5453396B, 919.500 MHz, BW 500 kHz, SF10, CR 4/5.
- Read the live radio configuration from each connected device. Do not silently
  reprogram either radio to a preset.

## Non-negotiable isolation
- One MobileBluetoothService per slot, with separate GATT handles and subscriptions.
- One MeshCoreConnection, packet parser/router, PingService, TxTracker and
  RxLogger per slot. Never use a shared mutable active-connection pointer.
- All observations carry immutable receiver slot, BLE identity, public key,
  actual radio configuration and timestamp at ingestion.
- Each receiver has independent connection/reconnect/disconnect state, battery,
  RSSI/SNR, discovery windows, ping/echo matching and packet counters.
- No ping sent on radio A can be matched with an echo on radio B.
- Shared phone GPS provides the location for both receivers, but no packet
  may be assigned to a transmitter's location based on receiver GPS alone.
- Local sessions and queued API uploads must preserve receiver attribution;
  upstream API compatibility must be verified before any combined upload.
- Duplicate BLE device assignment is rejected.

## Integration sequence (one consolidated release)
1. Extract single-radio state from AppStateProvider into a per-radio session
   object without changing the existing single-radio behavior.
2. Instantiate two radio sessions, with a shared GPS/map and per-radio UI
   status. Persist slot-to-BLE-device selection.
3. Route TX/RX/DISC events through their own radio sessions and tag records
   at creation, not at map display time.
4. Keep all original map controls and add only USA/CA, Philly, Both filters.
5. Partition offline storage, recovery, queue and uploads by source radio.
6. Verify background tracking, disconnect/reconnect and permission handling
   with both physical Heltec V4 devices.
7. Run flutter analyze, flutter test, Android debug/release builds and real
   dual-radio tests before distributing an APK.

## Status
Foundation only: slot identities, BLE identity guard, immutable observation
source, and tests are committed. Existing upstream UI and provider still run
in their original single-radio configuration. This branch is NOT yet a
functional two-radio APK. Do not represent it as such.

## Attribution
Upstream MeshMapper is MIT licensed. Retain LICENSE and third-party notices.
