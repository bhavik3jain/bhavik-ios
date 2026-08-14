# bhavik-ios

A personal iOS app with several self-contained tracker modules behind one home screen.

| Module | What it does |
| --- | --- |
| Gym | Log workouts as weight × reps, save routines, track per-exercise progress |
| TV | Track shows and episodes, with a catch-up backlog and an upcoming-episode schedule |
| Fuel | Log fill-ups per vehicle, track MPG and cost, import a Fuelly CSV export |

## Getting set up

The Xcode project is **generated** from `project.yml`, so it is not checked in. After cloning, or any time you add or move source files:

```bash
xcodegen generate
```

Then open `bhavik-ios.xcodeproj` as usual.

Requires Xcode 26+ and the iOS 26 SDK. [XcodeGen](https://github.com/yonaskolb/XcodeGen) and [SwiftLint](https://github.com/realm/SwiftLint) come from Homebrew:

```bash
brew install xcodegen swiftlint
```

## Layout

```
App/            Thin app shell — entry point, home screen, shared model container
Packages/
  Core/         Types shared across modules
  GymTracker/   Workouts, routines, exercise library
  TVTracker/    Shows, episodes, schedule, TMDB lookup
  FuelTracker/  Vehicles, fill-ups, MPG, Fuelly import
project.yml     XcodeGen project definition
```

Each tracker is its own local Swift package so the modules stay independent and can be developed — or removed — without disturbing the others.

## TV metadata

Show and episode details come from [TMDB](https://www.themoviedb.org), which needs a free API key for personal use. Add yours under **TV → Stats → Settings**; it is stored on the device and never checked in. Without a key the module still works — you can add shows and episodes by hand — you just don't get search or automatic episode lists.

What you have watched is always yours: it lives in your own iCloud account, not on TMDB.

> This product uses the TMDB API but is not endorsed or certified by TMDB.

## Importing fuel history

**Fuel → Garage → Import from Fuelly** takes a CSV exported from Fuelly. It reads fill-ups and service records for every vehicle in the file and skips anything already imported, so running it twice is harmless. You can also drop a CSV into the app's folder from Finder or the Files app.

## Data and sync

Data lives in SwiftData, backed by the CloudKit private database (`iCloud.com.bhavikjain.trackers`), so it syncs across devices on the same Apple ID and survives reinstalling the app. Two constraints this places on the models, both enforced by CloudKit:

- every property needs a default value, and every relationship must be optional
- every relationship needs an explicit inverse

Breaking either one fails at launch when the container loads, not at compile time.

## Tests

Each module carries its own suite. Run one with:

```bash
cd Packages/FuelTracker && xcodebuild test -scheme FuelTracker -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```

Swap in `GymTracker` or `TVTracker` for the others.
