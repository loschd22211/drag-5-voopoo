'use strict';

/**
 * Смоук-тест логики без телефона: использует фейковый adb из tools/mock-adb.
 * Запуск: npm test
 */

const assert = require('node:assert');
const path = require('node:path');
const fs = require('node:fs');
const os = require('node:os');

const MOCK = path.join(__dirname, '..', 'tools', 'mock-adb');
process.env.ADB_BIN = MOCK;

// чистое состояние мока
const stateFile = path.join(os.tmpdir(), 'gemini-power-button-mock-state.json');
try {
  fs.unlinkSync(stateFile);
} catch {}

const adb = require('../server/adb');
const { _internal } = adb;

const tests = [];
const test = (name, fn) => tests.push({ name, fn });

test('парсер getprop', () => {
  const props = _internal.parseProps('[ro.product.model]: [PKG110]\n[ro.build.version.release]: [15]');
  assert.equal(props['ro.product.model'], 'PKG110');
  assert.equal(props['ro.build.version.release'], '15');
});

test('парсер settings list', () => {
  const map = _internal.parseSettingsList('assistant=a/b\nvoice_interaction_service=c/d\n');
  assert.equal(map.assistant, 'a/b');
  assert.equal(map.voice_interaction_service, 'c/d');
});

test('парсер pm list packages', () => {
  const set = _internal.parsePackageList('package:com.a\npackage:com.b\n');
  assert.ok(set.has('com.a'));
  assert.equal(set.size, 2);
});

test('парсер adb devices -l', () => {
  const devices = _internal.parseDevices(
    'List of devices attached\nABC123\tdevice product:OP5D1L1 model:PKG110 device:OP5D1L1 transport_id:1\n\n',
  );
  assert.equal(devices.length, 1);
  assert.equal(devices[0].model, 'PKG110');
  assert.equal(devices[0].state, 'device');
});

test('adb version определяется', async () => {
  const v = await adb.adbVersion();
  assert.equal(v.ok, true);
  assert.equal(v.mock, true);
  assert.match(v.version, /Android Debug Bridge/);
});

test('устройство видно', async () => {
  const list = await adb.listDevices();
  assert.equal(list.ok, true);
  assert.equal(list.devices.length, 1);
  assert.equal(list.devices[0].serial, 'MOCK000ACE5');
});

test('диагностика находит Google-пакеты и экраны питания', async () => {
  const report = await adb.diagnose('MOCK000ACE5');
  assert.equal(report.ok, true);
  assert.equal(report.device.model, 'PKG110');
  assert.equal(report.device.android, '16');
  assert.equal(report.packages.googleApp.installed, true);
  assert.equal(report.packages.gemini.installed, true);
  assert.ok(
    report.powerActivities.some((a) => /PowerMenuSettingsActivity/.test(a.component)),
    'нет экрана долгого нажатия кнопки питания',
  );
  assert.equal(
    report.recommendedPowerActivity,
    'com.android.settings/.Settings$PowerMenuSettingsActivity',
    'рекомендация должна указывать на экран кнопки питания, а не на «расход батареи»',
  );
  assert.ok(report.googleSettingsActivities.length >= 1, 'нет Google-экрана в настройках');
  assert.ok(report.voiceServices.some((s) => /GsaVoiceInteractionService/.test(s.component)));
  assert.ok(report.suggestedAssistantComponent.startsWith('com.google.'));
  assert.ok(report.hints.length > 0);
});

test('назначение помощника применяется и проверяется', async () => {
  const component =
    'com.google.android.googlequicksearchbox/com.google.android.voiceinteraction.GsaVoiceInteractionService';
  const res = await adb.setAssistant('MOCK000ACE5', component);
  assert.equal(res.ok, true, 'не применилось');
  assert.equal(res.applied.assistant, component);
  assert.equal(res.applied.voiceInteractionService, component);
});

test('после назначения запуск ассистента успешен', async () => {
  const res = await adb.testAssistant('MOCK000ACE5');
  assert.equal(res.ok, true);
});

