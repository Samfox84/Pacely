# Set up your own Pacely server

A Pacely server keeps your plans in one place so your phone, Apple Watch, Mac and browser all show the same day.
It runs on a computer **you** own that stays switched on: an old laptop, a Raspberry Pi 4/5, or a home server.

This takes about 15 minutes. You'll copy and paste a few lines; you don't need to know how to code.

**You need**
- A computer running **Ubuntu** or **Debian** (Raspberry Pi OS works too), connected to the internet.
- A way to type commands on it: sit at it and open **Terminal**, or connect from another computer with `ssh`.
- *For use away from home:* a domain name (from about £1–£10 a year) whose DNS is on a free Cloudflare account. Step 3 explains.

---

## 1. Install Pacely

Paste this into the server's terminal:

```bash
sudo apt-get update && sudo apt-get install -y git
git clone https://github.com/Samfox84/Pacely.git ~/pacely
cd ~/pacely && bash install.sh
```

- It asks whether to install the **private AI helper** (about 3 GB download). Say **n** if your server is small
  or you don't want AI; you can add your own Gemini key later instead, or skip AI completely.
- When it finishes it shows a box like this:

```
 Pacely is running
 On your home network:  http://192.168.1.50:8742
 Password saved in:     ~/pacely-password.txt   (show it: cat ~/pacely-password.txt)
```

## 2. Try it at home

On your phone or computer (on the same Wi-Fi), open the **home network** address from the box and log in with the
password (`cat ~/pacely-password.txt` shows it). You can change the password in **Me › Password**.

That's enough to use Pacely at home. To use it anywhere, and to get notifications on your phone, carry on.

## 3. Use it away from home (free Cloudflare Tunnel)

Phones only allow notifications and installing from a secure `https://` address. A **Cloudflare Tunnel** gives you
one for free, without opening ports on your router: your server connects *out* to Cloudflare, and Cloudflare passes
visitors to it.

