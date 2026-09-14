import 'dart:async';
import 'dart:collection';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:multicast_dns/multicast_dns.dart';

class FreeboxPlayer {
  const FreeboxPlayer(this.address, this.port);

  final InternetAddress address;
  final int port;

  @override
  String toString() => '${address.address}:$port';
}

class FreeboxPlayerClient {
  RawDatagramSocket? _socket;
  StreamSubscription<RawSocketEvent>? _socketSubscription;

  InternetAddress? _address;
  int _port = 0;

  int _remoteSequence = 0;
  int _reliableSequence = 0;

  final Queue<Datagram> _receiveQueue = Queue<Datagram>();
  final List<Completer<Datagram?>> _receiveWaiters = <Completer<Datagram?>>[];

  final int _deviceId = 1;

  bool get isConnected => _socket != null;

  //==========================================================
  // RUDP constants
  //==========================================================

  static const int _rudpCmdConnReq = 0x02;
  static const int _rudpCmdConnRsp = 0x03;

  /*
   * D'après l'implémentation C fonctionnelle :
   *
   * RUDP_CMD_APP = 0x06
   */
  static const int _rudpCmdApp = 0x10;

  static const int _rudpOptReliable = 0x01;
  static const int _rudpOptAck = 0x02;
  static const int _rudpOptRetransmitted = 0x04;

  //==========================================================
  // HID commands
  //==========================================================

  static const int _hidDeviceNew = 0;
  static const int _hidDeviceDropped = 1;
  static const int _hidDeviceCreated = 2;
  static const int _hidDeviceClose = 3;
  static const int _hidFeature = 4;
  static const int _hidData = 5;
  static const int _hidGrab = 6;
  static const int _hidRelease = 7;
  static const int _hidFeatureSolicit = 8;

  //==========================================================
  // HID report IDs
  //==========================================================

  static const int _hidReportKeyboard = 2;
  static const int _hidReportConsumer = 3;

  //==========================================================
  // Device
  //==========================================================

  static const int _hidDeviceId = 1;

  static const String _hidDeviceName = 'FreeboxRemote';

  //==========================================================
  // Discovery
  //==========================================================

  Future<FreeboxPlayer?> discover({
    Duration timeout = const Duration(seconds: 5),
  }) async {
    if (kIsWeb) {
      debugPrint('mDNS non supporté sur le Web.');
      return null;
    }

    final mdns = MDnsClient();

    try {
      await mdns.start();

      const serviceTypes = ['_hid._udp.local'];

      final deadline = DateTime.now().add(timeout);

      for (final serviceType in serviceTypes) {
        if (DateTime.now().isAfter(deadline)) {
          break;
        }

        try {
          final services = mdns.lookup<PtrResourceRecord>(
            ResourceRecordQuery.serverPointer(serviceType),
          );

          await for (final service in services.timeout(
            const Duration(seconds: 2),
          )) {
            if (DateTime.now().isAfter(deadline)) {
              break;
            }

            await for (final srv in mdns.lookup<SrvResourceRecord>(
              ResourceRecordQuery.service(service.domainName),
            )) {
              if (DateTime.now().isAfter(deadline)) {
                break;
              }

              await for (final ip in mdns.lookup<IPAddressResourceRecord>(
                ResourceRecordQuery.addressIPv4(srv.target),
              )) {
                final player = FreeboxPlayer(ip.address, srv.port);

                debugPrint('Freebox Player détecté : $player');

                return player;
              }
            }
          }
        } on TimeoutException {
          continue;
        } catch (error) {
          debugPrint('Erreur mDNS pour $serviceType : $error');
          continue;
        }
      }

      return null;
    } finally {
      mdns.stop();
    }
  }

  //==========================================================
  // RUDP connect
  //==========================================================

  Future<void> connect(FreeboxPlayer player) async {
    await disconnect();

    debugPrint(
      'Connexion au Freebox Player ${player.address.address}:${player.port}',
    );

    _address = player.address;
    _port = player.port;

    _socket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);