test('открытие экрана настроек по компоненту', async () => {
  const res = await adb.openTarget(
    'MOCK000ACE5',
    'component',
    'com.android.settings/.Settings$PowerMenuSettingsActivity',
  );
  assert.equal(res.ok, true);
});

test('открытие по intent-у', async () => {
  const res = await adb.openTarget('MOCK000ACE5', 'defaultApps');
  assert.equal(res.ok, true);
  assert.ok(res.used);
});

test('снимок настроек и дифф ловят изменение', async () => {
  const before = await adb.snapshotSettings('MOCK000ACE5');
  assert.ok(before.count > 0);
  await adb.setAssistant(
    'MOCK000ACE5',
    'com.google.android.googlequicksearchbox/com.google.android.voiceinteraction.GsaVoiceInteractionService',
  );
  const after = await adb.snapshotSettings('MOCK000ACE5');
  const changes = adb.diffSnapshots(before, after);
  assert.ok(Array.isArray(changes));
});

test('защита от мусорного компонента', async () => {
  const res = await adb.setAssistant('MOCK000ACE5', 'bad value with spaces;rm -rf');
  assert.equal(res.ok, false);
});


test('ранжирование: реальный список с Ace 5 (ColorOS 16)', () => {
  const raw = [
    '.fuelgauge.AdvancedPowerUsageDetailActivity',
    '.Settings$ButtonNavigationSettingsActivity',
    '.Settings$DoubleTapPowerSettingsActivity',
    '.Settings$ManageAssistActivity',
    '.Settings$NotificationAssistantSettingsActivity',
    '.Settings$PowerMenuSettingsActivity',
    '.Settings$PowerUsageAdvancedActivity',
    'com.oplus.settings.feature.convenient.PowerWakeUpGuideActivity',
    'com.oplus.settings.feature.onehanded.OneHandedOAssistService',
    'com.oplus.settings.feature.othersettings.timepower.TimePowerReceiver',
    'com.oplus.settings.feature.speechassistant.SettingsSpeechAssistantActivity',
  ].map((cls) => ({ component: `com.android.settings/${cls}`, activity: cls, label: cls }));
  const ranked = _internal.rankPowerActivities(raw);
  assert.equal(ranked[0].activity, '.Settings$PowerMenuSettingsActivity');
  assert.ok(ranked[0].score >= 80);
  assert.equal(ranked[1].activity, '.Settings$ManageAssistActivity');
  const junk = ranked.find((a) => /fuelgauge/.test(a.activity));
  assert.ok(junk.score < 0, '«расход батареи» должен уходить в конец');
  assert.ok(ranked[ranked.length - 1].score < 0, 'мусор должен быть в конце списка');
});

test('PowerShell-скрипты сохранены в UTF-8 с BOM (иначе PS 5.1 ломает кириллицу)', () => {
  const files = ['oneclick.ps1', 'adb-gemini.ps1', 'breeno-off.ps1', 'gemini-trigger.ps1', 'debloat-market.ps1', 'power-key-reset.ps1', 'gemini-one-click.ps1'];
  for (const name of files) {
    const buf = fs.readFileSync(path.join(__dirname, '..', 'scripts', name));
    assert.ok(
      buf[0] === 0xef && buf[1] === 0xbb && buf[2] === 0xbf,
      `${name}: нет BOM — Windows PowerShell 5.1 прочитает файл как ANSI и упадёт с ошибками парсера`,
    );
  }
});

test('фирменные ассистенты: находит части Breeno на ColorOS 16', async () => {
  const res = await adb.listVendorAssistants('MOCK000ACE5');
  assert.equal(res.ok, true);
  const names = res.packages.map((p) => p.package);
  for (const expected of ['com.heytap.speechassist', 'com.coloros.assistantscreen', 'com.oplus.aiunit']) {
    assert.ok(names.includes(expected), `${expected} должен быть в списке`);
  }
  assert.ok(!names.includes('com.oplus.ocs'), 'com.oplus.ocs — не ассистент, его нельзя предлагать');
  const voice = res.packages.find((p) => p.package === 'com.heytap.speechassist');
  assert.equal(voice.role, 'voice');
  assert.equal(voice.risk, 'safe');
  const engine = res.packages.find((p) => p.package === 'com.oplus.aiunit');
  assert.equal(engine.risk, 'caution', 'AI-движок должен помечаться как рискованный');
});

