import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../l10n/l10n.dart';
import '../../services/clash_api.dart';
import '../../state/app_state.dart';
import '../theme/surfaces.dart';
import '../theme/theme.dart';
import '../widgets/common.dart';

/// Saved diagnostics, selected-node probe failures and the Clash `/logs` stream.
class LogsScreen extends StatefulWidget {
  const LogsScreen({super.key, required this.state});
  final AppState state;

  @override
  State<LogsScreen> createState() => _LogsScreenState();
}

class _LogsScreenState extends State<LogsScreen> {
  static const _maxLines = 2000;
  static const _maxProbeLines = 200;
  final List<ClashLogLine> _lines = [];
  final List<ClashLogLine> _probeLines = [];
  final Map<String, (String, String)> _probeErrors = {};
  final _scroll = ScrollController();
  StreamSubscription<ClashLogLine>? _sub;
  Timer? _fileTimer;
  bool _paused = false;
  bool _fileHistoryLoaded = false;
  String _filter = '';

  @override
  void initState() {
    super.initState();
    widget.state.addListener(_captureProbeErrors);
    _captureProbeErrors();
    final clash = widget.state.clash;
    if (clash != null) {
      final level = switch (widget.state.settings.logLevel.name) {
        'trace' || 'debug' => 'debug',
        'warn' => 'warning',
        final s => s,
      };
      _sub = clash.logs(level: level).listen(_add, onError: (Object _) {});
    }
    _loadFile();
    if (clash == null) {
      _fileTimer = Timer.periodic(
        const Duration(seconds: 2),
        (_) => _loadFile(),
      );
    }
  }

