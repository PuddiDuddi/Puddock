// Shared by background.js and content.js: Twitch URL -> channel name (or null).
const TWITCH_RESERVED = new Set([
  'directory', 'videos', 'settings', 'search', 'downloads', 'subscriptions', 'inventory', 'wallet',
  'drops', 'friends', 'messages', 'turbo', 'jobs', 'store', 'prime', 'p', 'login', 'signup', 'logout',
  'following', 'payments', 'security', 'privacy', 'team', 'broadcast', 'creatorcamp', 'bits', 'event',
  'user', 'dashboard', 'u', 'activate', 'collections',
]);

function twitchChannel(url) {
  let u;
  try { u = new URL(url); } catch { return null; }
  let name;
  if (u.hostname === 'player.twitch.tv') {
    name = u.searchParams.get('channel');
  } else if (/(^|\.)twitch\.tv$/.test(u.hostname)) {
    let seg = u.pathname.split('/').filter(Boolean);
    if (['popout', 'moderator', 'embed'].includes(seg[0])) seg = seg.slice(1);
    name = seg[0];
  }
  name = (name || '').toLowerCase();
  return /^[a-z0-9_]{1,25}$/.test(name) && !TWITCH_RESERVED.has(name) ? name : null;
}
