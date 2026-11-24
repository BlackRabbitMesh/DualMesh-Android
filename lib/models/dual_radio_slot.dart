/// Stable identity for each independent MeshCore receiver.
///
/// A slot is not a frequency: a receiver may be reconfigured, but its
/// observations must remain attributed to the physical BLE connection.
enum DualRadioSlot { usaCa, philly }

extension DualRadioSlotLabels on DualRadioSlot {
  String get label => switch (this) {
    DualRadioSlot.usaCa => 'USA/CA',
    DualRadioSlot.philly => 'Philly',
  };

  String get storageKey => switch (this) {
    DualRadioSlot.usaCa => 'usa_ca',
    DualRadioSlot.philly => 'philly',
  };
}

/// Receiver identity captured when an observation is produced, not when
/// the map renders it. Never infer the source from the currently selected tab.
class RadioObservationSource {
  final DualRadioSlot slot;
  final String bluetoothDeviceId;
  final String? publicKeyHex;
  final int? frequencyKHz;
  final int? bandwidthHz;
  final int? spreadingFactor;
  final int? codingRate;

  const RadioObservationSource({
    required this.slot,
    required this.bluetoothDeviceId,
    this.publicKeyHex,
    this.frequencyKHz,
    this.bandwidthHz,
    this.spreadingFactor,
    this.codingRate,
  });

  Map<String, Object?> toJson() => {
    'radioSlot': slot.storageKey,
    'bluetoothDeviceId': bluetoothDeviceId,
    'publicKeyHex': publicKeyHex,
    'frequencyKHz': frequencyKHz,
    'bandwidthHz': bandwidthHz,
    'spreadingFactor': spreadingFactor,
    'codingRate': codingRate,
  };
}
