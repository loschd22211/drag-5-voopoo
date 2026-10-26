'use strict';

/**
 * Тонкая обёртка над adb + вся логика диагностики и настройки.
 * Никаких внешних зависимостей: только child_process.
 */

const { execFile } = require('node:child_process');

const ADB_BIN = process.env.ADB_BIN || 'adb';
const IS_MOCK = /mock-adb/i.test(ADB_BIN);
const DEFAULT_TIMEOUT = 25000;

/** Пакеты, которые нас интересуют при диагностике. */
const PACKAGES = {
  googleApp: 'com.google.android.googlequicksearchbox',
  gemini: 'com.google.android.apps.bard',
  gms: 'com.google.android.gms',
  playStore: 'com.android.vending',
  gsf: 'com.google.android.gsf',
  oplusSettings: 'com.oplus.settings',
  colorosSettings: 'com.coloros.settings',
  aospSettings: 'com.android.settings',
  oplusMarket: 'com.heytap.market',
  oplusAppMarket: 'com.oplus.appmarket',
};

/** Пакеты, в которых может жить фирменный китайский ассистент (Breeno и родня). */
const VENDOR_ASSISTANT_RE = /breeno|voiceassist|speechassist|assistantscreen|aiunit/i;

/**
 * Пакеты, которые НЕЛЬЗЯ отключать, даже если они попали под регулярку:
 * это не голосовые ассистенты, а системные/облачные службы OPPO.
 */
const VENDOR_DENYLIST = [/com\.oplus\.ocs$/i, /com\.oplus\.aiunit\.engine$/i, /coloros\.ota/i];

/** Известные компоненты голосовых сервисов Google (fallback, если запрос сервисов не сработал). */
const KNOWN_VOICE_SERVICES = [
  {
    component:
      'com.google.android.googlequicksearchbox/com.google.android.voiceinteraction.GsaVoiceInteractionService',
    label: 'Google (классический компонент GsaVoiceInteractionService)',
    verified: false,
  },
  {
    component:
      'com.google.android.googlequicksearchbox/com.google.android.apps.search.assistant.surfaces.voice.service.AssistantVoiceInteractionService',
    label: 'Google / Gemini (AssistantVoiceInteractionService)',
    verified: false,
  },
];

/** Куда можно «прыгнуть» в настройках. Порядок = порядок попыток. */
const INTENTS = {
  defaultApps: [
    'am start -a android.settings.MANAGE_DEFAULT_APPS_SETTINGS',
    'am start -a android.settings.SETTINGS',
  ],
  voiceInput: [
    'am start -a android.settings.VOICE_INPUT_SETTINGS',
    'am start -a android.settings.MANAGE_DEFAULT_APPS_SETTINGS',
  ],
  assistantSettings: [
    'am start -a com.google.android.settings.ASSISTANT_SETTINGS',
    'am start -a android.settings.VOICE_INPUT_SETTINGS',
  ],
  googleAppInfo: [
    `am start -a android.settings.APPLICATION_DETAILS_SETTINGS -d package:${PACKAGES.googleApp}`,
  ],
  geminiAppInfo: [
    `am start -a android.settings.APPLICATION_DETAILS_SETTINGS -d package:${PACKAGES.gemini}`,
  ],
  playStoreAppInfo: [
    `am start -a android.settings.APPLICATION_DETAILS_SETTINGS -d package:${PACKAGES.playStore}`,
  ],
  accessibility: ['am start -a android.settings.ACCESSIBILITY_SETTINGS'],
  batteryOptimization: [
    `am start -a android.settings.IGNORE_BATTERY_OPTIMIZATION_SETTINGS`,
  ],
};

/** Ключи настроек, изменение которых имеет смысл отслеживать в диффе. */
const INTERESTING_SETTING_KEY_RE = /assist|voice|power|button|key|convenience|shortcut|gesture|gms|google/i;

// ---------------------------------------------------------------------------
// низкий уровень
// ---------------------------------------------------------------------------

