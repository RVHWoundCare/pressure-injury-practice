# Pressure Injury Staging Practice: GitHub Pages + Supabase

This folder is ready for a static GitHub Pages site. It adds:

- a required public username before the assessment begins;
- a 40-case assessment with five cases from each of the eight pressure-injury types;
- automatic score submission after all 40 cases are completed;
- a separate top-50 leaderboard page;
- a protected `admin.html` page for uploading or replacing each case's AI-generated image;
- Supabase Storage image overrides with the built-in simulations retained as fallbacks;
- local save/resume behavior when the browser is refreshed or closed;
- Supabase Row Level Security so each anonymous signed-in browser can submit only its own score and only allowlisted administrators can change images.

## 1. Create the Supabase database

1. Open your Supabase project and wait until it finishes provisioning.
2. Open **SQL Editor**, choose **New query**, and paste the complete contents of `supabase-setup.sql`. Run it again if you previously installed the 80-case version; it preserves old rows and shows only 40-case entries on the active leaderboard.
3. Choose **Run**. You should see a successful result.
4. Open **Authentication** and find the **Anonymous Sign-Ins** provider (the dashboard may place it under **Providers** or **Sign In / Providers**). Enable anonymous sign-ins and save.
5. For a public site, also review Supabase's CAPTCHA/bot-protection option for anonymous sign-ins.

The SQL creates the leaderboard, private administrator allowlist, public case-image metadata, a 5 MB `case-images` Storage bucket, ranking function, and Row Level Security policies. It is safe to rerun over either earlier package. If the SQL Editor warns about destructive operations, those are the targeted `drop policy if exists` and scoring-constraint upgrade statements; they do not drop the tables or stored leaderboard rows. Choose **Run and enable RLS**, not **Run without RLS**. Do not replace these policies with unrestricted public uploads or inserts.

## 2. Connect the site to Supabase

1. In Supabase, open the project's **Connect** dialog or **Settings → API Keys**.
2. Copy the **Project URL**.
3. Copy the **Publishable key**, which begins with `sb_publishable_`.
4. Open `config.js` and replace the two placeholder values.

Your finished file will look like this:

```js
window.APP_CONFIG = Object.freeze({
  supabaseUrl: "https://abc123.supabase.co",
  supabasePublishableKey: "sb_publishable_..."
});
```

The publishable key is intended for browser code and can be committed to GitHub when Row Level Security is enabled. **Never** put a Supabase secret key or legacy `service_role` key in `config.js`, HTML, GitHub, or any browser-facing file.

## 3. Upload the site to GitHub

1. On GitHub, choose **New repository**.
2. Give it a name such as `pressure-injury-practice`.
3. With a free GitHub account, make the repository **Public**, then create it.
4. In the new repository, choose **Add file → Upload files**.
5. Unzip this package on your computer, then upload the files inside the folder—not the ZIP itself. `index.html` and `config.js` must be at the repository root.
6. Commit the files to the `main` branch.

The repository root should contain:

```text
index.html
admin.html
config.js
supabase-setup.sql
README.md
```

## 4. Turn on GitHub Pages

1. In the repository, open **Settings → Pages**.
2. Under **Build and deployment**, set **Source** to **Deploy from a branch**.
3. Select branch **main** and folder **/(root)**.
4. Choose **Save**.
5. Wait for the Pages deployment to finish, then use **Visit site** in the same settings page.

For a repository named `pressure-injury-practice`, the address normally follows this pattern:

```text
https://YOUR-GITHUB-USERNAME.github.io/pressure-injury-practice/
```

## 5. Test the complete flow

1. Open the GitHub Pages address in a private/incognito window.
2. Enter a non-identifying username using 3–24 letters, numbers, spaces, hyphens, or underscores.
3. Complete all 40 cases. The final button is **Finish & View Leaderboard**.
4. Confirm that the score appears on the leaderboard and that **View My Detailed Results** opens the existing analysis page.
5. Open a second private window to verify that another username can create a separate entry.

If the quiz works but the leaderboard does not, check these three items first:

- both values in `config.js` were replaced;
- anonymous sign-ins are enabled in Supabase;
- `supabase-setup.sql` ran successfully in the same Supabase project.

## 6. Create your image-administrator account

The administrator password is handled by Supabase Auth and is never stored in GitHub.

1. In Supabase, open **Authentication → URL Configuration**.
2. Set the Site URL to your GitHub Pages address, for example:

   ```text
   https://YOUR-GITHUB-USERNAME.github.io/pressure-injury-practice/
   ```

3. Add this exact redirect URL to the allowed Redirect URLs list:

   ```text
   https://YOUR-GITHUB-USERNAME.github.io/pressure-injury-practice/admin.html
   ```

4. Confirm that the Supabase **Email** authentication provider allows email-and-password sign-ups. Keeping email confirmation enabled is recommended.
5. Open `admin.html` from your published site and choose **Create account**.
6. Confirm your email if requested, return to `admin.html`, and sign in.
7. The page will display your Supabase user ID. Copy it.
8. In the Supabase SQL Editor, run the command shown on `admin.html`. It has this form:

   ```sql
   insert into private.admin_users (user_id)
   values ('YOUR-COPIED-USER-ID')
   on conflict (user_id) do nothing;
   ```

9. Return to `admin.html` and choose **Check access again**.

This is a one-time grant. Do not add the user ID or this private allowlist operation to browser code. To authorize another image administrator, have that person create an account and insert their user ID the same way.

## 7. Upload case images

1. Sign in at `admin.html`.
2. Choose one of the 40 active case IDs.
3. Select a JPEG, PNG, WebP, or AVIF image no larger than 5 MB. A 4:3 image around 1200 × 900 px is recommended.
4. Write an accessible description of visible features without naming or revealing the correct classification.
5. Confirm that the file is an approved AI-generated simulation containing no real patient or identifying information.
6. Choose **Upload image**. Replacing an image updates that case automatically.

Uploaded images are public because the public assessment must display them. Uploading, replacement, metadata changes, and deletion are restricted to allowlisted administrators by database and Storage policies. Removing an override makes the case use its built-in simulation again.

## Important limitations

- Usernames and scores are public. Tell participants not to enter names, email addresses, employee numbers, patient information, or other personal information.
- Uploaded case images and their alt text are publicly accessible. Use only approved AI-generated assets that contain no patient data, personal information, confidential material, or third-party content you lack permission to publish.
- Anonymous users belong to one browser profile. Clearing site data or using another device creates a different anonymous user.
- This is a friendly practice leaderboard. Because GitHub Pages runs the scoring logic in the browser, a determined person can falsify a score. For prizes, formal competency records, or other high-stakes use, validate answers and scores in trusted server-side code such as a Supabase Edge Function.
- Each pressure-injury type has five scored cases, so a participant's type-specific result changes in 20-percentage-point increments. Treat those category scores as descriptive signals rather than precise estimates.
- The clinical prototype warnings remain in place. Its cases and simulated images still require qualified clinical review before educational deployment.

## Updating the site later

Edit the files in GitHub and commit to `main`, or upload replacements with the same names. GitHub Pages will publish the new commit automatically. Existing leaderboard rows and uploaded image metadata remain in Supabase. When upgrading from an earlier package, replace `index.html`, add `admin.html`, replace `README.md`, and rerun the updated `supabase-setup.sql`. Keep your existing configured `config.js` unless your Supabase project changed.
