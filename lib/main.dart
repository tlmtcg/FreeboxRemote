import 'package:flutter/material.dart';
import 'freebox_player_client.dart';

void main() {
  runApp(const FreeboxRemoteApp());
}

class FreeboxRemoteApp extends StatelessWidget {
  const FreeboxRemoteApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Télécommande Freebox',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        brightness: Brightness.dark,
        colorScheme: ColorScheme.fromSeed(
          seedColor: const Color(0xFF5B8CFF),
          brightness: Brightness.dark,
        ),
        scaffoldBackgroundColor: const Color(0xFF080B12),
        fontFamily: 'sans',
        useMaterial3: true,
      ),
      home: const RemoteHomePage(),
    );
  }
}

class RemoteHomePage extends StatefulWidget {
  const RemoteHomePage({super.key});

  @override
  State<RemoteHomePage> createState() => _RemoteHomePageState();
}

class _RemoteHomePageState extends State<RemoteHomePage> {
  int _selectedTab = 0;
  int _volume = 22;
  bool _isMuted = false;
  bool _isConnected = false;
  bool _isCheckingConnection = true;
  String _connectionMessage = 'Recherche de la Freebox sur le réseau local...';
  final FreeboxPlayerClient _playerClient = FreeboxPlayerClient();

  @override
  void initState() {
    super.initState();
    _connectPlayer();
  }

  Future<void> _connectPlayer() async {
    setState(() {
      _isCheckingConnection = true;
      _connectionMessage = 'Recherche du Player Delta sur le réseau local...';
    });
    try {
      final player = await _playerClient.discover();
      // final player = await _playerClient.discoverManual();
      if (player == null) throw StateError('Player introuvable');
      await _playerClient.connect(player);
      if (!mounted) return;
      setState(() {
        _isConnected = true;
        _isCheckingConnection = false;
        _connectionMessage = 'Player Delta connecté (${player.address.address}:${player.port})';
      });
    } catch (e) {
      print('Erreur de connexion détaillée : $e');
      await _playerClient.disconnect();
      if (!mounted) return;
      setState(() {
        _isConnected = false;
        _isCheckingConnection = false;
        _connectionMessage =
            'Player introuvable ou appairage refusé. Vérifiez le même Wi-Fi.';
      });
    }
  }

  Future<void> _sendCommand(String label, Future<void> Function() command) async {
    if (!_isConnected) {
      _showMessage('Connectez d’abord le Player Delta');
      return;
    }
    try {
      await command();
      _showMessage(label);
    } catch (_) {
      _showMessage('Échec de l’envoi de $label');
    }
  }