function run(cmd, args, { timeout = DEFAULT_TIMEOUT } = {}) {
  return new Promise((resolve) => {
    execFile(
      cmd,
      args,
      { timeout, maxBuffer: 64 * 1024 * 1024, encoding: 'utf8' },
      (err, stdout, stderr) => {
        resolve({
          ok: !err,
          code: err && typeof err.code === 'number' ? err.code : err ? 1 : 0,
          stdout: stdout || '',
          stderr: stderr || '',
          error: err ? String(err.message || err) : null,
        });
      },
    );
  });
}

function adb(args, opts) {
  return run(ADB_BIN, args, opts);
}

function shell(serial, cmd, opts) {
  return adb(['-s', serial, 'shell', cmd], opts);
}

function clip(text, max = 4000) {
  if (typeof text !== 'string') return '';
  return text.length > max ? `${text.slice(0, max)}\n… (обрезано, всего ${text.length} символов)` : text;
}

// ---------------------------------------------------------------------------
// парсеры
// ---------------------------------------------------------------------------

function parseProps(out) {
  const props = {};
  for (const line of String(out).split('\n')) {
    const m = line.match(/^\[([^\]]+)\]:\s*\[(.*)\]\s*$/);
    if (m) props[m[1]] = m[2];
  }
  return props;
}

function parseSettingsList(out) {
  const map = {};
  for (const line of String(out).split('\n')) {
    const trimmed = line.trim();
    if (!trimmed) continue;
    const idx = trimmed.indexOf('=');
    if (idx === -1) continue;
    map[trimmed.slice(0, idx)] = trimmed.slice(idx + 1);
  }
  return map;
}

function parsePackageList(out) {
  const set = new Set();
  for (const line of String(out).split('\n')) {
    const m = line.trim().match(/^package:(.+)$/);
    if (m) set.add(m[1].trim());
  }
  return set;
}

function parseDevices(out) {
  const devices = [];
  const lines = String(out).split('\n');
  for (const line of lines) {
    const trimmed = line.trim();
    if (!trimmed || /^List of devices/i.test(trimmed) || /^\*/.test(trimmed)) continue;
    const parts = trimmed.split(/\s+/);
    const serial = parts[0];
    const state = parts[1];
    if (!serial || !state) continue;
    const extra = {};
    for (const token of parts.slice(2)) {
      const i = token.indexOf(':');
      if (i > 0) extra[token.slice(0, i)] = token.slice(i + 1);
    }
    devices.push({
      serial,
      state,
      model: extra.model || null,
      product: extra.product || null,
      device: extra.device || null,
      transportId: extra.transport_id || null,
    });
  }
  return devices;
}

function parseVoiceServices(out) {
  const found = [];
  const seen = new Set();
  for (const line of String(out).split('\n')) {
    const trimmed = line.trim();
    if (!trimmed || /^(Service|Query|package:|priority=)/i.test(trimmed)) continue;
    // формат: pkg/cls  или  pkg/.cls  или  pkg/cls filter u0 ...
    const m = trimmed.match(/^([a-zA-Z0-9_.]+)\/([A-Za-z0-9_.$]+)/);
    if (!m) continue;
    const component = `${m[1]}/${m[2]}`;
    if (seen.has(component)) continue;
    seen.add(component);
    found.push({ component, label: component, verified: true });
  }
  return found;
}

function prettyActivityLabel(activity) {
  const simple = activity.split('.').pop() || activity;
  return simple
    .replace(/Activity$/, '')
    .replace(/([a-z0-9])([A-Z])/g, '$1 $2')
    .replace(/\bOplus\b/g, 'OPPO/OnePlus')
    .trim();
}

/**
 * Насколько экран полезен для задачи «повесить ассистента на кнопку питания».
 * Чем больше число — тем выше в списке. 0 и меньше = мусор, не показываем как рекомендацию.
 *
 * Правила выведены из реального дампа OnePlus Ace 5 (PKG110, Android 16, ColorOS 16):
 * там рядом с нужными экранами лежат fuelgauge.AdvancedPowerUsageDetailActivity,
 * TimePower*, PowerUsage* и OneHandedOAssistService — они к кнопке питания отношения не имеют.
 */
