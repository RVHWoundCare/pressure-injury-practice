# Pressure Injury Staging Practice

This repository contains a static 40-case learning activity hosted with GitHub Pages and backed by Supabase. It includes:

- five cases from each of eight pressure-injury assessment domains;
- unique participant usernames and password-protected resume access;
- a workplace-code enrollment gate validated only by a Supabase Edge Function;
- automatic progress saving after every answer;
- a public top-50 leaderboard that is available from the homepage;
- complete case-level attempt records available only to allowlisted administrators;
- an administrator page that shows each case description and detailed image-generation specification beside the upload controls; and
- administrator-uploaded AI-generated image overrides with built-in simulations retained as fallbacks.

## Security model

`config.js` contains the Supabase project URL and a **publishable** key. Both are designed to be public and may be committed to GitHub. Row Level Security (RLS) provides the actual authorization boundary.

Never put a Supabase secret key, legacy `service_role` key, participant password, or plaintext workplace code in GitHub, `config.js`, or an HTML file.

The two approved workplace codes are represented in `public.workplaces` only by SHA-256 hashes. The browser sends a submitted code to the `participant-account` Edge Function over HTTPS. That server-side function hashes it, checks the Supabase row, and creates the account only when a match exists. The function also reserves aliases used by the earlier leaderboard version.

Participant passwords are stored and verified by Supabase Auth. This implementation deliberately does not collect participant email addresses, so self-service password recovery is not available.

## Repository layout

```text
index.html
admin.html
case-catalog.js
config.js
supabase-setup.sql
README.md
supabase/
  functions/
    participant-account/
      index.ts
  migrations/
    20260721_participant_accounts_and_results.sql
```

## Supabase database setup

For a new project, open **SQL Editor → New query**, paste the complete contents of `supabase-setup.sql`, and run it. If the editor warns about destructive statements, review the named targets and choose **Run and enable RLS**. Do not choose **Run without RLS**.

The setup creates:

- `public.leaderboard_entries` for public aliases and aggregate scores;
- `private.admin_users` as the administrator allowlist;
- `public.case_images` and the `case-images` Storage bucket;
- `public.workplaces`, containing only workplace-code hashes;
- `public.participant_profiles`, with a case-insensitive unique username key;
- `public.participant_attempts`, containing resumable state and completed case-level results;
- `public.get_leaderboard(...)`, which exposes only public leaderboard fields;
- `public.is_current_user_admin()`, which checks the private allowlist; and
- `public.save_participant_attempt(...)`, which validates attempt structure, calculates the stored score on the server, saves progress, and creates a leaderboard row at completion.

Direct browser writes to the attempts and leaderboard tables are not allowed. Participants save through the authenticated database function. RLS allows participants to read only their own profile and attempts; allowlisted administrators can read all attempts.

## Participant account Edge Function

Deploy `supabase/functions/participant-account/index.ts` as a function named `participant-account` with legacy JWT verification disabled. The function implements its own publishable-key check because modern `sb_publishable_...` keys are opaque rather than JWTs.

With the Supabase CLI, the command is:

```bash
supabase functions deploy participant-account --no-verify-jwt
```

Hosted Supabase projects automatically provide `SUPABASE_URL`, `SUPABASE_PUBLISHABLE_KEYS`, and `SUPABASE_SECRET_KEYS` to Edge Functions. Do not create or commit a local secret-key file.

## Browser configuration

In Supabase, open **Settings → API Keys**, copy the Project URL and an active publishable key, and place them in `config.js`:

```js
window.APP_CONFIG = Object.freeze({
  supabaseUrl: "https://YOUR-PROJECT.supabase.co",
  supabasePublishableKey: "sb_publishable_..."
});
```

The publishable key is intentionally visible on GitHub. Keep RLS enabled on every browser-accessible table and never substitute a secret key.

## GitHub Pages

In the GitHub repository, open **Settings → Pages**, select **Deploy from a branch**, choose `main` and `/(root)`, and save. Commits to `main` are then published automatically.

The site URL normally has this form:

```text
https://YOUR-GITHUB-USERNAME.github.io/pressure-injury-practice/
```

## Participant flow

1. Open the homepage.
2. Optionally choose **View leaderboard** without signing in.
3. Create an account with a unique, non-identifying username, a 10–72 character password, and an approved workplace code.
4. Complete the activity, or choose **Save and Exit** and sign in later on the same or another device.
5. On completion, Supabase saves all 40 responses and adds the aggregate result to the public leaderboard.

Usernames are case-insensitively unique. A username already present in participant accounts or the historic leaderboard cannot be reused.

## Administrator setup and use

Administrator accounts continue to use Supabase email-and-password Auth.

1. In **Authentication → URL Configuration**, set the Site URL to the GitHub Pages address and add `admin.html` as an allowed redirect URL.
2. Open the published `admin.html`, create or sign in to an administrator account, and copy the displayed Supabase user ID.
3. In the SQL Editor, add that exact ID to the private allowlist:

   ```sql
   insert into private.admin_users (user_id)
   values ('COPIED-USER-ID')
   on conflict (user_id) do nothing;
   ```

4. Return to `admin.html` and choose **Check access again**.

The image uploader shows the selected case's anatomical location, expected classification, simulated phototype, clinical context, key findings, and full image-generation specification. Use only approved AI-generated simulations with no real patient information.

The completed-results section lists every finished attempt with alias, workplace, score, time, completion date, and all 40 participant answers. This data is protected by the administrator allowlist and is not exposed on the public leaderboard.

## Verification checklist

- Create one test participant for each workplace code.
- Confirm a wrong code is rejected and no account is created.
- Confirm a duplicate username is rejected regardless of letter case.
- Answer several cases, sign out, sign in again, and confirm the same attempt resumes.
- Complete a test attempt and confirm the public leaderboard shows only alias, score, duration, and completion date.
- Sign in as an administrator and confirm the full 40-response result is visible.
- Select several cases in the image uploader and verify that their guidance changes.
- Upload and remove a synthetic test image, confirming that the built-in image returns.

## Research and privacy limitations

- Public aliases should not contain names, email addresses, employee numbers, or other identifying information.
- Supabase stores the alias, workplace, timestamps, duration, and case-level responses for every attempt. Establish an approved retention/deletion plan and obtain the required privacy, research-ethics, and organizational approvals before collecting study data.
- Workplace codes are enrollment gates, not high-entropy secrets. Distribute them privately and rotate them if they are shared beyond the intended group.
- Uploaded images and alt text are public because the public assessment must display them. Never upload patient photographs or confidential material.
- Five cases per domain means domain percentages change in 20-point increments. Treat subgroup results as descriptive and plan sample size with a statistician using the study's primary outcome, expected effect, clustering, and attrition.
- The activity remains a clinical-education prototype until every case and image has been reviewed and approved by a qualified wound-care specialist.
- GitHub Pages exposes scoring code to participants. The database calculates the stored classification score independently, but this is still not a secure high-stakes examination platform.
