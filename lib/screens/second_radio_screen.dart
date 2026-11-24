import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import '../models/connection_state.dart';
import '../services/bluetooth/bluetooth_service.dart';
import '../services/bluetooth/mobile_bluetooth.dart';
import '../services/meshcore/connection.dart';

/// A separate BLE companion, independent of MeshMapper's primary connection.
/// This is a connection diagnostic, NOT a second mapping/wardriving pipeline.
class SecondRadioController extends ChangeNotifier {
  SecondRadioController._() {
    _statusSub = _ble.connectionStream.listen((_) => notifyListeners());
  }
  static final SecondRadioController instance = SecondRadioController._();

  final BluetoothService _ble = MobileBluetoothService();
  StreamSubscription<ConnectionStatus>? _statusSub;
  StreamSubscription<DiscoveredDevice>? _scanSub;
  StreamSubscription<({Uint8List raw, double snr, int rssi})>? _rxSub;
  final List<SecondRadioReception> receptions = [];
  int receivedPacketCount = 0;
  MeshCoreConnection? _mesh;
  final List<DiscoveredDevice> devices = [];
  String? error;
  bool scanning = false;
  bool connecting = false;
  String? connectedName;

  ConnectionStatus get status => _ble.connectionStatus;
  String? get publicKey => _mesh?.devicePublicKey;
  String? get radioConfig => _mesh?.selfInfo?.radioConfigApi;

  Future<void> scan() async {
    error = null;
    devices.clear();
    scanning = true;
    notifyListeners();
    try {
      await _scanSub?.cancel();
      _scanSub = _ble.scanForDevices(
        timeout: const Duration(seconds: 12),
      ).listen((device) {
        if (!devices.any((d) => d.id == device.id)) {
          devices.add(device);
          notifyListeners();
        }
      }, onError: (Object e) {
        error = e.toString();
        scanning = false;
        notifyListeners();
      }, onDone: () {
        scanning = false;
        notifyListeners();
      });
    } catch (e) {
      error = e.toString();
      scanning = false;
      notifyListeners();
    }
  }

  Future<void> connect(DiscoveredDevice device) async {
    connecting = true;
    error = null;
    notifyListeners();
    try {
      await _ble.stopScan();
      await _scanSub?.cancel();
      scanning = false;
      await _ble.connect(device.id);
      await _rxSub?.cancel();
      _mesh?.dispose();
      _mesh = MeshCoreConnection(transport: _ble);
      receptions.clear();
      receivedPacketCount = 0;
      _rxSub = _mesh!.logRxDataStream.listen((packet) {
        receivedPacketCount++;
        receptions.insert(0, SecondRadioReception(
          receivedAt: DateTime.now().toUtc(),
          receiverPublicKey: _mesh?.devicePublicKey ?? 'unknown',
          frequencyConfig: _mesh?.selfInfo?.radioConfigApi ?? 'unknown',
          snr: packet.snr,
          rssi: packet.rssi,
          rawBytes: Uint8List.fromList(packet.raw),
        ));
        if (receptions.length > 100) receptions.removeLast();
        notifyListeners();
      });
      await _mesh!.connect((_) async => null);
      connectedName = _mesh!.selfInfo?.name ?? device.name;
    } catch (e) {
      error = e.toString();
      await _rxSub?.cancel();
      _rxSub = null;
      await _ble.disconnect();
      _mesh?.dispose();
      _mesh = null;
      connectedName = null;
    } finally {
      connecting = false;
      notifyListeners();
    }
  }

  Future<void> disconnect() async {
    try {
      await _rxSub?.cancel();
      _rxSub = null;
      await _ble.disconnect();
    } finally {
      _mesh?.dispose();
      _mesh = null;
      connectedName = null;
      notifyListeners();
    }
  }
}

/// Immutable, receiver-attributed raw MeshCore RX frame.
/// Local diagnostic only: not a validated repeater observation or API upload.
class SecondRadioReception {
  final DateTime receivedAt;
  final String receiverPublicKey;
  final String frequencyConfig;
  final double snr;
  final int rssi;
  final Uint8List rawBytes;

  SecondRadioReception({
    required this.receivedAt,
    required this.receiverPublicKey,
    required this.frequencyConfig,
    required this.snr,
    required this.rssi,
    required this.rawBytes,
  });
}

class SecondRadioScreen extends StatefulWidget {
  const SecondRadioScreen({super.key});
  @override
  State<SecondRadioScreen> createState() => _SecondRadioScreenState();
}

class _SecondRadioScreenState extends State<SecondRadioScreen> {
  final controller = SecondRadioController.instance;

  @override
  void initState() {
    super.initState();
    controller.addListener(_refresh);
  }

  @override
  void dispose() {
    controller.removeListener(_refresh);
    super.dispose();
  }

  void _refresh() {
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final connected = controller.status == ConnectionStatus.connected;
    return Scaffold(
      appBar: AppBar(title: const Text('Second radio · BLE')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Independent second Bluetooth connection. Raw RX diagnostics '
            'are tracked by receiver; map and wardriving are not yet integrated.',
          ),
          const SizedBox(height: 16),
          Text('Status: ${controller.status.name}'),
          if (controller.connectedName != null)
            Text('Radio: ${controller.connectedName}'),
          if (controller.radioConfig != null)
            Text('Settings: ${controller.radioConfig}'),
          if (controller.publicKey != null)
            Text('Public key: ${controller.publicKey}'),
          if (controller.error != null)
            Text(controller.error!, style: const TextStyle(color: Colors.red)),
          const SizedBox(height: 16),
          Text('RX frames this connection: ${controller.receivedPacketCount}'),
          for (final reception in controller.receptions.take(12))
            ListTile(
              dense: true,
              title: Text('RSSI ${reception.rssi} dBm · SNR ${reception.snr} dB'),
              subtitle: Text(
                '${reception.receivedAt.toLocal()} · '
                '${reception.rawBytes.length} bytes · '
                '${reception.frequencyConfig}',
              ),
            ),
          const SizedBox(height: 16),
          if (connected)
            FilledButton(
              onPressed: controller.disconnect,
              child: const Text('Disconnect second radio'),
            )
          else ...[
            FilledButton(
              onPressed: controller.scanning || controller.connecting
                  ? null
                  : controller.scan,
              child: Text(controller.scanning ? 'Scanning…' : 'Scan for second radio'),
            ),
            for (final device in controller.devices)
              ListTile(
                title: Text(device.name.isEmpty ? 'MeshCore device' : device.name),
                subtitle: Text(device.id),
                trailing: const Icon(Icons.bluetooth),
                onTap: controller.connecting
                    ? null
                    : () => controller.connect(device),
              ),
          ],
        ],
      ),
    );
  }
}