const POWER_ACTIVITY_SCORES = [
  { re: /PowerMenuSettingsActivity$/i, score: 100, hint: 'долгое нажатие кнопки питания / меню питания' },
  { re: /ManageAssistActivity$/i, score: 95, hint: 'цифровой помощник по умолчанию' },
  { re: /(SpeechAssistant|AssistantSettings)Activity$/i, score: 90, hint: 'голосовой помощник' },
  { re: /(ButtonsAndGestures|ButtonNavigationSettings|ConvenienceTools|PowerButton)Activity$/i, score: 80, hint: 'кнопки и жесты' },
  { re: /DoubleTapPowerSettingsActivity$/i, score: 40, hint: 'двойное нажатие кнопки питания' },
];

const POWER_ACTIVITY_NOISE =
  /(fuelgauge|PowerUsage|TimePower|PowerOffPrompt|PowerWakeUp|NotificationAssistant|OneHanded|Receiver$|Service$|Provider$|GuideActivity$)/i;

function scoreActivity(activityClass) {
  if (POWER_ACTIVITY_NOISE.test(activityClass)) return { score: -10, hint: 'не относится к кнопке питания' };
  for (const rule of POWER_ACTIVITY_SCORES) {
    if (rule.re.test(activityClass)) return { score: rule.score, hint: rule.hint };
  }
  return { score: 10, hint: 'возможно, связано с кнопкой питания' };
}

/** Сортирует найденные экраны: сверху те, что реально нужны, мусор в конце. */
function rankPowerActivities(items) {
  return items
    .map((item) => {
      const { score, hint } = scoreActivity(item.activity);
      return { ...item, score, hint };
    })
    .sort((a, b) => b.score - a.score || a.component.localeCompare(b.component));
}

// ---------------------------------------------------------------------------
// шаги диагностики
// ---------------------------------------------------------------------------

async function adbVersion() {
  const r = await adb(['version'], { timeout: 8000 });
  const first = (r.stdout || r.stderr || '').split('\n').filter(Boolean);
  return {
    ok: r.ok,
    bin: ADB_BIN,
    mock: IS_MOCK,
    version: first[0] || null,
    detail: clip(r.stdout + r.stderr, 600),
    error: r.ok ? null : r.error || 'adb не найден',
  };
}

async function listDevices() {
  const r = await adb(['devices', '-l'], { timeout: 12000 });
  if (!r.ok) {
    return {
      ok: false,
      error: r.error || 'не удалось запустить adb',
      devices: [],
      raw: clip(r.stdout + r.stderr, 800),
    };
  }
  const devices = parseDevices(r.stdout);
  return { ok: true, devices, raw: clip(r.stdout, 800) };
}

