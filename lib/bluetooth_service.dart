import 'dart:async';
import 'dart:convert';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:fluttertoast/fluttertoast.dart';
import 'package:logger/logger.dart';
//If Logger is not used!
// class Logger {
//   void d(dynamic message, [dynamic error, StackTrace? stackTrace]) {}
//   void i(dynamic message, [dynamic error, StackTrace? stackTrace]) {}
//   void w(dynamic message, [dynamic error, StackTrace? stackTrace]) {}
//   void e(dynamic message, [dynamic error, StackTrace? stackTrace]) {}
// }

class BluetoothServiceControl {
  //Public
  BluetoothDevice? device;
  Stream<BluetoothState> btState = FlutterBluePlus.instance.state;
  String connectionID = "";

  //Private
  bool _initialized = false;
  bool _connectionIsRunning = false;
  bool _bluetoothOn = false;
  static const String _serviceStart = '0000ac00';
  static const String _serviceEnd = '0000ac08';
  StreamSubscription<BluetoothDeviceState>? _btDeviceStatelistener;
  BluetoothService? _btService;
  List<String> _serviceUUIDs = [];
  Logger? _logger;
  //bool _writeRunning = false;
  //static const String _serverAdress = '14:5A:FC:2B:50:94';

  final StreamController<bool> _connectionController = StreamController<bool>(
    onListen: (){},
    onCancel: (){},
    onResume: (){},
    onPause: (){},
  );

  final StreamController<Map> _serverMsgController = StreamController<Map>(
    onListen: (){},
    onCancel: (){},
    onResume: (){},
    onPause: (){},
  );

  BluetoothServiceControl([Logger? logger]) {
    _logger = logger;
    int serviceStart = int.parse(_serviceStart, radix: 16);
    int serviceEnd = int.parse(_serviceEnd, radix: 16);
    List<String> serviceUUIDs = [];
    for (int i = serviceStart; i <= serviceEnd; ++i) {
      serviceUUIDs.add("${i.toRadixString(16).padLeft(8, '0')}-0000-1000-8000-00805f9b34fb");
    }
    _serviceUUIDs = serviceUUIDs;
  }

  void setLogger(Logger logger) {
    _logger = logger;
  }

  Future<bool> turnBluetoothOn() {
    return FlutterBluePlus.instance.turnOn();
  }

  Future<bool> turnBluetoothOff() {
    return FlutterBluePlus.instance.turnOff();
  }

  Stream<bool> bluetoothOnStream() async* {
    await for (final state in btState) {
      _bluetoothOn = (state == BluetoothState.on);
      yield _bluetoothOn;
    }
  }

  Stream<bool> getConnectionController() {
    return _connectionController.stream;
  }

  Stream<Map> getMsgStream() {
    return _serverMsgController.stream;
  }

  showToast(String toastMSG) {
    Fluttertoast.showToast(msg: toastMSG);
  }

  Future<String> _startScanForDeviceAndUUID() async {
    String uuid = "";
    FlutterBluePlus.instance.startScan(timeout: const Duration(seconds: 10));
    _logger?.d("start scanning");
    await for (final results in FlutterBluePlus.instance.scanResults.timeout(const Duration(seconds: 10), onTimeout: (eventSink) => eventSink.close())) {
      bool serviceFound = false;
      for (ScanResult r in results) {
        if (r.advertisementData.serviceUuids.isEmpty) {
          continue;
        }
        //_logger?.d('${r.device.name}: found! rssi: ${r.rssi}');
        if (_serviceUUIDs.contains(r.advertisementData.serviceUuids[0])) {
          device = r.device;
          uuid = r.advertisementData.serviceUuids[0];
          serviceFound = true;
          break;
        }
      }
      if(serviceFound) {
        break;
      }
    }
    FlutterBluePlus.instance.stopScan();
    return uuid;
  }

  Future<BluetoothService?> _scanDeviceForService(String uuid) async {
    device?.discoverServices();
    BluetoothService? service;
    _logger?.d("start scanning for service $uuid");
    await for (final results in device!.services.timeout(const Duration(seconds: 2), onTimeout: (eventSink) => eventSink.close())) {
      bool serviceFound = false;
      for (BluetoothService s in results) {
        _logger?.d('Scan Device: ${s.uuid.toString()}');
        if(s.uuid.toString() == uuid) {
          serviceFound = true;
          service = s;
          _logger?.d('Found! ${s.uuid.toString()}');
          break;
        }
      }
      if(serviceFound) {
        break;
      }
    }
    return service;
  }

  List<int> _getBytes(String data) {
    List<int> bytes = utf8.encode(data);
    return bytes;
  }

  String _bytesToString(List<int> bytes) {
    return utf8.decode(bytes);
  }

  void onNewByteMsg(List<int> bytes) {
    String msgStr =_bytesToString(bytes);
    Map msg = json.decode(msgStr);

    if(!msg.containsKey("id") || !msg.containsKey("response")) {
      return;
    }

    _logger?.w(msgStr);
    if(msg["response"] == 500) {
      showToast('connection established');
      connectionID = msg["id"];
      _initialized = true;
      _connectionController.add(true);
    }
    _serverMsgController.add(msg);
  }