  void _showMessage(String label) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(label),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(milliseconds: 900),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SafeArea(
        child: Column(
          children: [
            _buildHeader(),
            Expanded(child: _selectedTab == 0 ? _buildRemote() : _buildPlaceholder()),
          ],
        ),
      ),
      bottomNavigationBar: _buildNavigationBar(),
    );
  }

  Widget _buildHeader() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 20, 24, 10),
      child: Row(
        children: [
          Container(
            width: 42,
            height: 42,
            decoration: BoxDecoration(
              color: const Color(0xFF17233F),
              borderRadius: BorderRadius.circular(13),
            ),
            child: const Icon(Icons.satellite_alt_rounded, color: Color(0xFF8EAEFF)),
          ),
          const SizedBox(width: 12),
          const Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('Télécommande Freebox', style: TextStyle(fontSize: 19, fontWeight: FontWeight.w700)),
                Text('Salon · Freebox Delta', style: TextStyle(color: Color(0xFF8E96A8), fontSize: 12)),
              ],
            ),
          ),
          IconButton(
            tooltip: 'Changer de Freebox',
            onPressed: _connectPlayer,
            icon: _isCheckingConnection
              ? const SizedBox(width: 20, height: 20, child: CircularProgressIndicator(strokeWidth: 2))
              : Icon(_isConnected ? Icons.wifi_rounded : Icons.wifi_off_rounded),
            color: _isConnected ? const Color(0xFF73E0B1) : const Color(0xFFFFB86B),
          ),
        ],
      ),
    );
  }

  Widget _buildRemote() {
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(24, 18, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _buildStatusCard(),
          const SizedBox(height: 26),
          _buildSectionTitle('Contrôle rapide', 'Les commandes essentielles, toujours à portée de main.'),
          const SizedBox(height: 14),
          _buildTransportControls(),
          const SizedBox(height: 26),
          _buildSectionTitle('Navigation', 'Naviguez dans vos contenus avec précision.'),
          const SizedBox(height: 14),
          _buildDirectionPad(),
          _buildSectionTitle(
            'Clavier numérique',
            'Envoyez directement les touches 0 à 9 au Player.',
          ),
          const SizedBox(height: 14),
          _buildNumericKeyboard(),
          const SizedBox(height: 26),
          _buildVolumeControl(),
        ],
      ),
    );
  }

  Widget _buildStatusCard() {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        gradient: const LinearGradient(colors: [Color(0xFF15244A), Color(0xFF101A31)]),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: const Color(0xFF29447F)),
      ),
      child: Row(
        children: [
          Container(
            width: 11,
            height: 11,
            decoration: BoxDecoration(
              color: _isConnected ? const Color(0xFF73E0B1) : const Color(0xFFFFB86B),
              shape: BoxShape.circle,
              boxShadow: [BoxShadow(color: (_isConnected ? const Color(0xFF73E0B1) : const Color(0xFFFFB86B)).withAlpha(90), blurRadius: 10)],
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_isCheckingConnection ? 'Détection...' : (_isConnected ? 'Server détecté' : 'Non connectée'), style: const TextStyle(fontWeight: FontWeight.w700)),
                Text(_connectionMessage, style: const TextStyle(color: Color(0xFF9DA8C0), fontSize: 12)),
              ],
            ),
          ),
          const Icon(Icons.chevron_right_rounded, color: Color(0xFF7C8CB1)),
        ],
      ),
    );
  }

  Widget _buildSectionTitle(String title, String subtitle) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
        const SizedBox(height: 4),
        Text(subtitle, style: const TextStyle(fontSize: 12, color: Color(0xFF81899B))),
      ],
    );
  }

  Widget _buildTransportControls() {
    return Row(
      children: [
        Expanded(child: _actionButton(Icons.power_settings_new_rounded, 'Power', const Color(0xFFFF6D7A), () => _playerClient.sendConsumer(0x30))),
        const SizedBox(width: 10),
        Expanded(child: _actionButton(Icons.replay_10_rounded, 'Retour', const Color(0xFF8EAEFF), () => _playerClient.sendConsumer(0x204))),
        const SizedBox(width: 10),
        Expanded(child: _actionButton(Icons.pause_rounded, 'Pause', const Color(0xFF8EAEFF), () => _playerClient.sendConsumer(0xCD))),
        const SizedBox(width: 10),
        Expanded(child: _actionButton(Icons.forward_10_rounded, 'Avance', const Color(0xFF8EAEFF), () => _playerClient.sendConsumer(0xB3))),
      ],
    );
  }

  Widget _actionButton(IconData icon, String label, Color color, Future<void> Function() command) {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => _sendCommand(label, command),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 15),
        decoration: BoxDecoration(color: const Color(0xFF121722), borderRadius: BorderRadius.circular(16)),
        child: Column(children: [Icon(icon, color: color, size: 22), const SizedBox(height: 7), Text(label, style: const TextStyle(fontSize: 11, color: Color(0xFFB8BFCD)))])
      ),
    );
  }

  Widget _buildDirectionPad() {
    return Center(
      child: SizedBox(
        width: 238,
        height: 238,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(width: 154, height: 154, decoration: const BoxDecoration(color: Color(0xFF151B28), shape: BoxShape.circle)),
            _padButton(Icons.keyboard_arrow_up_rounded, Alignment.topCenter, 'Haut'),
            _padButton(Icons.keyboard_arrow_down_rounded, Alignment.bottomCenter, 'Bas'),
            _padButton(Icons.keyboard_arrow_left_rounded, Alignment.centerLeft, 'Gauche'),
            _padButton(Icons.keyboard_arrow_right_rounded, Alignment.centerRight, 'Droite'),
            GestureDetector(
              onTap: () => _sendCommand('OK', () => _playerClient.sendKeyboard(0x28)),
              child: Container(width: 70, height: 70, decoration: const BoxDecoration(color: Color(0xFF5B8CFF), shape: BoxShape.circle), child: const Center(child: Text('OK', style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16)))),
            ),
          ],
        ),
      ),
    );
  }

  Widget _padButton(IconData icon, Alignment alignment, String label) {
    final keys = {'Haut': 0x52, 'Bas': 0x51, 'Gauche': 0x50, 'Droite': 0x4F};
    return Align(alignment: alignment, child: IconButton(tooltip: label, onPressed: () => _sendCommand(label, () => _playerClient.sendKeyboard(keys[label]!)), icon: Icon(icon, size: 36, color: const Color(0xFFDDE5FF))));
  }

  Widget _buildNumericKeyboard() {
  const keys = {
    '0': 0x62,
    '1': 0x59,
    '2': 0x5A,
    '3': 0x5B,
    '4': 0x5C,
    '5': 0x5D,
    '6': 0x5E,
    '7': 0x5F,
    '8': 0x60,
    '9': 0x61,
  };

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF121722),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(child: _numberButton('1', keys['1']!)),
              const SizedBox(width: 10),
              Expanded(child: _numberButton('2', keys['2']!)),
              const SizedBox(width: 10),
              Expanded(child: _numberButton('3', keys['3']!)),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(child: _numberButton('4', keys['4']!)),
              const SizedBox(width: 10),
              Expanded(child: _numberButton('5', keys['5']!)),
              const SizedBox(width: 10),
              Expanded(child: _numberButton('6', keys['6']!)),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(child: _numberButton('7', keys['7']!)),
              const SizedBox(width: 10),
              Expanded(child: _numberButton('8', keys['8']!)),
              const SizedBox(width: 10),
              Expanded(child: _numberButton('9', keys['9']!)),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              const Spacer(),
              Expanded(child: _numberButton('0', keys['0']!)),
              const Spacer(),
            ],
          ),
        ],
      ),
    );
  }

  Widget _numberButton(String number, int keyCode) {
    return InkWell(
      borderRadius: BorderRadius.circular(16),
      onTap: () => _sendCommand(
        number,
        () => _playerClient.sendKeyboard(keyCode),
      ),
      child: Container(
        height: 58,
        decoration: BoxDecoration(
          color: const Color(0xFF181F2D),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: const Color(0xFF27334A),
          ),
        ),
        child: Center(
          child: Text(
            number,
            style: const TextStyle(
              fontSize: 21,
              fontWeight: FontWeight.w700,
              color: Color(0xFFDDE5FF),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildVolumeControl() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 13),
      decoration: BoxDecoration(color: const Color(0xFF121722), borderRadius: BorderRadius.circular(16)),
      child: Row(
        children: [
          IconButton(tooltip: 'Muet', onPressed: () => _sendCommand('Muet', () async { setState(() => _isMuted = !_isMuted); await _playerClient.sendConsumer(0xE2); }), icon: Icon(_isMuted ? Icons.volume_off_rounded : Icons.volume_up_rounded, color: const Color(0xFFB6C6F4))),
          Expanded(child: Slider(value: _volume.toDouble(), max: 100, onChanged: (value) => setState(() { _volume = value.round(); _isMuted = false; }), onChangeEnd: (_) => _sendCommand('Volume', () => _playerClient.sendConsumer(0xE9)))),
          SizedBox(width: 34, child: Text('$_volume', textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w700))),
        ],
      ),
    );
  }

  Widget _buildPlaceholder() {
    final title = _selectedTab == 1 ? 'Applications' : 'Réglages';
    return Center(child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [const Icon(Icons.auto_awesome_motion_rounded, size: 46, color: Color(0xFF5B8CFF)), const SizedBox(height: 16), Text(title, style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)), const SizedBox(height: 6), const Text('Bientôt disponible', style: TextStyle(color: Color(0xFF81899B)))]));
  }

  Widget _buildNavigationBar() {
    return NavigationBar(
      selectedIndex: _selectedTab,
      onDestinationSelected: (index) => setState(() => _selectedTab = index),
      backgroundColor: const Color(0xFF0D111A),
      indicatorColor: const Color(0xFF1D356D),
      destinations: const [
        NavigationDestination(icon: Icon(Icons.gamepad_outlined), selectedIcon: Icon(Icons.gamepad_rounded), label: 'Télécommande'),
        NavigationDestination(icon: Icon(Icons.apps_outlined), selectedIcon: Icon(Icons.apps_rounded), label: 'Apps'),
        NavigationDestination(icon: Icon(Icons.tune_outlined), selectedIcon: Icon(Icons.tune_rounded), label: 'Réglages'),
      ],
    );
  }
}
