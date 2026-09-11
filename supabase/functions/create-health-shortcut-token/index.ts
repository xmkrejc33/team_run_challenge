import { createClient } from 'https://esm.sh/@supabase/supabase-js@2';

const corsHeaders = {
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Allow-Origin': '*',
  'Content-Type': 'application/json',
};

function reply(status: number, body: Record<string, unknown>) {
  return new Response(JSON.stringify(body), { status, headers: corsHeaders });
}

async function sha256(value: string) {
  const digest = await crypto.subtle.digest(
    'SHA-256',
    new TextEncoder().encode(value),
  );
  return Array.from(new Uint8Array(digest))
    .map((byte) => byte.toString(16).padStart(2, '0'))
    .join('');
}

function createToken() {
  const bytes = new Uint8Array(32);
  crypto.getRandomValues(bytes);
  return btoa(String.fromCharCode(...bytes))
    .replaceAll('+', '-')
    .replaceAll('/', '_')
    .replaceAll('=', '');
}

Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response('ok', { headers: corsHeaders });
  if (request.method !== 'POST') return reply(405, { ok: false, error: 'Použijte metodu POST.' });

  const supabaseUrl = Deno.env.get('SUPABASE_URL');
  const anonKey = Deno.env.get('SUPABASE_ANON_KEY');
  const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  const authorization = request.headers.get('Authorization');
  if (!supabaseUrl || !anonKey || !serviceRoleKey || !authorization) {
    return reply(401, { ok: false, error: 'Chybí přihlášení.' });
  }

  const client = createClient(supabaseUrl, anonKey, {
    global: { headers: { Authorization: authorization } },
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const { data: userData, error: userError } = await client.auth.getUser();
  if (userError || userData.user == null) {
    return reply(401, { ok: false, error: 'Přihlášení není platné.' });
  }

  const token = createToken();
  const tokenHash = await sha256(token);
  const adminClient = createClient(supabaseUrl, serviceRoleKey, {
    auth: { autoRefreshToken: false, persistSession: false },
  });
  const { error: insertError } = await adminClient
    .from('health_shortcut_tokens')
    .upsert({
      user_id: userData.user.id,
      token_hash: tokenHash,
      updated_at: new Date().toISOString(),
    }, { onConflict: 'user_id' });

  if (insertError) {
    console.error('Shortcut token creation failed:', insertError);
    return reply(500, { ok: false, error: 'Token se nepodařilo vytvořit.' });
  }

  return reply(200, {
    ok: true,
    token,
    endpoint: `${supabaseUrl}/functions/v1/import-health-shortcut`,
  });
});