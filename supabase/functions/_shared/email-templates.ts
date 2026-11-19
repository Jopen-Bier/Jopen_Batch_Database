// supabase/functions/_shared/email-templates.ts
//
// HTML for the account e-mails sent from database@jopenbier.nl (English
// only). The logo (Storage bucket "Jopen art", red on transparent, 586x650)
// sits on a white header: on red it disappears. Layout from
// supabase-invite-email-template.html: Outlook renders mail with Word, so
// tables, inline styles and bgcolor only.

// Page that turns a token_hash link into a session and asks for a password.
// Links point here, not at Supabase's /auth/v1/verify: mail scanners such as
// Microsoft Defender Safe Links open every link in incoming mail, and a plain
// GET on /verify uses up the single-use token before the person clicks it.
// accept-invite.html only spends the token when its JavaScript runs.
export const APP_URL = "https://jopen-bier.github.io/Jopen_Batch_Database";
export const ACCEPT_URL = `${APP_URL}/accept-invite.html`;

export function acceptLink(tokenHash: string, type: "invite" | "recovery"): string {
  return `${ACCEPT_URL}?token_hash=${encodeURIComponent(tokenHash)}&type=${type}`;
}

export function escapeHtml(value: unknown): string {
  return String(value ?? "")
    .replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;")
    .replace(/"/g, "&quot;").replace(/'/g, "&#39;");
}

const LOGO = "https://nrouqtxkeeoayqudkiud.supabase.co/storage/v1/object/public/Jopen%20art/Jopen%20logo.png";
const P = 'style="margin:0 0 16px 0; font-size:15px; line-height:1.5; color:#444444;"';
const SMALL = 'style="margin:0 0 8px 0; font-size:13px; line-height:1.5; color:#777777;"';

function layout(title: string, bodyHtml: string, footer: string): string {
  return `<!DOCTYPE html>
<html lang="en"><head><meta charset="UTF-8"><meta name="viewport" content="width=device-width, initial-scale=1.0"><title>${escapeHtml(title)}</title></head>
<body style="margin:0; padding:0; background-color:#f4f4f2; font-family:Arial, Helvetica, sans-serif;">
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" bgcolor="#f4f4f2" style="background-color:#f4f4f2; padding:24px 0;"><tr><td align="center">
<table role="presentation" width="480" cellpadding="0" cellspacing="0" bgcolor="#ffffff" style="background-color:#ffffff; border:1px solid #e5e5e0;">
<tr><td bgcolor="#ffffff" style="background-color:#ffffff; padding:24px 32px 16px 32px;" align="left"><img src="${LOGO}" alt="Jopen" width="64" height="71" style="display:block; border:0;"></td></tr>
<tr><td bgcolor="#E0001D" height="4" style="background-color:#E0001D; height:4px; font-size:0; line-height:0;">&nbsp;</td></tr>
<tr><td style="padding:32px;">
<h1 style="margin:0 0 16px 0; font-size:20px; color:#222222;">${escapeHtml(title)}</h1>
${bodyHtml}
</td></tr>
<tr><td bgcolor="#faf9f7" style="background-color:#faf9f7; padding:16px 32px; font-size:11px; color:#999999;">Jopen Batch Database &middot; internal system of Jopen Brouwerij (Haarlem)<br>${footer}</td></tr>
</table></td></tr></table></body></html>`;
}

function button(link: string, label: string): string {
  const href = escapeHtml(link);
  return `<table role="presentation" cellpadding="0" cellspacing="0" style="margin:0 0 20px 0;"><tr>
<td bgcolor="#E0001D" style="background-color:#E0001D; padding:12px 28px;"><a href="${href}" target="_blank" style="font-size:15px; font-weight:bold; color:#ffffff; text-decoration:none;">${escapeHtml(label)}</a></td>
</tr></table>
<p ${SMALL}>Button not working? Copy this link into your browser instead:<br><a href="${href}" style="color:#E0001D; word-break:break-all;">${href}</a></p>
<hr style="border:none; border-top:1px solid #eeeeee; margin:24px 0;">`;
}

export function inviteEmail(link: string, name: string, inviter: string) {
  const subject = "You've been invited to the Jopen Batch Database";
  const n = escapeHtml(name), by = escapeHtml(inviter);
  const html = layout(subject, `
<p ${P}>Hi ${n},</p>
<p ${P}>${by} has invited you to an account on the <strong>Jopen Batch Database</strong> &mdash; the internal system we use within the brewery for recipe management and batch reports.</p>
${button(link, "Create your account")}
<p ${SMALL}><strong>Not phishing:</strong> this email was sent because ${by} (an administrator at Jopen Brouwerij) added your email address to the Batch Database. If you weren't expecting this invitation, or you're unsure about the sender, please contact ${by} before clicking the button.</p>
<p ${SMALL}>We will never ask you to share your password by email.</p>`,
    "This invitation is single-use and expires; if it no longer works, ask an administrator for a new one.");
  return { subject, html };
}

export function passwordResetEmail(link: string, name: string | null) {
  const subject = "Reset your Jopen Batch Database password";
  const html = layout(subject, `
<p ${P}>Hi ${escapeHtml(name || "there")},</p>
<p ${P}>Someone (hopefully you) asked to reset the password of your <strong>Jopen Batch Database</strong> account. Click the button to choose a new password.</p>
${button(link, "Choose a new password")}
<p ${SMALL}>Didn't ask for this? Then you can ignore this email: your password stays the same.</p>
<p ${SMALL}>We will never ask you to share your password by email.</p>`,
    "This link is single-use and expires soon; if it no longer works, use \"Forgot password\" on the login page again.");
  return { subject, html };
}
