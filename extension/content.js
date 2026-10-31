// Floating "▶ Puddock" pill on Twitch channel pages (opt-in, see syncButton in background.js).
// Twitch is a SPA, so watch the URL.
(() => {
  // not in popout chat / player windows (incl. the chat embedded by Puddock itself) or iframes
  const wanted = () => window.top === window && !/^\/(popout|embed|moderator)\//.test(location.pathname);

  const SVG = 'http://www.w3.org/2000/svg';
  const btn = document.createElement('button');
  btn.id = 'puddock-btn';
  const svg = document.createElementNS(SVG, 'svg');
  svg.setAttribute('viewBox', '0 0 16 16');
  const path = document.createElementNS(SVG, 'path');
  path.setAttribute('d', 'M4 2.5v11l9.5-5.5z');
  svg.append(path);
  const label = document.createElement('span');
  label.textContent = 'Puddock';
  btn.append(svg, label);

  btn.addEventListener('click', e => {
    if (!e.isTrusted) return;                       // a real click, not page script calling .click()
    const channel = twitchChannel(location.href);
    if (channel) chrome.runtime.sendMessage({ type: 'watch', channel });
  });

  let last = null;
  setInterval(() => {
    if (location.href === last) return;
    last = location.href;
    const channel = wanted() && twitchChannel(location.href);
    if (channel) {
      btn.title = `Watch ${channel} in Puddock (Alt+M)`;
      if (!btn.isConnected) document.body.append(btn);
    } else {
      btn.remove();
    }
  }, 500);
})();
