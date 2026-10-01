// Command-palette entry for the double VPN. There is no chain service (the
// feature is pure config), so the chain widgets register the command on
// their first build; [registerChainCommands] is idempotent, and every
// caller may invoke it as often as it likes.

import 'package:flutter/material.dart';

import '../../state/app_scope.dart';
import '../../state/features.dart';

/// Id of the toggle command (see [registerChainCommands]).
const String kChainToggleCommand = 'chain.toggle';

/// Registers `chain.toggle` once per [Features]. Safe to call from a build:
/// nothing is notified when the command is already there.
void registerChainCommands(Features f) {
  if (f.commands.byId(kChainToggleCommand) != null) return;
  f.commands.register(AppCommand(
    id: kChainToggleCommand,
    titleKey: 'chain.toggleCmd',
    group: 'palette.g.settings',
    icon: Icons.route_rounded,
    keywords: const ['double vpn', 'chain', 'двойной', 'цепочка', 'entry', 'входной'],
    isOn: () => f.app.chain.enabled,
    run: (context) async {
      final app = context.appRead;
      app.updateChain((c) => c.enabled = !c.enabled);
    },
  ));
}

/// Registers the chain commands after the current frame, so a widget can
/// call this from `build` without notifying palette listeners mid-build.
void ensureChainCommands(BuildContext context) {
  final f = FeaturesScope.maybeOf(context);
  if (f == null || f.commands.byId(kChainToggleCommand) != null) return;
  WidgetsBinding.instance.addPostFrameCallback((_) => registerChainCommands(f));
}
