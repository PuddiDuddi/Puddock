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
    setStatus($('app-status'), '○  Puddock app not found', false);
    $('app-missing').hidden = false;
    $('app-ok').hidden = $('settings').hidden = $('account').hidden = true;
    return;
  }
  setStatus($('app-status'), `●  Connected to ${hello.app} ${hello.version}`, true);
  $('app-missing').hidden = true;
  $('app-ok').hidden = $('settings').hidden = $('account').hidden = false;
  $('dep-streamlink').className = hello.streamlink ? 'ok' : '';
  $('dep-mpv').className = hello.mpv ? 'ok' : '';
  setStatus($('account-status'), hello.account ? `●  Connected as ${hello.account}` : '○  Not connected', !!hello.account);
  $('disconnect').hidden = !hello.account;

  const { settings } = await native({ cmd: 'getSettings' });
  for (const key of FIELDS) {
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
  const reply = await native({ cmd: 'setSettings', settings: { [key]: value } });
  if (!reply.ok) return showError(reply.error);
  showError('');
  $('saved').hidden = false;
  clearTimeout(save.t);
  save.t = setTimeout(() => ($('saved').hidden = true), 1500);
}

// Asks for cookie access to twitch.tv only now, reads the single login cookie, hands it to
// the app, and gives the access back (keeping twitch.tv only if the ▶ button is on).
async function connect() {
  showError('');
  const granted = await ext.permissions.request({ permissions: ['cookies'], origins: [TWITCH] });
  if (!granted) return showError('Permission declined — nothing was read.');
  let cookie;
  try {
    cookie = await ext.cookies.get({ url: 'https://www.twitch.tv', name: 'auth-token' });
  } finally {
    const { button } = await ext.storage.local.get('button');
    ext.permissions.remove(button ? { permissions: ['cookies'] } : { permissions: ['cookies'], origins: [TWITCH] });
  }
  if (!cookie) return showError('You are not logged in to twitch.tv in this browser.');
  const reply = await native({ cmd: 'setToken', token: cookie.value });
  if (!reply.ok) return showError(reply.error);
  refresh();
}

async function disconnect() {
  await native({ cmd: 'clearToken' });
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
