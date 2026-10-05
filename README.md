# Multitrack

A personal app with eight self-contained tracker modules behind one home screen. Ships to iPhone
through TestFlight; also builds for the Mac.

| Module | What it does |
| --- | --- |
| Trips | Plan a trip day by day — itinerary, flights, bookings and door codes — with a map, the forecast, and a PDF itinerary to share; undecided ideas wait off the calendar, ranked by how far they are from you or a day's plan; Review Plan flags overlaps, tight walks, busy days and rain on outdoor plans with one-tap fixes, and on Apple Intelligence devices writes a short review and suggests real nearby places, on the device |
| Explore | Keep guides of places to eat, see and do in an area, mark them tried and rated, and see how far away they are |
| Gym | Log workouts as weight × reps, save routines, track per-exercise progress |
| TV | Track shows, episodes and films, with a catch-up backlog and an upcoming-episode schedule |
| Fuel | Log fill-ups per vehicle, track MPG and cost, import a Fuelly CSV export |
| Orders | Track FedEx, UPS and USPS deliveries, with an in-app browser for the ones that can't be read automatically |
| Points | Track credit card, hotel and airline points for everyone in the household, with balance history, expiry warnings, and sharing with a partner |
| Finance | Track net worth month by month — balances, cards, loans, gold and silver, spending and budgets — shared with a partner, live gold and silver prices, and an Export to Numbers on the Mac that fills the old Numbers sheet; every month (and every year) has a report, a web page built on the device that shares as .html or PDF, and on Apple Intelligence devices a written review of what went well, what to watch and what to try next, with one-tap fixes and "Ask about September" |

Each tracker is its own local Swift package so the modules stay independent and can be developed —
or removed — without disturbing the others.

## Tech stack

- **SwiftUI**, deploying to iOS 18 and macOS 15, built with Xcode 26 and Swift 6
- **SwiftData** for persistence, backed by the **CloudKit** private database
- **iOS 26 Liquid Glass** where the OS has it, behind availability checks, with a sensible fallback below
- **XcodeGen** generates the Xcode project from `project.yml`
- **GitHub Actions** for tests and TestFlight releases

**No third-party dependencies.** Everything links against OS-provided frameworks, which is why a
release build is about 1.6 MB.

## Getting set up

The Xcode project is **generated**, so it is not checked in. After cloning, or any time you add or
move source files:

```bash
xcodegen generate
```