  bool _releaseConnectionReturnFalse() {
    _connectionIsRunning = false;
    return false;
  }

  Future<bool> connectToServer() async {
    if (_connectionIsRunning) {
      _logger?.w("connection is curently running");
      return false;
    }
    _connectionIsRunning = true;

    if (!_bluetoothOn) {
      return _releaseConnectionReturnFalse();
    }

    String uuid = await _startScanForDeviceAndUUID();
    _logger?.d("Adcertise UUID: $uuid");
    if (device == null) {
      _logger?.w("No Device with right uuid in advertisement found");
      return _releaseConnectionReturnFalse();
    }

    _btDeviceStatelistener?.cancel();
    if (await device!.state.first == BluetoothDeviceState.connected) {
      _logger?.d("Already connected!");
    }
    else {
      _logger?.d("Try to connect to device ${device?.id.toString()}");
      await device?.connect(autoConnect: false); //.timeout(const Duration(seconds: 10), onTimeout: (){});
      final s = await device?.state.first;
      if (s != BluetoothDeviceState.connected) {
        _logger?.w("Could not connect with device ${device?.id.toString()}");
        return _releaseConnectionReturnFalse();
      }
      _logger?.d("Connected!");
    }

    _btDeviceStatelistener = device?.state.listen((state) {
      _connectionController.add(state == BluetoothDeviceState.connected);
    });
    int mtu = await device?.requestMtu(223) ?? -1;
    _logger?.d("New MTU: $mtu");

    BluetoothService? btService = await _scanDeviceForService(uuid);
    if(btService == null) {
      _logger?.w("could not find service $uuid in device ${device.toString()}");
      return _releaseConnectionReturnFalse();
    }
    _btService = btService;
    if(_btService!.characteristics.isEmpty) {
      _logger?.w("No Characeristic in service $uuid");
      return _releaseConnectionReturnFalse();
    }

    _logger?.d("Request Notification");
    BluetoothCharacteristic charactersitics = _btService!.characteristics[0];
    charactersitics.onValueChangedStream.listen(onNewByteMsg);

    //bool test = await charactersitics.setNotifyValue(false);
    bool test = await charactersitics.setNotifyValue(true);
    _logger?.d("notify = $test");
    await charactersitics.read();
    // await charactersitics.write( _getBytes("hello"), withoutResponse: true);
    // await charactersitics.read();
    _logger?.d("Notification established");


    _connectionIsRunning = false;
    return true;
  }

  disconnectFromServer() async {
    if(device == null) {
      _logger?.d("Device already disconnected");
      return true;
    }
    await device?.disconnect();
  }

Future<bool> sendMsg(String msg) async {
    BluetoothCharacteristic charactersitics = _btService!.characteristics[0];
    for(int i = 0; i < 10; ++i) {
      bool error = false;
      try {
        _logger?.i("Start Write");
        await charactersitics.write(_getBytes(msg), withoutResponse: false);
        _logger?.w("End Write");
      }
      on PlatformException catch(_) {
        error = true;
      }
      on Exception catch(e) {
        _logger?.w("End Write: $e");
        return false;
      }

      if(!error) {
        return true;
      }
  }
  return false;
}

/* -----------------------------------------------------------
----------------- DigiIsland Services ------------------------
-------------------------------------------------------------*/

  Map getMapFromRequest(int request) {
    Map requestMap = {
      "id": connectionID,
      "type": 0,
      "request": request,
      "payload": {}
    };
    return requestMap;
  }

  Future<bool> loginStation(int stationID) async {
    if (!_initialized) {
      _logger?.w("Not Initialized");
      return false;
    }

    Map request = getMapFromRequest(1);
    request["payload"] = {"station": stationID};

    String jsonData = jsonEncode(request);
    await sendMsg(jsonData);
    return true;
  }

  Future<bool> logoutStation(int stationID) async {
    if (!_initialized) {
      return false;
    }

    Map request = getMapFromRequest(2);
    request["payload"] = {"station": stationID};
    String jsonData = jsonEncode(request);
    await sendMsg(jsonData);
    return true;
  }

  Future<bool> startExercise(int stationID, int exerciseID, int setID) async {
    if (!_initialized) {
      return false;
    }

    Map request = getMapFromRequest(3);
    request["payload"] = {"station": stationID, "exercise": exerciseID, "set_id": setID};
    String jsonData = jsonEncode(request);
    await sendMsg(jsonData);
    return true;
  }

  Future<bool> stopExercise(int stationID, int exerciseID, int setID) async {
    if (!_initialized) {
      return false;
    }

    Map request = getMapFromRequest(4);
    request["payload"] = {"station": stationID, "exercise": exerciseID, "set_id": setID};
    String jsonData = jsonEncode(request);
    await sendMsg(jsonData);
    return true;
  }
}