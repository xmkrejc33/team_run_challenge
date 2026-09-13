import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const jsonHeaders = { 'Content-Type': 'application/json' };
const allowedActivityTypes = new Set(['running', 'trail_running']);

type ImportRequest = {
  token?: unknown;
  distanceMeters?: unknown;
  startTime?: unknown;
  endTime?: unknown;
  activityType?: unknown;
  externalId?: unknown;
};

function response(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), { status, headers: jsonHeaders });
}

function textValue(value: unknown) {
  return typeof value === 'string' ? value.trim() : '';
}

async function sha256(value: string) {
  const bytes = new TextEncoder().encode(value);
  const digest = await crypto.subtle.digest('SHA-256', bytes);
  return Array.from(new Uint8Array(digest))
    .map((byte) => byte.toString(16).padStart(2, '0'))
    .join('');
}

Deno.serve(async (request) => {
  if (request.method !== 'POST') {
    return response(405, { ok: false, error: 'Použijte metodu POST.' });
  }

  let payload: ImportRequest;
  try {
    payload = await request.json();
  } catch (_) {
    return response(400, { ok: false, error: 'Tělo požadavku musí být JSON.' });
  }

  const token = textValue(payload.token);
  const externalId = textValue(payload.externalId);
  const activityType = textValue(payload.activityType).toLowerCase();
  const distanceMeters = Number(payload.distanceMeters);
  const startTime = new Date(textValue(payload.startTime));
  const endTime = new Date(textValue(payload.endTime));

  if (token.length < 32 || externalId.length < 8 || externalId.length > 200) {
    return response(400, { ok: false, error: 'Neplatný token nebo identifikátor aktivity.' });
  }
  if (!allowedActivityTypes.has(activityType)) {
    return response(400, { ok: false, error: 'Podporován je pouze běh.' });
  }
  if (!Number.isFinite(distanceMeters) || distanceMeters <= 10 || distanceMeters > 500000) {
    return response(400, { ok: false, error: 'Vzdálenost musí být mezi 10 m a 500 km.' });
  }
  if (Number.isNaN(startTime.getTime()) || Number.isNaN(endTime.getTime()) || startTime >= endTime) {
    return response(400, { ok: false, error: 'Čas začátku nebo konce aktivity není platný.' });
  }
  if (endTime.getTime() - startTime.getTime() > 24 * 60 * 60 * 1000) {
    return response(400, { ok: false, error: 'Aktivita nesmí trvat déle než 24 hodin.' });
  }

  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  if (!supabaseUrl || !serviceRoleKey) {
    console.error('Missing Supabase service configuration.');
    return response(500, { ok: false, error: 'Server není správně nastaven.' });
  }

  const client = createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const tokenHash = await sha256(token);
  const { data: shortcutToken, error: tokenError } = await client
    .from('health_shortcut_tokens')
    .select('user_id')
    .eq('token_hash', tokenHash)
    .maybeSingle();

  if (tokenError) {
    console.error('Token lookup failed:', tokenError);
    return response(500, { ok: false, error: 'Nepodařilo se ověřit přístup.' });
  }
  if (shortcutToken == null) {
    return response(401, { ok: false, error: 'Neplatný importní token.' });
  }

  const userId = shortcutToken.user_id as string;
  const { data: profile, error: profileError } = await client
    .from('profiles')
    .select('runner_name, team_name')
    .eq('user_id', userId)
    .maybeSingle();

  if (profileError || profile == null || !textValue(profile.runner_name) || !textValue(profile.team_name)) {
    console.error('Profile lookup failed:', profileError);
    return response(422, { ok: false, error: 'Profil nemá vyplněné jméno běžce nebo tým.' });
  }

  const { error: reservationError } = await client
    .from('health_shortcut_imports')
    .insert({ user_id: userId, external_id: externalId });

  if (reservationError) {
    if (reservationError.code === '23505') {
      return response(200, { ok: true, duplicate: true, message: 'Aktivita již byla importována.' });
    }
    console.error('Import reservation failed:', reservationError);
    return response(500, { ok: false, error: 'Nepodařilo se připravit import aktivity.' });
  }

  const { data: activity, error: activityError } = await client
    .from('activities')
    .insert({
      team_name: textValue(profile.team_name),
      runner_name: textValue(profile.runner_name),
      km: Number((distanceMeters / 1000).toFixed(3)),
      start_time: startTime.toISOString(),
      end_time: endTime.toISOString(),
    })
    .select('id')
    .single();

  if (activityError) {
    console.error('Activity insert failed:', activityError);
    await client
      .from('health_shortcut_imports')
      .delete()
      .eq('user_id', userId)
      .eq('external_id', externalId);
    return response(500, { ok: false, error: 'Nepodařilo se uložit aktivitu.' });
  }

  await client
    .from('health_shortcut_imports')
    .update({ activity_id: activity.id })
    .eq('user_id', userId)
    .eq('external_id', externalId);

  return response(201, {
    ok: true,
    activityId: activity.id,
    message: 'Aktivita byla uložena.',
  });
});