  @override
  void didUpdateWidget(LogsScreen oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.state != widget.state) {
      oldWidget.state.removeListener(_captureProbeErrors);
      widget.state.addListener(_captureProbeErrors);
      _probeErrors.clear();
      _captureProbeErrors();
    }
  }

  void _captureProbeErrors() {
    if (_paused) return;
    final current = <String, (String, String)>{};
    final added = <ClashLogLine>[];
    for (final group in widget.state.engineGroups.values) {
      final stat = group.currentStat;
      final error = stat?.lastError?.trim();
      if (stat == null || error == null || error.isEmpty) continue;
      final failure = (stat.tag, error);
      current[group.selector] = failure;
      if (_probeErrors[group.selector] != failure) {
        added.add(
          ClashLogLine(
            'error',
            '[probe] selector=${group.selector} node=${stat.tag}: $error',
            DateTime.now(),
          ),
        );
      }
    }
    // A successful check (or a changed selection) resets deduplication, so
    // the same failure after recovery is recorded again. Clearing the visible
    // log deliberately keeps this snapshot until the next actual change.
    _probeErrors
      ..clear()
      ..addAll(current);
    if (added.isEmpty) return;
    setState(() {
      _lines.addAll(added);
      _probeLines.addAll(added);
      while (_probeLines.length > _maxProbeLines) {
        _lines.remove(_probeLines.removeAt(0));
      }
      _trimLines();
    });
    _toEnd();
  }

  Future<void> _loadFile() async {
    final text = await widget.state.vpn.readLog();
    if (text == null || !mounted || _paused) return;
    final lines = text.split('\n').where((l) => l.trim().isNotEmpty).map((l) {
      final lvl =
          RegExp(
            r'\b(ERROR|WARN|INFO|DEBUG|TRACE|FATAL)\b',
            caseSensitive: false,
          ).firstMatch(l)?.group(1)?.toLowerCase() ??
          'info';
      return ClashLogLine(lvl, l, DateTime.now());
    }).toList();
    final live = widget.state.clash != null;
    if (live && _fileHistoryLoaded) return;
    setState(() {
      if (live) {
        // A live event can arrive before the native file read finishes. Keep
        // both so the previous background stop is still visible after recovery.
        _lines.insertAll(0, lines);
      } else {
        _lines
          ..clear()
          ..addAll(lines)
          ..addAll(_probeLines);
      }
      _trimLines();
      _fileHistoryLoaded = true;
    });
    _toEnd();
  }

  void _add(ClashLogLine l) {
    if (_paused) return;
    setState(() {
      _lines.add(l);
      _trimLines();
    });
    _toEnd();
  }

  void _trimLines() {
    if (_lines.length <= _maxLines) return;
    final removed = _lines.take(_lines.length - _maxLines).toSet();
    _lines.removeRange(0, _lines.length - _maxLines);
    _probeLines.removeWhere(removed.contains);
  }

  void _togglePause() {
    setState(() => _paused = !_paused);
    if (!_paused) {
      _captureProbeErrors();
      _loadFile();
    }
  }

  void _toEnd() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients &&
          _scroll.position.maxScrollExtent - _scroll.offset < 200) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  @override
  void dispose() {
    widget.state.removeListener(_captureProbeErrors);
    _sub?.cancel();
    _fileTimer?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  /// Level marker: red / amber carry meaning; everything else is neutral.
  Color _levelColor(MelsiColors c, String level) => switch (level) {
        'error' || 'fatal' => c.danger,
        'warning' || 'warn' => c.warning,
        'debug' || 'trace' => c.separator,
        _ => c.tertiaryLabel,
      };

  @override
  Widget build(BuildContext context) {
    final l = context.l;
    final c = context.c;
    final f = _filter.toLowerCase();
    final shown = f.isEmpty ? _lines : _lines.where((e) => e.payload.toLowerCase().contains(f)).toList();
    return Scaffold(
      backgroundColor: c.background,
      appBar: AppBar(
        backgroundColor: Colors.transparent,
        surfaceTintColor: Colors.transparent,
        scrolledUnderElevation: 0,
        flexibleSpace: const Chrome(child: SizedBox.expand()),
        title: Text(l('settings.logs'), style: context.t.headline),
        actions: [
          IconButton(
            tooltip: _paused ? l('logs.resume') : l('logs.pause'),
            icon: Icon(_paused ? Icons.play_arrow_rounded : Icons.pause_rounded, size: 20),
            onPressed: _togglePause,
          ),
          IconButton(
            tooltip: l('logs.copy'),
            icon: const Icon(Icons.copy_rounded, size: 18),
            onPressed: () {
              Clipboard.setData(ClipboardData(text: shown.map((e) => e.payload).join('\n')));
              widget.state.notice('notice.copied');
            },
          ),
          IconButton(
            tooltip: l('logs.clear'),
            icon: const Icon(Icons.delete_sweep_outlined, size: 20),
            onPressed: () => setState(() {
              _lines.clear();
              _probeLines.clear();
            }),
          ),
        ],
      ),
      body: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(Space.l, Space.m, Space.l, Space.s),
          child: TextField(
            onChanged: (v) => setState(() => _filter = v),
            decoration: InputDecoration(
              hintText: l('logs.filter'),
              prefixIcon: Icon(Icons.filter_list_rounded, size: 18, color: c.tertiaryLabel),
              prefixIconConstraints: const BoxConstraints(minWidth: 38),
            ),
          ),
        ),
        Expanded(
          child: shown.isEmpty
              ? Center(
                  child: EmptyState(
                    icon: Icons.receipt_long_outlined,
                    title: l('logs.empty'),
                    message: widget.state.connected ? l('logs.waiting') : l('logs.notConnected'),
                  ),
                )
              : SelectionArea(
                  child: ListView.builder(
                    controller: _scroll,
                    padding: EdgeInsets.fromLTRB(
                        Space.l, 0, Space.l, Space.l + MediaQuery.paddingOf(context).bottom),
                    itemCount: shown.length,
                    itemBuilder: (context, i) {
                      final e = shown[i];
                      return Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                          Container(
                            width: 2,
                            height: 15,
                            margin: const EdgeInsets.only(top: 2, right: 10),
                            color: _levelColor(c, e.level),
                          ),
                          Expanded(
                            child: Text(e.payload,
                                style: context.t.mono.copyWith(fontSize: 12, fontWeight: FontWeight.w400, height: 1.45)),
                          ),
                        ]),
                      );
                    },
                  ),
                ),
        ),
      ]),
    );
  }
}
