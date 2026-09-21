# CLAUDE.md

Multitrack — a personal iOS/macOS app, six tracker modules (Trips, Explore, Gym, TV, Orders, Fuel)
behind one home screen. SwiftUI + SwiftData + CloudKit, live on TestFlight. `README.md` has what it does, the layout,
credentials, the CloudKit Console ritual and how to run tests — read it rather than asking here. This
file is only the things that will cost you an hour if you don't know them.

Repo slug `bhavik3jain/bhavik-ios`. Needs the iOS 26 SDK to compile at all (Xcode 26 or newer; CI selects the
newest installed Xcode at run time). Core depends on nothing, the six trackers depend only on Core,
no feature package imports another, zero remote dependencies — keep it that way. Each module's
namespace is a `<Module>TrackerModule` caseless enum (`models`, `accent`, `rootView()`).

When grepping, exclude `Packages/*/.build/` and `.swiftpm/`: they hold generated test runners, and an
unfiltered `grep -rn '#if os(' Packages` returns 16 artefact hits when the true answer is zero.

## The .xcodeproj is generated — never edit it

Only ever edit `project.yml`, files under `App/` and `Packages/`, the two workflows, and docs.

- `bhavik-ios.xcodeproj` is XcodeGen output and is **gitignored**. (Three stale iCloud conflict
  copies, `bhavik-ios 2/3/4.xcodeproj`, also sit in the root — ignore them.)
- `App/Resources/Info.plist` and `Info-macOS.plist` are **tracked in git but still generated**, from
  each target's `info: { path:, properties: }` block plus XcodeGen's own defaults
  (`CFBundleExecutable`, `CFBundleShortVersionString`, …). Hand edits vanish on the next generate.
- Signing, entitlements paths and plist keys live in `project.yml`, **not** Xcode's Signing &
  Capabilities tab. Run `xcodegen generate` after any `project.yml` change or file move.
- XcodeGen has **no `resources:` key** — assets go under `sources:`. A `resources:` key is silently
  ignored; that once shipped the app with no icon for weeks.

## CloudKit is the trap

`ModelContainer` is built in `BhavikApp.init()` from the six modules' `models` arrays. Any violation
below fails at **container load — a `fatalError` on launch**, never at compile time. The message
interpolates the underlying SwiftData error, which names the offending model: read it.

- Every **non-optional** stored property needs an inline default (`name: String = ""`). Optionals are
  written bare, no `= nil`.
- `inverse:` is declared **exactly once, on the to-many side**:
  `@Relationship(deleteRule: .cascade, inverse: \Episode.show) public var episodes: [Episode]? = []`.
  The to-one side is a bare `public var show: Show?`. Annotating both sides is itself the error.
- No `@Attribute(.unique)` anywhere — CloudKit doesn't support it. De-duplication is hand-rolled in
  the importers.
- Enums are never stored types: an `xxxRaw: String` property plus a computed accessor with a
  `?? .fallback`. Adding an enum case is therefore **not** a schema change.
- **A computed accessor is invisible to SwiftData** and cannot appear in a `#Predicate` or a
  `SortDescriptor` — that fails at runtime, not compile time. Filter on the stored raw value
  (`statusRaw == ParcelStatus.delivered.rawValue`), or fetch and filter in Swift the way `HomeView`
  does (`parcels.count { !$0.status.isSettled }`). Every predicate in the tree touches stored
  properties only.

No `VersionedSchema` or migration plan exists; every change so far has been additive.

**Adding a @Model.** Write it under `Packages/<Module>/Sources/<Module>/Models/`; add it to that
module's `models` array — the **only** registration point, and a type left out compiles and runs,
then fails the moment anything queries it; add it to `CloudKitSchemaSeeder.seed(in:)` **and wire
every relationship** (a relationship only enters the schema once a record carries it) with
`CloudKitSchemaSeeder.marker` in some string field, plus the matching fetch-and-delete in
`purge(in:)` — a join-style model with no string field (`WorkoutSet`, `RoutineExercise`) is reached
through its marked parent. Then the Console ritual: steps are in the seeder's docstring. Launch with
`-SeedCloudKitSchema YES` and **leave it running** — the local save is synchronous, the upload is
not. Nothing in CI does any of this.