    _socketSubscription = _socket!.listen(
      (event) {
        if (event != RawSocketEvent.read) {
          return;
        }

        while (true) {
          final datagram = _socket!.receive();

          if (datagram == null) {
            break;
          }

          debugPrint(
            'RUDP <- ${datagram.data.length} octets '
            'depuis ${datagram.address.address}:${datagram.port}',
          );

          _dumpPacket(datagram.data);

          if (_receiveWaiters.isNotEmpty) {
            final waiter = _receiveWaiters.removeAt(0);

            if (!waiter.isCompleted) {
              waiter.complete(datagram);
            }
          } else {
            _receiveQueue.addLast(datagram);
          }
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        debugPrint('RUDP SOCKET ERROR: $error');

        while (_receiveWaiters.isNotEmpty) {
          final waiter = _receiveWaiters.removeAt(0);

          if (!waiter.isCompleted) {
            waiter.completeError(error, stackTrace);
          }
        }
      },
      onDone: () {
        debugPrint('RUDP SOCKET: fermé.');
      },
    );

    _reliableSequence = Random().nextInt(65535);

    if (_reliableSequence == 0) {
      _reliableSequence = 1;
    }

    //========================================================
    // CONN_REQ
    //========================================================

    final request = _packet(
      _rudpCmdConnReq,
      _rudpOptReliable,
      0,
      _reliableSequence,
      0,
    );

    request.addAll(_u32(0));

    debugPrint('RUDP -> CONN_REQ (${request.length} octets)');

    _dumpPacket(request);

    await _send(request);

    //========================================================
    // CONN_RSP
    //========================================================

    final response = await _receive(const Duration(seconds: 2));

    if (response == null) {
      await disconnect();

      throw StateError('Timeout CONN_RSP.');
    }

    debugPrint('RUDP <- CONN_RSP (${response.length} octets)');

    _dumpPacket(response);

    if (response.length < 12 ||
        response[0] != _rudpCmdConnRsp ||
        _readU32(response, 8) == 0) {
      await disconnect();

      throw StateError(
        'Le Player Delta n\'a pas accepté '
        'la connexion RUDP.',
      );
    }

    /*
     * Comme dans le C :
     *
     * remote_seq = reliable
     *
     * Le champ RELIABLE du CONN_RSP est à l'offset 4.
     */

    _remoteSequence = _readU16(response, 4);

    debugPrint(
      'RUDP connecté : '
      'REMOTE_SEQ=$_remoteSequence '
      'LOCAL_SEQ=$_reliableSequence',
    );

    //========================================================
    // DEVICE_NEW
    //========================================================

    await _sendDeviceNew();

    //========================================================
    // DEVICE_CREATED
    //
    // C :
    //
    // RUDP_CMD_APP + FOILS_HID_DEVICE_CREATED
    //
    // 0x06 + 2 = 0x08
    //========================================================

    final created = await _waitForCommand(
      _rudpCmdApp + _hidDeviceCreated,
      const Duration(seconds: 2),
    );

    if (created == null || created.length < 8) {
      await disconnect();

      throw StateError(
        'Le Player Delta n\'a pas créé '
        'le périphérique HID.',
      );
    }

    final createdDeviceId = _readU32(created, 0);

    final createdReportId = _readU32(created, 4);

    debugPrint(
      'DEVICE_CREATED : '
      'device=$createdDeviceId '
      'report=$createdReportId',
    );

    if (createdDeviceId != _deviceId) {
      await disconnect();

      throw StateError('DEVICE_CREATED pour un mauvais device ID.');
    }

    //========================================================
    // GRAB
    //
    // C :
    //
    // RUDP_CMD_APP + FOILS_HID_GRAB
    //
    // 0x10 + 6 = 0x16
    //========================================================

    final grabs = <int>{};

    final deadline = DateTime.now().add(const Duration(seconds: 3));

    while ((!grabs.contains(_hidReportKeyboard) ||
            !grabs.contains(_hidReportConsumer)) &&
        DateTime.now().isBefore(deadline)) {
      final packet = await _receive(const Duration(milliseconds: 500));

      if (packet == null || packet.length < 16) {
        continue;
      }

      if (packet[0] != _rudpCmdApp + _hidGrab) {
        continue;
      }

      final payload = packet.sublist(8);

      final grabbedDeviceId = _readU32(payload, 0);

      final grabbedReportId = _readU32(payload, 4);

      debugPrint(
        'GRAB reçu : '
        'device=$grabbedDeviceId '
        'report=$grabbedReportId',
      );

      if (grabbedDeviceId == _deviceId && grabbedReportId < 32) {
        grabs.add(grabbedReportId);
      }
    }

    if (!grabs.contains(_hidReportKeyboard) ||
        !grabs.contains(_hidReportConsumer)) {
      await disconnect();

      throw StateError(
        'Le Player Delta n\'a pas activé '
        'les rapports HID clavier et consumer.',
      );
    }

    debugPrint('========================================');

    debugPrint('       HID CONNECTE AU FREEBOX PLAYER');

    debugPrint('========================================');
  }

