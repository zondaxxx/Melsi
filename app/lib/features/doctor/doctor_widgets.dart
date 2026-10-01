import 'package:flutter/widgets.dart';

import '../../l10n/l10n.dart';
import '../../state/app_state.dart';
import '../../ui/widgets/common.dart';
import '../../ui/widgets/page.dart';
import 'doctor_sheet.dart';

/// Settings › Tools rows: "Диагностика сети" opens the doctor sheet.
List<Widget> doctorRows(BuildContext context, AppState app) => [
      RowTile(
        key: const ValueKey('doctor-row'),
        title: context.l('doctor.title'),
        subtitle: context.l('doctor.subtitle'),
        chevron: true,
        onTap: () => showDoctorSheet(context),
      ),
    ];

/// Opens the doctor: a tall sheet on phones, a dialog on wide layouts. The
/// checks start on open — opening it *is* the request to run them.
Future<void> showDoctorSheet(BuildContext context) =>
    showMelsiSheet(context, expand: true, builder: (_) => const DoctorSheet());
