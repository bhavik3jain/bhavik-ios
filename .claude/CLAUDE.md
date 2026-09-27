# CLAUDE.md

Multitrack — a personal iOS/macOS app, eight tracker modules (Trips, Explore, Gym, TV, Orders, Fuel, Points,
Finance)
behind one home screen. SwiftUI + SwiftData + CloudKit, live on TestFlight. `README.md` has what it does, the layout,
credentials, the CloudKit Console ritual and how to run tests — read it rather than asking here. This
file is only the things that will cost you an hour if you don't know them.

Repo slug `bhavik3jain/bhavik-ios`. Needs the iOS 26 SDK to compile at all (Xcode 26 or newer; all three workflows
run on GitHub's `xcode-27` preview image, pinned to Xcode 27.0 — not the newest installed, which there is a
27.2 beta that App Store Connect rejects). Core depends on nothing, the eight trackers depend only on Core,
no feature package imports another, zero remote dependencies — keep it that way. Each module's
namespace is a `<Module>TrackerModule` caseless enum (`models`, `accent`, `symbolName`, `sections`,
`rootView()`).

When grepping, exclude `Packages/*/.build/` and `.swiftpm/`: they hold generated test runners, and an
unfiltered `grep -rn '#if os(' Packages` returns 16 artefact hits when the true answer is zero.

## The .xcodeproj is generated — never edit it

Only ever edit `project.yml`, files under `App/` and `Packages/`, the two workflows, and docs.
`scripts/finance/` (Mac-only Python, month JSON ↔ the Numbers sheet) is also fair game, but never commit
real `.numbers`/`.json` there — its `.gitignore` blocks them. `Finance Template.numbers` is the
user's sheet seeded with fake "Seed Data" rows, and goes in only after `make_template.py --check`
prints `clean` (it checks text and amounts): pivots and Numbers' calc cache kept card names and
merchants after every cell was cleared, until Numbers itself re-saved the file, so change the
template's numbers only in Numbers too. The export drives Numbers itself (JXA) to grow tables —
numbers-parser's `add_row` on a grouped table makes rows Numbers never shows.

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

`ModelContainer` is built in `BhavikApp.init()` from the SwiftData modules' `models` arrays (Gym, TV, Orders). Any violation
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

**Trip ideas are a sentinel, not a schema change.** An itinerary item with no day (Trips' Ideas tab,
ranked by distance in Nearby) is `dayIndex == SharedItineraryItem.unassignedDayIndex` (`-1`), and
`isUnassigned` treats **any** negative value as an idea; pickers map them all to `DayChoice.unassigned`.
Flights never take it — `FlightEditorView` passes `includesUnassigned: false`. Anything that clamps or
iterates days (`clampPlanToDates()`, `ItineraryReschedule`, day grouping) must skip negatives, or it
drags ideas onto Day 1 — which is exactly what builds from before ideas still do whenever they save a
trip, and that syncs to every sharer.

**Adding a @Model.** Write it under `Packages/<Module>/Sources/<Module>/Models/`; add it to that
module's `models` array — the **only** registration point, and a type left out compiles and runs,
then fails the moment anything queries it. Then the Console ritual (README → Data and sync): launch a
debug build signed in to iCloud with `-InitializeCloudKitSchema YES`, check the types in the
Development environment, **Deploy Schema Changes** to Production. The initializer builds its schema
from `AppSchema.models` via `NSManagedObjectModel.makeManagedObjectModel(for:)` and Core Data's
`initializeCloudKitSchema()` on a throwaway store, so there's no seed code to keep in step with the
models, and that launch opens an in-memory container instead of the real store. Nothing in CI does
any of this. (It replaced a seed-then-purge seeder whose comment claimed SwiftData had no bridge to
Core Data — it has had one since iOS 17.)

The same launch also initializes the five hand-built Core Data models (`TripModel`, `FuelModel`,
`GuideModel`, `PointsModel`, `FinanceModel` — Trips, Fuel and Explore moved off SwiftData for CloudKit sharing;
Points and Finance were born on Core Data). Adding an entity
or attribute to one of those needs the same ritual. Production never creates record types on its
own, only Development does: before the Core Data models were added here, TestFlight builds saved
those modules' data locally and never exported any of it to iCloud. That includes CloudKit's own
`cloudkit.share` type, which only appears once something has been shared: the run makes and deletes
one test share for it. Before it did, every Share button on TestFlight failed while making the link.