async function diagnose(serial) {
  const log = [];
  const note = (cmd, res, extra = {}) => {
    log.push({ cmd, ok: !!res.ok, out: clip(res.stdout || res.stderr || '', 1200), ...extra });
  };

  // 1. свойства устройства
  const propsRes = await shell(serial, 'getprop', { timeout: 30000 });
  note('getprop', propsRes);
  const props = parseProps(propsRes.stdout || '');

  const device = {
    brand: props['ro.product.brand'] || null,
    model: props['ro.product.model'] || null,
    marketName: props['ro.product.marketname'] || props['ro.product.oplus.marketname'] || null,
    device: props['ro.product.device'] || props['ro.product.name'] || null,
    android: props['ro.build.version.release'] || null,
    buildId: props['ro.build.display.id'] || null,
    ota: props['ro.build.version.ota'] || props['ro.ota.version'] || null,
    incremental: props['ro.build.version.incremental'] || null,
    securityPatch: props['ro.build.version.security_patch'] || null,
    region: props['ro.build.region'] || props['ro.oplus.region'] || null,
    isColorOS: /coloros/i.test(props['ro.build.version.oplusrom'] || props['ro.build.display.id'] || '') || null,
    oplusRom: props['ro.build.version.oplusrom'] || props['ro.build.version.opporom'] || null,
  };

  // 2. пакеты
  const pkgRes = await shell(serial, 'pm list packages', { timeout: 40000 });
  note('pm list packages', pkgRes);
  const packageSet = parsePackageList(pkgRes.stdout || '');
  const packages = {};
  for (const [key, value] of Object.entries(PACKAGES)) {
    packages[key] = { package: value, installed: packageSet.has(value) };
  }
  const vendorAssistants = [...packageSet].filter((p) => VENDOR_ASSISTANT_RE.test(p));

  // 3. текущий ассистент (secure settings)
  const secureRes = await shell(serial, 'settings list secure', { timeout: 25000 });
  note('settings list secure', secureRes);
  const secure = parseSettingsList(secureRes.stdout || '');
  const assistant = {
    assistant: secure.assistant || null,
    voiceInteractionService: secure.voice_interaction_service || null,
    voiceRecognitionService: secure.voice_recognition_service || null,
    active: secure.assistant || secure.voice_interaction_service || null,
  };

  // 4. какие голосовые сервисы реально объявлены на устройстве
  const voiceQueries = [
    'cmd package query-services -a android.service.voice.VoiceInteractionService --brief',
    'cmd package query-services --brief -a android.service.voice.VoiceInteractionService',
  ];
  let voiceRes = null;
  for (const q of voiceQueries) {
    const r = await shell(serial, q, { timeout: 20000 });
    if (r.ok && /\/[A-Za-z0-9_.$]+/.test(r.stdout || '') && !/^cmd: /m.test(r.stdout || '')) {
      voiceRes = r;
      break;
    }
  }
  if (voiceRes) {
    note(voiceQueries[0] + ' (или эквивалент)', voiceRes);
  } else {
    log.push({
      cmd: 'query-services VoiceInteractionService',
      ok: false,
      out: 'команда не поддержана прошивкой — использую известные компоненты-кандидаты',
    });
  }
  const discovered = voiceRes ? parseVoiceServices(voiceRes.stdout) : [];
  const googleVoiceService = discovered.filter((s) => s.component.startsWith('com.google.'));
  const voiceServices = discovered.length ? discovered : KNOWN_VOICE_SERVICES.map((s) => ({ ...s }));
  const suggestedVoiceService =
    googleVoiceService[0] ||
    voiceServices.find((s) => /GsaVoiceInteractionService/.test(s.component)) ||
    voiceServices[0] ||
    null;
  const suggestedAssistantComponent =
    (suggestedVoiceService && suggestedVoiceService.component) || null;

  // 5. активити настроек, связанные с кнопкой питания (для кнопки «открыть»)
  const settingsPkgs = [PACKAGES.oplusSettings, PACKAGES.colorosSettings, PACKAGES.aospSettings].filter(
    (p) => packageSet.has(p),
  );
  const powerActivities = [];
  const googleSettingsActivities = [];
  for (const pkg of settingsPkgs) {
    const r = await shell(serial, `dumpsys package ${pkg}`, { timeout: 30000 });
    log.push({ cmd: `dumpsys package ${pkg}`, ok: r.ok, out: clip(r.stdout, 600) });
    if (!r.ok) continue;
    const re = new RegExp(`${pkg.replace(/\./g, '\\.')}/([A-Za-z0-9_.$]+)`, 'g');
    const seen = new Set();
    let m;
    while ((m = re.exec(r.stdout))) {
      const cls = m[1];
      if (seen.has(cls)) continue;
      seen.add(cls);
      const component = `${pkg}/${cls}`;
      const short = cls.replace(`${pkg}.`, '');
      const item = { component, label: prettyActivityLabel(short), activity: cls };
      if (/power|button|assist|convenience|shortcut|key/i.test(cls)) powerActivities.push(item);
      else if (/google/i.test(cls)) googleSettingsActivities.push(item);
    }
  }

  const rankedPowerActivities = rankPowerActivities(powerActivities);

  // 6. сводные подсказки
  const hints = buildHints({ device, packages, assistant, vendorAssistants, suggestedAssistantComponent });

  return {
    ok: true,
    serial,
    device,
    packages,
    vendorAssistants,
    assistant,
    voiceServices,
    suggestedAssistantComponent,
    settingsApps: settingsPkgs,
    powerActivities: rankedPowerActivities,
    recommendedPowerActivity:
      (rankedPowerActivities.find((a) => a.score >= 80) || {}).component || null,
    googleSettingsActivities,
    hints,
    log,
    timestamp: new Date().toISOString(),
  };
}

