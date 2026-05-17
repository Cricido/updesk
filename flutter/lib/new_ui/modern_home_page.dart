import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart' as material show Dialog;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hbb/common.dart';
import 'package:flutter_hbb/consts.dart';
import 'package:flutter_hbb/desktop/pages/desktop_setting_page.dart';
import 'package:flutter_hbb/desktop/pages/desktop_tab_page.dart';
import 'package:flutter_hbb/models/platform_model.dart';
import 'package:flutter_hbb/models/state_model.dart';
import 'package:flutter_hbb/new_ui/ud_theme.dart';
import 'package:flutter_hbb/utils/multi_window_manager.dart' show winManager;
import 'package:flutter_hbb/utils/multi_window_manager.dart';
import 'package:flutter_hbb/utils/update_service.dart';
import 'package:window_manager/window_manager.dart';
import 'package:flutter_hbb/utils/platform_channel.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:get/get.dart';
import 'package:provider/provider.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:window_size/window_size.dart' as window_size;

class ModernHomePage extends StatefulWidget {
  const ModernHomePage({Key? key}) : super(key: key);
  @override
  State<ModernHomePage> createState() => _ModernHomePageState();
}

class _ModernHomePageState extends State<ModernHomePage>
    with AutomaticKeepAliveClientMixin, TickerProviderStateMixin, WidgetsBindingObserver {
  @override
  bool get wantKeepAlive => true;

  UdColors get _ud => UdTheme.of(context);

  final _connectController = TextEditingController();
  final _connectFocus = FocusNode();

  String _myId = '';
  String _myPassword = '';
  int _statusNum = 0; // -1=err, 0=connecting, 1=online
  String _systemError = '';
  bool _isInstalled = true;
  bool _isLowerVersion = false;
  bool _installCardClosed = false;
  String _updateActionStatus = '';
  String _updateActionError = '';
  Timer? _timer;
  bool _connecting = false;
  var svcStopped = false.obs;
  StreamSubscription? _uniLinksSubscription;

  late AnimationController _pulseCtrl;
  late Animation<double> _pulseAnim;

  @override
  void initState() {
    super.initState();
    _pulseCtrl = AnimationController(vsync: this, duration: const Duration(seconds: 2))
      ..repeat(reverse: true);
    _pulseAnim = Tween(begin: 0.6, end: 1.0).animate(
      CurvedAnimation(parent: _pulseCtrl, curve: Curves.easeInOut));

    _timer = Timer.periodic(const Duration(seconds: 1), (_) => _refresh());
    _refresh();

    Get.put<RxBool>(svcStopped, tag: 'stop-service');
    winManager.registerActiveWindowListener(onActiveWindowChanged);

    screenToMap(window_size.Screen screen) => {
      'frame': {
        'l': screen.frame.left, 't': screen.frame.top,
        'r': screen.frame.right, 'b': screen.frame.bottom,
      },
      'visibleFrame': {
        'l': screen.visibleFrame.left, 't': screen.visibleFrame.top,
        'r': screen.visibleFrame.right, 'b': screen.visibleFrame.bottom,
      },
      'scaleFactor': screen.scaleFactor,
    };

    winManager.setMethodHandler((call, fromWindowId) async {
      debugPrint("[Main] call ${call.method} from window $fromWindowId");
      if (call.method == kWindowMainWindowOnTop) {
        windowOnTop(null);
      } else if (call.method == kWindowRefreshCurrentUser) {
        gFFI.userModel.refreshCurrentUser();
      } else if (call.method == kWindowGetWindowInfo) {
        final screen = (await window_size.getWindowInfo()).screen;
        if (screen == null) return '';
        return jsonEncode(screenToMap(screen));
      } else if (call.method == kWindowGetScreenList) {
        return jsonEncode(
            (await window_size.getScreenList()).map(screenToMap).toList());
      } else if (call.method == kWindowActionRebuild) {
        reloadCurrentWindow();
      } else if (call.method == kWindowEventShow) {
        await winManager.registerActiveWindow(call.arguments["id"]);
      } else if (call.method == kWindowEventHide) {
        await winManager.unregisterActiveWindow(call.arguments['id']);
      } else if (call.method == kWindowConnect) {
        await connectMainDesktop(
          call.arguments['id'],
          isFileTransfer: call.arguments['isFileTransfer'],
          isViewCamera: call.arguments['isViewCamera'],
          isTerminal: call.arguments['isTerminal'],
          isTcpTunneling: call.arguments['isTcpTunneling'],
          isRDP: call.arguments['isRDP'],
          password: call.arguments['password'],
          forceRelay: call.arguments['forceRelay'],
          connToken: call.arguments['connToken'],
        );
      } else if (call.method == kWindowBumpMouse) {
        return RdPlatformChannel.instance.bumpMouse(
          dx: call.arguments['dx'],
          dy: call.arguments['dy']);
      } else if (call.method == kWindowEventMoveTabToNewWindow) {
        final args = call.arguments.split(',');
        int? windowId;
        try { windowId = int.parse(args[0]); } catch (e) {}
        WindowType? windowType;
        try { windowType = WindowType.values.byName(args[3]); } catch (e) {}
        if (windowId != null && windowType != null) {
          await winManager.moveTabToNewWindow(windowId, args[1], args[2], windowType);
        }
      } else if (call.method == kWindowEventOpenMonitorSession) {
        final args = jsonDecode(call.arguments);
        final windowId = args['window_id'] as int;
        final peerId = args['peer_id'] as String;
        final display = args['display'] as int;
        final displayCount = args['display_count'] as int;
        final windowType = args['window_type'] as int;
        final screenRect = parseParamScreenRect(args);
        await winManager.openMonitorSession(
            windowId, peerId, display, displayCount, screenRect, windowType);
      } else if (call.method == kWindowEventRemoteWindowCoords) {
        final windowId = int.tryParse(call.arguments);
        if (windowId != null) {
          return jsonEncode(await winManager.getOtherRemoteWindowCoords(windowId));
        }
      }
    });

    _uniLinksSubscription = listenUniLinks();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    _uniLinksSubscription?.cancel();
    Get.delete<RxBool>(tag: 'stop-service');
    _timer?.cancel();
    _pulseCtrl.dispose();
    _connectController.dispose();
    _connectFocus.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  Future<void> _refresh() async {
    final id = await bind.mainGetMyId();
    final statusJson = await bind.mainGetConnectStatus();
    final error = await bind.mainGetError();
    String passwd = '';
    try {
      passwd = gFFI.serverModel.serverPasswd.text;
    } catch (_) {}

    int status = 0;
    try {
      final decoded = jsonDecode(statusJson);
      status = decoded['status_num'] as int? ?? 0;
    } catch (_) {}

    bool installed = true;
    bool lowerVersion = false;
    if (isWindows && !bind.isDisableInstallation()) {
      installed = bind.mainIsInstalled();
      lowerVersion = installed && bind.mainIsInstalledLowerVersion();
    }

    final v = await mainGetBoolOption(kOptionStopService);
    if (v != svcStopped.value) svcStopped.value = v;
    final updateActionStatus =
        bind.mainGetCommonSync(key: 'software-update-status').trim();
    final updateActionError =
        bind.mainGetCommonSync(key: 'software-update-error').trim();

    if (!mounted) return;
    if (id != _myId || status != _statusNum || passwd != _myPassword ||
        error != _systemError || installed != _isInstalled || lowerVersion != _isLowerVersion ||
        updateActionStatus != _updateActionStatus || updateActionError != _updateActionError) {
      setState(() {
        _myId = id;
        _statusNum = status;
        _myPassword = passwd;
        _systemError = error;
        _isInstalled = installed;
        _isLowerVersion = lowerVersion;
        _updateActionStatus = updateActionStatus;
        _updateActionError = updateActionError;
      });
    }
  }

  String _formatId(String id) {
    final clean = id.replaceAll(RegExp(r'\D'), '');
    if (clean.length == 9) {
      return '${clean.substring(0, 3)} ${clean.substring(3, 6)} ${clean.substring(6, 9)}';
    }
    return id;
  }

  Color get _statusColor {
    if (_statusNum == 1) return UdTheme.online;
    if (_statusNum == 0) return UdTheme.connecting;
    return UdTheme.errorColor;
  }

  String get _statusLabel {
    if (_statusNum == 1) return 'Online';
    if (_statusNum == 0) return 'Connessione...';
    return 'Offline';
  }

  Future<void> _doConnect() async {
    final id = _connectController.text.trim().replaceAll(' ', '');
    if (id.isEmpty) return;
    setState(() => _connecting = true);
    await Future.delayed(const Duration(milliseconds: 200));
    await connectMainDesktop(id,
        isFileTransfer: false,
        isTcpTunneling: false,
        isRDP: false,
        isTerminal: false,
        isViewCamera: false,
        forceRelay: false);
    if (mounted) setState(() => _connecting = false);
  }

  void _copyId() {
    Clipboard.setData(ClipboardData(text: _myId));
    showToast(translate('Copied'));
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    return Container(
      color: _ud.bg,
      child: Column(
        children: [
          // top install/error banner
          Builder(builder: (_) {
            final banner = _buildInstallBanner();
            if (banner == null) return const SizedBox.shrink();
            return Container(
              color: _ud.surface,
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: banner,
            );
          }),
          // update banner
          Obx(() => _buildAnyUpdateBanner()),
          // main two-column layout
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                // ── LEFT PANEL ───────────────────────────────
                Container(
                  width: 280,
                  color: _ud.surface,
                  padding: const EdgeInsets.all(24),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      _buildBrand(),
                      const SizedBox(height: 28),
                      _buildIdPanel(),
                      const Spacer(),
                      _buildQuickSupportPanel(),
                    ],
                  ),
                ),
                // divider
                Container(width: 1, color: _ud.surfaceBorder),
                // ── RIGHT PANEL ──────────────────────────────
                Expanded(
                  child: Container(
                    color: _ud.bg,
                    padding: const EdgeInsets.all(32),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _buildConnectPanel(),
                        const Spacer(),
                        _buildFooter(),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── LEFT PANEL WIDGETS ──────────────────────────────────────────────────────

  Widget _buildBrand() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            SvgPicture.asset('assets/icon.svg', width: 28, height: 28),
            const SizedBox(width: 9),
            Text('UpDesk',
                style: TextStyle(color: _ud.textPrimary, fontSize: 18,
                    fontWeight: FontWeight.w700, letterSpacing: 0.3)),
            const Spacer(),
            _IconBtn(icon: Icons.settings_outlined, onTap: () => DesktopTabPage.onAddSetting()),
          ],
        ),
        const SizedBox(height: 10),
        _StatusPill(color: _statusColor, label: _statusLabel, pulse: _statusNum == 0, pulseAnim: _pulseAnim),
      ],
    );
  }

  Widget _buildIdPanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(translate('Your ID'),
            style: TextStyle(color: _ud.textSecondary, fontSize: 12, fontWeight: FontWeight.w500)),
        const SizedBox(height: 12),
        SelectableText(
          _myId.isEmpty ? '— — —' : _myId,
          style: TextStyle(
            color: _myId.isEmpty ? _ud.textMuted : _ud.textPrimary,
            fontSize: 32,
            fontWeight: FontWeight.w800,
            letterSpacing: _myId.isEmpty ? 3 : 4,
            fontFamily: 'RobotoMono',
          ),
        ),
        const SizedBox(height: 14),
        if (_myId.isNotEmpty)
          Row(
            children: [
              Expanded(
                child: _SmallBtn(
                  icon: Icons.copy_outlined,
                  label: translate('Copy'),
                  onTap: _copyId,
                ),
              ),
            ],
          ),
      ],
    );
  }

  Widget _buildQuickSupportPanel() {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: UdTheme.green.withOpacity(0.07),
        borderRadius: BorderRadius.circular(UdTheme.radMd),
        border: Border.all(color: UdTheme.green.withOpacity(0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(children: [
            const Icon(Icons.support_agent, color: UdTheme.green, size: 16),
            const SizedBox(width: 7),
            Text(translate('Quick Support'),
                style: TextStyle(color: _ud.textPrimary, fontSize: 13, fontWeight: FontWeight.w600)),
          ]),
          const SizedBox(height: 10),
          _qsRow(_statusNum == 1 ? translate('Ready for assistance') : translate('Connecting to server...'),
              color: _statusNum == 1 ? UdTheme.green : UdTheme.connecting),
          const SizedBox(height: 5),
          _qsRow(translate('Protected connection (end-to-end encrypted)')),
          const SizedBox(height: 5),
          _qsRow(translate('Share your ID code with the technician')),
        ],
      ),
    );
  }

  Widget _qsRow(String text, {Color? color}) {
    color ??= _ud.textSecondary;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 4),
          child: Container(width: 5, height: 5,
              decoration: BoxDecoration(color: color, shape: BoxShape.circle)),
        ),
        const SizedBox(width: 7),
        Expanded(child: Text(text,
            style: TextStyle(color: color, fontSize: 11, height: 1.4))),
      ],
    );
  }

  // ── RIGHT PANEL WIDGETS ─────────────────────────────────────────────────────

  Widget _buildConnectPanel() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(translate('Control Remote Desktop'),
            style: TextStyle(color: _ud.textSecondary, fontSize: 13, fontWeight: FontWeight.w500)),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: TextField(
                controller: _connectController,
                focusNode: _connectFocus,
                style: TextStyle(color: _ud.textPrimary, fontSize: 20,
                    fontWeight: FontWeight.w600, letterSpacing: 3),
                keyboardType: TextInputType.number,
                decoration: InputDecoration(
                  hintText: translate('Enter Remote ID'),
                  prefixIcon: null,
                  suffixIcon: _connectController.text.isNotEmpty
                      ? GestureDetector(
                          onTap: () { _connectController.clear(); setState(() {}); },
                          child: Icon(Icons.close, color: _ud.textMuted, size: 18))
                      : null,
                ),
                onChanged: (_) => setState(() {}),
                onSubmitted: (_) => _doConnect(),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              height: 56,
              child: ElevatedButton(
                onPressed: _connecting ? null : _doConnect,
                style: ElevatedButton.styleFrom(
                  backgroundColor: _connectController.text.trim().isEmpty
                      ? _ud.surfaceHigh : UdTheme.green,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  padding: const EdgeInsets.symmetric(horizontal: 28),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(UdTheme.radMd)),
                ),
                child: _connecting
                    ? const SizedBox(width: 20, height: 20,
                        child: CircularProgressIndicator(color: Colors.white, strokeWidth: 2))
                    : Text(translate('Connect'),
                        style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            _ActionChip(icon: Icons.folder_outlined, label: translate('Transfer file'),
                onTap: () => _connectAs(isFileTransfer: true)),
          ],
        ),
      ],
    );
  }

  Widget _buildFooter() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.end,
      children: [
        TextButton.icon(
          onPressed: _isUpdateBusy ? null : _runManualUpdateCheck,
          icon: const Icon(Icons.refresh_rounded, size: 15),
          label: const Text('Verifica aggiornamenti'),
        ),
        const SizedBox(width: 12),
        Text('${bind.mainGetAppNameSync()} v${bind.mainGetVersion()}',
            style: TextStyle(color: _ud.textMuted, fontSize: 11)),
      ],
    );
  }

  Widget _buildAnyUpdateBanner() {
    final info = updateNotifier.value;
    if (info != null) {
      return _buildUpdateBanner(info);
    }

    final updateUrl = stateGlobal.updateUrl.value;
    if (updateUrl.isEmpty) {
      return const SizedBox.shrink();
    }

    return _buildCoreUpdateBanner(
      updateUrl: updateUrl,
      version: stateGlobal.updateVersion.value.isNotEmpty
          ? stateGlobal.updateVersion.value
          : bind.mainGetNewVersion(),
      changelog: stateGlobal.updateChangelog.value.trim(),
      mandatory: stateGlobal.updateMandatory.value,
      minSupported: stateGlobal.updateMinSupported.value.trim(),
    );
  }

  Future<void> _connectAs({bool isFileTransfer = false, bool isTcpTunneling = false}) async {
    final id = _connectController.text.trim().replaceAll(' ', '');
    if (id.isEmpty) { _connectFocus.requestFocus(); return; }
    await connectMainDesktop(id,
        isFileTransfer: isFileTransfer,
        isTcpTunneling: isTcpTunneling,
        isRDP: false, isTerminal: false,
        isViewCamera: false, forceRelay: false);
  }

  Widget _buildUpdateBanner(UpdateInfo info) {
    return Container(
      decoration: BoxDecoration(
        color: UdTheme.green.withOpacity(0.08),
        border: Border(bottom: BorderSide(color: UdTheme.green.withOpacity(0.20))),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: Row(
        children: [
          Icon(Icons.system_update_rounded, color: UdTheme.green, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Aggiornamento ${info.version} pronto${info.notes.isNotEmpty ? " — ${info.notes}" : ""}',
                  style: TextStyle(color: _ud.textPrimary, fontSize: 13, fontWeight: FontWeight.w500),
                  overflow: TextOverflow.ellipsis,
                ),
                if (_updateActionLabel.isNotEmpty)
                  Text(
                    _updateActionLabel,
                    style: TextStyle(
                      color: _updateActionError.isNotEmpty ? UdTheme.errorColor : _ud.textMuted,
                      fontSize: 11,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          if (!info.force)
            TextButton(
              onPressed: () => updateNotifier.value = null,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text('Più tardi', style: TextStyle(color: _ud.textMuted, fontSize: 12)),
            ),
          const SizedBox(width: 4),
          ElevatedButton.icon(
            onPressed: _isUpdateBusy ? null : () => _applyUpdate(info),
            icon: const Icon(Icons.restart_alt_rounded, size: 16),
            label: const Text('Riavvia e installa', style: TextStyle(fontSize: 12)),
            style: ElevatedButton.styleFrom(
              backgroundColor: UdTheme.green,
              foregroundColor: Colors.white,
              elevation: 0,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCoreUpdateBanner({
    required String updateUrl,
    required String version,
    required String changelog,
    required bool mandatory,
    required String minSupported,
  }) {
    final parts = <String>[];
    if (changelog.isNotEmpty) {
      parts.add(changelog);
    }
    if (mandatory) {
      parts.add('Aggiornamento richiesto');
    }
    if (minSupported.isNotEmpty) {
      parts.add('Min supportata: $minSupported');
    }
    final subtitle = parts.join(' • ');

    return Container(
      decoration: BoxDecoration(
        color: UdTheme.green.withOpacity(0.08),
        border: Border(bottom: BorderSide(color: UdTheme.green.withOpacity(0.20))),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
      child: Row(
        children: [
          const Icon(Icons.system_update_rounded, color: UdTheme.green, size: 18),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Aggiornamento $version disponibile${subtitle.isNotEmpty ? " — $subtitle" : ""}',
                  style: TextStyle(color: _ud.textPrimary, fontSize: 13, fontWeight: FontWeight.w500),
                  overflow: TextOverflow.ellipsis,
                ),
                if (_updateActionLabel.isNotEmpty)
                  Text(
                    _updateActionLabel,
                    style: TextStyle(
                      color: _updateActionError.isNotEmpty ? UdTheme.errorColor : _ud.textMuted,
                      fontSize: 11,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          if (!mandatory)
            TextButton(
              onPressed: () {
                stateGlobal.updateUrl.value = '';
              },
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 10),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text('Più tardi', style: TextStyle(color: _ud.textMuted, fontSize: 12)),
            ),
          const SizedBox(width: 4),
          ElevatedButton.icon(
            onPressed: _isUpdateBusy ? null : () => _applyUpdateUrl(updateUrl),
            icon: const Icon(Icons.restart_alt_rounded, size: 16),
            label: const Text('Riavvia e installa', style: TextStyle(fontSize: 12)),
            style: ElevatedButton.styleFrom(
              backgroundColor: UdTheme.green,
              foregroundColor: Colors.white,
              elevation: 0,
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _applyUpdate(UpdateInfo info) async {
    await _applyUpdateUrl(info.url);
  }

  Future<void> _applyUpdateUrl(String updateUrl) async {
    setState(() {
      _updateActionStatus = 'preparing';
      _updateActionError = '';
    });
    await bind.mainSetCommon(key: 'update-me', value: updateUrl);
    await Future.delayed(const Duration(milliseconds: 300));
    await _refresh();
    if (_updateActionStatus == 'installer-launched') {
      showToast('Aggiornamento avviato. UpDesk si chiudera per completare l\'installazione.');
    } else if (_updateActionError.isNotEmpty) {
      showToast(_updateActionError);
    }
  }

  Future<void> _runManualUpdateCheck() async {
    setState(() {
      _updateActionStatus = 'checking';
      _updateActionError = '';
    });
    bind.mainGetSoftwareUpdateUrl();
    await Future.delayed(const Duration(seconds: 2));
    await _refresh();
    if (_updateActionStatus == 'up-to-date') {
      showToast('Nessun aggiornamento disponibile.');
    } else if (_updateActionError.isNotEmpty) {
      showToast(_updateActionError);
    }
  }

  bool get _isUpdateBusy =>
      const {'checking', 'downloading', 'verifying', 'preparing', 'launching'}
          .contains(_updateActionStatus);

  String get _updateActionLabel {
    if (_updateActionError.isNotEmpty) {
      return _updateActionError;
    }
    switch (_updateActionStatus) {
      case 'checking':
        return 'Controllo aggiornamenti in corso...';
      case 'available':
        return 'Nuova versione rilevata.';
      case 'downloading':
        return 'Download aggiornamento in corso...';
      case 'verifying':
        return 'Verifica integrita del pacchetto...';
      case 'ready':
        return 'Pacchetto pronto per l\'installazione.';
      case 'preparing':
        return 'Preparazione aggiornamento...';
      case 'launching':
        return 'Avvio installer in corso...';
      case 'installer-launched':
        return 'Installer avviato correttamente.';
      case 'up-to-date':
        return 'Il client e gia aggiornato.';
      default:
        return '';
    }
  }

  Widget? _buildInstallBanner() {
    if (_installCardClosed) return null;

    String? message;
    String? btnLabel;
    VoidCallback? onBtn;
    bool isError = false;

    if (_systemError.isNotEmpty) {
      message = _systemError;
      isError = true;
    } else if (isWindows && !bind.isDisableInstallation()) {
      if (!_isInstalled) {
        message = translate('install_tip');
        btnLabel = translate('Install');
        onBtn = () async {
          await winManager.closeAllSubWindows();
          bind.mainGotoInstall();
        };
      } else if (_isLowerVersion) {
        message = translate('Your installation is lower version.');
        btnLabel = translate('Upgrade');
        onBtn = () async {
          await winManager.closeAllSubWindows();
          bind.mainUpdateMe();
        };
      }
    }

    if (message == null) return null;

    final borderColor = isError
        ? UdTheme.errorColor.withOpacity(0.5)
        : UdTheme.navy.withOpacity(0.6);
    final textColor = isError ? UdTheme.errorColor : _ud.textSecondary;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: _ud.surface,
        borderRadius: BorderRadius.circular(UdTheme.radMd),
        border: Border.all(color: borderColor),
      ),
      child: Row(
        children: [
          Icon(
            isError ? Icons.warning_amber_rounded : Icons.info_outline,
            size: 15,
            color: textColor,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              message,
              style: TextStyle(color: textColor, fontSize: 12, height: 1.4),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (onBtn != null) ...[
            const SizedBox(width: 10),
            GestureDetector(
              onTap: onBtn,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                decoration: BoxDecoration(
                  color: UdTheme.navy,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  btnLabel!,
                  style: const TextStyle(
                      color: Colors.white, fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ),
            ),
          ],
          const SizedBox(width: 6),
          GestureDetector(
            onTap: () => setState(() => _installCardClosed = true),
            child: Icon(Icons.close, color: _ud.textMuted, size: 15),
          ),
        ],
      ),
    );
  }

}

// ── Password dialog ───────────────────────────────────────────────────────────

class _PasswordDialog extends StatefulWidget {
  final TextEditingController controller;
  final bool isNew;
  final String? currentMasked;
  const _PasswordDialog({required this.controller, required this.isNew, this.currentMasked});

  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  bool _obscure = true;

  UdColors get _ud => UdTheme.of(context);

  @override
  Widget build(BuildContext context) {
    return material.Dialog(
      backgroundColor: _ud.surface,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(UdTheme.radLg)),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 360),
        child: Padding(
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Container(
                    width: 38, height: 38,
                    decoration: BoxDecoration(
                      color: UdTheme.green.withOpacity(0.12),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: const Icon(Icons.lock_open_rounded, color: UdTheme.green, size: 20),
                  ),
                  const SizedBox(width: 12),
                  Text(
                    widget.isNew ? 'Imposta password accesso' : 'Cambia password accesso',
                    style: TextStyle(color: _ud.textPrimary, fontSize: 15, fontWeight: FontWeight.w700),
                  ),
                ],
              ),
              const SizedBox(height: 20),
              Text(
                'Il tecnico userà questa password per connettersi senza il tuo click.',
                style: TextStyle(color: _ud.textSecondary, fontSize: 13, height: 1.5),
              ),
              const SizedBox(height: 20),
              TextField(
                controller: widget.controller,
                obscureText: _obscure,
                autofocus: true,
                decoration: InputDecoration(
                  labelText: 'Nuova password',
                  labelStyle: TextStyle(color: _ud.textMuted),
                  filled: true,
                  fillColor: _ud.bg,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(UdTheme.radMd),
                    borderSide: BorderSide(color: _ud.surfaceBorder),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(UdTheme.radMd),
                    borderSide: BorderSide(color: _ud.surfaceBorder),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(UdTheme.radMd),
                    borderSide: const BorderSide(color: UdTheme.green, width: 1.5),
                  ),
                  suffixIcon: IconButton(
                    icon: Icon(_obscure ? Icons.visibility_off_outlined : Icons.visibility_outlined,
                        size: 18, color: _ud.textMuted),
                    onPressed: () => setState(() => _obscure = !_obscure),
                  ),
                ),
                onSubmitted: (_) => Navigator.of(context).pop(true),
              ),
              const SizedBox(height: 24),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(false),
                    child: Text('Annulla', style: TextStyle(color: _ud.textMuted)),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton(
                    onPressed: () => Navigator.of(context).pop(true),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: UdTheme.green,
                      foregroundColor: Colors.white,
                      elevation: 0,
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(UdTheme.radMd)),
                    ),
                    child: const Text('Salva'),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Reusable widgets ──────────────────────────────────────────────────────────

class _Card extends StatelessWidget {
  final Widget child;
  final Color? borderColor;
  const _Card({required this.child, this.borderColor});

  @override
  Widget build(BuildContext context) {
    final ud = UdTheme.of(context);
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: ud.surface,
        borderRadius: BorderRadius.circular(UdTheme.radLg),
        border: Border.all(color: borderColor ?? ud.surfaceBorder),
        boxShadow: UdTheme.cardShadow,
      ),
      child: child,
    );
  }
}

class _StatusPill extends StatelessWidget {
  final Color color;
  final String label;
  final bool pulse;
  final Animation<double> pulseAnim;
  const _StatusPill({required this.color, required this.label, required this.pulse, required this.pulseAnim});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: color.withOpacity(0.12),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(color: color.withOpacity(0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          pulse
            ? FadeTransition(
                opacity: pulseAnim,
                child: _StatusDot(color: color, size: 6))
            : _StatusDot(color: color, size: 6),
          const SizedBox(width: 5),
          Text(label, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.w600)),
        ],
      ),
    );
  }
}

class _StatusDot extends StatelessWidget {
  final Color color;
  final double size;
  const _StatusDot({required this.color, this.size = 7});

  @override
  Widget build(BuildContext context) =>
    Container(width: size, height: size,
      decoration: BoxDecoration(color: color, shape: BoxShape.circle));
}

class _IconBtn extends StatefulWidget {
  final IconData icon;
  final VoidCallback onTap;
  const _IconBtn({required this.icon, required this.onTap});
  @override
  State<_IconBtn> createState() => _IconBtnState();
}
class _IconBtnState extends State<_IconBtn> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final ud = UdTheme.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.all(7),
          decoration: BoxDecoration(
            color: _hover ? ud.surfaceHigh : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
          ),
          child: Icon(widget.icon, color: _hover ? ud.textPrimary : ud.textSecondary, size: 20),
        ),
      ),
    );
  }
}

class _SmallBtn extends StatefulWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _SmallBtn({required this.icon, required this.label, required this.onTap});
  @override
  State<_SmallBtn> createState() => _SmallBtnState();
}
class _SmallBtnState extends State<_SmallBtn> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final ud = UdTheme.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
          decoration: BoxDecoration(
            color: _hover ? UdTheme.green.withOpacity(0.12) : ud.surfaceHigh,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: _hover ? UdTheme.green.withOpacity(0.4) : ud.surfaceBorder),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(widget.icon, size: 13, color: _hover ? UdTheme.green : ud.textSecondary),
              const SizedBox(width: 4),
              Text(widget.label,
                  style: TextStyle(color: _hover ? UdTheme.green : ud.textSecondary, fontSize: 12, fontWeight: FontWeight.w500)),
            ],
          ),
        ),
      ),
    );
  }
}