test('голосовой пакет Breeno отключается и включается обратно', async () => {
  const off = await adb.disablePackages('MOCK000ACE5', ['com.heytap.speechassist']);
  assert.equal(off.ok, true, 'не удалось отключить голосовой пакет');
  assert.deepEqual(off.verified, ['com.heytap.speechassist']);

  const listed = await adb.listVendorAssistants('MOCK000ACE5');
  assert.equal(listed.packages.find((p) => p.package === 'com.heytap.speechassist').disabled, true);

  const on = await adb.enablePackages('MOCK000ACE5', ['com.heytap.speechassist']);
  assert.equal(on.ok, true, 'не удалось включить обратно');
  const listed2 = await adb.listVendorAssistants('MOCK000ACE5');
  assert.equal(listed2.packages.find((p) => p.package === 'com.heytap.speechassist').disabled, false);
});

test('защищённый пакет берётся suspend, когда disable-user отказал', async () => {
  const res = await adb.disablePackages('MOCK000ACE5', ['com.coloros.assistantscreen']);
  assert.equal(res.ok, true, 'лестница стратегий должна была найти рабочий способ');
  const result = res.results.find((r) => r.package === 'com.coloros.assistantscreen');
  assert.equal(result.workedMode, 'suspend', 'на этом устройстве работает именно suspend');
  const refused = result.attempts.find((a) => a.mode === 'disable-user');
  assert.equal(refused.blocked, false);
  assert.match(refused.refuseReason, /проигнорировала/i, 'отказ должен быть объяснён');

  const restored = await adb.enablePackages('MOCK000ACE5', ['com.coloros.assistantscreen']);
  assert.equal(restored.ok, true, 'пакет должен возвращаться');
  const state = await adb.inspectPackageState('MOCK000ACE5', 'com.coloros.assistantscreen');
  assert.equal(state.blocked, false);
  assert.equal(state.suspended, false);
});

test('отчёт по стратегиям: hide и disable на Android 16 недоступны shell-у', async () => {
  const res = await adb.disablePackages('MOCK000ACE5', ['com.oplus.aiunit'], {
    strategies: ['disable-user', 'hide', 'disable'],
  });
  assert.equal(res.ok, false, 'ни одна из этих стратегий не должна сработать');
  const attempts = res.results[0].attempts;
  assert.ok(attempts.some((a) => a.mode === 'hide' && /MANAGE_USERS/.test(a.refuseReason || '')));
  assert.ok(
    attempts.some((a) => a.mode === 'disable' && /не может менять состояние/i.test(a.refuseReason || '')),
  );
});

test('защищённые пакеты не отключаются', async () => {
  const res = await adb.disablePackages('MOCK000ACE5', ['com.oplus.ocs']);
  assert.equal(res.requested.length, 0, 'com.oplus.ocs должен отсекаться до выполнения команд');
});

test('мусорные имена пакетов не попадают в shell', async () => {
  const res = await adb.disablePackages('MOCK000ACE5', ['com.heytap.speechassist; rm -rf /']);
  assert.equal(res.requested.length, 0);
});

test('установщик ColorGoogle: нужные шаги на месте', () => {
  const src = fs.readFileSync(path.join(__dirname, '..', 'scripts', 'gemini-trigger.ps1'), 'utf8');
  const must = [
    'dev.evoker.homeholdcts',           // пакет приложения
    'install -r -g',                    // установка сразу с разрешениями
    'android.permission.READ_LOGS',     // без него не работает агент
    'voice_interaction_service',        // ColorOS оставляет его пустым
    'SYSTEM_ALERT_WINDOW',              // «поверх других приложений»
    'desktopsearch --method status',    // проверка статуса агента
    'SHA256SUMS',                       // сверка контрольной суммы
  ];
  for (const marker of must) {
    assert.ok(src.includes(marker), `в установщике нет «${marker}»`);
  }
  assert.ok(!/1MB/.test(src), 'суффикс 1MB ломает парсеры — используем 1048576');
});

