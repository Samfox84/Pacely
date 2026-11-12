# Privacy in detail

Pacely has no company behind it, no accounts, no analytics and no adverts. Your plans live only where you put them.

## Where your plans are kept

| You use | Plans are kept |
|---|---|
| Browser version | In that browser, on that device |
| iPhone, "just this phone" | In the app's own storage on that iPhone |
| Mac app, "on this Mac" | A file on the Mac, with a daily backup (the last 14 are kept) |
| Your own server | One file on your server (`/opt/pacely/data`) |

## What can leave your device, and only if you switch it on

| Feature | What is sent | To |
|---|---|---|
| AI helper with Gemini | The text (or photo) you ask about | Google (Gemini API). On Google's free tier, Google may use it to improve its products. |
| AI helper, private | Nothing leaves your server | Ollama, running on your own server |
| Find it and plan it, private helper | Your search words | DuckDuckGo |
| Find it and plan it, Gemini | Your search words | Google (Gemini with Google Search) |
| When to leave, journeys | Postcodes or place names | postcodes.io, OpenStreetMap (Nominatim and OSRM), and TfL for public transport |
| Calendars | Nothing is sent: Pacely only downloads the calendar links you add | The calendar provider you chose |
| Phone notifications from your server | The reminder text | Apple or Google's push services, which deliver it |
| Family helper | What you choose to share | Only the person you invited, through your own server |

## Good to know

- Backup files never contain your Gemini key.
- Things marked **Private** never show to anyone you share with.
- A family invite works once, on one phone. Making a new invite signs the old phone out.
- The widget link (iPhone widgets) is a read-only key. Treat it like a password.
- If you fork this project, don't commit your own widget link (`ios/Config/widget-link.txt`).
