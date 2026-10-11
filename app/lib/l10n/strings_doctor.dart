// Strings owned by the doctor feature. Keys start with doctor.;
// Russian first, English mirrors every key.

import 'strings.dart';

const StringTable kDoctorStrings = StringTable(
  prefixes: ['doctor.'],
  ru: <String, String>{
    // entry
    'doctor.title': 'Диагностика сети',
    'doctor.subtitle': 'Пошаговая проверка соединения',

    // steps (ids double as titles)
    'doctor.internet': 'Интернет',
    'doctor.server': 'Сервер',
    'doctor.core': 'Ядро',
    'doctor.tunnel': 'Туннель',
    'doctor.dns': 'Сервис DNS через туннель',
    'doctor.leak': 'Утечка IP',
    'doctor.rulesets': 'Наборы правил',
    'doctor.clock': 'Время',

    // step details
    'doctor.pending': 'ожидание',
    'doctor.checking': 'проверяем…',
    'doctor.skipped': 'пропущено: не подключено',
    'doctor.skippedIos': 'пропущено: недоступно на iOS',
    'doctor.notRun': 'не проверялось',
    'doctor.noServer': 'сервер не выбран',
    'doctor.timeout': 'нет ответа',
    'doctor.error': 'ошибка проверки',
    'doctor.dnsBroken': 'сеть есть, DNS не отвечает',
    'doctor.tcpBlocked': 'DNS работает, соединения блокируются',
    'doctor.noCore': 'ядро не найдено',
    'doctor.coreOk': 'отвечает',
    'doctor.noApi': 'API ядра недоступен',
    'doctor.leakUnknown': 'не удалось определить IP',
    'doctor.leakSame': 'IP не изменился',
    'doctor.leakOk': 'IP отличается от реального',
    'doctor.rulesetsNone': 'файлы не найдены',
    'doctor.rulesetsN': '{n} .srs',
    'doctor.clockUnknown': 'не удалось сверить',

    'doctor.udpServer': 'TCP-проверка неприменима к UDP-серверу',
    'doctor.probeService':
        'Другой сайт через VPN отвечает; основной адрес проверки недоступен',
    'doctor.probe.dns':
        'Проверка не прошла: не удалось разрешить имя через DNS',
    'doctor.probe.tls':
        'Проверка не прошла: ошибка защищённого соединения TLS/REALITY',
    'doctor.probe.authentication': 'Сервер отклонил данные доступа',
    'doctor.probe.refused': 'Соединение при проверке отклонено',
    'doctor.probe.route': 'Сеть или маршрут до адреса проверки недоступны',
    'doctor.probe.timeout': 'Время ожидания проверки истекло',
    'doctor.probe.core': 'Локальное API ядра недоступно или отклонило запрос',
    'doctor.probe.unknown': 'Проверка не прошла; подробности в журнале',
    'doctor.v.probeService': 'VPN отвечает, но выбранный адрес проверки недоступен. Попробуйте другой URL проверки в настройках.',

    // status glyph semantics
    'doctor.st.ok': 'в порядке',
    'doctor.st.warn': 'замечание',
    'doctor.st.fail': 'сбой',
    'doctor.st.skipped': 'пропущено',

    // verdict
    'doctor.verdict': 'Диагноз',
    'doctor.running': 'Проверяем…',
    'doctor.v.offline': 'Сетевые проверки не отвечают: проверьте подключение к интернету и туннель',
    'doctor.v.port':
        'Порт сервера не отвечает: попробуйте другой сервер или анти-DPI',
    'doctor.v.core': 'Ядро недоступно: переподключитесь и проверьте журнал',
    'doctor.v.tunnel': 'HTTPS-проверки через VPN не проходят. Причина может быть в сервере, DNS или доступности сайтов проверки; подробности в журнале.',
    'doctor.v.dns': 'Сервис проверки DNS недоступен через VPN. Это не доказывает сбой DNS устройства.',
    'doctor.v.clock': 'Проверьте время на устройстве',
    'doctor.v.leak': 'Трафик идёт мимо туннеля',
    'doctor.v.warn': 'Проверка завершена с замечаниями',
    'doctor.v.ok': 'Всё в порядке',
    'doctor.v.partial': 'Проверка не завершена',
    'doctor.fix.antiDpi': 'Включить анти-DPI',
    'doctor.fix.switch': 'Сменить сервер',
    'doctor.antiDpiOn': 'Анти-DPI включён',

    // actions
    'doctor.copy': 'Скопировать отчёт',
    'doctor.again': 'Повторить',
    'doctor.report.title': 'Отчёт диагностики',
  },
  en: <String, String>{
    'doctor.title': 'Network diagnostics',
    'doctor.subtitle': 'Step-by-step connection check',

    'doctor.internet': 'Internet',
    'doctor.server': 'Server',
    'doctor.core': 'Core',
    'doctor.tunnel': 'Tunnel',
    'doctor.dns': 'DNS service via tunnel',
    'doctor.leak': 'IP leak',
    'doctor.rulesets': 'Rule-sets',
    'doctor.clock': 'Clock',

    'doctor.pending': 'waiting',
    'doctor.checking': 'checking…',
    'doctor.skipped': 'skipped: not connected',
    'doctor.skippedIos': 'skipped: unavailable on iOS',
    'doctor.notRun': 'not checked',
    'doctor.noServer': 'no server selected',
    'doctor.timeout': 'no response',
    'doctor.error': 'check failed',
    'doctor.dnsBroken': 'network up, DNS does not answer',
    'doctor.tcpBlocked': 'DNS works, connections are blocked',
    'doctor.noCore': 'core not found',
    'doctor.coreOk': 'responds',
    'doctor.noApi': 'core API unavailable',
    'doctor.leakUnknown': 'could not determine the IP',
    'doctor.leakSame': 'the IP did not change',
    'doctor.leakOk': 'differs from the real IP',
    'doctor.rulesetsNone': 'no files found',
    'doctor.rulesetsN': '{n} .srs',
    'doctor.clockUnknown': 'could not compare',

    'doctor.udpServer': 'A TCP check does not apply to this UDP server',
    'doctor.probeService': 'Another site answers through the VPN; the primary probe URL is unavailable',
    'doctor.probe.dns': 'Probe failed: DNS could not resolve a name',
    'doctor.probe.tls':
        'Probe failed: TLS/REALITY handshake or certificate error',
    'doctor.probe.authentication': 'The server rejected the credentials',
    'doctor.probe.refused': 'The probe connection was refused',
    'doctor.probe.route':
        'The network or route to the probe destination is unavailable',
    'doctor.probe.timeout': 'The probe timed out',
    'doctor.probe.core':
        'The local core API is unavailable or rejected the request',
    'doctor.probe.unknown': 'The probe failed; see the log for details',
    'doctor.v.probeService': 'The VPN responds, but the selected probe URL is unavailable. Try another probe URL in Settings.',

    'doctor.st.ok': 'ok',
    'doctor.st.warn': 'warning',
    'doctor.st.fail': 'failed',
    'doctor.st.skipped': 'skipped',

    'doctor.verdict': 'Verdict',
    'doctor.running': 'Checking…',
    'doctor.v.offline': 'Network checks did not respond: check the internet connection and tunnel',
    'doctor.v.port':
        'The server port does not answer: try another server or anti-DPI',
    'doctor.v.core': 'The core is unavailable: reconnect and check the log',
    'doctor.v.tunnel': 'HTTPS checks through the VPN failed. The server, DNS or probe sites may be unavailable; see the log for details.',
    'doctor.v.dns': 'The DNS test service is unreachable through the VPN. This does not establish a device DNS failure.',
    'doctor.v.clock': 'Check the device clock',
    'doctor.v.leak': 'Traffic bypasses the tunnel',
    'doctor.v.warn': 'Checks completed with remarks',
    'doctor.v.ok': 'All good',
    'doctor.v.partial': 'Check incomplete',
    'doctor.fix.antiDpi': 'Enable anti-DPI',
    'doctor.fix.switch': 'Switch server',
    'doctor.antiDpiOn': 'Anti-DPI enabled',

    'doctor.copy': 'Copy report',
    'doctor.again': 'Run again',
    'doctor.report.title': 'Diagnostics report',
  },
);
