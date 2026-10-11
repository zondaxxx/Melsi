// Strings owned by the netcheck feature. Keys start with geo. / speed.;
// Russian first, English mirrors every key.

import 'strings.dart';

const StringTable kNetcheckStrings = StringTable(
  prefixes: ['geo.', 'speed.'],
  ru: <String, String>{
    'speed.error.dns':
        'Не удалось разрешить имя сервера теста. Проверьте DNS и соединение.',
    'speed.error.tls':
        'Не удалось установить защищённое соединение с сервером теста.',
    'speed.error.proxy':
        'Локальный VPN-прокси недоступен. Переподключитесь и повторите тест.',
    'speed.error.notReady':
        'Подключение ещё не готово. Повторите тест после подключения.',
    'speed.interrupted.connection':
        'Соединение изменилось — запустите новый тест.',
    'speed.interrupted.background':
        'Тест остановлен после сворачивания приложения.',

    // «Где я»: public IP panel
    'geo.title': 'Сеть',
    'geo.yours': 'Ваш IP',
    'geo.exit': 'Выход',
    'geo.noAnswer': 'нет ответа',
    'geo.checking': 'проверяю…',
    'geo.leakDirect': 'Трафик идёт напрямую',
    'geo.leakMaybe': 'Похоже на утечку',
    'geo.setting': 'Проверять IP',
    'geo.settingHint': 'Запрос к ipwho.is / ip.sb / ipinfo.io',
    'geo.refreshCmd': 'Обновить IP',
    'geo.copyCmd': 'Скопировать IP',

    // in-tunnel speed test
    'speed.title': 'Скорость',
    'speed.cmd': 'Тест скорости',
    'speed.phase.ping': 'Пинг',
    'speed.phase.down': 'Загрузка',
    'speed.phase.up': 'Отдача',
    'speed.phase.done': 'Результат',
    'speed.run': 'Запустить',
    'speed.cancel': 'Отмена',
    'speed.note':
        'Оценка по одному соединению. Тест расходует ~60 МБ трафика подписки.',
    'speed.quota': 'Квота подписки почти исчерпана',
    'speed.prev': '{ago} · ↓ {d} ↑ {u}',
    'speed.direct': 'напрямую',
    'speed.notMeasured': 'Ещё не измеряли',
    'speed.failed': 'Не удалось измерить',
    'speed.failedAt': '{phase}: {reason}',
    'speed.error.timeout': 'Сервер теста не ответил вовремя',
    'speed.error.server': 'Сервер теста вернул ошибку HTTP {status}',
    'speed.error.connection': 'Соединение с сервером теста прервалось',
    'speed.error.empty': 'Сервер теста не передал данные',
    'speed.previous': 'Предыдущие',
  },
  en: <String, String>{
    'speed.error.dns':
        'Could not resolve the test server. Check DNS and your connection.',
    'speed.error.tls':
        'Could not establish a secure connection to the test server.',
    'speed.error.proxy':
        'The local VPN proxy is unavailable. Reconnect and try again.',
    'speed.error.notReady':
        'The connection is not ready. Try again after connecting.',
    'speed.interrupted.connection': 'The connection changed. Start a new test.',
    'speed.interrupted.background':
        'The test stopped when the app went into the background.',

    'geo.title': 'Network',
    'geo.yours': 'Your IP',
    'geo.exit': 'Exit',
    'geo.noAnswer': 'no answer',
    'geo.checking': 'checking…',
    'geo.leakDirect': 'Traffic is going direct',
    'geo.leakMaybe': 'Looks like a leak',
    'geo.setting': 'Check public IP',
    'geo.settingHint': 'Queries ipwho.is / ip.sb / ipinfo.io',
    'geo.refreshCmd': 'Refresh IP',
    'geo.copyCmd': 'Copy public IP',

    'speed.title': 'Speed',
    'speed.cmd': 'Speed test',
    'speed.phase.ping': 'Ping',
    'speed.phase.down': 'Download',
    'speed.phase.up': 'Upload',
    'speed.phase.done': 'Result',
    'speed.run': 'Run',
    'speed.cancel': 'Cancel',
    'speed.note':
        'Single-connection estimate. Uses ~60 MB of subscription traffic.',
    'speed.quota': 'Subscription quota nearly used',
    'speed.prev': '{ago} · ↓ {d} ↑ {u}',
    'speed.direct': 'direct',
    'speed.notMeasured': 'Not measured yet',
    'speed.failed': 'Could not measure',
    'speed.failedAt': '{phase}: {reason}',
    'speed.error.timeout': 'The test server did not respond in time',
    'speed.error.server': 'The test server returned HTTP {status}',
    'speed.error.connection':
        'The connection to the test server was interrupted',
    'speed.error.empty': 'The test server transferred no data',
    'speed.previous': 'Previous',
  },
);