**Adding a whole module** needs these further edits, none optional: `packages:` **and** the
`&appDependencies` anchor in `project.yml` (the anchor covers both targets, so the Mac build follows
for free); the `AppSchema.models` sum in `BhavikApp.swift`; a `ModuleRow` (with its `.contextMenu` peek) in
`HomeView.swift`; a case in its `SelectedModule` enum (with its `icon` and `sections`) **and** the
`moduleContent` switch arm, plus its arms in the Mac's `sidebarDetail` and `overviewCard`; a
`TrackerRow` in `AppSettingsView.swift`;
its test target in `project.yml`'s `AllPackageTests` scheme, which is what CI runs — leave it out and CI never runs that suite, silently.

A **Core Data module** (like Points or Finance) has no `models` array and is **not** added to
`AppSchema.models`. Instead it needs: its own container in `BhavikApp.init()` — **both** branches,
or the schema-init / in-memory launch crashes on a missing env value; a
`ShareAcceptRouter.shared.register(recordTypePrefix: "CD_Shared…")` for its share root, or accepted
shares land nowhere; env keys in Core's `ModuleManagedObjectContexts.swift` **and**
`ModulePersistentContainers.swift`; and an entry in `CloudKitSchemaInitializer.coreDataModels()`,
or Production never gets its record types. It also needs a `describeSharedChange` on its
`<Module>TrackerModule` and a row in `BhavikApp.startSharedChangeNotifications` (plus
`SharedChangeNotificationsSection.modules`), or a partner's edits to it are never notified, and its
container in the `syncMonitor.track` loop beside it, or Refresh from iCloud never waits on it. Its
container must come from `CloudSharedStore.makeContainer`, which stamps the `app` transaction author
that keeps this device's own saves out of those notifications. `SharedChangeNotifier` also **purges
persistent history** once an export has succeeded — anything new that reads history must be added to
its cutoff, or it loses the transactions it hasn't read yet. `/add-tracker` (`.claude/skills/add-tracker`) scaffolds a
new module and walks this whole list.

## Module chrome — a new root view can ship with no way back

On the phone modules are presented as `fullScreenCover`, which carries **no dismiss control**; the
way out is a "Home" tab whose selection dismisses. Every module root view therefore goes through
Core's `ModuleTabView(selection:sections:)` (`ModuleChrome.swift`), which builds that chrome in one
place: a Home tab with empty content first, then one tab per `ModuleSection`,
`.minimizesTabBarOnScroll()` and `.dismissesOnHomeTab` restoring to the **first section**, never
Home, or the module reopens blank. The root view adds only `.tint(<Module>TrackerModule.accent.color)`.
A hand-rolled `TabView` gets none of this and nothing catches it: views are untested by policy.

Each module declares `sections` (the tabs, in order — the first is where it opens) and `symbolName`
on its `<Module>TrackerModule`, and its `rootView` takes an optional `section: Binding<String>?`
that is nil on the phone. The Mac passes the sidebar's selection there and sets
`\.moduleLayout = .sidebar`, under which `ModuleTabView` shows just the selected section with no
tab bar. Trips has one section; its `rootView` takes `trip:`/`tripSection:` bindings instead.

## macOS: one file holds every platform conditional *inside a module*

Feature packages contain **zero** `#if os(...)`. It all lives in Core: `MacCompat.swift` (no-op shims
for `keyboardType`, `textInputAutocapitalization`, `navigationBarTitleDisplayMode`, `EditButton`, and
`fullScreenCover` → `.sheet`, plus a `UIPasteboard` stand-in backed by `NSPasteboard` for Trips'
tap-to-copy), `SafariView.swift`, `GlassEffects.swift`. An iOS-only SwiftUI modifier
needed in a feature package means **adding a shim to MacCompat.swift**, not a `#if` at the call site.