### 3a. Put your domain on Cloudflare (once)
1. Make a free account at [dash.cloudflare.com](https://dash.cloudflare.com).
2. Click **Add a domain** (or **Add a site**), type your domain and choose the **Free** plan.
3. Cloudflare shows two **nameservers**. Log in where you bought the domain and replace its nameservers with those two.
4. Wait until Cloudflare emails you that the domain is **active** (usually under an hour).

Already use Cloudflare for your domain? Skip this.

### 3b. Run the tunnel script
Choose the address you want, such as `plan.yourdomain.com`, and paste:

```bash
cd ~/pacely && bash setup-tunnel.sh plan.yourdomain.com
```

1. It prints a long link. Open it on any computer, log in to Cloudflare, and click your domain.
   (If you're using the server's own screen, the browser may open by itself.)
2. Come back to the terminal. It creates the tunnel, the web address and a service that starts with the computer.
3. When it says **Done**, open `https://plan.yourdomain.com`.

You don't need to touch the Cloudflare **Zero Trust** or **Tunnels** pages: the script does it all.

**Already have a tunnel on this computer** for other websites? The script finds it and *adds* Pacely, keeping
your other sites. Your old settings are saved as `/etc/cloudflared/config.yml.before-pacely`.

## 4. Install it on your devices

| Device | What to do |
|---|---|
| iPhone (web app) | Open your address in **Safari** › Share › **Add to Home Screen**. Open it from the Home Screen and allow notifications in **Me**. |
| iPhone + Apple Watch (native app) | See [ios/README.md](../ios/README.md). |
| Mac | Install [Pacely for Mac](../mac/README.md) and choose **On my Pacely server**. |
| Windows, Chromebook, Android | Open your address in Chrome or Edge and click **Install** in the address bar. |

Got plans in the browser version or on a Mac already? In that copy, **Save a copy** (Mac: **File › Export
Database**), then in your server copy go to **Me › Load a file** and choose **Merge**.

## Add someone else in your home

Each person gets their own private planner, address and password:

```bash
/opt/pacely/add-profile.sh alex
```

## Updating

```bash
cd ~/pacely && git pull && bash install.sh
```

Your plans and password are kept. A copy of your plans is also kept before any **Replace** import.

## The AI helper (optional)

The AI helper is off until you set it up. Pick one in **Me › AI helper**:

| | Private helper (Ollama) | Google Gemini |
|---|---|---|
| Where it runs | On your server. Nothing leaves it. | Google's servers |
| Cost | Free | Free tier (Google may use what you send to improve its products) |
| Speed | Slow on older computers (a minute or more) | A few seconds |
| Photos to tasks | No | Yes |
| Find it and plan it | Searches DuckDuckGo | Searches Google |

**Private helper:** say **y** when `install.sh` asks, or run `bash install.sh` again later. It downloads a small model
(about 3 GB).

**Gemini:**
1. Go to [aistudio.google.com](https://aistudio.google.com), sign in, and choose **Get API key › Create API key**.
2. In Pacely: **Me › AI helper › Google Gemini**, paste the key, and press **Save**.
3. Leave **Model** on **Automatic**. If Google says a model is busy ("high demand"), Pacely quietly tries another.

Press **Test the AI helper** at any time: it says how long it took, or exactly why it didn't answer.

## Family helper

**Me › Share with family › Invite someone** makes a private invite. Send it to them; they open it on an iPhone with
Pacely installed and the app joins your plan. Each invite works once, on one phone. They can add things to your plan,
send you lists, and see what you choose to share. Anything you mark **Private** never shows. A web page and calendar
feed for them are off unless you switch them on.

## Getting about (optional)

**Me › Getting about**: add your home and work postcodes, your start and finish times, and the transport you're happy
to take. Pacely then works out when to leave for anything with a place, and on days marked **In the office** it checks
your route with TfL before work and before you head home. You only get a notification if the time you need to leave
changes by 10 minutes or more.

Postcodes go to free map services (postcodes.io and OpenStreetMap) and to TfL. TfL works without a key; if you use it
a lot, get a free key at [api-portal.tfl.gov.uk](https://api-portal.tfl.gov.uk) and add `PACELY_TFL_KEY=yourkey` to
`/etc/default/pacely`, then `sudo systemctl restart pacely`.

## Something's wrong?

| What you see | What to do |
|---|---|
| The home address doesn't open | `sudo systemctl status pacely` should say **active (running)**. If not: `sudo journalctl -u pacely -n 30` and look at the last lines. |
| Cloudflare **Error 1033** | The tunnel isn't running on your server: `sudo systemctl restart cloudflared`, wait a minute, then `sudo systemctl status cloudflared`. |
| Cloudflare **Error 502** | The tunnel works but Pacely isn't running: `sudo systemctl restart pacely`. |
| Forgot the password | `/opt/pacely/venv/bin/python /opt/pacely/app.py --reset-password` shows a new one. Then `sudo systemctl restart pacely`. |
| "Port 8742 is already in use" | Something else uses that port. Install on another: `PACELY_PORT=8750 bash install.sh` |
| AI helper says it's not ready | The first download can take a while. `ollama list` shows what's installed. |
| AI helper never answers | Press **Me › AI helper › Test the AI helper**: it says why. Private helper: `sudo systemctl start ollama`. Gemini: check the key. |
| Partner invite says it's been used | Each invite works once. Make a new one in **Me › Share with family**. |

Still stuck? [Open an issue](https://github.com/Samfox84/Pacely/issues) with a screenshot of what you see
(cover your password and web address).

## Where things live

| What | Where |
|---|---|
| Pacely program | `/opt/pacely` |
| Your plans, password hash and keys | `/opt/pacely/data` (back this folder up, or use **Me › Save a copy**) |
| Service | `pacely.service` (`sudo systemctl restart pacely`) |
| Tunnel settings | `/etc/cloudflared/config.yml` |
