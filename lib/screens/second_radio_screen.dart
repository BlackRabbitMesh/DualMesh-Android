import 'dart:async';
import 'dart:typed_data';
import 'dart:convert';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:share_plus/share_plus.dart';
import '../providers/app_state_provider.dart';
import '../services/meshcore/packet_metadata.dart';
import '../services/meshcore/rx_logger.dart';
import '../services/meshcore/packet_validator.dart';
import '../services/meshcore/channel_service.dart';
import '../services/fix_altitude.dart';

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
  Position? _lastGps;
  AppStateProvider? _gpsProvider;
  Timer? _saveTimer;
  bool _loaded = false;
  static const _storageKey = 'dualmesh_second_radio_observations_v1';

  void bindGps(AppStateProvider provider) {
    if (identical(provider, _gpsProvider)) return;
    _gpsProvider?.removeListener(_updateGps);
    _gpsProvider = provider;
    _updateGps();
    provider.addListener(_updateGps);
    _configureWardriving();
    if (!_loaded) {
      _loaded = true;
      _restore();
    }
  }

  void _configureWardriving() {
    final provider = _gpsProvider;
    if (provider == null) return;
    final channels = <int, ChannelInfo>{};
    for (final entry in ChannelService.getAllowedChannelsForValidator().entries) {
      channels[entry.key] = ChannelInfo(
        channelName: entry.value.channelName,
        key: entry.value.key,
        hash: entry.value.hash,
      );
    }
    _validator = PacketValidator(
      allowedChannels: channels,
      disableRssiFilter: provider.preferences.disableRssiFilter,
    );
    _wardriveLogger = RxLogger(
      getGpsLocation: () {
        final gps = _lastGps;
        if (gps == null ||
            DateTime.now().difference(gps.timestamp).inSeconds.abs() > 60) {
          return null;
        }
        return (lat: gps.latitude, lon: gps.longitude,
            altitude: const FixAltitude.unknown());
      },
      carpeaterPrefix: provider.preferences.ignoreCarpeater
          ? provider.preferences.carpeaterPublicKey : null,
      onObservation: (_) {
        validatedRepeaterCount++;
        notifyListeners();
      },
      onRxEntry: (entry) async {
        final radio = _mesh?.selfInfo?.radioConfigApi;
        if (radio == null || radio.isEmpty) return;
        await provider.enqueueSecondaryRx(
          latitude: entry.lat,
          longitude: entry.lon,
          repeaterId: entry.repeaterId,
          snr: entry.snr,
          timestamp: entry.timestamp,
          sourceRadioFreq: radio,
        );
      },
    )..startWardriving();
  }

  void _updateGps() {
    _lastGps = _gpsProvider?.currentPosition;
  }

  Future<void> _restore() async {
    final prefs = await SharedPreferences.getInstance();
    final saved = prefs.getStringList(_storageKey) ?? <String>[];
    final existing = receptions.map((e) => e.receivedAt.toIso8601String()).toSet();
    for (final value in saved) {
      try {
        final item = SecondRadioReception.fromJson(jsonDecode(value) as Map<String, dynamic>);
        if (existing.add(item.receivedAt.toIso8601String())) receptions.add(item);
      } catch (_) { /* Ignore malformed historic records. */ }
    }
    receptions.sort((a, b) => b.receivedAt.compareTo(a.receivedAt));
    if (receptions.length > 500) receptions.removeRange(500, receptions.length);
    notifyListeners();
  }

  Future<void> _saveNow() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_storageKey,
        receptions.take(500).map((e) => jsonEncode(e.toJson())).toList());
  }

  void _scheduleSave() {
    _saveTimer?.cancel();
    _saveTimer = Timer(const Duration(seconds: 2), _saveNow);
  }

  Future<void> exportCsv() async {
    const header = 'timestamp_utc,receiver_key,radio_config,latitude,longitude,gps_accuracy_m,rssi_dbm,snr_db,packet_type,bytes';
    final lines = receptions.map((e) => [
      e.receivedAt.toIso8601String(), e.receiverPublicKey, e.frequencyConfig,
      e.latitude?.toString() ?? '', e.longitude?.toString() ?? '',
      e.gpsAccuracy?.toString() ?? '', e.rssi.toString(), e.snr.toString(),
      e.packetType, e.rawBytes.length.toString(),
    ].map((v) => '\"${v.replaceAll('\"', '\"\"')}\"').join(',')).toList();
    await Share.share([header, ...lines].join('\n'), subject: 'DualMesh USA/CA RX observations CSV');
  }
  MeshCoreConnection? _mesh;
  RxLogger? _wardriveLogger;
  PacketValidator? _validator;
  int validatedRepeaterCount = 0;
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
      await _wardriveLogger?.stopWardriving(trigger: 'radio_reconnect');
      _configureWardriving();
      _mesh?.dispose();
      _mesh = MeshCoreConnection(transport: _ble);
      receivedPacketCount = 0;
      _rxSub = _mesh!.logRxDataStream.listen((packet) {
        receivedPacketCount++;
        final gps = _lastGps;
        final logger = _wardriveLogger;
        final validator = _validator;
        if (logger != null && validator != null) {
          try {
            final metadata = PacketMetadata.fromRawPacket(
              raw: packet.raw, snr: packet.snr, rssi: packet.rssi);
            unawaited(logger.handlePacket(metadata, validator));
          } catch (_) { /* Invalid raw frame; diagnostic capture continues. */ }
        }
        // Never associate a stale fix with a received frame.
        final freshGps = gps != null &&
            DateTime.now().difference(gps.timestamp).inSeconds.abs() <= 60
            ? gps : null;
        String type = 'unknown';
        try {
          final metadata = PacketMetadata.fromRawPacket(
            raw: packet.raw, snr: packet.snr, rssi: packet.rssi);
          type = '0x${metadata.header.toRadixString(16).padLeft(2, '0')}';
        } catch (_) { /* Keep undecodable frames for diagnostics. */ }
        receptions.insert(0, SecondRadioReception(
          receivedAt: DateTime.now().toUtc(),
          latitude: freshGps?.latitude,
          longitude: freshGps?.longitude,
          gpsAccuracy: freshGps?.accuracy,
          packetType: type,
          receiverPublicKey: _mesh?.devicePublicKey ?? 'unknown',
          frequencyConfig: _mesh?.selfInfo?.radioConfigApi ?? 'unknown',
          snr: packet.snr,
          rssi: packet.rssi,
          rawBytes: Uint8List.fromList(packet.raw),
        ));
        if (receptions.length > 500) receptions.removeLast();
        _scheduleSave();
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
    _saveTimer?.cancel();
    await _wardriveLogger?.stopWardriving(trigger: 'radio_disconnect');
    await _saveNow();
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
  final double? latitude;
  final double? longitude;
  final double? gpsAccuracy;
  final String packetType;

  Map<String, dynamic> toJson() => {
    'time': receivedAt.toIso8601String(), 'key': receiverPublicKey,
    'radio': frequencyConfig, 'snr': snr, 'rssi': rssi,
    'raw': base64Encode(rawBytes), 'lat': latitude, 'lon': longitude,
    'accuracy': gpsAccuracy, 'type': packetType,
  };

  factory SecondRadioReception.fromJson(Map<String, dynamic> data) => SecondRadioReception(
    receivedAt: DateTime.parse(data['time'] as String),
    receiverPublicKey: data['key'] as String,
    frequencyConfig: data['radio'] as String,
    snr: (data['snr'] as num).toDouble(), rssi: data['rssi'] as int,
    rawBytes: base64Decode(data['raw'] as String),
    latitude: (data['lat'] as num?)?.toDouble(),
    longitude: (data['lon'] as num?)?.toDouble(),
    gpsAccuracy: (data['accuracy'] as num?)?.toDouble(),
    packetType: data['type'] as String? ?? 'unknown',
  );

  SecondRadioReception({
    required this.receivedAt,
    required this.receiverPublicKey,
    required this.frequencyConfig,
    required this.snr,
    required this.rssi,
    required this.rawBytes,
    this.latitude,
    this.longitude,
    this.gpsAccuracy,
    this.packetType = 'unknown',
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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) controller.bindGps(context.read<AppStateProvider>());
    });
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
            'are saved with available phone GPS fixes. Repeater mapping '
            'and wardriving API uploads are not yet integrated.',
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
          Text('Validated repeater observations: ${controller.validatedRepeaterCount}'),
          Text('Saved observations: ${controller.receptions.length}'),
          if (controller.receptions.isNotEmpty)
            OutlinedButton.icon(
              onPressed: controller.exportCsv,
              icon: const Icon(Icons.share),
              label: const Text('Export USA/CA observations CSV'),
            ),
          for (final reception in controller.receptions.take(12))
            ListTile(
              dense: true,
              title: Text('RSSI ${reception.rssi} dBm · SNR ${reception.snr} dB'),
              subtitle: Text(
                '${reception.receivedAt.toLocal()} · '
                '${reception.rawBytes.length} bytes · '
                '${reception.frequencyConfig} · ${reception.packetType}'
                '${reception.latitude == null ? ' · no GPS' : ' · GPS ${reception.latitude!.toStringAsFixed(5)}, ${reception.longitude!.toStringAsFixed(5)}'}',
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