  //==========================================================
  // Disconnect
  //==========================================================

  Future<void> disconnect() async {
    //==========================================================
    // Arrêt du listener unique.
    //==========================================================

    await _socketSubscription?.cancel();

    _socketSubscription = null;

    //==========================================================
    // Réveille les éventuels receive() en attente.
    //==========================================================

    while (_receiveWaiters.isNotEmpty) {
      final waiter = _receiveWaiters.removeAt(0);

      if (!waiter.isCompleted) {
        waiter.complete(null);
      }
    }

    //==========================================================
    // Fermeture socket.
    //==========================================================

    _socket?.close();

    _socket = null;

    //==========================================================
    // Nettoyage.
    //==========================================================

    _receiveQueue.clear();

    _address = null;
    _port = 0;

    _remoteSequence = 0;
    _reliableSequence = 0;
  }

  //==========================================================
  // Keyboard
  //==========================================================

  Future<void> sendKeyboard(int key) async {
    final report = Uint8List(2);

    /*
     * Exactement comme le C :
     *
     * press :
     *   02 XX
     *
     * release :
     *   02 00
     */

    report[0] = key;
    report[1] = 0;

    await _sendData(_hidReportKeyboard, report);
  }

  //==========================================================
  // Desktop
  //==========================================================

  // Future<void> sendDesktop(int usage) async {
  //   final report = Uint8List(2);

  //   final data = ByteData.sublistView(report);

  //   data.setUint16(0, usage, Endian.little);

  //   await _sendData(_hidReportDesktop, report);
  // }

  //==========================================================
  // Consumer
  //==========================================================

  Future<void> sendConsumer(int usage) async {
    final report = Uint8List(2);

    final data = ByteData.sublistView(report);

    /*
     * Le C utilise explicitement :
     *
     * write_u16_le()
     */
    data.setUint16(0, usage, Endian.little);

    await _sendData(_hidReportConsumer, report);
  }

  //==========================================================
  // HID DATA
  //==========================================================

  Future<void> _sendData(int reportId, Uint8List report) async {
    /*
     * C :
     *
     * uint8_t payload[10];
     *
     * [0..3] = device ID
     * [4..7] = report ID
     * [8..9] = report
     *
     * Total = 10 octets.
     */

    final pressPayload = <int>[
      ..._u32(_deviceId),
      ..._u32(reportId),
      ...report,
    ];

    if (pressPayload.length != 10) {
      throw StateError(
        'Payload HID invalide : '
        '${pressPayload.length} octets.',
      );
    }

    //========================================================
    // PRESS
    //========================================================

    await _sendApp(_hidData, pressPayload, reliable: true);

    //========================================================
    // RELEASE après 100 ms
    //========================================================

    await Future<void>.delayed(const Duration(milliseconds: 100));

    final releasePayload = <int>[..._u32(_deviceId), ..._u32(reportId), 0, 0];

    if (releasePayload.length != 10) {
      throw StateError(
        'Release HID invalide : '
        '${releasePayload.length} octets.',
      );
    }

    await _sendApp(_hidData, releasePayload, reliable: true);
  }

  //==========================================================
  // DEVICE_NEW
  //==========================================================

