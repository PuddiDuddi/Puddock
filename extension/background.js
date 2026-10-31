// Puddock — background (service worker in Chromium, event page in Firefox).
if (typeof importScripts === 'function') importScripts('channel.js');
// Firefox: `browser.*` is the promise-based API; Chromium: `chrome.*` already returns promises.
const ext = globalThis.browser ?? chrome;

const HOST = 'com.puddock.native';          // the Puddock app, registered by its installer
const POPUP = { width: 360, height: 720 };

const native = msg => ext.runtime.sendNativeMessage(HOST, msg);

function randomHex(bytes = 16) {
  const a = new Uint8Array(bytes);
  crypto.getRandomValues(a);
  return Array.from(a, b => b.toString(16).padStart(2, '0')).join('');
}

function chatUrl(channel, dark, nonce) {
  const q = [];
  if (dark) q.push('darkpopout');
  if (nonce) q.push('puddock=' + nonce);
  return `https://www.twitch.tv/popout/${channel}/chat${q.length ? '?' + q.join('&') : ''}`;
}

// A popup window that doesn't steal focus (Firefox doesn't accept `focused`, so retry without).
async function openPopup(opts) {
  try {
    return await ext.windows.create({ ...opts, type: 'popup', focused: false, ...POPUP });
  } catch {
    return ext.windows.create({ ...opts, type: 'popup', ...POPUP });
  }
}

async function flash(tabId, text, title) {
  if (tabId == null) return;
  await ext.action.setBadgeBackgroundColor({ color: '#9146FF', tabId });
  await ext.action.setBadgeText({ text, tabId });
  await ext.action.setTitle({ title, tabId });
  setTimeout(() => {
    ext.action.setBadgeText({ text: '', tabId });
    ext.action.setTitle({ title: 'Watch in Puddock (Alt+M)', tabId });
  }, 3000);
}

// Pause Twitch's own player in that tab, with the one-off access the click gave us (activeTab).
function pauseVideo(tabId) {
  ext.scripting.executeScript({
    target: { tabId },
    func: () => document.querySelectorAll('video').forEach(v => v.pause()),
  }).catch(() => {});
}

// The ▶ button on channel pages is opt-in (options page) because it needs all of twitch.tv:
// registered only while the user has enabled it AND granted that access.
const TWITCH = 'https://www.twitch.tv/*';
const BUTTON = { id: 'puddock-button', matches: [TWITCH], js: ['channel.js', 'content.js'], css: ['content.css'], runAt: 'document_idle' };

async function syncButton() {
  const { button } = await ext.storage.local.get('button');
  const allowed = await ext.permissions.contains({ origins: [TWITCH] });
  const registered = (await ext.scripting.getRegisteredContentScripts({ ids: [BUTTON.id] })).length > 0;
  if (button && allowed && !registered) await ext.scripting.registerContentScripts([BUTTON]);
  else if (!(button && allowed) && registered) await ext.scripting.unregisterContentScripts({ ids: [BUTTON.id] });
}
ext.runtime.onStartup.addListener(syncButton);
ext.storage.onChanged.addListener(syncButton);
ext.permissions.onAdded.addListener(syncButton);
ext.permissions.onRemoved.addListener(syncButton);

// The app put this nonce into a URL (chat window / connect request): ask it whether it's real
// before acting on it, so a web page can't trigger these with made-up links.
async function nonceIsOurs(kind, nonce) {
  if (!/^[a-f0-9]{16,64}$/.test(nonce || '')) return false;
  try {
    return !!(await native({ cmd: 'checkNonce', kind, nonce }))?.ok;
  } catch {
    return false;
  }
}

// at most one watch request every 3 s per tab
const lastWatch = new Map();
function rateLimited(tabId) {
  const now = Date.now();
  if (now - (lastWatch.get(tabId) || 0) < 3000) return true;
  lastWatch.set(tabId, now);
  return false;
}

// Ask the app to play `channel`. If it wants a chat, open the popout here, in the user's own
// browser, so their chat extensions (7TV, BTTV…) apply; the nonce lets the app find that window.
async function watch(channel, tab, pauseTab) {
  const nonce = randomHex();
  let reply;
  try {
    reply = await native({ cmd: 'watch', channel, nonce });
  } catch {
    ext.runtime.openOptionsPage();       // app missing or not registered: show how to set it up
    return;
  }
  if (!reply || !reply.ok) {
    flash(tab?.id, '!', reply?.error || 'Puddock could not start the stream');
    return;
  }
  if (pauseTab && tab?.url && twitchChannel(tab.url) === channel) pauseVideo(tab.id);
  if (reply.chat) openPopup({ url: chatUrl(channel, reply.chatDark, nonce) });
}

ext.action.onClicked.addListener(tab => {
  const channel = twitchChannel(tab.url || '');
  channel ? watch(channel, tab, true) : flash(tab.id, '?', 'Open a Twitch channel first');
});

ext.runtime.onInstalled.addListener(({ reason }) => {
  ext.contextMenus.removeAll(() => {
    ext.contextMenus.create({
      id: 'link', title: 'Watch in Puddock', contexts: ['link'],
      targetUrlPatterns: ['*://*.twitch.tv/*'],
    });
    ext.contextMenus.create({
      id: 'page', title: 'Watch this channel in Puddock', contexts: ['page'],
      documentUrlPatterns: ['https://www.twitch.tv/*'],
    });
  });
  syncButton();
  if (reason === 'install') ext.runtime.openOptionsPage();
});

ext.contextMenus.onClicked.addListener((info, tab) => {
  const channel = twitchChannel(info.menuItemId === 'link' ? info.linkUrl : info.pageUrl);
  if (channel) watch(channel, tab, info.menuItemId === 'page');
});

// Messages from our own content scripts only (web pages can't reach this listener directly,
// but twitch.tv's own scripts could imitate a click — hence isTrusted, nonces and rate limits).
ext.runtime.onMessage.addListener((msg, sender, sendResponse) => {
  const tab = sender.tab;
  // sender.url is the page our content script runs in (known even without host access to the tab)
  if (sender.id !== ext.runtime.id || !tab || !/^https:\/\/www\.twitch\.tv\//.test(sender.url || '')) return;

  if (msg?.type === 'watch') {
    const channel = twitchChannel('https://www.twitch.tv/' + msg.channel);
    if (channel && !rateLimited(tab.id)) watch(channel, tab, true);
  } else if (msg?.type === 'chat-ready') {
    // A popout carrying a nonce the app issued: make it a popup window (if the app opened it as
    // a tab) and tell chat.js it may mark the window title.
    nonceIsOurs('Chat', msg.nonce).then(async ok => {
      if (ok) {
        const w = await ext.windows.get(tab.windowId);
        if (w.type !== 'popup') await openPopup({ tabId: tab.id });
      }
      sendResponse({ ok });
    });
    return true;                                  // answering asynchronously
  } else if (msg?.type === 'open-options') {
    nonceIsOurs('Connect', msg.nonce).then(ok => {
      if (!ok) return;
      ext.tabs.create({ url: ext.runtime.getURL('options.html#account') });
      ext.tabs.remove(tab.id).catch(() => {});    // the helper tab the app opened
    });
  }
});