function buildHints({ device, packages, assistant, vendorAssistants, suggestedAssistantComponent }) {
  const hints = [];
  const isCN = /^(PLK|PKG|PHK|PJD|PJF|PJH)/i.test(device.model || '') || /_11\./i.test(device.ota || '');
  const googleReady = packages.googleApp.installed && packages.gms.installed;

  if (isCN) {
    hints.push({
      level: 'warn',
      text:
        'Похоже на китайскую сборку (ColorOS CN). Именно здесь чаще всего пункт «Цифровой помощник» для кнопки питания не работает или скрыт — это ожидаемо, не баг телефона.',
    });
  }

  if (!googleReady) {
    hints.push({
      level: 'error',
      text:
        'Нет Google-сервисов или приложения Google. Сначала: Настройки → Система и обновления → Настройки Google → включить GMS, затем поставить Play Маркет и из него Google + Gemini.',
    });
  }

  if (!packages.gemini.installed) {
    hints.push({
      level: 'warn',
      text: 'Приложение Gemini не найдено. Без него «Гугл» в роли помощника = старый Ассистент, не Gemini.',
    });
  }

  if (vendorAssistants.length) {
    hints.push({
      level: 'info',
      text: `Найден фирменный ассистент: ${vendorAssistants.join(', ')}. Он может перехватывать долгое нажатие — стоит отключить/отозвать у него роль помощника по умолчанию.`,
    });
  }

  if (assistant.assistant && /com\.google/i.test(assistant.assistant)) {
    hints.push({
      level: 'ok',
      text: `Google уже назначен цифровым помощником: ${assistant.assistant}`,
    });
  }

  if (assistant.voiceInteractionService && !/com\.google/i.test(assistant.voiceInteractionService)) {
    hints.push({
      level: 'warn',
      text: `Голосовой сервис по умолчанию не Google: ${assistant.voiceInteractionService}`,
    });
  }

  if (suggestedAssistantComponent) {
    hints.push({
      level: 'info',
      text: `Компонент-кандидат для назначения: ${suggestedAssistantComponent}`,
    });
  }

  if (!hints.length) {
    hints.push({ level: 'ok', text: 'Всё выглядит штатно: можно назначать помощника.' });
  }
  return hints;
}

// ---------------------------------------------------------------------------
// действия
// ---------------------------------------------------------------------------

async function setAssistant(serial, component) {
  if (!component || !component.includes('/')) {
    return { ok: false, error: 'нужен компонент вида pkg/Class' };
  }
  const safe = String(component).replace(/[^A-Za-z0-9_.$/]/g, '');
  const steps = [];
  const targets = [
    ['assistant', `settings put secure assistant ${safe}`],
    ['voice_interaction_service', `settings put secure voice_interaction_service ${safe}`],
  ];
  for (const [key, cmd] of targets) {
    const r = await shell(serial, cmd, { timeout: 15000 });
    steps.push({ key, cmd, ok: r.ok, out: clip(r.stdout + r.stderr, 600) });
  }
  const after = await shell(serial, 'settings list secure', { timeout: 20000 });
  const secure = parseSettingsList(after.stdout || '');
  const applied = {
    assistant: secure.assistant || null,
    voiceInteractionService: secure.voice_interaction_service || null,
  };
  const verified =
    applied.assistant === safe || applied.voiceInteractionService === safe;
  return { ok: verified, steps, applied, verified, component: safe };
}

async function openTarget(serial, target, customComponent) {
  if (target === 'component') {
    if (!customComponent || !customComponent.includes('/')) {
      return { ok: false, error: 'нужен компонент вида pkg/Class' };
    }
    const safe = String(customComponent).replace(/[^A-Za-z0-9_.$/]/g, '');
    const r = await shell(serial, `am start -n ${safe}`, { timeout: 15000 });
    return {
      ok: r.ok && !/Error|Exception|does not exist/i.test(r.stdout + r.stderr),
      tried: [`am start -n ${safe}`],
      out: clip(r.stdout + r.stderr, 1200),
    };
  }
  const candidates = INTENTS[target];
  if (!candidates) return { ok: false, error: `неизвестная цель: ${target}` };
  const tried = [];
  for (const cmd of candidates) {
    const r = await shell(serial, cmd, { timeout: 15000 });
    tried.push(cmd);
    const failed = /Error|Exception|does not exist|unable to resolve|ActivityNotFound/i.test(
      r.stdout + r.stderr,
    );
    if (r.ok && !failed) {
      return { ok: true, tried, out: clip(r.stdout + r.stderr, 1200), used: cmd };
    }
    if (!r.ok) break;
  }
  return { ok: false, tried, out: clip(tried.join('\n'), 1200) };
}

