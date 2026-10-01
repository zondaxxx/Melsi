// Registry of string tables. Each feature module owns one file
// (`strings_<feature>.dart`) and one entry here; the core table comes first.

import 'strings.dart';
import 'strings_onboarding.dart';
import 'strings_motion.dart';
import 'strings_chain.dart';
import 'strings_netcheck.dart';
import 'strings_stats.dart';
import 'strings_favorites.dart';
import 'strings_palette.dart';
import 'strings_backup.dart';
import 'strings_doctor.dart';

const List<StringTable> kStringTables = [
  kCoreStrings,
  kOnboardingStrings,
  kMotionStrings,
  kChainStrings,
  kNetcheckStrings,
  kStatsStrings,
  kFavoritesStrings,
  kPaletteStrings,
  kBackupStrings,
  kDoctorStrings,
];
