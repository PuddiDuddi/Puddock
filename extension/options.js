// Puddock options: talks to the local app over native messaging (same host as background.js).
// Firefox: `browser.*` is the promise-based API; Chromium: `chrome.*` already returns promises.
const ext = globalThis.browser ?? chrome;
const HOST = 'com.puddock.native';
const native = msg => ext.runtime.sendNativeMessage(HOST, msg);
const $ = id => document.getElementById(id);
const TWITCH = 'https://www.twitch.tv/*';
const BOOLS = ['LowLatency', 'TopBar', 'ChatDark', 'ChatInFullscreen', 'RememberPos', 'StartFullscreen', 'AlwaysOnTop'];
const NUMBERS = ['Rewind', 'ChatWidth'];
const FIELDS = ['Quality', 'Rewind', 'VideoMode', 'ChatSide', 'ChatWidth', ...BOOLS];

function showError(text) {
  $('error').textContent = text || '';
  $('error').hidden = !text;
}

function setStatus(el, text, ok) {
  el.textContent = text;
  el.className = 'status ' + (ok ? 'ok' : 'warn');
}

async function refresh() {
  showError('');
  let hello;
  try {
    hello = await native({ cmd: 'hello' });
  } catch {
    setStatus($('app-status'), 'Puddock app not found', false);
    $('app-missing').hidden = false;
    $('app-ok').hidden = $('settings').hidden = $('account').hidden = true;
    return;
  }
  setStatus($('app-status'), `Connected to ${hello.app} ${hello.version}`, true);
  $('app-missing').hidden = true;
  $('app-ok').hidden = $('settings').hidden = $('account').hidden = false;
  $('dep-streamlink').className = hello.streamlink ? 'ok' : '';
  $('dep-mpv').className = hello.mpv ? 'ok' : '';
  setStatus($('account-status'), hello.account ? `Connected as ${hello.account}` : 'Not connected', !!hello.account);
  $('disconnect').hidden = !hello.account;

  // The app and the extension are updated separately (the extension is loaded unpacked, so the
  // browser keeps running the old copy until it is reloaded). 0.0.0 = an unstamped dev build.
  const mine = ext.runtime.getManifest().version;
  const real = v => typeof v === 'string' && /^\d+(\.\d+)*$/.test(v) && v !== '0.0.0';
  const differ = real(mine) && real(hello.version) && mine !== hello.version;
  $('version-note').textContent = differ
    ? `The app is version ${hello.version}, this extension is ${mine}. After updating Puddock, reload the extension on your browser's extensions page.`
    : '';
  $('version-note').hidden = !differ;

  let reply;
  try {
    reply = await native({ cmd: 'getSettings' });
  } catch {
    reply = null;
  }
  const settings = reply?.ok ? reply.settings : null;
  if (!settings || typeof settings !== 'object') {
    return showError(reply?.error || 'Could not read the settings from the Puddock app.');
  }
  for (const key of FIELDS) {
    if (!(key in settings)) continue;
    const el = $(key);
    if (BOOLS.includes(key)) el.checked = !!settings[key];
    else el.value = String(settings[key]);
  }

  // opened from the app's "Connect in browser": show the section, but leave the click to the user
  if (location.hash === '#account') $('account').scrollIntoView({ behavior: 'smooth' });
}

async function save(key) {
  const el = $(key);
  let value = BOOLS.includes(key) ? (el.checked ? 1 : 0) : el.value;
  if (NUMBERS.includes(key)) value = parseInt(value, 10);
  let reply;
  try {
    reply = await native({ cmd: 'setSettings', settings: { [key]: value } });
  } catch {
    return showError('Could not reach the Puddock app — the setting was not saved.');
  }
  if (!reply?.ok) return showError(reply?.error || 'The setting was not saved.');
  showError('');
  $('saved').hidden = false;
  clearTimeout(save.t);
  save.t = setTimeout(() => ($('saved').hidden = true), 1500);
}

// Asks for cookie access to twitch.tv only now, reads the single login cookie, hands it to
// the app, and gives the access back (keeping twitch.tv only if the ▶ button is on).
async function connect() {
  showError('');
  let granted = false;
  try {
    granted = await ext.permissions.request({ permissions: ['cookies'], origins: [TWITCH] });
  } catch {}
  if (!granted) return showError('Permission declined — nothing was read.');
  let cookie, failed = false;
  try {
    cookie = await ext.cookies.get({ url: 'https://www.twitch.tv', name: 'auth-token' });
  } catch {
    failed = true;
  } finally {
    // whatever happened above, the access goes back
    let button = false;
    try {
      ({ button } = await ext.storage.local.get('button'));
    } catch {}
    ext.permissions.remove(button ? { permissions: ['cookies'] } : { permissions: ['cookies'], origins: [TWITCH] })
      .catch(() => {});
  }
  if (failed) return showError('The browser did not let the extension read the twitch.tv login cookie.');
  if (!cookie) return showError('You are not logged in to twitch.tv in this browser.');
  let reply;
  try {
    reply = await native({ cmd: 'setToken', token: cookie.value });
  } catch {
    return showError('Could not reach the Puddock app — the account was not connected.');
  }
  if (!reply?.ok) return showError(reply?.error || 'The account was not connected.');
  refresh();
}

async function disconnect() {
  let reply;
  try {
    reply = await native({ cmd: 'clearToken' });
  } catch {
    return showError('Could not reach the Puddock app — the account is still connected.');
  }
  if (!reply?.ok) return showError(reply?.error || 'The account is still connected.');
  refresh();
}

// ▶ button on channel pages: asks for twitch.tv access when turned on, gives it back when off
async function loadButton() {
  const { button } = await ext.storage.local.get('button');
  $('Button').checked = !!button && await ext.permissions.contains({ origins: [TWITCH] });
}

$('Button').addEventListener('change', async e => {
  if (e.target.checked) {
    if (!(await ext.permissions.request({ origins: [TWITCH] }))) { e.target.checked = false; return; }
    await ext.storage.local.set({ button: true });
  } else {
    await ext.storage.local.set({ button: false });
    await ext.permissions.remove({ origins: [TWITCH] });
  }
});

$('retry').addEventListener('click', refresh);
$('open-setup').addEventListener('click', () => native({ cmd: 'openApp', page: 'setup' }));
$('open-launcher').addEventListener('click', () => native({ cmd: 'openApp' }));
$('connect').addEventListener('click', connect);
$('disconnect').addEventListener('click', disconnect);
for (const key of FIELDS) $(key).addEventListener('change', () => save(key));
loadButton();
refresh();
