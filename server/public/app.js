'use strict';

/* Интерфейс инструмента. Стейт держим в памяти страницы, все данные — с локального сервера. */

const state = {
  env: null,
  devices: [],
  serial: null,
  diagnosis: null,
  lastSnapshot: null,
  log: [],
};

const $ = (sel) => document.querySelector(sel);
const $$ = (sel) => Array.from(document.querySelectorAll(sel));

function esc(value) {
  return String(value ?? '')
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

async function api(path, body, method) {
  const opts = { method: method || (body ? 'POST' : 'GET'), headers: {} };
  if (body) {
    opts.headers['content-type'] = 'application/json';
    opts.body = JSON.stringify(body);
  }
  const res = await fetch(path, opts);
  const data = await res.json().catch(() => ({ ok: false, error: 'ответ не JSON' }));
  return data;
}

function log(text, isCommand = false) {
  const t = new Date().toLocaleTimeString('ru-RU');
  state.log.push({ t, text, isCommand });
  if (state.log.length > 400) state.log.shift();
  renderLog();
}

function renderLog() {
  const showCommands = $('#verboseToggle').checked;
  const items = state.log.filter((e) => showCommands || !e.isCommand);
  const el = $('#log');
  el.textContent = items.map((e) => `${e.t}  ${e.text}`).join('\n') || '— пока пусто —';
  el.scrollTop = el.scrollHeight;
}

function badge(el, text, kind) {
  el.textContent = text;
  el.className = `badge ${kind ? `badge-${kind}` : ''}`;
}

// ---------------------------------------------------------------------------
// подключение
// ---------------------------------------------------------------------------

function renderDevices() {
  const select = $('#deviceSelect');
  const usable = state.devices.filter((d) => d.state === 'device');
  if (!usable.length) {
    select.innerHTML = '<option value="">— нет подключённых устройств —</option>';
    badge($('#deviceBadge'), 'устройство не выбрано', 'muted');
    return;
 }
  select.innerHTML = usable
    .map(
      (d) =>
        `<option value="${esc(d.serial)}">${esc(d.model || d.serial)}${d.product ? ` · ${esc(d.product)}` : ''} · ${esc(d.serial)}</option>`,
    )
    .join('');
  if (!state.serial || !usable.some((d) => d.serial === state.serial)) {
    state.serial = usable[0].serial;
  }
  select.value = state.serial;
  const current = usable.find((d) => d.serial === state.serial);
  badge($('#deviceBadge'), `подключено: ${current?.model || state.serial}`, 'ok');
}

async function refreshDevices() {
  const data = await api('/api/devices');
  if (!data.ok) {
    log(`adb: ${data.error || 'ошибка'}${data.raw ? ` — ${data.raw.trim()}` : ''}`);
    state.devices = [];
  } else {
    state.devices = data.devices || [];
    log(`найдено устройств: ${state.devices.length}`);
  }
  renderDevices();
  return data;
}

async function pairOrConnect() {
  const hostPort = $('#pairHost').value.trim();
  const code = $('#pairCode').value.trim();
  const out = $('#connectOut');
  if (!hostPort) {
    alert('Введи адрес вида 192.168.1.50:37123');
    return;
  }
  const data = await api('/api/pair', { hostPort, code: code || undefined });
  out.classList.remove('hidden');
  out.textContent = data.out || data.error || '(пусто)';
  log(`pair/connect ${hostPort}: ${data.ok ? 'ок' : 'ошибка'}`);
  await refreshDevices();
}

// ---------------------------------------------------------------------------
// диагностика
// ---------------------------------------------------------------------------

function row(label, value) {
  if (value === null || value === undefined || value === '') return '';
  return `<tr><th>${esc(label)}</th><td>${esc(value)}</td></tr>`;
}

function renderDiagnosis(d) {
  const el = $('#diagnoseOut');
  if (!d || !d.ok) {
    el.innerHTML = `<div class="hint error">${esc(d?.error || 'диагностика не удалась')}</div>`;
    return;
  }

  const dev = d.device || {};
  const pkgs = d.packages || {};
  const pkgRows = Object.entries(pkgs)
    .map(([, v]) => {
      const cls = v.installed ? 'ok' : 'no';
      const label = v.installed ? 'установлен' : 'нет';
      return `<tr><th>${esc(v.package)}</th><td><span class="pill ${cls}">${label}</span></td></tr>`;
    })
    .join('');

  const hints = (d.hints || [])
    .map((h) => `<div class="hint ${esc(h.level)}">${esc(h.text)}</div>`)
    .join('');

  const voice = (d.voiceServices || [])
    .map(
      (s) =>
        `<li><code>${esc(s.component)}</code> ${s.verified ? '<span class="pill ok">объявлен на устройстве</span>' : '<span class="pill skip">кандидат</span>'}</li>`,
    )
    .join('');

  el.innerHTML = `
    <div class="section-title">Устройство</div>
    <table>
      ${row('Модель', dev.marketName || dev.model)}
      ${row('Код модели', dev.model)}
      ${row('Бренд', dev.brand)}
      ${row('Android', dev.android)}
      ${row('Прошивка', dev.oplusRom || dev.buildId)}
      ${row('OTA', dev.ota)}
      ${row('Регион', dev.region)}
      ${row('Патч безопасности', dev.securityPatch)}
      ${row('Serial', d.serial)}
    </table>

    <div class="section-title">Google-сервисы</div>
    <table>${pkgRows}</table>

    <div class="section-title">Текущий помощник</div>
    <table>
      ${row('assistant', d.assistant?.assistant || 'не задан')}
      ${row('voice_interaction_service', d.assistant?.voiceInteractionService || 'не задан')}
      ${row('voice_recognition_service', d.assistant?.voiceRecognitionService || 'не задан')}
      ${d.vendorAssistants?.length ? row('Фирменные ассистенты', d.vendorAssistants.join(', ')) : ''}
    </table>

    <div class="section-title">Выводы</div>
    ${hints || '<p class="muted small">Замечаний нет.</p>'}

    <div class="section-title">Голосовые сервисы на устройстве</div>
    <ul class="list">${voice || '<li>не удалось определить</li>'}</ul>

    <div class="section-title">Экраны настроек</div>
    <p class="muted small">settings-пакеты: ${esc((d.settingsApps || []).join(', ') || 'не найдены')}</p>
  `;

  // заполняем селект компонентов
  const compSelect = $('#componentSelect');
  const opts = (d.voiceServices || [])
    .slice()
    .sort((a, b) => Number(/^com\.google/.test(b.component)) - Number(/^com\.google/.test(a.component)));
  const prev = compSelect.value;
  compSelect.innerHTML = opts
    .map((s) => `<option value="${esc(s.component)}">${esc(s.component)}</option>`)
    .join('');
  if (prev && opts.some((o) => o.component === prev)) compSelect.value = prev;
  else if (d.suggestedAssistantComponent) compSelect.value = d.suggestedAssistantComponent;

  // список экранов кнопки питания
  const power = $('#powerOut');
  const items = d.powerActivities || [];
  if (!items.length) {
    power.innerHTML =
      '<div class="hint warn">Не нашёл активности с «power/button» в названии. Открой настройки вручную: «Доступность и удобство → Кнопка питания».</div>';
  } else {
    const useful = items.filter((a) => a.score >= 0);
    const junk = items.filter((a) => a.score < 0);
    const row = (a, first) => `<tr>
      <td>${first ? '<span class="pill ok">начать здесь</span> ' : ''}${esc(a.label)}</td>
      <td class="muted small">${esc(a.hint || '')}</td>
      <td><code>${esc(a.component)}</code></td>
      <td><button class="btn tiny" data-open-component="${esc(a.component)}">Открыть</button></td>
    </tr>`;
    power.innerHTML = `
      <table>
        <thead><tr><th>Экран</th><th>Что это</th><th>Компонент</th><th></th></tr></thead>
        <tbody>${useful.map((a, i) => row(a, i === 0)).join('')}</tbody>
      </table>
      ${
        junk.length
          ? `<details class="wifi"><summary>Ещё найдено, но к кнопке питания не относится (${junk.length})</summary>
             <table><tbody>${junk
               .map(
                 (a) => `<tr><td class="muted small">${esc(a.label)}</td><td><code>${esc(a.component)}</code></td>
                 <td><button class="btn tiny" data-open-component="${esc(a.component)}">Открыть</button></td></tr>`,
               )
               .join('')}</tbody></table></details>`
          : ''
      }`;
  }

  const google = d.googleSettingsActivities || [];
  if (google.length) {
    power.innerHTML += `
      <div class="section-title">Google-настройки в системном приложении</div>
      <table><tbody>
        ${google
          .map(
            (a) => `<tr>
              <td>${esc(a.label)}</td>
              <td><code>${esc(a.component)}</code></td>
              <td><button class="btn tiny" data-open-component="${esc(a.component)}">Открыть</button></td>
            </tr>`,
          )
          .join('')}
      </tbody></table>`;
  }

  $('[data-action="export-report"]').disabled = false;
}

async function diagnose() {
  const data = await api('/api/diagnose', { serial: state.serial });
  state.diagnosis = data;
  if (!data.ok) {
    log(`диагностика: ${data.error || 'ошибка'}`);
  } else {
    log(`диагностика ок: ${data.device?.model || '?'}, android ${data.device?.android || '?'}`);
    if (data.log) {
      for (const step of data.log) log(`$ adb shell ${step.cmd}  → ${step.ok ? 'ok' : 'fail'}`, true);
    }
  }
  renderDiagnosis(data);
}

// ---------------------------------------------------------------------------
// действия
// ---------------------------------------------------------------------------

async function setAssistant() {
  const component = $('#componentSelect').value;
  if (!component) {
    alert('Сначала запусти диагностику, чтобы найти компонент.');
    return;
  }
  const data = await api('/api/set-assistant', { serial: state.serial, component });
  const el = $('#assignOut');
  const ok = data.ok;
  el.innerHTML = `
    <div class="hint ${ok ? 'ok' : 'error'}">
      ${
        ok
          ? 'Готово: Google назначен цифровым помощником. Теперь зажми кнопку питания на телефоне (около 0,5 с).'
          : 'Не применилось: система вернула прежнее значение. Значит, прошивка защищает эту настройку — используй экраны из шага 5 или Activity Launcher (см. README).'
      }
    </div>
    <table>
      <tr><th>assistant</th><td><code>${esc(data.applied?.assistant || '—')}</code></td></tr>
      <tr><th>voice_interaction_service</th><td><code>${esc(data.applied?.voiceInteractionService || '—')}</code></td></tr>
    </table>
    <pre class="log small">${esc((data.steps || []).map((s) => `$ adb shell ${s.cmd}\n${s.out || ''}`).join('\n'))}</pre>
  `;
  log(`назначение помощника: ${ok ? 'ок' : 'не применилось'}`);
  if (data.steps) for (const s of data.steps) log(`$ adb shell ${s.cmd}`, true);
}

async function openTarget(target, component) {
  const data = await api('/api/open', { serial: state.serial, target, component });
  const el = $('#checkOut');
  el.innerHTML = data.ok
    ? `<div class="hint ok">Экран открыт на телефоне${data.used ? `: <code>${esc(data.used)}</code>` : ''}</div>`
    : `<div class="hint warn">Не удалось открыть. Попробовал: <code>${esc((data.tried || []).join(' | '))}</code>${data.out ? `<pre class="log small">${esc(data.out)}</pre>` : ''}</div>`;
  log(`открыть ${target || component}: ${data.ok ? 'ок' : 'не вышло'}`);
}

async function testAssist() {
  const data = await api('/api/test-assist', { serial: state.serial });
  const el = $('#checkOut');
  el.innerHTML = `<div class="hint ${data.ok ? 'ok' : 'warn'}">${esc(data.note || '')}</div>
    <pre class="log small">${esc(data.out || '')}</pre>`;
  log(`тест запуска ассистента: ${data.ok ? 'ок' : 'ошибка'}`);
}

async function simple(route, payload, label, targetEl) {
  const data = await api(route, { serial: state.serial, ...payload });
  const el = $(targetEl);
  el.innerHTML = `<div class="hint ${data.ok ? 'ok' : 'warn'}">${esc(label)}: ${data.ok ? 'ок' : 'не удалось'}</div>
    ${data.out ? `<pre class="log small">${esc(data.out)}</pre>` : ''}`;
  log(`${label}: ${data.ok ? 'ок' : 'ошибка'}`);
}

// ---------------------------------------------------------------------------
// снимки настроек
// ---------------------------------------------------------------------------

async function snapshot() {
  const data = await api('/api/prefs/snapshot', { serial: state.serial });
  if (!data.ok) {
    log(`снимок: ${data.error || 'ошибка'}`);
    return;
  }
  state.lastSnapshot = data;
  $('#diffOut').innerHTML = `<div class="hint ok">Снимок №1 сохранён: ${esc(data.count)} параметров.
    Теперь переключи кнопку питания на телефоне вручную и нажми «Сравнить».</div>`;
  log(`снимок сохранён (${data.count} параметров)`);
}

async function diff() {
  if (!state.lastSnapshot) {
    alert('Сначала сними снимок.');
    return;
  }
  const data = await api('/api/prefs/diff', { serial: state.serial, id: state.lastSnapshot.id });
  const el = $('#diffOut');
  if (!data.ok) {
    el.innerHTML = `<div class="hint error">${esc(data.error || 'ошибка')}</div>`;
    return;
  }
  if (!data.changes.length) {
    el.innerHTML =
      '<div class="hint warn">Ничего не изменилось. Либо переключение не применилось, либо эта прошивка хранит состояние в другом месте — тогда рабочий путь через Activity Launcher / MiCTS (см. README).</div>';
    return;
  }
  el.innerHTML = `
    <div class="hint ok">Изменений: ${data.changes.length}</div>
    <table>
      <thead><tr><th>Ключ</th><th>Было</th><th>Стало</th></tr></thead>
      <tbody>
        ${data.changes
          .map(
            (c) => `<tr>
              <td><code>${esc(c.key)}</code></td>
              <td>${esc(c.before ?? '—')}</td>
              <td>${esc(c.after ?? '—')}</td>
            </tr>`,
          )
          .join('')}
      </tbody>
    </table>`;
  log(`дифф: изменений ${data.changes.length}`);
}

// ---------------------------------------------------------------------------
// отчёт
// ---------------------------------------------------------------------------

function exportReport() {
  const d = state.diagnosis;
  if (!d || !d.ok) return;
  const lines = [
    '# Диагностика: Gemini на кнопку питания',
    '',
    `Дата: ${new Date().toLocaleString('ru-RU')}`,
    `Serial: ${d.serial}`,
    '',
    '## Устройство',
    `- Модель: ${d.device?.marketName || d.device?.model || '—'}`,
    `- Код: ${d.device?.model || '—'}`,
    `- Android: ${d.device?.android || '—'}`,
    `- Прошивка: ${d.device?.oplusRom || d.device?.buildId || '—'}`,
    `- OTA: ${d.device?.ota || '—'}`,
    `- Регион: ${d.device?.region || '—'}`,
    '',
    '## Пакеты',
    ...Object.values(d.packages || {}).map((p) => `- ${p.package}: ${p.installed ? 'есть' : 'нет'}`),
    '',
    '## Ассистент',
    `- assistant: ${d.assistant?.assistant || '—'}`,
    `- voice_interaction_service: ${d.assistant?.voiceInteractionService || '—'}`,
    `- voice_recognition_service: ${d.assistant?.voiceRecognitionService || '—'}`,
    '',
    '## Выводы',
    ...(d.hints || []).map((h) => `- [${h.level}] ${h.text}`),
    '',
    '## Голосовые сервисы',
    ...(d.voiceServices || []).map((s) => `- ${s.component}${s.verified ? '' : ' (кандидат)'}`),
  ];
  const blob = new Blob([lines.join('\n')], { type: 'text/markdown;charset=utf-8' });
  const a = document.createElement('a');
  a.href = URL.createObjectURL(blob);
  a.download = `gemini-power-button-${d.device?.model || 'report'}.md`;
  a.click();
  URL.revokeObjectURL(a.href);
  log('отчёт скачан');
}

// ---------------------------------------------------------------------------
// инициализация
// ---------------------------------------------------------------------------

async function init() {
  const env = await api('/api/env');
  state.env = env;
  const mode = $('#modeBadge');
  if (env.mock) {
    badge(mode, 'ДЕМО-РЕЖИМ · фейковый телефон', 'demo');
  } else if (env.ok) {
    badge(mode, `${env.version || 'adb'}`, 'ok');
  } else {
    badge(mode, 'adb не найден', 'warn');
    log('adb не найден. Установи platform-tools и добавь adb в PATH, либо задай ADB_BIN.');
  }
  log(`сервер: node ${env.node}, ${env.platform}, порт ${env.port}`);
  await refreshDevices();

  $$('[data-action]').forEach((btn) => {
    btn.addEventListener('click', async () => {
      const action = btn.dataset.action;
      btn.disabled = true;
      try {
        if (action === 'refresh-devices') await refreshDevices();
        else if (action === 'pair') await pairOrConnect();
        else if (action === 'connect') await pairOrConnect();
        else if (action === 'diagnose') await diagnose();
        else if (action === 'set-assistant') await setAssistant();
        else if (action === 'open') await openTarget(btn.dataset.target);
        else if (action === 'test-assist') await testAssist();
        else if (action === 'grant-mic') await simple('/api/grant-mic', { package: 'com.google.android.apps.bard' }, 'микрофон Gemini', '#checkOut');
        else if (action === 'battery') await simple('/api/battery', {}, 'оптимизация батареи', '#checkOut');
        else if (action === 'snapshot') await snapshot();
        else if (action === 'diff') await diff();
        else if (action === 'export-report') exportReport();
      } finally {
        btn.disabled = false;
      }
    });
  });

  $('#powerOut').addEventListener('click', async (event) => {
    const btn = event.target.closest('[data-open-component]');
    if (!btn) return;
    await openTarget('component', btn.dataset.openComponent);
  });

  $('#deviceSelect').addEventListener('change', (event) => {
    state.serial = event.target.value;
    state.diagnosis = null;
    renderDevices();
  });

  $('#verboseToggle').addEventListener('change', renderLog);

  renderLog();
}

init();
