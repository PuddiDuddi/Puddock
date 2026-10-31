// Popout chat.
// Opened for Puddock (?puddock=<nonce>): make sure it is a popup window, and keep
// "puddock:<nonce>:<top>:<left>:<right>:<bottom>" in the title — the browser chrome around the
// page in device pixels — so the app finds exactly this window and can hide that chrome.
// Shortcuts the app's menu sends as keystrokes:
//   Alt+Shift+S          open Twitch's chat settings
//   Alt+Shift+Up / Down  zoom the chat in / out (only this page, not twitch.tv tabs)
//   Alt+Shift+0          reset zoom
(() => {
  const nonce = new URLSearchParams(location.search).get('puddock');
  if (nonce && /^[a-f0-9]{16,64}$/.test(nonce)) chrome.runtime.sendMessage({ type: 'chat-ready', nonce }, reply => {
    if (!reply?.ok) return;                         // not a nonce the app issued: leave the page alone
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

  const KEY = 'puddock-chat-zoom';
  const apply = z => { document.documentElement.style.zoom = z === 1 ? '' : String(z); };
  const clamp = z => Math.round(Math.min(2, Math.max(0.6, z)) * 10) / 10;
  let zoom = clamp(parseFloat(localStorage.getItem(KEY)) || 1);   // the page can write localStorage too
  apply(zoom);

  const setZoom = z => {
    zoom = clamp(z);
    localStorage.setItem(KEY, zoom);
    apply(zoom);
  };

  window.addEventListener('keydown', e => {
    if (!e.altKey || !e.shiftKey || e.ctrlKey || e.metaKey) return;
    switch (e.code) {
      case 'KeyS':
        document.querySelector('[data-a-target="chat-settings"], button[aria-label="Chat settings" i], button[aria-label*="chat settings" i]')?.click();
        break;
      case 'ArrowUp':   setZoom(zoom + 0.1); break;
      case 'ArrowDown': setZoom(zoom - 0.1); break;
      case 'Digit0':    setZoom(1); break;
      default: return;
    }
    e.preventDefault();
    e.stopPropagation();
  }, true);
})();