This rule is scoped to `Packages/<Module>` — a module asks **how it is shown**
(`@Environment(\.moduleLayout)`: `.tabs` on the phone, `.sidebar` on the Mac), never where it runs.
That flag is how a module drops its phone-only header, moves its section picker into the toolbar
(Trips' Plan/Ideas/Nearby/Map/Codes as `.principal`), shows the Mac-only Ideas inspector (⌥⌘I) and
drag-and-drop, or turns Fuel's vehicle chips into a toolbar segmented control. `moduleSubtitle(_:)`
puts a line under the toolbar title in the sidebar layout only.

`App/Sources/HomeView.swift`, `MacOverview.swift`, `MacSettingsView.swift` and `BhavikApp.swift` are
the composition root, not a feature package, and **do** carry `#if os(macOS)` directly: iOS gets the
hub list + `fullScreenCover`; macOS gets a `NavigationSplitView` whose sidebar is Overview, then the
visible trackers, with the selected one's sections (only when it has more than one) or Trips' trips
+ "Past trips" nested under it, and an iCloud footer with Refresh. It lands on the Overview — one
`overviewCard(…)` per module, fed from `HomeView`'s queries like the peeks. Settings is its own
scene (⌘,). A `⌘0`–`⌘9` Trackers menu reaches `HomeView`'s selection via a `Notification.Name` (a
Scene's `.commands` sits outside the `WindowGroup` and has no other way in). The Mac never shows a
module's Home tab. Don't move this into Core — it's the two platforms genuinely wanting different
navigation, and it belongs where the hub itself lives.

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

Debug launch arguments, all `#if DEBUG`: `-InitializeCloudKitSchema YES`, plus
the module seeders that are the only way to get a simulator into a state worth looking at —
`-TVSeedShows` (needs a TMDB key, no-ops if any `Show` exists), `-FuelSeedCSV`, `-ParcelSeed`,
`-TripSeed`, `-ExploreSeed`, `-PointsSeed`, `-FinanceSeed` (each no-ops once its store has a record). Seeders run from the module
root view's `.task`, so nothing happens until the module is opened. `-WeatherStub YES` injects
`StubWeatherProvider` at the app root — the only way to see weather on a simulator today. `-CloudSyncRefreshAfter <seconds>` runs one Refresh from iCloud after launch and prints its outcome.

## CI and release — what README doesn't say

**A `v*` tag does not run tests**, and `testflight.yml` has **no test gate of its own**. Build number
is `github.run_number + 100` (`BUILD_OFFSET`), passed only as `CURRENT_PROJECT_VERSION` on the
archive command line; marketing version is hardcoded `"1.0"` in `project.yml`, and a tag name does
not change it.

`mac-release.yml` is the Mac equivalent, manual-only (`workflow_dispatch`), producing a notarized
`.dmg` as a run artifact rather than shipping anywhere. **Cloud-managed signing does not cover
Developer ID** — that was the first thing tried, and it fails with `Cloud signing permission error` /
`No profiles for 'com.bhavikjain.trackers' were found`, because Apple never holds a Developer ID
private key on your behalf the way it does for App Store distribution; the whole point of Developer
ID is that you hold it. So the workflow imports a real certificate (exported from Xcode once, stored
as `MAC_DEVELOPER_ID_P12` + `MAC_DEVELOPER_ID_P12_PASSWORD` in the `testflight` environment) into a
disposable keychain each run; the existing App Store Connect key still handles matching it to a
Developer ID provisioning profile and authorizing notarization. A Developer ID export is **signed but
not notarized** on its own; Gatekeeper refuses to launch it on any Mac but the one that built it until
the notary step staples a ticket to it, which is why that step exists and can't be skipped for "just
testing."

The Developer ID provisioning profile itself comes from a third secret, `MAC_DEVELOPER_ID_PROFILE`
(base64 of a profile downloaded from the portal by hand). **A profile's entitlements are frozen when
it's generated**, so any new capability in `App-macOS.entitlements` breaks the next Mac Release until
that profile is regenerated and the secret replaced; the only clue is a codesign/export error about an
entitlement the profile doesn't allow. `com.apple.developer.aps-environment` (CloudKit pushes) is the
first such addition: Push Notifications is already on for the App ID (a signed local build with
`-allowProvisioningUpdates` turned it on, and the team profile it made carries it), but the Developer
ID profile in the secret predates it. TestFlight should need nothing: its `-allowProvisioningUpdates`
archive fetches a fresh App Store profile each run.

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
- CloudKit pushes are on: `aps-environment` in `App.entitlements`, `com.apple.developer.aps-environment`
  in `App-macOS.entitlements` (both `development`; export rewrites them from the profile), plus
  `UIBackgroundModes: [remote-notification]` and `registerForRemoteNotifications()` in
  `ShareAcceptDelegate.swift`. Until they were added a partner's change only arrived at the next
  launch or foreground, minutes later. Silent-push delivery is still at the system's discretion and
  there is no `BGTaskScheduler` anywhere, so don't promise instant sync or background parcel
  tracking. (`SyncedSecret.swift` cites "a background parcel refresh" for
  `kSecAttrAccessibleAfterFirstUnlock` — fiction, but the choice is right: ThisDeviceOnly won't sync.)
- There is no "sync now" in `NSPersistentCloudKitContainer`. Core's `CloudSyncMonitor` (injected at
  the app root) re-posts the app's did-become-active notification — at most once a minute, or
  `dasd` rate-limits all syncing for hours — then waits, bounded, for a real import event. A list
  gets pull-to-refresh with `.refreshesFromCloud()`; don't hand-roll a `.refreshable` that sleeps.
  Never "force" a sync by removing and re-adding stores: every managed object a view holds dies.
- `CSVParser.swift`'s `case "\n", "\r\n", "\r":` only *looks* redundant. Swift folds CRLF into a
  single `Character`, so `"\r\n"` matches neither neighbour. Delete it and a Windows-exported CSV
  arrives as one enormous field and parses to zero rows — breaking both importers.