  Future<void> _sendDeviceNew() async {
    /*
     * Descriptor officiel Freebox.
     */

    const descriptor = <int>[
      0x05,
      0x01,
      0x09,
      0x06,
      0xA1,
      0x01,
      0x85,
      0x01,
      0x05,
      0x10,
      0x08,
      0x95,
      0x01,
      0x75,
      0x20,
      0x14,
      0x27,
      0xFF,
      0xFF,
      0xFF,
      0x81,
      0x62,
      0xC0,

      0xA1,
      0x01,
      0x85,
      0x02,
      0x95,
      0x01,
      0x75,
      0x08,
      0x15,
      0x00,
      0x26,
      0xFF,
      0x00,
      0x05,
      0x07,
      0x19,
      0x00,
      0x2A,
      0xFF,
      0x00,
      0x80,
      0xC0,

      0x05,
      0x0C,
      0x09,
      0x01,
      0xA1,
      0x01,
      0x85,
      0x03,
      0x95,
      0x01,
      0x75,
      0x10,
      0x19,
      0x00,
      0x2A,
      0xB0,
      0x0F,
      0x15,
      0x00,
      0x26,
      0xB0,
      0x0F,
      0x80,
      0xC0,

      0x05,
      0x01,
      0x0A,
      0x80,
      0x00,
      0xA1,
      0x01,
      0x85,
      0x04,
      0x75,
      0x01,
      0x95,
      0x04,
      0x1A,
      0x81,
      0x00,
      0x2A,
      0x84,
      0x00,
      0x81,
      0x02,
      0x75,
      0x01,
      0x95,
      0x04,
      0x81,
      0x01,
      0xC0,
    ];

    const int hidHeaderSize = 8;
    const int deviceNewSize = 112;
    const int trailingSize = 8;

    final descriptorSize = descriptor.length;

    /*
     * Offsets arrondis à 4 octets.
     */
    final descriptorBlobSize = _roundUp4(descriptorSize);

    const int physicalSize = 0;
    const int stringsSize = 0;

    final physicalBlobSize = _roundUp4(physicalSize);

    final stringsBlobSize = _roundUp4(stringsSize);

    /*
     * IMPORTANT :
     *
     * Les données réellement envoyées utilisent :
     *
     * descriptor réel
     * + physical réel
     * + strings réel
     * + trailing 8
     *
     * Pas le padding d'alignement.
     */

    final totalPayloadSize =
        hidHeaderSize +
        deviceNewSize +
        descriptorSize +
        physicalSize +
        stringsSize +
        trailingSize;

    final payload = Uint8List(totalPayloadSize);

    final data = ByteData.sublistView(payload);

    //========================================================
    // HID HEADER
    //========================================================

    data.setUint32(0, _deviceId, Endian.big);

    data.setUint32(4, 0, Endian.big);

    //========================================================
    // DEVICE_NEW
    //========================================================

    const deviceOffset = hidHeaderSize;

    /*
     * name[64]
     */

    final nameBytes = _hidDeviceName.codeUnits;

    final nameLength = min(nameBytes.length, 63);

    for (var i = 0; i < nameLength; ++i) {
      payload[deviceOffset + i] = nameBytes[i];
    }

    /*
     * serial[32] reste à zéro.
     */

    /*
     * zero
     *
     * offset :
     *
     * 64 + 32 = 96
     */

    final zeroOffset = deviceOffset + 64 + 32;

    data.setUint16(zeroOffset, 0, Endian.big);

    /*
     * version = 1.00
     */

    data.setUint16(zeroOffset + 2, 0x0100, Endian.big);

    /*
     * descriptor_offset
     *
     * 112 = 0x0070
     */

    data.setUint16(zeroOffset + 4, deviceNewSize, Endian.big);

    /*
     * descriptor_size
     */

    data.setUint16(zeroOffset + 6, descriptorSize, Endian.big);

    /*
     * physical_offset
     *
     * 112 + round_up_4(descriptor)
     */

    data.setUint16(
      zeroOffset + 8,
      deviceNewSize + descriptorBlobSize,
      Endian.big,
    );

    /*
     * physical_size = 0
     */

    data.setUint16(zeroOffset + 10, physicalSize, Endian.big);

    /*
     * strings_offset
     *
     * 112
     * + descriptor arrondi
     * + physical arrondi
     */

    data.setUint16(
      zeroOffset + 12,
      deviceNewSize + descriptorBlobSize + physicalBlobSize,
      Endian.big,
    );

    /*
     * strings_size = 0
     */

    data.setUint16(zeroOffset + 14, stringsSize, Endian.big);

    //========================================================
    // DESCRIPTOR
    //========================================================

    payload.setAll(hidHeaderSize + deviceNewSize, descriptor);

    //========================================================
    // TRAILING 8 BYTES
    //========================================================

    final trailingOffset =
        hidHeaderSize +
        deviceNewSize +
        descriptorSize +
        physicalSize +
        stringsSize;

    /*
     * Uint8List est déjà initialisé à zéro.
     */

    for (var i = 0; i < trailingSize; ++i) {
      payload[trailingOffset + i] = 0;
    }

    //========================================================
    // DEBUG
    //========================================================

    debugPrint('=== DEVICE_NEW DEBUG ===');

    debugPrint('HID header      : $hidHeaderSize');

    debugPrint('DEVICE_NEW      : $deviceNewSize');

    debugPrint('Descriptor      : $descriptorSize');

    debugPrint('Descriptor blob : $descriptorBlobSize');

    debugPrint('Physical blob   : $physicalBlobSize');

    debugPrint('Strings blob    : $stringsBlobSize');

    debugPrint('Trailing blob   : $trailingSize');

    debugPrint('HID payload     : ${payload.length}');

    debugPrint(
      'Descriptor off  : 0x${deviceNewSize.toRadixString(16).padLeft(4, '0')}',
    );

    debugPrint(
      'Physical off    : 0x${(deviceNewSize + descriptorBlobSize).toRadixString(16).padLeft(4, '0')}',
    );

    debugPrint(
      'Strings off     : 0x${(deviceNewSize + descriptorBlobSize + physicalBlobSize).toRadixString(16).padLeft(4, '0')}',
    );

    debugPrint(
      'Trailing off    : 0x${trailingOffset.toRadixString(16).padLeft(4, '0')}',
    );

    //========================================================
    // RUDP APP
    //========================================================

    await _sendApp(_hidDeviceNew, payload, reliable: true);

    debugPrint('DEVICE_NEW envoyé.');
  }