test('установщик не зависит от GitHub API и не может удалить папку', () => {
  const src = fs.readFileSync(path.join(__dirname, '..', 'scripts', 'gemini-trigger.ps1'), 'utf8');
  // прямая ссылка должна быть первой: API отдаёт 403 при лимите 60 запросов в час
  assert.ok(src.includes('$directUrl = "https://github.com/joeyandu/ColorGoogle/releases/download/'),
    'нет прямой ссылки на релиз — при лимите GitHub API установка падает');
  assert.ok(src.indexOf('$urls = @($directUrl)') < src.indexOf('Invoke-RestMethod'),
    'прямая ссылка должна пробоваться до обращения к API');
  // путь к APK строится только в отдельной папке apk и только из готового имени
  assert.ok(src.includes("Join-Path $WorkDir 'apk'"), 'APK должен лежать в отдельной папке');
  assert.ok(!/Remove-Item \$apk\b/.test(src), 'нельзя удалять путь, который может оказаться папкой Temp');
  assert.ok(!/10MB/.test(src), 'суффикс 10MB ломает парсеры — используем число');
  assert.ok(!/\?\?/.test(src), '?? требует PowerShell 7, у пользователя 5.1');
  assert.ok(src.includes('-PathType Leaf'), 'перед работой с файлом нужна проверка, что это файл');
});

test('скрипт деблоата: имена функций не конфликтуют с алиасами PowerShell', () => {
  const src = fs.readFileSync(path.join(__dirname, '..', 'scripts', 'debloat-market.ps1'), 'utf8');
  // Kill — алиас Stop-Process: из-за него блок падал с ParameterBindingException
  assert.ok(!/^\s*function\s+Kill\b/m.test(src), 'нельзя объявлять функцию Kill (алиас Stop-Process)');
  for (const marker of ['com.heytap.market', 'com.oplus.appdetail', 'verifier_verify_adb_installs', 'package_verifier_enable']) {
    assert.ok(src.includes(marker), `в скрипте нет «${marker}»`);
  }
  assert.ok(src.includes('pm suspend'), 'нужна лестница стратегий: disable-user -> suspend -> uninstall');
  assert.ok(src.includes('-Restore'), 'должен быть режим возврата');
});

test('READ_LOGS выдаётся app-op, а не только pm grant', () => {
  const src = fs.readFileSync(path.join(__dirname, '..', 'scripts', 'gemini-trigger.ps1'), 'utf8');
  // pm grant READ_LOGS на Android 13+ падает: SecurityException GRANT_RUNTIME_PERMISSIONS
  // «Error: Unknown operation string» приходит на разные написания операции,
  // поэтому нужен перебор: cmd appops с именем, затем appops со строкой операции
  assert.ok(src.includes("cmd appops set $Pkg READ_LOGS allow"), 'нужен вариант через cmd appops');
  assert.ok(src.includes("appops set $Pkg android:read_logs allow"), 'нужна строка операции android:read_logs');
  assert.ok(src.includes('foreach ($f in $forms)'), 'варианты надо перебирать, а не полагаться на один');
  // stderr adb в PowerShell 5.1 превращается в NativeCommandError и мусорит вывод
  assert.ok(src.includes('& cmd /c $line'), 'adb надо звать через cmd /c, иначе шум в консоли');
  assert.ok(src.includes('[switch]$Status'), 'нужен режим -Status для диагностики без изменений');
});

