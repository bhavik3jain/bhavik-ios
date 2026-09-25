# Multitrack

A personal app with eight self-contained tracker modules behind one home screen. Ships to iPhone
through TestFlight; also builds for the Mac.

| Module | What it does |
| --- | --- |
| Trips | Plan a trip day by day — itinerary, flights, bookings and door codes — with a map, the forecast, and a PDF itinerary to share |
| Explore | Keep guides of places to eat, see and do in an area, mark them tried and rated, and see how far away they are |
| Gym | Log workouts as weight × reps, save routines, track per-exercise progress |
| TV | Track shows, episodes and films, with a catch-up backlog and an upcoming-episode schedule |
| Fuel | Log fill-ups per vehicle, track MPG and cost, import a Fuelly CSV export |
| Orders | Track FedEx, UPS and USPS deliveries, with an in-app browser for the ones that can't be read automatically |
| Points | Track credit card, hotel and airline points for everyone in the household, with balance history, expiry warnings, and sharing with a partner |
| Finance | Track net worth month by month — balances, cards, loans, gold and silver, spending and budgets — shared with a partner, with a JSON export that scripts turn back into the old Numbers sheet |

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
  finance/        Mac-only Python (uv + numbers-parser): month JSON <-> the Numbers sheet; see its README
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

**Adding or changing a `@Model` needs one extra step.** CloudKit only creates a record type when a
record of that type first syncs, and it never creates schema in Production — so a new model silently
fails to sync until the schema is deployed. The ritual:

1. On a device or simulator signed in to your iCloud account, run a debug build with
   `-InitializeCloudKitSchema YES`. The app opens a status screen instead of itself, sends every
   model's record type to the **Development** environment, and lists them when it's done. It never
   opens the app's real database, so it's safe on a phone holding real data.
2. In the CloudKit Console's **Development** environment, confirm the record types are there
3. Hit **Deploy Schema Changes** to promote them to Production
4. Remove the launch argument

There are no records to create or clean up: it uses Core Data's `initializeCloudKitSchema()` on a
throwaway store (`App/Sources/CloudKitSchemaInitializer.swift`). Adding a case to an enum stored as
a `String` raw value is *not* a schema change and needs none of this.

Development and Production are separate **data** stores as well as separate schemas, so a debug build
and a TestFlight build never see each other's records.

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

## Weather

Trips and Explore show a forecast through **WeatherKit** (`Packages/Core/Sources/Core/Weather.swift`).
It needs two things, both in place: the WeatherKit capability enabled for `com.bhavikjain.trackers` in
the developer portal (on both the Capabilities and App Services tabs), and the
`com.apple.developer.weatherkit` entitlement in both entitlements files. If either goes missing, every
request throws and both modules quietly show no weather — no card, no spinner.

A simulator build that isn't signed with the team may get no weather; launch a debug build with
`-WeatherStub YES` to swap in made-up but deterministic weather for the whole app.

## Debug launch arguments

All debug-only, and inert unless passed (Product → Scheme → Edit Scheme → Run → Arguments):

| Argument | What it does |
| --- | --- |
| `-InitializeCloudKitSchema YES` | The schema ritual above — opens a status screen, not the app |
| `-TVSeedShows YES` | Adds sample shows, looked up on TMDB (needs a key; does nothing if any show exists) |
| `-FuelSeedCSV YES` | Imports a sample Fuelly export |
| `-ParcelSeed YES` | Adds sample orders |
| `-TripSeed YES` | Adds four trips, one under way today (does nothing if any trip exists) |
| `-ExploreSeed YES` | Adds three guides with real places (does nothing if any guide exists) |
| `-PointsSeed YES` | Adds a sample household with people and points accounts (does nothing if any account exists) |
| `-FinanceSeed YES` | Adds a sample household with accounts, cards, metals, three months and budgets (does nothing if any household has data) |
| `-WeatherStub YES` | Made-up weather in place of WeatherKit |

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
container — so the two see the same data. The hub is a `NavigationSplitView`: a sidebar lists the eight
trackers, and the selected one's content sits in the detail pane — no sheet, no segmented strip.
`⌘1`–`⌘8` (the Trackers menu) jump straight to a tracker. Each module's own screens are otherwise
identical to iOS, including its internal "Home" tab, which has nothing to dismiss once embedded in
the detail pane and just bounces back to the module's own first tab — leaving a tracker is what the
sidebar is for now. Only `App/Sources/HomeView.swift` and `BhavikApp.swift` know about any of this;
no feature package changed.

Platform differences inside a module are handled in `Packages/Core/Sources/Core/MacCompat.swift`,
which provides `#if os(macOS)` no-op shims so the feature packages compile unchanged. Files relying on
those shims must `import Core`.

### Installing it

There's no App Store listing, so `gh workflow run "Mac Release"` (or a manual dispatch from the
Actions tab) is how you get a build: it archives `bhavik-macOS`, signs it with a Developer ID
certificate, notarizes it with Apple's notary service, and uploads a `Multitrack.dmg` as the run's
artifact. Download it, open it, drag Multitrack into Applications. It's signed for **Production**
CloudKit — the same real data as your phone — unlike a debug build run from Xcode, which always
talks to Development regardless of what account is signed in.

The workflow reuses the `testflight` environment, plus two secrets of its own — `MAC_DEVELOPER_ID_P12`
and `MAC_DEVELOPER_ID_P12_PASSWORD` — imported into a disposable keychain for the run. Cloud-managed
signing (what the App Store Connect key does for iOS) only covers App Store distribution; Apple never
holds a Developer ID private key for you, by design, so this genuinely needed a real certificate
exported from Xcode once and stored as a secret, not something the API key alone could mint. The same
key still handles matching that certificate to a Developer ID provisioning profile and authorizing
notarization.
