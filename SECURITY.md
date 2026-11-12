# Security

Pacely holds people's daily plans, so keeping it safe matters. Thank you for helping.

## Found a security problem?

**Please don't post it publicly.** Use GitHub's private report instead: on the
[Security tab](https://github.com/Samfox84/Pacely/security), press **Report a vulnerability**. Only the
maintainer sees it. Say what you found and how to repeat it; we'll reply as soon as we can and credit you in the
changelog if you'd like.

## How Pacely keeps things safe

- **One password per server**, stored only as a salted hash (PBKDF2). Logins are slowed down after wrong guesses.
- **Apps get their own key** after you log in once; your password is never saved on the phone or Mac.
- **The widget link** (read-only key) can only read upcoming plans, not change them. Treat it like a password.
- **Nothing secret is in this project's files.** Your data, password hash, keys and push-notification keys live in
  `/opt/pacely/data` on your server (or on your own device), and are ignored by git.
- **Backups never include your Gemini key.**
- **Use HTTPS** when Pacely is reachable from the internet (the Cloudflare Tunnel guide does this for you).

## Keeping your server up to date

```bash
cd ~/pacely && git pull && bash install.sh
```