async function testAssistant(serial) {
  const r = await shell(serial, 'am start -a android.intent.action.VOICE_COMMAND', {
    timeout: 15000,
  });
  const failed = /Error|Exception|unable to resolve/i.test(r.stdout + r.stderr);
  return {
    ok: r.ok && !failed,
    out: clip(r.stdout + r.stderr, 1200),
    note: 'Телефон должен быть разблокирован. Если ассистент не появился — помощник не назначен либо прошивка блокирует запуск.',
  };
}

async function grantMic(serial, pkg) {
  const allowed = [PACKAGES.gemini, PACKAGES.googleApp];
  const target = allowed.includes(pkg) ? pkg : PACKAGES.gemini;
  const r = await shell(
    serial,
    `pm grant ${target} android.permission.RECORD_AUDIO`,
    { timeout: 15000 },
  );
  return {
    ok: r.ok && !/Error|Exception/i.test(r.stdout + r.stderr),
    out: clip(r.stdout + r.stderr, 800),
  };
}

async function disableBatteryOpt(serial, pkg) {
  const r = await shell(
    serial,
    `dumpsys deviceidle whitelist +${pkg}`,
    { timeout: 15000 },
  );
  return { ok: r.ok, out: clip(r.stdout + r.stderr, 800) };
}

// ---------------------------------------------------------------------------
// снимок/дифф настроек: «нажми вручную — и увидишь, что изменилось»
// ---------------------------------------------------------------------------

async function snapshotSettings(serial) {
  const result = {};
  const parts = ['secure', 'system', 'global'];
  for (const part of parts) {
    const r = await shell(serial, `settings list ${part}`, { timeout: 25000 });
    const map = parseSettingsList(r.stdout || '');
    for (const [k, v] of Object.entries(map)) {
      if (INTERESTING_SETTING_KEY_RE.test(k)) result[`${part}:${k}`] = v;
    }
  }
  return {
    id: `snap-${Date.now()}`,
    createdAt: new Date().toISOString(),
    values: result,
    count: Object.keys(result).length,
  };
}

function diffSnapshots(before, after) {
  const changes = [];
  const keys = new Set([...Object.keys(before.values), ...Object.keys(after.values)]);
  for (const key of [...keys].sort()) {
    const a = before.values[key];
    const b = after.values[key];
    if (a !== b) changes.push({ key, before: a ?? null, after: b ?? null });
  }
  return changes;
}

async function rawCommand(serial, cmd) {
  const r = await shell(serial, String(cmd), { timeout: 30000 });
  return { ok: r.ok, out: clip(r.stdout + (r.stderr ? `\n[stderr]\n${r.stderr}` : ''), 8000) };
}

// ---------------------------------------------------------------------------
// фирменные ассистенты (Breeno и родня): найти и обратимо снять
// ---------------------------------------------------------------------------

function isDeniedVendorPackage(pkg) {
  return VENDOR_DENYLIST.some((re) => re.test(pkg));
}

/**
 * На ColorOS 16 пакета `com.oplus.breeno` больше нет: Breeno разложен на части.
 * Классификация нужна, чтобы не отключать вслепую AI-движок, которым пользуются
 * другие системные функции (галерея, перевод и т.п.).
 */
function classifyVendorPackage(pkg) {
  if (/speechassist|voiceassist|\bbreeno\b/i.test(pkg)) {
    return { role: 'voice', label: 'голосовой ассистент (Breeno)', risk: 'safe' };
  }
  if (/assistantscreen/i.test(pkg)) {
    return { role: 'screen', label: 'экран ассистента Breeno', risk: 'safe' };
  }
  if (/aiunit/i.test(pkg)) {
    return { role: 'engine', label: 'AI-движок OPPO (может быть нужен другим функциям)', risk: 'caution' };
  }
  return { role: 'other', label: 'фирменный ассистент', risk: 'caution' };
}