**Adding a whole module** needs these further edits, none optional: `packages:` **and** the
`&appDependencies` anchor in `project.yml` (the anchor covers both targets, so the Mac build follows
for free); the hardcoded sum in `BhavikApp.swift`; a `ModuleRow` (with its `.contextMenu` peek) in
`HomeView.swift`; a case in its private `SelectedModule` enum **and** the `fullScreenCover` switch
arm; a seed/purge pair in `CloudKitSchemaSeeder.swift`; a `TrackerRow` in `AppSettingsView.swift`;
the package loop in `tests.yml` — leave it out and CI never runs that suite, silently.

## Module chrome — a new root view can ship with no way back

Modules are presented as `fullScreenCover`, which carries **no dismiss control**. Every module root
view must therefore be a `TabView(selection:)` over `String` tab values that opens with
`Tab("Home", systemImage: "house", value: ModuleTab.home) { Color.clear }` — the empty content is
deliberate, selecting it dismisses rather than showing a screen — and ends with
`.tint(<Module>TrackerModule.accent.color)`, `.minimizesTabBarOnScroll()` and
`.dismissesOnHomeTab($selection, restoringTo: "<this module's own first tab>")`. `restoringTo:` must
name a real tab, never `ModuleTab.home`, or the module reopens blank. All six root views do this
identically, and nothing can catch a violation: views are untested by policy.

## macOS: one file holds every platform conditional

Feature packages contain **zero** `#if os(...)`. It all lives in Core: `MacCompat.swift` (no-op shims
for `keyboardType`, `textInputAutocapitalization`, `navigationBarTitleDisplayMode`, `EditButton`, and
`fullScreenCover` → `.sheet`, plus a `UIPasteboard` stand-in backed by `NSPasteboard` for Trips'
tap-to-copy), `SafariView.swift`, `GlassEffects.swift`. An iOS-only SwiftUI modifier
needed in a feature package means **adding a shim to MacCompat.swift**, not a `#if` at the call site.

- Eighteen view files carry `import Core // Only reached on macOS, …`. The import looks unused on iOS;
  **deleting it breaks only the Mac build**, the last CI step. Keep the marker comment on new ones.
- Never use `SafariView` directly — it doesn't exist on macOS. Go through `WebPage` +
  `.webSheet(_:tint:)`.
- `if #available(iOS 26, *)` does **not** gate macOS: `*` matches every other platform. Write
  `#available(iOS 26, macOS 26, *)`, or wrap in `#if os(iOS)`. The bare check inside
  `minimizesTabBarOnScroll()` is already inside `#if os(iOS)` and is correct — don't "fix" it.
- `App-macOS.entitlements` is load-bearing (CloudKit forces the sandbox, which then has to be
  reopened for networking and file import). Read its inline comments before touching it.

## Tests

Swift Testing only — no XCTest, no `@Suite`, no classes. **Views are deliberately untested: extract
logic into a value type and leave the view declarative.**

- SwiftData tests use the package's local `makeContext()` with `isStoredInMemoryOnly: true` and are
  `@MainActor`. No test may touch CloudKit.
- Live API tests must be gated — `@Test(.enabled(if: cred != nil, "Set TMDB_KEY_FILE to run …"))` —
  so a missing key reports a named skip and can never read as a pass. CI has no credentials.
- `#expect(throws: SomeError.someCase)` needs the error type `Equatable`. `CarrierError` is;
  `TMDBError` is not, which is why TV tests can only assert `.self`.

