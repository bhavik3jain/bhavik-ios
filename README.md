# Multitrack

A personal app with four self-contained tracker modules behind one home screen. Ships to iPhone
through TestFlight; also builds for the Mac.

| Module | What it does |
| --- | --- |
| Gym | Log workouts as weight × reps, save routines, track per-exercise progress |
| TV | Track shows, episodes and films, with a catch-up backlog and an upcoming-episode schedule |
| Fuel | Log fill-ups per vehicle, track MPG and cost, import a Fuelly CSV export |
| Orders | Track FedEx, UPS and USPS deliveries, with an in-app browser for the ones that can't be read automatically |

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
App/              Thin app shell — entry point, home screen, settings, schema seeder
Packages/
  Core/           Shared types: module chrome, glass effects, CSV parser, keychain, macOS shims
  GymTracker/     Workouts, routines, exercise library
  TVTracker/      Shows, episodes, films, schedule, TMDB lookup, library import
  FuelTracker/    Vehicles, fill-ups, MPG, Fuelly import
  ParcelTracker/  Parcels, carriers, tracking-number detection
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

**Adding or changing a `@Model` needs one extra step.** CloudKit only creates a record type when a
record of that type first syncs, and it never creates schema in Production — so a new model silently
fails to sync until the schema is deployed. The ritual:

1. Run a debug build with `-SeedCloudKitSchema YES`, which writes one throwaway record of every model
2. Let it sync, then confirm the record types appear in the CloudKit Console's **Development** environment
3. Hit **Deploy Schema Changes** to promote them to Production
4. Run again with `-PurgeCloudKitSchema YES` to delete the throwaways

See `App/Sources/CloudKitSchemaSeeder.swift`. Adding a case to an enum stored as a `String` raw value
is *not* a schema change and needs none of this.

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

## Tests

Each module carries its own suite. Run one the way CI does:

```bash
cd Packages/FuelTracker && xcodebuild test -scheme FuelTracker -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Swap in `Core`, `GymTracker`, `TVTracker` or `ParcelTracker` for the others.

The TV suite also carries tests that hit the real TMDB API. They are skipped by default and report
*why* they skipped, so a missing key can never read as a pass. To run them, put a key in a file and
point the test runner at it from Xcode's scheme editor (Product → Scheme → Edit Scheme → Test →
Arguments), setting `TMDB_KEY_FILE` to its path. `xcodebuild` does not forward environment variables
into the simulator, so exporting the variable in a shell will not work.

## Releasing

`Tests` runs on every push to `main`: the five package suites, an iOS app build, and an unsigned macOS
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
container — so the two see the same data. The UI is still iPhone-shaped: all four modules use a
`TabView` that renders as a segmented strip on a Mac, and the hub-and-module navigation wants to be a
`NavigationSplitView`. Treat it as working but unfinished.

Platform differences are handled in `Packages/Core/Sources/Core/MacCompat.swift`, which provides
`#if os(macOS)` no-op shims so the feature packages compile unchanged. Files relying on those shims
must `import Core`.
