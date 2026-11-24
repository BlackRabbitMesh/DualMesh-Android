import 'dart:async';
import 'dart:typed_data';

import '../../models/connection_state.dart';
import '../../models/dual_radio_slot.dart';
import '../bluetooth/bluetooth_service.dart';
import '../bluetooth/mobile_bluetooth.dart';
import 'dual_radio_registry.dart';

/// A received BLE frame tagged *before* it can enter any packet processing.
class RadioBleFrame {
  final DualRadioSlot slot;
  final String deviceId;
  final DateTime receivedAt;
  final Uint8List bytes;

  RadioBleFrame({
    required this.slot,
    required this.deviceId,
    required this.receivedAt,
    required Uint8List bytes,
  }) : bytes = Uint8List.fromList(bytes);
}

/// Separate BLE transport per slot. Does not replace MeshMapper's existing
/// provider until its ping, API, and session state are also split.
class DualBleManager {
  final DualRadioRegistry registry;
  final Map<DualRadioSlot, BluetoothService> _transports;
  final Map<DualRadioSlot, StreamSubscription<Uint8List>> _dataSubs = {};
  final Map<DualRadioSlot, StreamSubscription<ConnectionStatus>> _statusSubs = {};
  final _frames = StreamController<RadioBleFrame>.broadcast();
  final _statuses =
      StreamController<(DualRadioSlot, ConnectionStatus)>.broadcast();

  bool _disposed = false;

  DualBleManager({
    DualRadioRegistry? registry,
    BluetoothService Function()? transportFactory,
  })  : registry = registry ?? DualRadioRegistry(),
        _transports = {
          for (final slot in DualRadioSlot.values)
            slot: (transportFactory ?? MobileBluetoothService.new)(),
        } {
    for (final slot in DualRadioSlot.values) {
      final transport = _transports[slot]!;
      _dataSubs[slot] = transport.dataStream.listen((bytes) {
        final deviceId = this.registry.deviceFor(slot);
        if (!_disposed && deviceId != null) {
          _frames.add(RadioBleFrame(
            slot: slot,
            deviceId: deviceId,
            receivedAt: DateTime.now().toUtc(),
            bytes: bytes,
          ));
        }
      });
      _statusSubs[slot] = transport.connectionStream.listen((status) {
        if (!_disposed) _statuses.add((slot, status));
      });
    }
  }

  Stream<RadioBleFrame> get frames => _frames.stream;
  Stream<(DualRadioSlot, ConnectionStatus)> get statuses => _statuses.stream;

  BluetoothService transportFor(DualRadioSlot slot) => _transports[slot]!;

  ConnectionStatus statusFor(DualRadioSlot slot) =>
      transportFor(slot).connectionStatus;

  Future<void> connect(DualRadioSlot slot, String deviceId) async {
    if (_disposed) throw StateError('DualBleManager is disposed');
    final transport = transportFor(slot);
    if (registry.deviceFor(slot) != null) {
      throw StateError('Disconnect ${slot.label} before changing devices');
    }
    registry.assign(slot, deviceId);
    try {
      await transport.connect(deviceId);
    } catch (_) {
      registry.release(slot);
      rethrow;
    }
  }

  Future<void> disconnect(DualRadioSlot slot) async {
    try {
      await transportFor(slot).disconnect();
    } finally {
      registry.release(slot);
    }
  }

  Future<void> write(DualRadioSlot slot, Uint8List data) =>
      transportFor(slot).write(data);

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    for (final sub in _dataSubs.values) {
      await sub.cancel();
    }
    for (final sub in _statusSubs.values) {
      await sub.cancel();
    }
    for (final slot in DualRadioSlot.values) {
      try {
        await _transports[slot]!.disconnect();
      } finally {
        registry.release(slot);
        _transports[slot]!.dispose();
      }
    }
    await _frames.close();
    await _statuses.close();
  }
}
