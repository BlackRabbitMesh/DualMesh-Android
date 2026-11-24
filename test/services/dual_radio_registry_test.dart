import 'package:flutter_test/flutter_test.dart';
import 'package:mesh_mapper/models/dual_radio_slot.dart';
import 'package:mesh_mapper/services/dual_radio/dual_radio_registry.dart';

void main() {
  test('two different devices stay in separate slots', () {
    final registry = DualRadioRegistry();
    registry.assign(DualRadioSlot.usaCa, 'MeshCore-4EF6615C');
    registry.assign(DualRadioSlot.philly, 'MeshCore-5453396B');
    expect(registry.deviceFor(DualRadioSlot.usaCa), 'MeshCore-4EF6615C');
    expect(registry.deviceFor(DualRadioSlot.philly), 'MeshCore-5453396B');
  });

  test('the same BLE device cannot occupy both slots', () {
    final registry = DualRadioRegistry();
    registry.assign(DualRadioSlot.usaCa, 'same-device');
    expect(
      () => registry.assign(DualRadioSlot.philly, 'same-device'),
      throwsStateError,
    );
  });

  test('observation retains its original receiver and frequency', () {
    final registry = DualRadioRegistry();
    registry.assign(DualRadioSlot.usaCa, 'radio-one');
    registry.assign(DualRadioSlot.philly, 'radio-two');
    final first = registry.sourceFor(
      DualRadioSlot.usaCa,
      frequencyKHz: 910525,
      bandwidthHz: 62500,
      spreadingFactor: 7,
      codingRate: 5,
    );
    final second = registry.sourceFor(
      DualRadioSlot.philly,
      frequencyKHz: 919500,
      bandwidthHz: 500000,
      spreadingFactor: 10,
      codingRate: 5,
    );
    expect(first.toJson()['radioSlot'], 'usa_ca');
    expect(second.toJson()['radioSlot'], 'philly');
    expect(first.frequencyKHz, 910525);
    expect(second.frequencyKHz, 919500);
    registry.release(DualRadioSlot.usaCa);
    expect(second.bluetoothDeviceId, 'radio-two');
  });
}