  //==========================================================
  // RUDP APP
  //==========================================================

  Future<void> _sendApp(
    int command,
    List<int> payload, {
    required bool reliable,
  }) async {
    final appCommand = _rudpCmdApp + command;

    int nextReliable = _reliableSequence;

    if (reliable) {
      nextReliable = (_reliableSequence + 1) & 0xFFFF;

      if (nextReliable == 0) {
        nextReliable = 1;
      }
    }

    /*
     * C :
     *
     * options = ACK
     *           + RELIABLE si nécessaire
     *
     * reliable_ack = rudp->remote_seq
     * reliable     = next sequence
     */

    var options = _rudpOptAck;

    if (reliable) {
      options |= _rudpOptReliable;
    }

    final packet = _packet(
      appCommand,
      options,
      _remoteSequence,
      nextReliable,
      0,
    );

    packet.addAll(payload);

    debugPrint(
      'RUDP -> APP '
      'cmd=0x${appCommand.toRadixString(16).padLeft(2, '0')} '
      'payload=${payload.length} '
      'REL_SEQ=$nextReliable '
      'ACK=$_remoteSequence',
    );

    _dumpPacket(packet);

    await _send(packet);

    /*
     * Comme dans hid_device_new() du C :
     *
     * le compteur est mis à jour après l'envoi réel.
     */

    if (reliable) {
      _reliableSequence = nextReliable;
    }
  }

  //==========================================================
  // RUDP packet
  //==========================================================

  List<int> _packet(
    int command,
    int options,
    int ack,
    int reliable,
    int unreliable,
  ) {
    return <int>[
      command & 0xFF,
      options & 0xFF,
      ..._u16(ack),
      ..._u16(reliable),
      ..._u16(unreliable),
    ];
  }

  //==========================================================
  // Send
  //==========================================================

  Future<void> _send(List<int> bytes) async {
    final socket = _socket;
    final address = _address;

    if (socket == null || address == null) {
      throw StateError('Socket RUDP non connectée.');
    }

    final data = Uint8List.fromList(bytes);

    try {
      socket.send(data, address, _port);
    } catch (error) {
      throw StateError('Erreur envoi RUDP : $error');
    }
  }

  //==========================================================
  // Receive
  //==========================================================

  Future<List<int>?> _receive(Duration timeout) async {
    //==========================================================
    // Un paquet est déjà en attente.
    //==========================================================

    if (_receiveQueue.isNotEmpty) {
      final datagram = _receiveQueue.removeFirst();

      return datagram.data;
    }

    //==========================================================
    // Aucun paquet : attendre le prochain.
    //==========================================================

    final completer = Completer<Datagram?>();

    _receiveWaiters.add(completer);

    try {
      final datagram = await completer.future.timeout(timeout);

      return datagram?.data;
    } on TimeoutException {
      _receiveWaiters.remove(completer);

      return null;
    } catch (error) {
      _receiveWaiters.remove(completer);

      rethrow;
    }
  }

