# bhavik-ios

A personal iOS app with several self-contained tracker modules behind one home screen.

| Module | Status | What it does |
| --- | --- | --- |
| Gym | Built (v1) | Log workouts as weight × reps, save routines, track per-exercise progress |
| TV | Planned | Track shows and episodes, with an upcoming-episode schedule |
| Fuel | Planned | Log fill-ups and track MPG and cost over time |

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
  GymTracker/   Gym module: SwiftData models, seed data, views, tests
project.yml     XcodeGen project definition
```

Each tracker is its own local Swift package so the modules stay independent and can be developed — or removed — without disturbing the others.

## Data and sync

Data lives in SwiftData, backed by the CloudKit private database (`iCloud.com.bhavikjain.trackers`), so it syncs across devices on the same Apple ID and survives reinstalling the app. Two constraints this places on the models, both enforced by CloudKit:

- every property needs a default value, and every relationship must be optional
- every relationship needs an explicit inverse

Breaking either one fails at launch when the container loads, not at compile time.

## Tests

```bash
cd Packages/GymTracker && xcodebuild test -scheme GymTracker -destination 'platform=iOS Simulator,name=iPhone 17 Pro'
```