Debug launch arguments, all `#if DEBUG`: `-SeedCloudKitSchema YES` / `-PurgeCloudKitSchema YES`, plus
the module seeders that are the only way to get a simulator into a state worth looking at —
`-TVSeedShows` (needs a TMDB key, no-ops if any `Show` exists), `-FuelSeedCSV`, `-ParcelSeed`,
`-TripSeed`, `-ExploreSeed` (each no-ops once its store has a record). Seeders run from the module
root view's `.task`, so nothing happens until the module is opened. `-WeatherStub YES` injects
`StubWeatherProvider` at the app root — the only way to see weather on a simulator today.

## CI and release — what README doesn't say

**A `v*` tag does not run tests**, and `testflight.yml` has **no test gate of its own**. Build number
is `github.run_number + 100` (`BUILD_OFFSET`), passed only as `CURRENT_PROJECT_VERSION` on the
archive command line; marketing version is hardcoded `"1.0"` in `project.yml`, and a tag name does
not change it.

## Conventions

- Comments record the defect that motivated the code, with its symptom. **Carry them across when
  refactoring — for several bugs they are the only record.**
- Zero warnings is the standard but nothing enforces it: no `-warnings-as-errors`, and CI passes
  `-quiet`, which hides warnings. `.swiftlint.yml` exists but is **never run**; the tree already
  exceeds its own `line_length: 120` in both prose and code. Don't reflow user-facing `Text("…")`
  copy to satisfy a linter nobody runs.
- Time-dependent functions take `asOf now: Date = .now` rather than a clock abstraction.
- The Orders module is named **`ParcelTracker`** in code and **"Orders"** on screen. The rename was
  user-facing copy only: `Parcel`/`ParcelEvent` are live CloudKit record types and renaming a record
  type orphans every record already in Production. Grep for `Parcel` when you mean the code, `Orders`
  when you mean the UI; new user-facing copy says order, never parcel.
- Strings built outside a `Text` literal must use Core's `counted(_:_:plural:)` — SwiftUI's
  `^[…](inflect:)` markup only resolves when the literal reaches `Text` directly, and otherwise
  renders verbatim on screen.

## Weather fails quietly

Trips and Explore read `@Environment(\.weatherProvider)`, which defaults to the live
`WeatherKitProvider`. WeatherKit is enabled for the app ID in the developer portal and
`com.apple.developer.weatherkit` is in **both** entitlements files — remove either and every call
throws. The modules treat any error as "no weather" and show nothing, so a broken setup looks like a
quiet day, not a failure. A simulator build signed to run locally may get no weather either; use
`-WeatherStub YES` there. Apple's weather attribution (`WeatherAttributionView`) must appear wherever
weather is shown.

Explore's map asks for location only when it opens. That needs `NSLocationWhenInUseUsageDescription`
in **both** targets' `info.properties`, plus `com.apple.security.personal-information.location` in
`App-macOS.entitlements` — without either, the request is dropped and no blue dot ever appears.

## Known-stale things in the tree

Don't trust these comments, and don't "fix" the code they describe.

- `TVTrackerModule.apiKeyDefaultsKey`, `ParcelTrackerModule.fedExKeyDefaultsKey` /
  `fedExSecretDefaultsKey` and their doc comments say "user defaults". They are **iCloud Keychain
  account names** — credentials go through `Core/SyncedSecret.swift`.
- The app declares `UIBackgroundModes: [remote-notification]` but has **no `aps-environment`
  entitlement**, and there is no `BGTaskScheduler` anywhere, so sync is foreground/opportunistic and
  no background work exists at all. Don't promise live cross-device sync or background parcel
  tracking. (`SyncedSecret.swift` cites "a background parcel refresh" for
  `kSecAttrAccessibleAfterFirstUnlock` — fiction, but the choice is right: ThisDeviceOnly won't sync.)
- `CSVParser.swift`'s `case "\n", "\r\n", "\r":` only *looks* redundant. Swift folds CRLF into a
  single `Character`, so `"\r\n"` matches neither neighbour. Delete it and a Windows-exported CSV
  arrives as one enormous field and parses to zero rows — breaking both importers.