Then open `bhavik-ios.xcodeproj`. [XcodeGen](https://github.com/yonaskolb/XcodeGen) comes from
Homebrew:

```bash
brew install xcodegen
```

## Layout

```
App/              Thin app shell — entry point, home screen, settings, CloudKit schema initializer
Packages/
  Core/           Shared types: module chrome, glass effects, CSV parser, keychain, weather, macOS shims
  TripTracker/    Trips, itinerary, flights, bookings, day plan, forecast, PDF itinerary
  ExploreTracker/ Guides, places, category guessing, map with walking distance
  GymTracker/     Workouts, routines, exercise library
  TVTracker/      Shows, episodes, films, schedule, TMDB lookup, library import
  FuelTracker/    Vehicles, fill-ups, MPG, Fuelly import
  ParcelTracker/  Parcels, carriers, tracking-number detection
  PointsTracker/  Household, people, loyalty accounts, balance history, expiry warnings
  FinanceTracker/ Household, accounts, monthly balances, metals, card transactions, budgets, month JSON
scripts/
  finance/        Mac-only Python (uv, Numbers): month JSON <-> the Numbers sheet, "Export Finance to Numbers"; see its README
.github/workflows/
  tests.yml       Runs on every push
  testflight.yml  Ships a build
project.yml       XcodeGen project definition — two targets, iOS and macOS
```

## Credentials

There are no environment variables and no `.env`. The app asks for what it needs at runtime, and
stores it in your **iCloud Keychain** — so credentials survive deleting the app and reach your other
devices, while your tracked data comes back separately from CloudKit.

| Credential | Where you enter it | Keychain account |
| --- | --- | --- |
| TMDB API key | TV → Settings | `tmdb.apiKey` |
| FedEx API key | Orders → Settings | `fedex.apiKey` |
| FedEx API secret | Orders → Settings | `fedex.apiSecret` |

Without a TMDB key the TV module still works — you can add shows by hand — you just lose search,
episode lists and artwork. Without FedEx credentials, orders fall back to manual status.

> This product uses the TMDB API but is not endorsed or certified by TMDB.

CI needs its own credentials, which live in a GitHub **deployment environment named `testflight`**
rather than repository secrets, so only `main` and `v*` tags can read them:

| Secret | What it is |
| --- | --- |
| `ASC_KEY_ID` | App Store Connect API key id |
| `ASC_ISSUER_ID` | App Store Connect issuer id |
| `ASC_PRIVATE_KEY` | base64 of the `.p8` private key |

The API key must have the **Admin** role. App Manager is not enough — cloud-managed distribution
signing fails with `Cloud signing permission error`.

## Data and sync

Data lives in SwiftData backed by the CloudKit private database
(`iCloud.com.bhavikjain.trackers`), so it syncs across devices on the same Apple ID and survives
reinstalling the app. Two constraints this places on the models, both enforced by CloudKit:

- every property needs a default value, and every relationship must be optional
- every relationship needs an explicit inverse

Breaking either one fails at launch when the container loads, not at compile time.

Trips, Explore, Fuel, Points and Finance are the exception: they use hand-built Core Data models
(`TripModel`, `GuideModel`, `FuelModel`, `PointsModel`, `FinanceModel`) on their own `NSPersistentCloudKitContainer`s,
so their data can be shared with another iCloud account through a `CKShare`. In Points the shared
root is the household, so sharing it shares everyone in it — people, accounts and balance history.
Once you accept a partner's share, new people and accounts you add go into that shared household.
Finance works the same way: its household (`SharedFinanceHousehold`) is the share root, and sharing it
shares every owner, account, month, metal item and transaction in it.
The schema ritual below covers these models too.

**Sharing.** Share first finds or makes the share in the app's own sheet — what it's doing, a Cancel
button, and every wait bounded — and only hands a saved share with a link to the system's sharing UI
(`UICloudSharingController` on the iPhone, the app's own sheet on the Mac). Core's `SharePreparer`
does it, deciding each step with `SharePreparationPlan`: if iCloud is mid-sync on that tracker it
waits for it ("Waiting for iCloud to finish syncing…"); it never makes a second share for something
already shared, nor for something it couldn't check; it asks iCloud whether an earlier try left a
copy in a share zone of its own and, if so, says so and waits for **Share Anyway** rather than add
another; if making the share fails or times out it waits for the upload already under way and looks
again. The worst case is iCloud's own error with **Try Again**, never an endless spinner. Each step is
logged: `log show --last 1h --predicate 'subsystem == "com.bhavikjain.trackers" AND category == "Sharing"'`.
On the Mac, `scripts/cloudkit/init-schema.sh --share-probe` times a real share end to end against the
Development environment on throwaway data, and cleans up after itself.

**Trip ideas need every sharer on a current build.** An idea is an itinerary item whose `dayIndex`
is `-1` — no new attribute, so no schema change — but builds from before ideas existed clamp any
negative `dayIndex` to Day 1 whenever they save a trip (any edit to its title, notes or dates), and
CloudKit then syncs that to everyone on the trip. They also show ideas as ordinary stops. Before
anyone adds ideas to a shared trip, make sure every device on it has updated its TestFlight build.

**Notifications about shared changes.** When someone you share a trip, vehicle, guide or household
with changes it, the app posts a local notification ("Saloni added Gelato at Giolitti to Day 3"),
one per shared item per burst of edits; tapping it opens that tracker. Core's `SharedChangeNotifier`
reads each Core Data container's persistent history after every remote change, keeps only what the
CloudKit mirroring delegate imported (this device's own saves carry the `app` transaction author),
keeps only objects that are actually shared, and asks each module's `describeSharedChange` for the
wording. Settings → Notifications has the switch and one per tracker; permission is asked when you
share or accept a share, or from that switch — never at launch. The honest limits:

- That rich notification exists only once *this* device has imported the change: while the app is
  running, when a CloudKit silent push wakes it (the `aps-environment` entitlement is on — see *How
  quickly changes arrive*; delivery is at the system's discretion), or the next time it opens. iOS
  never wakes a force-quit app, and a rebooted phone doesn't count as running until it's opened.
- So iCloud also sends an alert of its own, shown by the system with the app not running at all
  (Core's `SharedChangeServerAlerts`). It's a CloudKit subscription whose text is fixed when it's
  saved, so it can't say who or what: the owner of a share gets "Rome & Amalfi was updated" (one
  record-zone subscription per shared trip, vehicle, guide or household, reworded when it's renamed);
  someone it's shared *with* gets "Something shared with you was updated", because the shared
  database only accepts one subscription for everything in it. Tapping one opens its tracker (the
  participant's only when everything shared with them is in one tracker). When the app posts its own
  notification about the same share, it removes iCloud's; while the app is open iCloud's isn't shown.
- iCloud's alert comes from the account, not the app, so it has two limits. **Your own edits alert
  your other devices**: CloudKit skips only the device that made the change, and has no "not from me"
  option for zone or database subscriptions. If the app is alive on the other device it removes the
  alert once it has imported the change and seen it was yours; after a force-quit it stays. And the
  subscriptions belong to the Apple Account, so **the Settings switch acts for every device**:
  turning it off deletes them everywhere, and any device with it on (and permission granted)
  re-creates them the next time it opens. A share only gets one once someone else is on it.
- The first download after installing (or after this feature first ships) is never announced, nor is
  the download that follows accepting a share. Deletions are never announced — a deleted record can't
  be read to say what it was.
- The name comes from the share's participant list, cached locally. When the record doesn't say who
  last changed it, the notification says "Someone". Edits from your own other devices are skipped.
- A notification about the tracker you're looking at is held back while the app is in front.

**Adding or changing a `@Model` needs one extra step.** CloudKit only creates a record type when a
record of that type first syncs, and it never creates schema in Production — so a new model silently
fails to sync until the schema is deployed. The ritual:

1. On a device or simulator signed in to your iCloud account, run a debug build with
   `-InitializeCloudKitSchema YES`. The app opens a status screen instead of itself, sends every
   model's record type to the **Development** environment, and lists them when it's done. It never
   opens the app's real database, so it's safe on a phone holding real data.
   On the Mac, `scripts/cloudkit/init-schema.sh` does this step in one go — it builds the Mac app,
   signs it with the Mac's own development certificate and profile (no Apple ID in Xcode needed),
   runs it, and prints the record types. Either way the Mac or device must be signed in to iCloud.
2. In the CloudKit Console's **Development** environment, confirm the record types are there
3. Hit **Deploy Schema Changes** to promote them to Production — **before** any TestFlight build that
   uses the new type or field ships. Production refuses records with fields it doesn't know, so
   until then those records don't sync. This step is Console-only: there's no API for it.
4. Remove the launch argument

There are no records to create or clean up: it uses Core Data's `initializeCloudKitSchema()` on a
throwaway store (`App/Sources/CloudKitSchemaInitializer.swift`). Adding a case to an enum stored as
a `String` raw value is *not* a schema change and needs none of this.

Development and Production are separate **data** stores as well as separate schemas, so a debug build
and a TestFlight build never see each other's records.

**How quickly changes arrive.** Mirroring imports at launch, whenever the app comes to the foreground,
and when a CloudKit push says the database changed. The push entitlement (`aps-environment`, and
`com.apple.developer.aps-environment` on the Mac) is what makes a partner's new itinerary item or
fuel-up show up within seconds while the app is open; before it was added they waited for the next
foreground, often minutes. Pushes are best-effort — iOS may delay or coalesce them, especially in the
background — so there is also a manual refresh:

- pull to refresh on the hub (every tracker), Trips' list and day plan, Fuel's log and garage,
  Explore's guides, Points, and Finance's summary and months (just that tracker's store);
- **Settings → Sync**, which shows "Last synced …" next to the iCloud status, with a **Refresh from
  iCloud** button;
- **View → Refresh from iCloud** (`⌘R`) on the Mac.

There is no public "sync now" API, so a refresh asks mirroring to run its foreground import (at most
once a minute — asking more often gets all syncing throttled for hours) and waits up to 15 seconds for
that import to finish. It then says what actually happened: updated, nothing new yet, failed with
CloudKit's error, or iCloud unavailable. "Last synced" is the latest import or export this session
saw finish; it resets on relaunch. Run with `-com.apple.CoreData.CloudKitDebug 1` and filter the
console on the `CloudSync` category to watch it.

## Importing

**TV → Settings → Import Library** reads a watch-history export — `library.csv` for what you track and
`watches.csv` for what you've seen. Pick both at once; they're told apart by their headers. Every
title is looked up on TMDB to get episode lists and artwork, so a full library takes a few minutes and
shows progress. Anything it can't place is listed afterwards and can be searched for by hand, pointed
at the right show, episode or film, or ignored.

**Fuel → Garage → Import from Fuelly** takes a CSV exported from Fuelly. It reads fill-ups and service
records for every vehicle in the file and skips anything already imported, so running it twice is
harmless.

Both accept files dropped into the app's folder from Finder or the Files app.

## New episode alerts in TV

**TV → Settings → New Episode Alerts** sends a notification on the day a new episode of a show you're
watching comes out — "S02E05 “Trojan's Horse” is out today", or "3 new episodes of The Bear are out
today" when several drop at once — at a time you pick (9:00 by default). It's off until you turn it
on, there or from a card on Up Next, and that's when the app asks to send notifications. The bell on
a show's screen mutes that show; Settings → Shows lists them all. The settings sync across your
devices, but each device schedules its own notifications and needs its own permission. Tapping one
opens TV on Up Next. Only the next three weeks are scheduled, at most 40 at a time: iOS keeps an app's
64 soonest and drops the rest, and Finance's monthly reminder takes 12.

The alerts can only be as current as TV's episode lists, so those are now refreshed from TMDB: when TV
opens, when you pull down on Up Next, and on the iPhone in the background. Each show is looked up at
most every 12 hours — those being watched or not started, and finished ones in case a new season
appears (a finished show that gets one goes back to Watching). A refresh adds newly announced
episodes and takes new titles and moved air dates; it never removes an episode or changes what
you've watched. Without a TMDB key nothing is refreshed and the alerts come from what's already
there. The background refresh is iOS's background app refresh, which iOS runs when it sees fit — not
on a timetable, never in Low Power Mode or with Background App Refresh off, and not after the app is
force-quit. The Mac has none; it catches up whenever it's opened.

## Weather

Trips and Explore show a forecast through **WeatherKit** (`Packages/Core/Sources/Core/Weather.swift`).
It needs two things, both in place: the WeatherKit capability enabled for `com.bhavikjain.trackers` in
the developer portal (on both the Capabilities and App Services tabs), and the
`com.apple.developer.weatherkit` entitlement in both entitlements files. If either goes missing, every
request throws and both modules quietly show no weather — no card, no spinner.

A simulator build that isn't signed with the team may get no weather; launch a debug build with
`-WeatherStub YES` to swap in made-up but deterministic weather for the whole app.

## Apple Intelligence in Trips

On iOS 26 / macOS 26 with Apple Intelligence, Trips' Review Plan adds a one-line written review, and
Ideas, Nearby and the Mac's Ideas inspector can suggest places from Apple Maps. The on-device model
picks them and says why. Swift works out every problem, fix and candidate place; the model only
words and ranks them, and nothing is sent off the device except the Apple Maps search. **Settings →
Apple Intelligence → Trips** turns it off everywhere, and the setting syncs across your devices. Off,
or on a device without Apple Intelligence, Review Plan is the plain plan check. The switch is hidden
where the model can never run.

## Finance reports and Apple Intelligence in Finance

Each Finance month has a **report**: a self-contained web page — net worth and its change, key
figures, where the money sits, what moved, the last 12 months, accounts, gold and silver, spending
and budgets, cards, and what's worth fixing — built on the device from the household's own figures
and shown in an in-app browser. It opens from the Summary's Report button (⇧⌘R on the Mac), a
month's **View Report** under Months, **Year in Review** for a whole year, and the screen shown after
finishing a month. It shares as an .html file or a PDF, prints, and can be shown for everyone or one
person. On the Mac it opens in a window of its own with a contents sidebar and the review in an
inspector. A month that isn't finished yet says so, and its gold and silver are labelled as live
prices. Reports are never saved to iCloud: a shared report is a file and won't update.

On iOS 26 / macOS 26 with Apple Intelligence, the Summary's "September in brief" card and the
review sheet add a **written review**: a headline, what went well, what to watch and what to try
next month, each with a one-tap fix (adjust a budget, show the charges, update balances, open gold
and silver), plus **Ask about September** for questions answered only from the report's figures.
Swift works out every figure and finding; the model only ranks and words them, never adds a number
and never gives investment advice. Off, or without Apple Intelligence, the same findings appear in
Swift's own words as "September check". The review is cached on the device only.

The review says when it was written ("Written today at 9:14"), and is written again on its own
whenever a figure it was written from changes — a balance, a charge, a budget, in that month or one
it's compared with — but not when only the live gold and silver prices move: those notes fall back
to Swift's words until it's written again. **Write Review Again** is in the report's ••• menu (More
in the Mac's report window), the "in brief" card's ••• menu, a month's (or year's) context menu under
Months, and the Report menu on a month's own screen — and as **Write Again** in the review sheet and
the Mac's review inspector; the Months and month-screen ones forget the month's review for every
person and open its report to write it fresh.

**Settings → Apple Intelligence → Finance** turns the model off (synced across your devices), and
**Settings → Finance reports** sets whether finishing a month writes its review, whether this device
is told "September's report is ready" when a month is finished on another one, whether shared
reports carry table views, and whose figures a report opens on.

## Debug launch arguments

All debug-only, and inert unless passed (Product → Scheme → Edit Scheme → Run → Arguments):

| Argument | What it does |
| --- | --- |
| `-InitializeCloudKitSchema YES` | The schema ritual above — opens a status screen, not the app |
| `-AlertSubscriptionProbe YES` | With `-InMemoryStores YES` on an iCloud-signed build: saves the iCloud alert subscriptions to Development, prints what CloudKit says to each, deletes them, and quits |
| `-InMemoryStores YES` | The whole app on empty in-memory stores with no iCloud — for looking at an unsigned Mac build; add a seeder to fill it |
| `-TVSeedShows YES` | Adds sample shows, looked up on TMDB (needs a key; does nothing if any show exists) |
| `-TVEpisodeAlertProbe YES` | With `-InMemoryStores YES` (add `-TVSeedShows YES` to fill it): one refresh from TMDB that ignores the 12-hour wait (none without a key), then prints TV's new-episode alert plan and what's pending with the system; add `-TVEpisodeAlertProbeQuit YES` to quit after |
| `-FuelSeedCSV YES` | Imports a sample Fuelly export |
| `-ParcelSeed YES` | Adds sample orders |
| `-TripSeed YES` | Adds four trips, one under way today with six ideas for Nearby (does nothing if any trip exists) |
| `-ExploreSeed YES` | Adds three guides with real places (does nothing if any guide exists) |
| `-PointsSeed YES` | Adds a sample household with people and points accounts (does nothing if any account exists) |
| `-FinanceSeed YES` | Adds a sample household with accounts, cards, metals, budgets and twelve months — eleven finished with spending, the current one open — set up to trip most of the report's findings (does nothing if any household has data) |
| `-FinanceAdvisorStub YES` | A made-up month reviewer in place of Apple Intelligence, for Finance's review and Ask on a simulator |
| `-FinanceAdvisorProbe YES` | Seeds an in-memory household and prints Finance's month check, the brief the model sees, a streamed review from the real on-device model, Ask answers and the year in review, and writes both HTML reports to Caches; add `-FinanceAdvisorProbeQuit YES` to quit after |
| `-FinanceOpenReport YES` | Once Finance is opened (after the seed), presents the report for the month the Summary headlines |
| `-FinanceOpenReview YES` | Likewise, the review sheet (the report wins if both are given) |
| `-WeatherStub YES` | Made-up weather in place of WeatherKit |
| `-TripAdvisorStub YES` | A made-up plan reviewer and made-up places in place of Apple Intelligence and Apple Maps, for Trips on a simulator |
| `-TripAdvisorProbe YES` | Runs Trips' plan check, the real on-device model and an Apple Maps search on a made-up trip in memory only, and prints it all; add `-TripAdvisorProbeQuit YES` to quit after |
| `-CloudSyncRefreshAfter <seconds>` | Runs a Refresh from iCloud that long after launch and prints how it ended |

The module seeders run when their module is first opened, not at launch.

## Tests

Each module carries its own suite. Run one the way CI does:

```bash
cd Packages/FuelTracker && xcodebuild test -scheme FuelTracker -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Swap in `Core`, `GymTracker`, `TVTracker`, `ParcelTracker`, `TripTracker`, `ExploreTracker`, `PointsTracker` or `FinanceTracker` for the others.

The TV suite also carries tests that hit the real TMDB API. They are skipped by default and report
*why* they skipped, so a missing key can never read as a pass. To run them, put a key in a file and
point the test runner at it from Xcode's scheme editor (Product → Scheme → Edit Scheme → Test →
Arguments), setting `TMDB_KEY_FILE` to its path. `xcodebuild` does not forward environment variables
into the simulator, so exporting the variable in a shell will not work.

## Releasing

`Tests` runs on every push to `main`: the nine package suites, an iOS app build, and an unsigned macOS
build.

`TestFlight` ships. It is deliberately **not** triggered by every push — otherwise each
work-in-progress commit becomes a build your phone offers to install. Trigger it by hand:

```bash
gh workflow run TestFlight --ref main
```

or by pushing a version tag:

```bash
git tag v1.0.1 && git push --tags
```

It archives, signs, uploads and cleans up in a couple of minutes, with no Mac involved. Build numbers
come from the workflow's run number plus an offset, so they only ever go up.

Signing is **cloud-managed**: Apple holds the distribution private key, so there is no `.p12` to
export and `security find-identity` shows only an Apple Development identity locally. CI reaches the
distribution certificate through the App Store Connect API key.

## macOS

`bhavik-macOS` builds and runs, sharing every source file with the iPhone app and the same CloudKit
container — so the two see the same data. The hub is a `NavigationSplitView`: the sidebar opens
on an Overview of every tracker, then lists the trackers, with the open one's sections (or Trips'
trips) nested under it — the Mac has no tab bars. iCloud status and Refresh (`⌘R`) sit at the foot
of the sidebar, Settings is its own window (`⌘,`), and `⌘0`–`⌘9` (the Trackers menu) jump to the
Overview or a tracker. Modules learn they are in the sidebar from Core's `moduleLayout` environment
value, so no feature package contains a platform check.

Platform differences inside a module are handled in `Packages/Core/Sources/Core/MacCompat.swift`,
which provides `#if os(macOS)` no-op shims so the feature packages compile unchanged. Files relying on
those shims must `import Core`.

### Installing it

The Mac app is the macOS platform of the same App Store Connect app as the iPhone one (Universal
Purchase: one bundle id), so it installs through **TestFlight**, like the phone: every TestFlight run
uploads both (`testflight.yml`'s `mac` job). Install the TestFlight app from the Mac App Store, sign
in, and install Multitrack. It's signed for **Production** CloudKit, the same real data as your
phone. A debug build run from Xcode is a separate app, "Multitrack Dev" (`com.bhavikjain.trackers.dev`),
with its own local data, syncing only with iCloud's Development environment; see CLAUDE.md for why.

No certificate is stored for it. The job archives unsigned, signs the app ad hoc with
`App-macOS.entitlements` resolved by hand so the archive carries them, and the App Store export
re-signs it through the App Store Connect key (cloud-managed). A capability added to
`App-macOS.entitlements` only needs turning on for the App ID in
[Certificates, Identifiers & Profiles](https://developer.apple.com/account/resources/identifiers/list)
→ Identifiers → `com.bhavikjain.trackers` (a signed debug build with automatic signing usually does
this); the export fetches a current App Store profile every time.

A notarized `.dmg` outside the App Store (Developer ID) was the route until TestFlight took over. It
needed an exported Developer ID certificate as a secret, since Apple never holds that key for you, plus
a notary step and a profile script. It was retired; `git log -- .github/workflows/mac-release.yml` has
it if it's ever needed again.