/** Список фирменных ассистентов на устройстве + отключены ли они уже. */
async function listVendorAssistants(serial) {
  const installedRes = await shell(serial, 'pm list packages --user 0', { timeout: 30000 });
  const disabledRes = await shell(serial, 'pm list packages -d', { timeout: 30000 });
  const installed = parsePackageList(installedRes.stdout || '');
  const fallback = installed.size ? installedRes : await shell(serial, 'pm list packages', { timeout: 30000 });
  const universe = parsePackageList(fallback.stdout || '');
  const disabled = parsePackageList(disabledRes.stdout || '');
  const all = [...universe].filter((p) => VENDOR_ASSISTANT_RE.test(p));
  return {
    ok: fallback.ok,
    packages: all
      .map((pkg) => {
        const { role, label, risk } = classifyVendorPackage(pkg);
        return {
          package: pkg,
          role,
          kind: label,
          risk,
          disabled: disabled.has(pkg),
          protected: isDeniedVendorPackage(pkg),
          installedDist: installed.size ? installed.has(pkg) : true,
        };
      })
      .sort((a, b) => Number(a.protected) - Number(b.protected) || a.package.localeCompare(b.package)),
  };
}

/**
 * Лестница стратегий блокировки. OPPO защищает часть пакетов от `disable-user`
 * (ответ «new state: default» — отказ) и от `uninstall` (DELETE_FAILED_INTERNAL_ERROR),
 * но нередко пропускает `hide` или `suspend`. Все стратегии обратимы, root не нужен.
 */
const BLOCK_STRATEGIES = [
  { name: 'disable-user', cmd: (p) => `pm disable-user --user 0 ${p}`, okRe: /new state: disabled/i },
  { name: 'suspend', cmd: (p) => `pm suspend --user 0 ${p}`, okRe: /new suspended state: true|suspended/i },
  { name: 'hide', cmd: (p) => `pm hide ${p}`, okRe: /new state: (hidden|disabled)/i },
  { name: 'uninstall-user', cmd: (p) => `pm uninstall --user 0 ${p}`, okRe: /Success/i },
  // на Android 16 shell-у запрещено: SecurityException "Shell cannot change component state"
  { name: 'disable', cmd: (p) => `pm disable --user 0 ${p}`, okRe: /new state: disabled/i },
];

/** Причины отказа, которые встречались на реальных устройствах — для понятных сообщений. */
const BLOCK_FAILURE_HINTS = [
  { re: /requires: android\.permission\.MANAGE_USERS/i, text: 'shell-у запрещено (нужен MANAGE_USERS) — только root' },
  { re: /Shell cannot change component state/i, text: 'shell не может менять состояние этого пакета' },
  { re: /DELETE_FAILED_INTERNAL_ERROR/i, text: 'прошивка запрещает uninstall --user 0' },
  { re: /new state: default/i, text: 'прошивка проигнорировала команду (состояние не изменилось)' },
];

const UNBLOCK_COMMANDS = [
  (p) => `pm unsuspend --user 0 ${p}`,
  (p) => `pm unhide ${p}`,
  (p) => `pm enable ${p}`,
  (p) => `cmd package install-existing ${p}`,
];

/**
 * Смотрит фактическое состояние пакета: текст ответа врёт, а состояние — нет.
 */
async function inspectPackageState(serial, pkg) {
  const [disabledRes, installedRes, dumpRes] = await Promise.all([
    shell(serial, 'pm list packages -d', { timeout: 25000 }),
    shell(serial, 'pm list packages --user 0', { timeout: 25000 }),
    shell(serial, `dumpsys package ${pkg}`, { timeout: 25000 }),
  ]);
  const disabled = parsePackageList(disabledRes.stdout || '').has(pkg);
  const installedForUser = parsePackageList(installedRes.stdout || '').has(pkg);
  const dump = dumpRes.stdout || '';
  const suspended = /suspended=true/i.test(dump);
  const hidden = /hidden=true/i.test(dump);
  const evidence = [];
  if (disabled) evidence.push('есть в pm list packages -d');
  if (!installedForUser) evidence.push('не установлен для пользователя 0');
  if (suspended) evidence.push('suspended=true в dumpsys');
  if (hidden) evidence.push('hidden=true в dumpsys');
  return {
    blocked: disabled || !installedForUser || suspended || hidden,
    disabled,
    installedForUser,
    suspended,
    hidden,
    evidence,
  };
}

