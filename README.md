# Semantic

A natural-language Spotlight replacement for macOS. Press **⌘Y** (configurable), describe what you want.

It runs Google's [EmbeddingGemma 2](https://huggingface.co/google/embeddinggemma-2) locally through
llama.cpp. Files, images, audio, video, apps and commands all live in one 512-d embedding space,
so "screenshot with bar receipt" matches on the pixels and the OCR text of a screenshot, not its filename.

## Build

    ./build.sh

Builds llama.cpp (static, Metal), downloads the models (176 MB text + 555 MB vision/audio encoders)
to `~/Library/Application Support/Semantic/models`, installs `~/Applications/Semantic.app` and launches it.
Needs Xcode command line tools and `cmake` (or `uv`, which fetches cmake on the fly).

| Option | Effect |
| --- | --- |
| `--no-run` | build and install, don't launch |
| `--build-only` | build into `$BUILD` only |
| `--test` | build and run the regression checks |
| `BUILD=dir` | build output directory (default `./build`), so several builds can run side by side |
| `SIGN_IDENTITY=…` | code-signing identity; default is the first valid "Apple Development" identity, else ad-hoc |

A stable signing identity keeps privacy permissions (Accessibility, Screen Recording, Full Disk Access)
across rebuilds; an ad-hoc signature changes every build and macOS drops them.

On first launch Semantic shows its **Permissions** window once, adds a menu bar item, and registers itself
as a login item (once; turning it off in System Settings or Semantic Settings sticks).

## Keys

| Key | Action |
| --- | --- |
| ⌘Y | show / hide; with nothing typed it lists what you are likely to want now |
| ⌘Y ↩ | open the top suggestion (usually the app you were about to type) |
| ↑ ↓ | select a result and update its inline preview |
| ↩ | open (at the matching page or time, when the match was inside the file) |
| ⌘↩ | reveal in Finder |
| ⇥ | put the selected file into the bar, to act on it |
| ⇧⌘C | copy the selected file to paste into another app |
| click / double-click | select and preview / open |
| ⌘V | attach files copied in Finder, or an image on the clipboard |
| drag | drag a result or its preview to another app; drop files onto the field to attach them |
| ⌫ | on an empty field, remove the attached file |
| ⌘P | Quick Look |
| ⌘Z | on an empty field, undo the last rename, move or trash from the past two minutes |
| esc | hide |

## Acting on a file

Attach a file (⇥ on a result, ⌘V, or open the bar over Finder with something selected) and say what
to do with it. With nothing typed you get the actions that fit its type.

| Say | Result |
| --- | --- |
| `turn into jpg`, `as heic`, `make it a pdf` | image conversion (JPEG, PNG, HEIC, TIFF, GIF, BMP, PDF) |
| `turn into pngs` on a PDF | every page rendered at 2x into a folder beside it |
| `resize to 800 wide`, `1200x630`, `half the size` | resized copy |
| `rotate left`, `flip`, `black and white` | transformed copy |
| `copy text` | OCR (images, scanned PDFs) to the clipboard |
| `convert to pdf` / `as plain text` on a Word, RTF, Markdown or text file | laid-out PDF / text |
| `convert to wav`, `m4a`, `flac` on audio | audio conversion |
| `extract audio`, `convert to mp4` on a video | export |
| `zip it`, `combine into a pdf`, `merge` (several files) | archive / one PDF |
| `rename to …`, `move to downloads`, `copy to …`, `open with preview`, `trash` | file management |
| `find similar` | query by example: nearest images or audio in the index |
| `email this to dan` | a draft with the file attached (never sent for you) |

Conversions and image transforms preserve originals; results get a new name next to them and are revealed in Finder.
Explicit rename, move and trash commands change the originals; their confirmation has an **Undo** button
(also ⌘Z in the bar for two minutes). Undo moves items back, out of the Trash too, and never overwrites a file
that has since taken the old name: it reports the conflict and can be retried once it is cleared. Rename accepts one file at a time.
ZIP keeps nested folders and disambiguates repeated attachment names. Resize accepts 1–16,384 pixels
per side and at most 40 million output pixels. Explicit Copy text checks every PDF page.
Batch operations check every attachment before starting and report any completed outputs if a later runtime failure occurs.
Phrasings the rules do not catch go to the local command model.

