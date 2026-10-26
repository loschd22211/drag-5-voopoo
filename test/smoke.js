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
  assert.equal(report.device.android, '15');
  assert.equal(report.packages.googleApp.installed, true);
  assert.equal(report.packages.gemini.installed, true);
  assert.ok(report.powerActivities.some((a) => /PowerButton/i.test(a.component)), 'нет экрана кнопки питания');
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
    'com.oplus.settings/.OplusPowerButtonSettingsActivity',
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
