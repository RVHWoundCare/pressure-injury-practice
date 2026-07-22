import { createClient } from "npm:@supabase/supabase-js@2.110.8";

const corsHeaders = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "apikey, content-type",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};

const responseHeaders = {
  ...corsHeaders,
  "Content-Type": "application/json; charset=utf-8",
  "Cache-Control": "no-store",
};

function readKeys(name: string): string[] {
  const raw = Deno.env.get(name) ?? "";
  if (!raw) return [];
  try {
    const parsed = JSON.parse(raw);
    return Object.values(parsed).filter((value): value is string =>
      typeof value === "string" && value.length > 0
    );
  } catch {
    return [raw];
  }
}

function normalizeUsername(value: unknown): string {
  return String(value ?? "").trim().replace(/\s+/g, " ");
}

function validUsername(username: string): boolean {
  return /^[A-Za-z0-9][A-Za-z0-9 _-]{2,23}$/.test(username);
}

async function sha256(value: string): Promise<string> {
  const bytes = new TextEncoder().encode(value);
  const hash = await crypto.subtle.digest("SHA-256", bytes);
  return [...new Uint8Array(hash)]
    .map((byte) => byte.toString(16).padStart(2, "0"))
    .join("");
}

async function loginEmail(usernameKey: string): Promise<string> {
  const digest = await sha256(usernameKey);
  return `pi-${digest.slice(0, 40)}@participants.invalid`;
}

function json(body: Record<string, unknown>, status = 200): Response {
  return new Response(JSON.stringify(body), { status, headers: responseHeaders });
}

Deno.serve(async (req: Request) => {
  if (req.method === "OPTIONS") {
    return new Response("ok", { headers: corsHeaders });
  }
  if (req.method !== "POST") return json({ error: "Method not allowed." }, 405);

  const url = Deno.env.get("SUPABASE_URL") ?? "";
  const publishableKeys = [
    ...readKeys("SUPABASE_PUBLISHABLE_KEYS"),
    ...readKeys("SUPABASE_PUBLISHABLE_KEY"),
    ...readKeys("SUPABASE_ANON_KEY"),
  ];
  const secretKeys = [
    ...readKeys("SUPABASE_SECRET_KEYS"),
    ...readKeys("SUPABASE_SECRET_KEY"),
    ...readKeys("SUPABASE_SERVICE_ROLE_KEY"),
  ];
  const requestKey = req.headers.get("apikey") ?? "";
  const publishableKey = publishableKeys[0] ?? "";
  const secretKey = secretKeys[0] ?? "";

  if (!url || !publishableKey || !secretKey) {
    console.error("Supabase function environment is incomplete.");
    return json({ error: "Account service is unavailable." }, 503);
  }
  if (!requestKey || !publishableKeys.includes(requestKey)) {
    return json({ error: "Invalid application key." }, 401);
  }

  let payload: Record<string, unknown>;
  try {
    payload = await req.json();
  } catch {
    return json({ error: "A JSON request body is required." }, 400);
  }

  const action = String(payload.action ?? "");
  const username = normalizeUsername(payload.username);
  const usernameKey = username.toLowerCase();
  const password = String(payload.password ?? "");

  if (!validUsername(username)) {
    return json({ error: "Use a username of 3–24 letters, numbers, spaces, hyphens, or underscores." }, 400);
  }
  if (password.length < 10 || password.length > 72) {
    return json({ error: "Use a password between 10 and 72 characters." }, 400);
  }

  const admin = createClient(url, secretKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const authClient = createClient(url, publishableKey, {
    auth: { persistSession: false, autoRefreshToken: false },
  });
  const email = await loginEmail(usernameKey);

  try {
    if (action === "register") {
      const accessCode = String(payload.accessCode ?? "").trim();
      if (!accessCode || accessCode.length > 80) {
        return json({ error: "Enter the workplace access code." }, 400);
      }

      const codeHash = await sha256(accessCode);
      const workplaceResult = await admin
        .from("workplaces")
        .select("id,display_name")
        .eq("code_hash", codeHash)
        .eq("active", true)
        .maybeSingle();
      if (workplaceResult.error) throw workplaceResult.error;
      if (!workplaceResult.data) {
        return json({ error: "The workplace access code is not valid." }, 403);
      }

      const existing = await admin
        .from("participant_profiles")
        .select("user_id")
        .eq("username_key", usernameKey)
        .maybeSingle();
      if (existing.error) throw existing.error;
      if (existing.data) {
        return json({ error: "That username is already in use. Choose another." }, 409);
      }

      // Reserve aliases from the earlier anonymous-leaderboard version too.
      // Usernames cannot contain SQL LIKE wildcards other than underscore, so
      // escape it before using a case-insensitive exact-pattern comparison.
      const historicPattern = username.replace(/([_\\%])/g, "\\$1");
      const historic = await admin
        .from("leaderboard_entries")
        .select("id")
        .ilike("username", historicPattern)
        .limit(1);
      if (historic.error) throw historic.error;
      if ((historic.data?.length ?? 0) > 0) {
        return json({ error: "That username is already in use. Choose another." }, 409);
      }

      const created = await admin.auth.admin.createUser({
        email,
        password,
        email_confirm: true,
        app_metadata: {
          account_type: "participant",
          workplace_id: workplaceResult.data.id,
        },
        user_metadata: { display_username: username },
      });
      if (created.error || !created.data.user) {
        const duplicate = /already|registered|exists/i.test(created.error?.message ?? "");
        return json({
          error: duplicate
            ? "That username is already in use. Choose another."
            : "The participant account could not be created.",
        }, duplicate ? 409 : 400);
      }

      const user = created.data.user;
      const profile = await admin.from("participant_profiles").insert({
        user_id: user.id,
        username,
        username_key: usernameKey,
        workplace_id: workplaceResult.data.id,
      });
      if (profile.error) {
        await admin.auth.admin.deleteUser(user.id);
        const duplicate = profile.error.code === "23505";
        return json({
          error: duplicate
            ? "That username is already in use. Choose another."
            : "The participant profile could not be created.",
        }, duplicate ? 409 : 400);
      }

      const signed = await authClient.auth.signInWithPassword({ email, password });
      if (signed.error || !signed.data.session) {
        return json({ error: "Account created. Sign in with your username and password." }, 201);
      }

      return json({
        session: {
          access_token: signed.data.session.access_token,
          refresh_token: signed.data.session.refresh_token,
        },
        profile: {
          username,
          workplaceId: workplaceResult.data.id,
          workplaceName: workplaceResult.data.display_name,
        },
      }, 201);
    }

    if (action === "login") {
      const signed = await authClient.auth.signInWithPassword({ email, password });
      if (signed.error || !signed.data.session || !signed.data.user) {
        return json({ error: "The username or password is incorrect." }, 401);
      }

      const profile = await admin
        .from("participant_profiles")
        .select("username,workplace_id")
        .eq("user_id", signed.data.user.id)
        .maybeSingle();
      if (profile.error) throw profile.error;
      if (!profile.data) {
        await authClient.auth.signOut();
        return json({ error: "The username or password is incorrect." }, 401);
      }

      return json({
        session: {
          access_token: signed.data.session.access_token,
          refresh_token: signed.data.session.refresh_token,
        },
        profile: {
          username: profile.data.username,
          workplaceId: profile.data.workplace_id,
        },
      });
    }

    return json({ error: "Unsupported account action." }, 400);
  } catch (error) {
    console.error("Participant account failure", error);
    return json({ error: "Account service is temporarily unavailable." }, 500);
  }
});