## Saying what you mean

A sentence can name the thing it is about; the rest of the sentence is then handled as if that file
were attached. The line under the bar always shows what was picked.

| You type | What happens |
| --- | --- |
| `what does most recent screenshot say` | newest screenshot (read from disk, so one taken seconds ago counts) → Ask |
| `convert my latest screenshot to jpg`, `rename the screenshot i just took to receipt` | the file command runs on it |
| `summarize my last download`, `move last 2 downloads to documents` | newest files in Downloads |
| `latest screenshots`, `newest pdf in downloads`, `open latest screenshot` | shows them, with the actions that fit |
| `turn the ifp syllabus into a pdf`, `summarize my resume` | the file that description matches; runners-up are listed below, ⇥ on one to use it instead |
| `explain what's on my screen`, `what is this error` | takes a screenshot when you press Return and asks about it (needs Screen Recording) |
| `fix the grammar of my clipboard`, `translate my clipboard to french` | clipboard text goes with the question |
| `what's due in my algos homework` | Ask with the relevant file candidates listed in the action |

## Asking ChatGPT, Claude or Gemini

`"assistant"` in the config (or Settings) picks where Ask goes: `"chatgpt"` (default; the app when installed),
`"web"` (chatgpt.com), `"claude"` (the Claude app when installed, else claude.ai) or `"gemini"` (gemini.google.com).
Starting a request with `ask claude`, `ask gemini` or `ask chatgpt` overrides it for that request. Rows say
where they go ("Ask Claude: …").

