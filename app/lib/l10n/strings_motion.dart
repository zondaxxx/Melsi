// Strings owned by the motion feature. Keys start with motion.;
// Russian first, English mirrors every key.

import 'strings.dart';

const StringTable kMotionStrings = StringTable(
  prefixes: ['motion.'],
  ru: <String, String>{
    // Session summary under the status headline after a disconnect.
    'motion.summary': 'Сессия {t} · ↓ {down} · ↑ {up}',
    'motion.summary.short': 'Сессия {t}',
  },
  en: <String, String>{
    'motion.summary': 'Session {t} · ↓ {down} · ↑ {up}',
    'motion.summary.short': 'Session {t}',
  },
);