  //==========================================================
  // Receive
  //==========================================================

  //   Future<List<int>?> _receive(
  //   Duration timeout,
  // ) async {
  //   final socket = _socket;

  //   if (socket == null) {
  //     return null;
  //   }

  //   final completer = Completer<List<int>?>();

  //   StreamSubscription<RawSocketEvent>? subscription;
  //   Timer? timer;

  //   void complete(List<int>? data) {
  //     if (!completer.isCompleted) {
  //       completer.complete(data);
  //     }
  //   }

  //   try {
  //     subscription = socket.listen(
  //       (event) {
  //         debugPrint(
  //           'RUDP EVENT: $event',
  //         );

  //         if (event != RawSocketEvent.read ||
  //             completer.isCompleted) {
  //           return;
  //         }

  //         final datagram = socket.receive();

  //         if (datagram == null) {
  //           debugPrint(
  //             'RUDP <- événement READ mais aucun datagramme.',
  //           );
  //           return;
  //         }

  //         debugPrint(
  //           'RUDP <- ${datagram.data.length} octets '
  //           'depuis ${datagram.address.address}:${datagram.port}',
  //         );

  //         _dumpPacket(datagram.data);

  //         complete(datagram.data);
  //       },
  //       onError: (
  //         Object error,
  //         StackTrace stackTrace,
  //       ) {
  //         debugPrint(
  //           'RUDP RECEIVE ERROR: $error',
  //         );

  //         if (!completer.isCompleted) {
  //           completer.completeError(
  //             error,
  //             stackTrace,
  //           );
  //         }
  //       },
  //       onDone: () {
  //         debugPrint(
  //           'RUDP RECEIVE: socket fermé.',
  //         );
  //       },
  //     );

  //     timer = Timer(
  //       timeout,
  //       () {
  //         debugPrint(
  //           'RUDP RECEIVE: timeout après '
  //           '${timeout.inMilliseconds} ms',
  //         );

  //         complete(null);
  //       },
  //     );

  //     return await completer.future;
  //   } finally {
  //     timer?.cancel();
  //     await subscription?.cancel();
  //   }
  // }

  //==========================================================
  // Wait APP command
  //==========================================================

  Future<List<int>?> _waitForCommand(int command, Duration timeout) async {
    final deadline = DateTime.now().add(timeout);

    while (DateTime.now().isBefore(deadline)) {
      final packet = await _receive(const Duration(milliseconds: 500));

      if (packet == null || packet.length < 8) {
        continue;
      }

      /*
       * Ignore les paquets RUDP de contrôle.
       */

      if (packet[0] < _rudpCmdApp) {
        continue;
      }

      if (packet[0] != command) {
        debugPrint(
          'APP inattendu : '
          '0x${packet[0].toRadixString(16).padLeft(2, '0')} '
          '(attendu '
          '0x${command.toRadixString(16).padLeft(2, '0')})',
        );

        continue;
      }

      return packet.sublist(8);
    }

    return null;
  }

  //==========================================================
  // Helpers
  //==========================================================

  static int _roundUp4(int value) {
    return (value + 3) & ~3;
  }

  List<int> _u16(int value) {
    return <int>[(value >> 8) & 0xFF, value & 0xFF];
  }

  List<int> _u32(int value) {
    return <int>[
      (value >> 24) & 0xFF,
      (value >> 16) & 0xFF,
      (value >> 8) & 0xFF,
      value & 0xFF,
    ];
  }

  int _readU16(List<int> bytes, int offset) {
    return (bytes[offset] << 8) | bytes[offset + 1];
  }

  int _readU32(List<int> bytes, int offset) {
    return (bytes[offset] << 24) |
        (bytes[offset + 1] << 16) |
        (bytes[offset + 2] << 8) |
        bytes[offset + 3];
  }

  void _dumpPacket(List<int> bytes) {
    final text = bytes
        .map((value) => value.toRadixString(16).padLeft(2, '0').toUpperCase())
        .join(' ');

    debugPrint(text);
  }

  Future<FreeboxPlayer?> discoverManual() async {
    const ip = '192.168.0.93';
    const port = 24322;

    return FreeboxPlayer(InternetAddress(ip), port);
  }
}