Only ChatGPT has the automated handoff described below. For Claude and Gemini, Return opens the app or site,
puts the files (or, with no files, the question) on the clipboard, and opens the local draft window with
**Open Claude**/**Open Gemini**, **Copy files** and **Copy question**. Nothing is submitted.

The visible **Ask ChatGPT** action lists the files it will attach. When no files are attached to the
bar, it uses the strongest file candidates from the current search, at most five. Files you explicitly
attach are kept separately from that search-result limit. Search itself stays local; files are handed
to ChatGPT only when you invoke the action.

Semantic prefers the installed ChatGPT app. With Accessibility access it opens a new draft, inserts the
question, pastes actual files and checks for their attachment cards. It leaves sending to you.
On macOS 27 this permission is named **Device Control and Data Access**, under **Privacy & Security**.
**Use extracted text instead** is an explicit excerpt alternative (up to 4,000 characters per file,
12,000 total) that omits diagrams and formatting.
`"assistant": "web"` uses the website; Command-Return on Ask switches destinations.

If automation is unavailable or cannot be verified, a local **ChatGPT draft** window retains your
question and full attachment list in an independent window until you close it. Unavailable attachments
are listed with removal and Retry controls; permission failures include a Settings shortcut. It provides **Copy files**, **Copy question**, and **Open ChatGPT** buttons (Command-2,
Command-1 and Command-O). This also handles browser handoff. It does not silently claim an upload
succeeded, replace an existing draft, or submit the message.

The attachment chip has a remove button. Removing attachments keeps the typed request. Backspace
also removes attachments when the field is empty. Files can be added through Tab, **Add to bar**,
Finder copy/paste, or drag and drop.

## Searching

- **Five file suggestions maximum**: exact and normalized filename/path matches, small typos,
  indexed text/OCR, and local semantic similarity are combined. Weak results are not added just
  to fill five slots. Other sources and actions are separate.
- **Inline preview**: the selected file appears beside the results below the search field, including
  the matching PDF page, image/document thumbnail, or plain text. Use Open, Add to bar, Reveal or
  Copy file; the preview and file rows can be dragged out. No separate Quick Look step is required.
- **Explicit searches**: `file: report`, `folder: notes`, `ext:pdf,docx aspirin`,
  `in:~/Desktop report`, `type:image`, `*.pdf`, `regex:^chapter [12]`, `grep:invoice number`.
  Filters compose; `grep:` matches a tokenized phrase in indexed content.
- **Fast first results**: filename, typo and indexed-content matches arrive on a separate queue while
  the local model loads or refines results. A changing result cannot silently change the selected action.
- **Names first**: file metadata is published before expensive content extraction or model startup,
  including source filenames in repositories. Content and semantic indexing then fill in gradually.
  The index covers configured roots, not every file on the disk; hidden, cache, dependency and build
  folders remain excluded. File watching is batched, so newly created files can take roughly a minute
  to appear. PDF keyword extraction currently covers up to 80 pages per file.

- **Filters**: `pdfs from last week`, `screenshots from yesterday`, `images in downloads larger than 1 mb`,
  `videos`, `notes from september`. What was understood is shown under the bar.
- **Inside files**: PDFs are indexed per page, audio per 30 s, video per frame; a hit says `Page 12` or
  `At 3:20` and opens there (PDF pages open in the browser, since Preview cannot be told a page).
- **Other sources**: browser history and bookmarks (every profile of Chrome, Brave, Edge, Arc, Vivaldi, Opera
  and Dia; Firefox, Zen, Orion; Safari with Full Disk Access), calendar events, contacts, Apple Notes (read only
  while Notes is open), clipboard history (last 200 text clips, dropped after `clipboardDays`; entries marked
  secret by password managers, and anything copied while a password manager or Keychain Access is in front,
  are skipped; images are not kept).
- **Find Similar**: image/video and audio matches must pass a similarity threshold before the five-file
  cap. The thresholds were checked with synthetic drawings and speech, not a broad real-world benchmark.
- **More commands**: `switch to the figma window` (open windows; titles need Screen Recording, raising a
  particular window needs Accessibility, otherwise the app is activated), `quit spotify` / `force quit chrome`
  (running apps; ⌘↩ force-quits, after a confirmation), `party emoji` / `thumbs up emoji` (a built-in table
  of about 500; Return copies), `run shortcut morning routine` (Shortcuts, via `shortcuts run`), about 35 System
  Settings panes (`trackpad settings`, `do not disturb`, `hot corners`), `clear clipboard history`,
  `settings` and `permissions` (Semantic's own windows).
- **Apps first**: a word of an app's name (`chrome`, `spot`, `s`) ranks the app above files with similar names.
- **Learning**: what you pick for a query leads that query next time, and its first letters too (one letter of
  `spot` predicts Spotify). A choice repeated for the same words makes them mean that thing, even without a
  name match. Learning follows a file that moved. It reorders results but never hides relevant runners-up.
- **Habits**: picks and app switches (apps kept in front for 3 s or more) build a local model of what you open,
  at what hour, and after which app. It drives the empty-bar suggestions and a bounded boost for typed searches.
  Everything decays with a three-week half-life, so a changed routine overtakes an old one. Stored in the `habits`
  table of the index; `Semantic --suggest` prints what the empty bar would offer now.
- **Duplicates**: same-folder download-copy names of the same size collapse into one row (`+3 copies`).
  Numbered chapters and files in different folders remain distinct.

## Commands with details

`remind me to call mum at 5`, `lunch with sam friday 1pm at nobu`, `email the syllabus to dan and say
sorry for the delay`. A rule-based reading appears instantly; the command model (LFM2.5 1.2B, 730 MB,
loaded only while needed) refines it a moment later. Fields from the model are used only when their
words occur in what you typed. Reminders and events are created through EventKit; email opens a draft.

## Calculator

Anything that can be computed is answered in the first row; Return copies it (`ans` recalls it).

| Type | Examples |
| --- | --- |
| Arithmetic | `12*(3+4)`, `2^10`, `3(4+5)`, `2pi`, `5!`, `5k + 2.5k`, `8 x 7`, `12*(3+` (answers while you type) |
| Functions | `sqrt 16`, `sin(30 deg)`, `log(1000)`, `ln(e)`, `max(3, 9, 4)`, `ncr(52,5)`, `round(3.14159, 2)` |
| Words | `12 times 12`, `half of 90`, `3 squared plus 4 squared`, `2 million / 4` |
| Percentages | `15% of 80`, `80 + 15%`, `20% off 150`, `18% tip on 64.50`, `45 is what percent of 180`, `change from 80 to 100` |
| Units | `5 km in miles`, `72 f to c`, `5 ft 3 in in cm`, `how many cups in 2 liters`, `500 mb to gb`, `60 mph to km/h` |
| Currency | `100 usd to sgd`, `$50 in euros` (daily rates from open.er-api.com, cached; the app's only network request) |
| Bases | `255 in hex`, `0xff to decimal`, `10 to binary`, `0xff + 1` |
| Dates | `days until christmas`, `days since jan 1 2026`, `in 3 weeks`, `today + 45 days`, `what day is july 4 2027` |
| World time | `time in tokyo`, `london time` |

`Semantic --calc "expr" ...` prints calculator answers from the command line.

## How it works

- **Bar process** (`Semantic`): AppKit panel, no dock icon. Loads only the 176 MB text tower, and only
  while you are using it; it is freed after 5 minutes hidden. Queries combine filename/path matching and SQLite full-text search with a
  local embedding and a scan of an int8 matrix.
- **Indexer** (`Semantic --index`): a short-lived child process. It is the only thing that ever loads the
  vision and audio encoders, and it exits when done. It walks everything at launch and hourly; file changes
  start an incremental run over just the changed folders (`--index --paths`, debounced at least 5 s, at most
  once a minute). If nothing changed it exits without loading a model. Failing files are retried with backoff
  and given up after 3 attempts. With `reduceIndexingOnBattery`, image/audio/video work waits while on battery,
  in Low Power Mode or when the Mac is hot. The menu bar item pauses, resumes and rebuilds it.
- **Extraction**: PDF, Word, PowerPoint (every slide and its notes), Keynote/Pages/Numbers (through their
  QuickLook preview), EPUB, RTF and plain text; long documents are split into passages. The first 10 minutes
  of audio and video are transcribed on-device, only when Speech Recognition is allowed.
- **Signals per file**: name + extracted text (PDF, Office, plain text), the image itself, OCR of the
  image, 30 s of audio, one video frame. Scores are z-normalised per signal, then combined with a
  lexical filename match.
- **Intents** (`Actions.swift`): each action has a few example phrasings; the query is routed to the
  nearest one. Actions check what is installed before choosing a handler (Spotify vs Apple Music vs
  browser, Dictionary vs web, and so on).

## Menu bar, Settings and Permissions

The menu bar item has Show Semantic (with the current shortcut), the indexing status (read only while the
menu is open), Pause/Resume Indexing, Rebuild Index (`--index --full`), Settings…, Permissions…, Open Config
File and Quit. `"menuBar": false` hides it; the bar's `settings` command still opens everything.

**Settings** writes `config.json` directly, keeping keys it does not show: the shortcut (click and type a new
one; a shortcut another app holds is refused with a message and the old one kept), menu bar item, open at
login, indexed folders, excluded folders and patterns, sources, clipboard history (on/off, how long, clear),
the Ask destination and how long the text model stays loaded.

**Permissions** lists Full Disk Access, Accessibility, Screen Recording, Calendar, Reminders, Contacts,
Automation (Finder) and Speech Recognition, whether each is allowed, what it enables, and a button that asks
for it or opens the right System Settings pane. Nothing requires any of them.

## Config

Optional `~/.config/semantic/config.json` (all keys optional):

    {
      "roots": ["~/Documents", "~/Screenshots"],
      "excludes": ["~/Documents/Private", "*.secret"],
      "maps": "browser",
      "searchURL": "https://duckduckgo.com/?q=%s",
      "unloadAfter": 300,
      "hotkey": "cmd+y",
      "menuBar": true,
      "clipboard": true,
      "clipboardDays": 30,
      "clipboardIgnoreApps": ["com.1password.1password", "com.bitwarden.desktop"],
      "finderSelection": true,
      "sources": ["web", "calendar", "contacts", "notes"],
      "assistant": "chatgpt",
      "reduceIndexingOnBattery": true
    }

| Key | Meaning |
| --- | --- |
| `roots` | folders to index; default: visible folders in your home directory, excluding caches, dependencies and build outputs |
| `excludes` | folders (`~` allowed) or glob patterns never indexed. A `.semanticignore` file (one glob per line) excludes within its folder |
| `hotkey` | modifiers `cmd`, `shift`, `alt`/`opt`, `ctrl` plus a key: `alt+space`, `cmd+shift+space`, `ctrl+opt+k`, `f13` (F-keys need no modifier). Default `cmd+y` |
| `menuBar` | `false` hides the menu bar item |
| `clipboardDays` | clipboard rows older than this are deleted (default 30; `0` keeps them until the 200-row cap) |
| `clipboardIgnoreApps` | bundle ids whose copies are never kept; default 1Password, Bitwarden, Keychain Access and Passwords |
| `assistant` | `chatgpt` (default; `app` is the older spelling), `web`, `claude`, `gemini` |
| `reduceIndexingOnBattery` | defer image/audio/video work on battery, Low Power Mode or when hot (default true) |
| `maps` | `browser` or `apple` |
| `unloadAfter` | seconds hidden before the text model is freed (default 300) |

Repository filenames are indexed; expensive content extraction remains selective.

## Privacy

Everything runs on this Mac: the index, the models, the habit data and clipboard history live in
`~/Library/Application Support/Semantic`. The only network request Semantic makes itself is the daily
currency-rate fetch for the calculator. Questions and files go to ChatGPT, Claude or Gemini only when you
choose an Ask row, and nothing is ever sent for you: you review and send the draft. Web, maps and YouTube rows
open your browser only when chosen.

## Debugging

    Semantic --query-latency asprin                    # first asynchronous callback timing
    Semantic --query "ifp syllabus" "coffee near me"   # print ranked rows and intent scores
    Semantic --query "/path/a.png|turn into jpg"       # what a request about an attached file resolves to
    Semantic --do "/path/a.png|turn into jpg"          # run it
    Semantic --llm "remind me to call mum at 5"        # raw command-model output
    Semantic --similar /path/photo.jpg                 # query by example
    Semantic --index --full                            # rebuild the index from scratch
    Semantic --eval [--verbose]                        # replay past picks: how highly the current ranking puts them
    Semantic --suggest                                 # what the empty bar would offer now
    Semantic --calc "15% of 80"                        # calculator only

## Development checks

`./build.sh --test` runs isolated search, indexing and interaction regression checks using temporary
fixtures. `./build.sh --build-only` builds without installing; `--no-run` installs without launching.
`build/Semantic.app/Contents/MacOS/Semantic --lexical --query asprin` checks name/content search without
loading the model; omit `--lexical` for the full local model. These command-line checks do not prove
cross-app dragging, Accessibility permissions or successful server-side attachment upload.

For optional synthetic text/image relevance checks with the installed model, run the built test binary:

    SEMANTIC_MODELS="$HOME/Library/Application Support/Semantic/models" build/SearchTests.app/Contents/MacOS/Semantic

These use generic filenames, unrelated queries, and an isolated temporary index. They verify a small
fixture set; they do not establish general search accuracy.

The hybrid search and preview design draws on [FSearch](https://github.com/noahdunnagan/fsearch) and
[DigUp](https://github.com/ARahim3/DigUp). This implementation uses Semantic's native SQLite and Swift
index; it does not embed FSearch's Rust daemon or claim its whole-disk benchmark results.
