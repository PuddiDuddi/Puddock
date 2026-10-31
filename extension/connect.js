// The app's "Connect in browser" button opens https://www.twitch.tv/?puddock=connect-<nonce>.
// The background checks that nonce with the app before opening the options page.
{
  const m = location.pathname === '/' && /^connect-([a-f0-9]{32})$/.exec(new URLSearchParams(location.search).get('puddock') || '');
  if (m) {
    history.replaceState(null, '', '/');
    chrome.runtime.sendMessage({ type: 'open-options', nonce: m[1] });
  }
}