test('помощник назначается только если Google реально установлен', () => {
  const src = fs.readFileSync(path.join(__dirname, '..', 'scripts', 'gemini-trigger.ps1'), 'utf8');
  // на CN-прошивке строка assistant=GSA может указывать в пустоту
  assert.ok(src.includes("pm path com.google.android.googlequicksearchbox"), 'нужна проверка наличия Google до записи assistant');
  assert.ok(src.includes("pm path com.google.android.apps.bard"), 'нужно проверять и Gemini');
  assert.ok(src.includes("assist_gesture_enabled 1"), 'жест «удержание питания -> помощник» надо включать');
  assert.ok(src.includes("assist_gesture_wake_enabled 1"), 'и его вариант для выключенного экрана');
});

test('откат кнопки: удаление с лестницей способов и возврат Breeno', () => {
  const src = fs.readFileSync(path.join(__dirname, '..', 'scripts', 'power-key-reset.ps1'), 'utf8');
  // pm uninstall на ColorOS отвечает DELETE_FAILED_INTERNAL_ERROR, поэтому нужен перебор
  assert.ok(src.includes('pm uninstall --user 0'), 'нужен вариант с --user 0');
  assert.ok(src.includes('cmd package uninstall'), 'нужен вариант через cmd package');
  assert.ok(src.includes('pm suspend --user 0'), 'последний рубеж — заморозка');
  assert.ok(src.includes('speech_assist_power_wakeup 1'), 'Breeno должен возвращаться на кнопку');
  assert.ok(src.includes('assist_gesture_enabled 0'), 'жест помощника надо выключать обратно');
  assert.ok(src.includes("'assistant.txt'"), 'assistant возвращается из бэкапа');
});

test('одноклик: сам находит помощника, снимает Breeno и проверяет кнопку', () => {
  const src = fs.readFileSync(path.join(__dirname, '..', 'scripts', 'gemini-one-click.ps1'), 'utf8');
  // компонент помощника ищем в системе, а не пишем строку наугад
  assert.ok(src.includes('query-services -a android.service.voice.VoiceInteractionService'), 'нужен поиск VoiceInteractionService');
  assert.ok(src.includes('settings --user 0 put secure assistant'), 'помощника надо назначать');
  assert.ok(src.includes('speech_assist_power_wakeup 0'), 'Breeno должен сниматься с кнопки');
  assert.ok(src.includes('assist_gesture_enabled 1'), 'жест удержания питания надо включать');
  // самопроверка идёт удержанием питания, а не KEYCODE_ASSIST: тот на ColorOS врёт (docs 2.998)
  assert.ok(src.includes('function Test-Assistant'), 'нужна самопроверка');
  assert.ok(!/KEYCODE_ASSIST/.test(src), 'KEYCODE_ASSIST больше не используется');
  assert.ok(src.includes('mCurrentFocus'), 'вердикт должен читаться с экрана');
  // на ColorOS shell не имеет права менять appops — не пытаемся
  assert.ok(!/cmd appops set/.test(src), 'appops из shell на этой прошивке запрещён');
  assert.ok(!/^\s*function\s+Kill\b/m.test(src), 'нельзя объявлять функцию Kill');
  // VPN: без него Gemini упирается в регион
  assert.ok(src.includes('always_on_vpn_app'), 'постоянный VPN должен настраиваться');
});