/** Перебирает стратегии блокировки, проверяя результат состоянием. */
async function disablePackages(serial, packages, options = {}) {
  const targets = (Array.isArray(packages) ? packages : [packages])
    .filter((p) => typeof p === 'string' && /^[a-zA-Z0-9_.]+$/.test(p))
    .filter((p) => !isDeniedVendorPackage(p));

  const strategies = options.strategies
    ? BLOCK_STRATEGIES.filter((st) => options.strategies.includes(st.name))
    : BLOCK_STRATEGIES;

  const steps = [];
  const results = [];

  for (const pkg of targets) {
    const attempts = [];
    let blocked = false;
    for (const strategy of strategies) {
      if (blocked) break;
      const r = await shell(serial, strategy.cmd(pkg), { timeout: 25000 });
      const out = (r.stdout + r.stderr).trim();
      const state = await inspectPackageState(serial, pkg);
      attempts.push({
        package: pkg,
        mode: strategy.name,
        cmd: strategy.cmd(pkg),
        saysOk: strategy.okRe.test(out),
        refuseReason: (BLOCK_FAILURE_HINTS.find((h) => h.re.test(out)) || {}).text || null,
        blocked: state.blocked,
        evidence: state.evidence,
        out: clip(out, 400),
      });
      blocked = state.blocked;
    }
    results.push({
      package: pkg,
      blocked,
      attempts,
      workedMode: (attempts.find((a) => a.blocked) || {}).mode || null,
    });
    steps.push(...attempts);
  }

  const verified = results.filter((r) => r.blocked).map((r) => r.package);
  const failed = results.filter((r) => !r.blocked).map((r) => r.package);
  return { ok: failed.length === 0, verified, failed, requested: targets, steps, results };
}

/** Включает пакеты обратно: пробует все способы разблокировки подряд. */
async function enablePackages(serial, packages) {
  const targets = (Array.isArray(packages) ? packages : [packages]).filter(
    (p) => typeof p === 'string' && /^[a-zA-Z0-9_.]+$/.test(p),
  );
  const steps = [];
  const stillBlocked = [];

  for (const pkg of targets) {
    let restored = false;
    for (const build of UNBLOCK_COMMANDS) {
      const cmd = build(pkg);
      const r = await shell(serial, cmd, { timeout: 25000 });
      const out = (r.stdout + r.stderr).trim();
      steps.push({ package: pkg, cmd, ok: !/Error|Exception|Failure/i.test(out), out: clip(out, 300) });
      const state = await inspectPackageState(serial, pkg);
      if (!state.blocked) {
        restored = true;
        break;
      }
    }
    if (!restored) stillBlocked.push(pkg);
  }

  return { ok: stillBlocked.length === 0, steps, stillBlocked };
}

// ---------------------------------------------------------------------------
// беспроводное подключение
// ---------------------------------------------------------------------------

async function pair(hostPort, code) {
  const r = await adb(['pair', hostPort, String(code)], { timeout: 60000 });
  return { ok: r.ok, out: clip(r.stdout + r.stderr, 1500) };
}

async function connect(hostPort) {
  const r = await adb(['connect', hostPort], { timeout: 30000 });
  return { ok: r.ok, out: clip(r.stdout + r.stderr, 1500) };
}

async function enableTcpip(port = 5555) {
  const r = await adb(['tcpip', String(port)], { timeout: 20000 });
  return { ok: r.ok, out: clip(r.stdout + r.stderr, 800) };
}

module.exports = {
  ADB_BIN,
  IS_MOCK,
  PACKAGES,
  INTENTS,
  adbVersion,
  listDevices,
  diagnose,
  setAssistant,
  openTarget,
  testAssistant,
  grantMic,
  disableBatteryOpt,
  snapshotSettings,
  diffSnapshots,
  rawCommand,
  listVendorAssistants,
  disablePackages,
  enablePackages,
  inspectPackageState,
  BLOCK_STRATEGIES,
  BLOCK_FAILURE_HINTS,
  pair,
  connect,
  enableTcpip,
  // экспорт парсеров для тестов
  _internal: {
    parseProps,
    parseSettingsList,
    parsePackageList,
    parseDevices,
    parseVoiceServices,
    rankPowerActivities,
    scoreActivity,
    classifyVendorPackage,
  },
};
