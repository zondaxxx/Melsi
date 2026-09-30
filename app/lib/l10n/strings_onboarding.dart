// Strings owned by the onboarding feature. Keys start with onboard.;
// Russian first, English mirrors every key.

import 'strings.dart';

const StringTable kOnboardingStrings = StringTable(
  prefixes: ['onboard.'],
  ru: <String, String>{
    // step 1 — what Melsi does
    'onboard.f1': 'Умный выбор сервера',
    'onboard.f1d': 'Пинг, джиттер и потери измеряются постоянно',
    'onboard.f2': 'Игровой режим',
    'onboard.f2d': 'Отдельная группа серверов для игр',
    'onboard.f3': 'Раздельная маршрутизация',
    'onboard.f3d': 'Российские сайты напрямую, остальное через VPN',
    'onboard.next': 'Далее',
    'onboard.skip': 'Пропустить',

    // step 2 — add a server
    'onboard.addTitle': 'Добавьте сервер',
    'onboard.added': 'Добавлено: {n}',
    'onboard.added.plural': 'сервер|сервера|серверов',
    'onboard.later': 'Позже',

    // step 3 — almost there
    'onboard.finishTitle': 'Почти готово',
    'onboard.permNote': 'При первом подключении система попросит разрешение на VPN',
    'onboard.open': 'Открыть Melsi',

    // settings › app
    'onboard.replay': 'Показать приветствие',
  },
  en: <String, String>{
    'onboard.f1': 'Smart server pick',
    'onboard.f1d': 'Latency, jitter and loss measured continuously',
    'onboard.f2': 'Game mode',
    'onboard.f2d': 'A separate server group for games',
    'onboard.f3': 'Split routing',
    'onboard.f3d': 'Russian sites direct, the rest via VPN',
    'onboard.next': 'Next',
    'onboard.skip': 'Skip',

    'onboard.addTitle': 'Add a server',
    'onboard.added': 'Added: {n}',
    'onboard.added.plural': 'server|servers|servers',
    'onboard.later': 'Later',

    'onboard.finishTitle': 'Almost there',
    'onboard.permNote': 'The system will ask for VPN permission on first connect',
    'onboard.open': 'Open Melsi',

    'onboard.replay': 'Show welcome',
  },
);