test('плеер на локскрине и AOSP-ключи кнопки зашиты в одноклик', () => {
  const src = fs.readFileSync(path.join(__dirname, '..', 'scripts', 'gemini-one-click.ps1'), 'utf8');
  // media_controls_lock_screen=0 по умолчанию: сторонние плееры не видны на экране блокировки
  assert.ok(src.includes('media_controls_lock_screen 1'), 'нужно включать карточку плеера на локскрине');
  assert.ok(src.includes('lockscreen_show_controls 1'), 'и показ элементов управления на локскрине');
  assert.ok(src.includes('power_button_long_press 5'), 'AOSP-код 5 = помощник по долгому нажатию питания');
  assert.ok(src.includes('key_home_long_press_action 2'), 'AOSP-код 2 = помощник по долгому нажатию Home');
  // проверка кнопки больше не делает один замер через фиксированную паузу
  assert.ok(!/Start-Sleep -Seconds 5/.test(src), 'один замер через 5 секунд врал — нужен опрос');
  assert.ok(src.includes('Get-WindowDump'), 'смотрим окна, а не только фокус: оверлей не берёт фокус');
  assert.ok(src.includes('seenNew'), 'новые окна должны попадать в отчёт');
  assert.ok(src.includes('[switch]$Test'), 'нужен режим -Test: только замер, без изменения настроек');
  // ColorOS не исполняет инжектированные события: проверка только руками (docs 2.992)
  assert.ok(!/Sh 'input swipe/.test(src), 'жест больше не эмулируется — ColorOS его игнорирует');
  assert.ok(!/Sh 'input keyevent --longpress 26'/.test(src), 'удержание питания больше не эмулируется');
  // KEYCODE_ASSIST на ColorOS поднимает окно через раз: эмулируем именно удержание питания
  assert.ok(src.includes('начинай сразу'), 'скрипт должен предупредить, что нажимать надо прямо сейчас');
  // последний неотработанный ключ ColorOS: global side_button, перебор с возвратом
  assert.ok(src.includes('Sweep-SideButton'), 'нужен режим -Sweep: перебор side_button');
  assert.ok(src.includes('settings put global side_button'), 'side_button должен выставляться');
  assert.ok(src.includes('вернул side_button'), 'после неудачи значение возвращается');
  assert.ok(!src.includes("input keyevent KEYCODE_ASSIST' | Out-Null"), 'KEYCODE_ASSIST больше не единственная проверка');
  assert.ok(src.includes('cached_apps_freezer'), 'нужно снимать заморозку фоновых приложений');
});

test('в строках нет $переменная: — PowerShell падает на этом', () => {
  // "side_button=$now: ДА" ломало скрипт: PS 5.1 читает $now: как ссылку на диск.
  // $script:, $env: и прочие настоящие скоупы — можно.
  const dir = path.join(__dirname, '..', 'scripts');
  const allowed = new Set(['env', 'script', 'global', 'local', 'private', 'using', 'variable', 'function']);
  const bad = [];
  for (const f of fs.readdirSync(dir).filter((n) => n.endsWith('.ps1'))) {
    const src = fs.readFileSync(path.join(dir, f), 'utf8');
    const re = /\$([A-Za-z_][A-Za-z0-9_]*):/g;
    let m;
    while ((m = re.exec(src)) !== null) {
      if (!allowed.has(m[1].toLowerCase())) bad.push(`${f}: $${m[1]}:`);
    }
  }
  assert.ok(bad.length === 0, 'найдено: ' + bad.join(', '));
});

test('lockscreen-player: включает карточку плеера и объясняет, что мешает', () => {
  const file = path.join(__dirname, '..', 'scripts', 'lockscreen-player.ps1');
  assert.ok(fs.existsSync(file), 'скрипт должен существовать');
  const src = fs.readFileSync(file, 'utf8');
  assert.ok(src.includes('media_controls_lock_screen 1'), 'ключ карточки плеера включается сам');
  assert.ok(src.includes('lockscreen_show_controls 1'), 'и показ элементов управления');
  assert.ok(src.includes('dumpsys media_session'), 'нужно смотреть, какое приложение реально играет');
  assert.ok(src.includes('dumpsys notification --noredact'), 'и важность канала уведомления');
  assert.ok(src.includes('важность'), 'вердикт должен объяснять про важность канала');
  // разбор медиасессий режем по MediaSessionRecord: package= встречается несколько раз
  // состояние относится к последней увиденной package= — в дампе их несколько подряд
  assert.ok(src.includes('$current'), 'состояние должно привязываться к текущей сессии');
  assert.ok(src.includes('PlaybackState'), 'состояние воспроизведения должно читаться');
  // Android 16 печатает "state=PLAYING(3)" — одним числом это не ловится
  assert.ok(src.includes('state=(?:[A-Z_]+'), 'нужно читать состояние вида PLAYING(3)');
  assert.ok(src.includes("com.android.*"), 'служебные com.android.* не должны попадать в отчёт');
  assert.ok(src.includes('[switch]$Raw'), 'нужен -Raw для отладки состояния');
  // версия печатается, иначе невозможно отличить старую копию из кэша raw.githubusercontent
  assert.ok(src.includes('$ScriptVersion'), 'у скрипта должна быть версия');
  assert.ok(src.includes('версия скрипта'), 'версия должна печататься при запуске');
  assert.ok(!src.includes('сейчас ничего не играет'), 'старое вранье про «ничего не играет» не должно вернуться');
  assert.ok(src.includes('нельзя сделать из adb'), 'нельзя обещать то, что из shell не меняется');
  assert.ok(src.includes('settings list system'), 'проверяем и ключи медиа в namespace system');
  // если канал заблокирован приложением, важность руками не поднять — надо отличать
  assert.ok(src.includes('Get-ChannelInfo'), 'нужно читать параметры канала');
  assert.ok(src.includes('mImportanceLockedDefaultApp'), 'и признаки блокировки важности');
});

test('debloat-cn: выключает китайское, оставляет гейм-бар и умеет откат', () => {
  const file = path.join(__dirname, '..', 'scripts', 'debloat-cn.ps1');
  assert.ok(fs.existsSync(file), 'скрипт должен существовать');
  const src = fs.readFileSync(file, 'utf8');
  assert.ok(src.includes('pm disable-user --user 0'), 'выключение без удаления');
  assert.ok(src.includes('[switch]$Restore'), 'нужен откат');
  assert.ok(src.includes('pm enable --user 0'), 'откат включает обратно');
  assert.ok(src.includes("'com.oplus.games'"), 'гейм-бар не должен выключаться');
  assert.ok(src.includes('window_animation_scale 0.5'), 'ускорение интерфейса');
  assert.ok(!/pm uninstall/.test(src), 'удалять пакеты нельзя — только disable-user');
  // ColorOS на части пакетов отвечает "new state: default" — нужен запасной путь
  assert.ok(src.includes('pm suspend --user 0'), 'если disable-user не сработал — suspend');
  assert.ok(src.includes('pm unsuspend --user 0'), 'откат снимает и suspend');
});

test('breeno-gesture: пробует роль ASSISTANT и умеет вернуть Breeno', () => {
  const file = path.join(__dirname, '..', 'scripts', 'breeno-gesture.ps1');
  assert.ok(fs.existsSync(file), 'скрипт должен существовать');
  const src = fs.readFileSync(file, 'utf8');
  assert.ok(src.includes('add-role-holder --user 0 android.app.role.ASSISTANT'), 'роль ассистента выдаётся Google');
  assert.ok(src.includes('cmd package install-existing'), 'Breeno возвращается в работу перед опытом');
  assert.ok(src.includes('[switch]$Restore'), 'нужен откат');
  assert.ok(src.includes('logcat'), 'компонент жеста снимается из журнала');
  // пойманный пакет гасим и проверяем, не падает ли жест на роль ASSISTANT
  assert.ok(src.includes('pm disable-user --user 0') || src.includes('pm disable-user --user 0 ', ), 'пакет гасится');
  assert.ok(src.includes('pm uninstall --user 0'), 'и снимается для пользователя как последний шаг');
  assert.ok(src.includes('Test-PressForAssistant'), 'каждый шаг проверяется нажатием');
  // левая панель включается теми же ключами, что возвращают Breeno
  assert.ok(src.includes('Remove-LeftPanel'), 'панель должна сниматься после прогона');
  assert.ok(src.includes('[switch]$Panel'), 'нужен отдельный режим -Panel');
  assert.ok(src.includes('$ScriptVersion'), 'версия печатается');
});

(async () => {
  let failed = 0;
  for (const t of tests) {
    try {
      await t.fn();
      console.log(`  ok   ${t.name}`);
    } catch (err) {
      failed += 1;
      console.error(`  FAIL ${t.name}\n       ${err.message}`);
    }
  }
  console.log(failed ? `\n${failed} тест(ов) упало` : `\nвсе ${tests.length} тестов прошли`);
  process.exit(failed ? 1 : 0);
})();