class _ActionChip extends StatefulWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  const _ActionChip({required this.icon, required this.label, required this.onTap});
  @override
  State<_ActionChip> createState() => _ActionChipState();
}
class _ActionChipState extends State<_ActionChip> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final ud = UdTheme.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
          decoration: BoxDecoration(
            color: _hover ? ud.surfaceHigh : Colors.transparent,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: _hover ? ud.surfaceBorder : ud.surfaceBorder.withOpacity(0.5)),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(widget.icon, size: 14, color: _hover ? ud.textPrimary : ud.textMuted),
              const SizedBox(width: 5),
              Text(widget.label,
                  style: TextStyle(color: _hover ? ud.textPrimary : ud.textMuted,
                      fontSize: 12, fontWeight: FontWeight.w500)),
            ],
          ),
        ),
      ),
    );
  }
}

class _PasswordField extends StatefulWidget {
  final String password;
  const _PasswordField({required this.password});
  @override
  State<_PasswordField> createState() => _PasswordFieldState();
}
class _PasswordFieldState extends State<_PasswordField> {
  bool _visible = false;
  @override
  Widget build(BuildContext context) {
    final ud = UdTheme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          _visible ? widget.password : '•' * widget.password.length,
          style: TextStyle(
            color: _visible ? ud.textPrimary : ud.textMuted,
            fontSize: 13, fontFamily: 'RobotoMono', letterSpacing: _visible ? 1 : 3),
        ),
        const SizedBox(width: 8),
        GestureDetector(
          onTap: () => setState(() => _visible = !_visible),
          child: Icon(_visible ? Icons.visibility_off_outlined : Icons.visibility_outlined,
              color: ud.textMuted, size: 15),
        ),
        const SizedBox(width: 6),
        GestureDetector(
          onTap: () { Clipboard.setData(ClipboardData(text: widget.password)); showToast(translate('Copied')); },
          child: Icon(Icons.copy_outlined, color: ud.textMuted, size: 15),
        ),
      ],
    );
  }
}

class _FooterLink extends StatefulWidget {
  final String label;
  final String url;
  const _FooterLink({required this.label, required this.url});
  @override
  State<_FooterLink> createState() => _FooterLinkState();
}
class _FooterLinkState extends State<_FooterLink> {
  bool _hover = false;
  @override
  Widget build(BuildContext context) {
    final ud = UdTheme.of(context);
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: () => launchUrl(Uri.parse(widget.url), mode: LaunchMode.externalApplication),
        child: Text(
          widget.label,
          style: TextStyle(
            color: _hover ? UdTheme.navy : ud.textMuted,
            fontSize: 11,
            decoration: _hover ? TextDecoration.underline : TextDecoration.none,
            decorationColor: UdTheme.navy,
          ),
        ),
      ),
    );
  }
}

class _Divider extends StatelessWidget {
  @override
  Widget build(BuildContext context) =>
    Container(height: 1, color: UdTheme.of(context).surfaceBorder);
}
