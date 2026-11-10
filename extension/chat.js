// Popout chat.
// Opened for Puddock (?puddock=<nonce>): make sure it is a popup window, and keep
// "puddock:<nonce>:<top>:<left>:<right>:<bottom>" in the title — the browser chrome around the
// page in device pixels — so the app finds exactly this window and can hide that chrome.
// What the app's menu asks for — as a message through the background's port, or, without a
// port, as keystrokes:
//   Alt+Shift+S          open Twitch's chat settings
//   Alt+Shift+Up / Down  zoom the chat in / out (only this page, not twitch.tv tabs)
//   Alt+Shift+0          reset zoom
//   Alt+Shift+R          reload the chat
// Shortcuts and zoom are for Puddock's chat only — any other popout chat is left alone: they
// start once the app has confirmed the nonce.
(() => {
  const nonce = new URLSearchParams(location.search).get('puddock');
  if (!nonce || !/^[a-f0-9]{16,64}$/.test(nonce)) return;

  const KEY = 'puddock-chat-zoom';
  const CONFIRMED = 'puddock-chat';       // sessionStorage: the nonce the app confirmed for this window
  let started = false;
  const start = () => {
    if (started) return;
    started = true;
    const apply = z => { document.documentElement.style.zoom = z === 1 ? '' : String(z); };
    const clamp = z => Math.round(Math.min(2, Math.max(0.6, z)) * 10) / 10;
    let zoom = clamp(parseFloat(localStorage.getItem(KEY)) || 1);   // the page can write localStorage too
    apply(zoom);

    const setZoom = z => {
      zoom = clamp(z);
      localStorage.setItem(KEY, zoom);
      apply(zoom);
    };

    const act = action => {
      switch (action) {
        case 'settings':
          document.querySelector('[data-a-target="chat-settings"], button[aria-label="Chat settings" i], button[aria-label*="chat settings" i]')?.click();
          break;
        case 'zoomIn':    setZoom(zoom + 0.1); break;
        case 'zoomOut':   setZoom(zoom - 0.1); break;
        case 'zoomReset': setZoom(1); break;
        case 'reload':    location.reload(); break;
      }
    };

    // from the app, through the background's port (only our own extension can send these)
    chrome.runtime.onMessage.addListener(msg => {
      if (msg?.type === 'puddock-chat' && typeof msg.action === 'string') act(msg.action);
    });

    // the same as keystrokes, for when there is no port
    const KEYS = { KeyS: 'settings', ArrowUp: 'zoomIn', ArrowDown: 'zoomOut', Digit0: 'zoomReset', KeyR: 'reload' };
    window.addEventListener('keydown', e => {
      if (!e.altKey || !e.shiftKey || e.ctrlKey || e.metaKey || !Object.hasOwn(KEYS, e.code)) return;
      e.preventDefault();
      e.stopPropagation();
      act(KEYS[e.code]);
    }, true);
  };

  // The app accepts a chat nonce for 10 minutes; the chat can be reloaded (F5) long after that,
  // with the same address. So remember the confirmation for this window (sessionStorage survives
  // a reload, not a new window). The page could write that too — and would only gain these
  // shortcuts on itself.
  try {
    if (sessionStorage.getItem(CONFIRMED) === nonce) start();
  } catch {}

  chrome.runtime.sendMessage({ type: 'chat-ready', nonce }, reply => {
    if (!reply?.ok) return;                         // not a nonce the app issued: leave the page alone
    try { sessionStorage.setItem(CONFIRMED, nonce); } catch {}
    start();
    const marker = () => {
      const r = window.devicePixelRatio || 1;
      const side = Math.max(0, Math.round(((outerWidth - innerWidth) / 2) * r));
      const top = Math.max(0, Math.round((outerHeight - innerHeight) * r) - side);
      return `puddock:${nonce}:${top}:${side}:${side}:${side}`;
    };
    const keep = () => { const t = marker(); if (document.title !== t) document.title = t; };
    setInterval(keep, 500);                 // Twitch keeps setting its own title
    addEventListener('resize', keep);
  });
})();
