import '../../models/dual_radio_slot.dart';

/// Owns assignment of physical BLE identities to logical receiver slots.
///
/// The registry deliberately does not share a transport, decoder, connection,
/// subscription, ping tracker or upload session between slots. Those are
/// constructed per slot by the integration layer.
class DualRadioRegistry {
  final Map<DualRadioSlot, String> _devices = {};

  String? deviceFor(DualRadioSlot slot) => _devices[slot];

  /// Reject connecting the same physical device to both receiver slots.
  void assign(DualRadioSlot slot, String bluetoothDeviceId) {
    final id = bluetoothDeviceId.trim();
    if (id.isEmpty) {
      throw ArgumentError.value(bluetoothDeviceId, 'bluetoothDeviceId');
    }
    for (final entry in _devices.entries) {
      if (entry.key != slot && entry.value == id) {
        throw StateError('Device is already assigned to ${entry.key.label}');
      }
    }
    _devices[slot] = id;
  }

  void release(DualRadioSlot slot) => _devices.remove(slot);

  /// Snapshots remain tagged with their originating receiver, even if the
  /// user later changes the selected map filter.
  RadioObservationSource sourceFor(
    DualRadioSlot slot, {
    String? publicKeyHex,
    int? frequencyKHz,
    int? bandwidthHz,
    int? spreadingFactor,
    int? codingRate,
  }) {
    final id = _devices[slot];
    if (id == null) {
      throw StateError('No device assigned to ${slot.label}');
    }
    return RadioObservationSource(
      slot: slot,
      bluetoothDeviceId: id,
      publicKeyHex: publicKeyHex,
      frequencyKHz: frequencyKHz,
      bandwidthHz: bandwidthHz,
      spreadingFactor: spreadingFactor,
      codingRate: codingRate,
    );
  }
}
