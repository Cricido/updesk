import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/desktop/pages/desktop_home_page.dart'
    show setPasswordDialog;
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/new_ui/ud_theme.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:window_manager/window_manager.dart';

class QuickSupportPage extends StatefulWidget {
  const QuickSupportPage({Key? key}) : super(key: key);
  @override
  State<QuickSupportPage> createState() => _QuickSupportPageState();
}

class _QuickSupportPageState extends State<QuickSupportPage>
    with TickerProviderStateMixin {
  String _myId = '';
  int _statusNum = 0;
  Timer? _timer;
  bool _unattendedEnabled = false;

  late AnimationController _pulseCtrl;
  late Animation<double> _pulseAnim;
  late AnimationController _fadeCtrl;
  late Animation<double> _fadeAnim;

  UdColors get _ud => UdTheme.of(context);

  @override
  void initState() {
    super.initState();

    _pulseCtrl = AnimationController(
        vsync: this, duration: const Duration(seconds: 2))
      ..repeat(reverse: true);
    _pulseAnim = Tween(begin: 0.5, end: 1.0).animate(
        CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));

    _fadeCtrl = AnimationController(
        vsync: this, duration: const Duration(milliseconds: 600));
    _fadeAnim = CurvedAnimation(parent: _fadeCtrl, curve: Curves.easeOut);
    _fadeCtrl.forward();

    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
    _refresh();
    _loadUnattended();
  }

  @override
  void dispose() {
    _timer?.cancel();
    _pulseCtrl.dispose();
    _fadeCtrl.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final id = await bind.mainGetMyId();
    final statusJson = await bind.mainGetConnectStatus();
    int status = 0;
    try {
      final decoded = jsonDecode(statusJson);
      status = decoded['status_num'] as int? ?? 0;
    } catch (_) {}
    if (!mounted) return;
    if (id != _myId || status != _statusNum) {
      setState(() {
        _myId = id;
        _statusNum = status;
      });
    }
  }

  Future<void> _loadUnattended() async {
    final pw = await bind.mainGetPermanentPassword();
    final mode = bind.mainGetOptionSync(key: kOptionApproveMode);
    if (!mounted) return;
    setState(() {
      _unattendedEnabled = pw.isNotEmpty && mode == 'password';
    });
  }

  void _toggleUnattended(bool value) async {
    if (value) {
      setState(() => _unattendedEnabled = true);
      setPasswordDialog(notEmptyCallback: () async {
        await bind.mainSetOption(key: kOptionApproveMode, value: 'password');
        await bind.mainSetOption(
            key: kOptionVerificationMethod,
            value: 'use-permanent-password');
      });
    } else {
      await bind.mainSetPermanentPassword(password: '');
      await bind.mainSetOption(key: kOptionApproveMode, value: 'click');
      await bind.mainSetOption(key: kOptionVerificationMethod, value: '');
      if (!mounted) return;
      setState(() => _unattendedEnabled = false);
    }
  }

  void _copyId() {
    Clipboard.setData(ClipboardData(text: _myId));
    showToast(translate('Copied'));
  }

  Color get _statusColor {
    if (_statusNum == 1) return UdTheme.online;
    if (_statusNum == 0) return UdTheme.connecting;
    return UdTheme.errorColor;
  }

  String get _statusLabel {
    if (_statusNum == 1) return translate('Ready for assistance');
    if (_statusNum == 0) return translate('Connecting...');
    return translate('Offline');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: _ud.bg,
      body: FadeTransition(
        opacity: _fadeAnim,
        child: Column(
          children: [
            _buildTitleBar(),
            Expanded(
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 420),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 40, vertical: 20),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.center,
                      children: [
                        _buildLogo(),
                        const SizedBox(height: 24),
                        _buildIdCard(),
                        const SizedBox(height: 16),
                        _buildStatusBadge(),
                        const SizedBox(height: 16),
                        _buildUnattendedCard(),
                        const SizedBox(height: 16),
                        _buildBullets(),
                        const Spacer(),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTitleBar() {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanStart: (_) => windowManager.startDragging(),
      child: Container(
        height: 38,
        color: _ud.bg,
        child: Row(
          children: [
            const Expanded(child: SizedBox()),
            _winBtn(Icons.remove_rounded, () => windowManager.minimize()),
            _winBtn(Icons.close_rounded, () => windowManager.close()),
            const SizedBox(width: 6),
          ],
        ),
      ),
    );
  }

  Widget _winBtn(IconData icon, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      hoverColor: icon == Icons.close_rounded
          ? UdTheme.errorColor.withOpacity(0.12)
          : _ud.surface,
      child: SizedBox(
        width: 36,
        height: 36,
        child: Icon(icon, size: 16, color: _ud.textMuted),
      ),
    );
  }

  Widget _buildLogo() {
    return Column(
      children: [
        SvgPicture.asset('assets/icon.svg', width: 52, height: 52),
        const SizedBox(height: 12),
        Text(
          'UptimeDesk',
          style: TextStyle(
            color: _ud.textPrimary,
            fontSize: 22,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.3,
          ),
        ),
      ],
    );
  }

  Widget _buildIdCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 20, horizontal: 28),
      decoration: BoxDecoration(
        color: _ud.surface,
        borderRadius: BorderRadius.circular(UdTheme.radLg),
        border: Border.all(color: _ud.surfaceBorder),
        boxShadow: UdTheme.cardShadow,
      ),
      child: Column(
        children: [
          Text(
            translate('Your ID'),
            style: TextStyle(
              color: _ud.textSecondary,
              fontSize: 13,
              fontWeight: FontWeight.w500,
              letterSpacing: 0.5,
            ),
          ),
          const SizedBox(height: 16),
          SelectableText(
            _myId.isEmpty ? '— — —' : _myId,
            style: TextStyle(
              color: _myId.isEmpty ? _ud.textMuted : _ud.textPrimary,
              fontSize: 42,
              fontWeight: FontWeight.w800,
              letterSpacing: 6,
              fontFamily: 'RobotoMono',
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 24),
          if (_myId.isNotEmpty)
            SizedBox(
              width: double.infinity,
              height: 48,
              child: ElevatedButton.icon(
                onPressed: _copyId,
                icon: const Icon(Icons.copy_rounded, size: 18),
                label: Text(
                  translate('Copy ID'),
                  style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
                ),
                style: ElevatedButton.styleFrom(
                  backgroundColor: UdTheme.green,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(UdTheme.radMd),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildStatusBadge() {
    final isConnecting = _statusNum == 0;
    return AnimatedBuilder(
      animation: _pulseAnim,
      builder: (_, __) {
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          decoration: BoxDecoration(
            color: _statusColor.withOpacity(isConnecting ? _pulseAnim.value * 0.12 : 0.10),
            borderRadius: BorderRadius.circular(100),
            border: Border.all(
              color: _statusColor.withOpacity(isConnecting ? _pulseAnim.value * 0.5 : 0.35),
            ),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: _statusColor.withOpacity(isConnecting ? _pulseAnim.value : 1.0),
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 10),
              Text(
                _statusLabel,
                style: TextStyle(
                  color: _statusColor,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _buildUnattendedCard() {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(vertical: 14, horizontal: 16),
      decoration: BoxDecoration(
        color: _ud.surface,
        borderRadius: BorderRadius.circular(UdTheme.radLg),
        border: Border.all(color: _ud.surfaceBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(Icons.lock_person_rounded, size: 20, color: UdTheme.green),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Accesso non vigilato',
                      style: TextStyle(
                        color: _ud.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      'Il tecnico si connette con password senza il tuo click',
                      style: TextStyle(
                        color: _ud.textSecondary,
                        fontSize: 11,
                        height: 1.3,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Switch(
                value: _unattendedEnabled,
                onChanged: _toggleUnattended,
                activeColor: UdTheme.green,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ],
          ),
          if (_unattendedEnabled) ...[
            const SizedBox(height: 10),
            SizedBox(
              width: double.infinity,
              height: 38,
              child: OutlinedButton.icon(
                onPressed: () => setPasswordDialog(),
                icon: const Icon(Icons.lock_reset_rounded, size: 15),
                label: const Text(
                  'Cambia password',
                  style: TextStyle(fontSize: 13),
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: UdTheme.green,
                  side: BorderSide(color: UdTheme.green.withOpacity(0.5)),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(UdTheme.radMd),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildBullets() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _bullet(Icons.lock_outline_rounded, translate('End-to-end encrypted connection')),
        const SizedBox(height: 10),
        _bullet(Icons.support_agent_rounded, translate('Share your ID code with the technician')),
        const SizedBox(height: 10),
        _bullet(Icons.notifications_active_outlined, translate('You will be notified when someone connects')),
      ],
    );
  }

  Widget _bullet(IconData icon, String text) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, size: 16, color: UdTheme.green),
        const SizedBox(width: 10),
        Expanded(
          child: Text(
            text,
            style: TextStyle(color: _ud.textSecondary, fontSize: 13, height: 1.4),
          ),
        ),
      ],
    );
  }

}
