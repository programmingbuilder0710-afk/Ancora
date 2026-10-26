export type Block = { source: string; start: string; end: string };
export type Account = { id: string; app: string; name: string };
export type Json = Record<string, any>;
export type Proxy = (url: string, method?: string, body?: Json, headers?: Record<string, string>) => Promise<Json>;
export const apps = ['google_calendar', 'microsoft_outlook_calendar'];
const google = 'https://www.googleapis.com/calendar/v3';
const outlook = 'https://graph.microsoft.com/v1.0';
const utcHeaders = { Prefer: 'outlook.timezone="UTC"' };

function interval(source: string, start: string, end: string): Block[] {
  const a = new Date(start), b = new Date(end);
  return Number.isFinite(+a) && +b > +a ? [{ source, start: a.toISOString(), end: b.toISOString() }] : [];
}
export function googleBusy(data: Json, source: string): Block[] {
  return Object.values(data.calendars ?? {}).flatMap((calendar: any) =>
    (calendar.busy ?? []).flatMap((b: any) => interval(source, b.start, b.end)));
}
export function outlookBusy(data: Json, source: string): Block[] {
  const utc = (s: string) => /(?:Z|[+-]\d\d:\d\d)$/i.test(s) ? s : `${s}Z`;
  return (data.value ?? []).filter((e: any) => !e.isCancelled && e.showAs !== 'free')
    .flatMap((e: any) => interval(source, utc(e.start?.dateTime ?? ''), utc(e.end?.dateTime ?? '')));
}

async function pages(proxy: Proxy, url: string, isGoogle: boolean, headers = {}): Promise<Json[]> {
  const items: Json[] = [];
  // ponytail: cap provider paging at ten pages; surface overflow instead of hiding busy time.
  for (let page = 0; page < 10; page++) {
    const data = await proxy(url, 'GET', undefined, headers);
    items.push(...(isGoogle ? data.items ?? [] : data.value ?? []));
    const next = isGoogle ? data.nextPageToken : data['@odata.nextLink'];
    if (!next) return items;
    if (isGoogle) {
      const parsed = new URL(url); parsed.searchParams.set('pageToken', next); url = parsed.href;
    } else {
      const parsed = new URL(next);
      if (parsed.origin !== 'https://graph.microsoft.com') throw new Error('Invalid calendar paging URL');
      url = parsed.href;
    }
  }
  throw new Error('Calendar paging limit reached');
}
async function calendars(proxy: Proxy, app: string) {
  return pages(proxy, app === apps[0] ? `${google}/users/me/calendarList?maxResults=250` : `${outlook}/me/calendars`, app === apps[0]);
}
export async function readBusy(proxy: Proxy, account: Account, start: string, end: string): Promise<Block[]> {
  const isGoogle = account.app === apps[0];
  const all = (await calendars(proxy, account.app)).filter(c => (isGoogle ? c.summary : c.name) !== 'My Plan');
  const source = `pd:${account.app}:${account.name}`;
  const blocks: Block[] = [];
  if (isGoogle) {
    for (let i = 0; i < all.length; i += 50) {
      const data = await proxy(`${google}/freeBusy`, 'POST', { timeMin: start, timeMax: end, items: all.slice(i, i + 50).map(c => ({ id: c.id })) });
      // ponytail: calendars freeBusy reports errors for (e.g. revoked shared calendars) are skipped, not fatal to the account.
      blocks.push(...googleBusy(data, source));
    }
  } else {
    for (const c of all) {
      const url = new URL(`${outlook}/me/calendars/${encodeURIComponent(c.id)}/calendarView`);
      url.searchParams.set('startDateTime', start); url.searchParams.set('endDateTime', end);
      const value = await pages(proxy, url.href, false, utcHeaders);
      blocks.push(...outlookBusy({ value }, source));
    }
  }
  return blocks;
}
// Pipedream's managed Google OAuth client grants calendar.events and calendar.readonly,
// not calendar creation, so inserting "My Plan" is denied (403). Google plans then go to
// the primary calendar as "free" time, which keeps them out of freeBusy and therefore
// out of Doer's own busy sync.
async function planCalendar(proxy: Proxy, isGoogle: boolean): Promise<{ id: string; primary: boolean }> {
  const plan = (await calendars(proxy, isGoogle ? apps[0] : apps[1])).find(c => isGoogle
    ? c.summary === 'My Plan' && ['owner', 'writer'].includes(c.accessRole) : c.name === 'My Plan');
  if (plan?.id) return { id: plan.id, primary: false };
  let created: Json;
  try {
    created = await proxy(isGoogle ? `${google}/calendars` : `${outlook}/me/calendars`, 'POST', isGoogle ? { summary: 'My Plan' } : { name: 'My Plan' });
  } catch (e) {
    if (isGoogle && typeof e === 'object' && e !== null && 'status' in e && e.status === 403) return { id: 'primary', primary: true };
    throw e;
  }
  if (!created.id) throw new Error('Could not create My Plan');
  return { id: created.id, primary: false };
}
export async function writeEvents(proxy: Proxy, account: Account, deletes: string[], creates: Json[]) {
  const isGoogle = account.app === apps[0];
  const plan = await planCalendar(proxy, isGoogle);
  const base = isGoogle ? `${google}/calendars/${encodeURIComponent(plan.id)}/events` : `${outlook}/me/calendars/${encodeURIComponent(plan.id)}/events`;
  const created: Record<string, string> = {}, errors: Json[] = [];
  for (const id of deletes) {
    try { await proxy(`${base}/${encodeURIComponent(id)}`, 'DELETE'); }
    catch (e) { if (![404, 410].includes((e as { status: number }).status)) errors.push({ event: id, message: 'Event deletion failed' }); }
  }
  for (const event of creates) {
    try {
      const data = await proxy(base, 'POST', isGoogle ? {
        summary: event.title, description: 'Planned by Doer', start: { dateTime: event.start }, end: { dateTime: event.end },
        ...(plan.primary ? { transparency: 'transparent' } : {}),
      } : {
        subject: event.title, body: { contentType: 'text', content: 'Planned by Doer' },
        start: { dateTime: event.start.replace(/Z$/, ''), timeZone: 'UTC' }, end: { dateTime: event.end.replace(/Z$/, ''), timeZone: 'UTC' },
      });
      if (!data.id) throw new Error('Missing event id');
      created[event.key] = data.id;
    } catch { errors.push({ key: event.key, message: 'Event creation failed' }); }
  }
  return { created, errors };
}
