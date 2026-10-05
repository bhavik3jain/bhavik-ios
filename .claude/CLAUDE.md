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
numbers-parser's `add_row` on a grouped table makes rows Numbers never shows. The template's
`Credit Card` and `Personal Items Pivot` are **plain tables standing in for the real sheet's
pivots** — Numbers' scripting can't refresh a pivot, so every export showed seed data in them;
don't turn them back into pivots. Writing a number into a currency cell turns it automatic, so
money ops carry a fourth element, `"currency"`, and the fill script *types* the amount
("$173,902.21") into template cells formatted currency/two places; Metal Price is written as the
sheet's `=STOCK("GC=F")`/`=STOCK("SI=F")`.

**A month's export holds the transactions *entered* since the month before was closed**
(`SheetPeriod`, by `createdAt`), not those dated in the calendar month — the user's sheet runs
from close to close, and by date 19 of September's 116 charges were missing. So `createdAt`
matters: the importer caps it at the imported month's close (or end), or a backfilled month would
land on the open month's sheet, and `DebugSeed` sets it to each charge's date. The app's own
screens (spending, budgets, reports) still go by calendar month. The **Mac app** runs
the same export in-process (`App/Sources/MacFinanceNumbers.swift`, OSAKit): project.yml bundles
`numbers_fill.js` and the template into the Mac target, and `FinanceNumbersSpec.swift` is a port of
`export_numbers.build_spec` — **change one, change the other**. It needs the Apple-events sandbox
exception, `com.apple.security.automation.apple-events` and `NSAppleEventsUsageDescription`; lose
any one and every Apple event fails -1743 with no prompt. `-FinanceNumbersExportProbe YES` (Debug,
Mac) runs it on a made-up month at launch.

**A new Finance month starts every balance at zero** (`MonthRollover`), so a half-filled month's
totals are a fraction of the real ones. Anything headlining a net worth (Summary, peek, Overview,
home row) goes through `FinanceHome.reportedMonth`, which falls back to the month before until the
open one is complete; a new screen that reads `latestMonth` for totals will report a fake crash.

**Gold and silver prices are live and deliberately not stored as they arrive.** `MetalPriceFeed`
reads GC=F / SI=F (Yahoo's chart endpoint, no key, undocumented) and the household's latest month,
while open, is valued at them everywhere (`MonthSummary`, `FinanceHistory`, progress, exports all
take `live:`). Closing the month writes them into it. Saving on every refresh would sync, and
iCloud's zone alert subscriptions fire on any change — every app open would alert the partner.

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

**Finance's "No budget" is a sentinel too.** A category kept with no budget is a `SharedFinanceBudget`
with `limit == SharedFinanceBudget.noLimit` (`-1`); `hasLimit` treats any negative limit that way.
`BudgetStatus` lists those, and every category spent on without a budget, as `unbudgetedLines`, never
as budget lines; the Numbers export (Swift spec **and** `export_numbers.py`) leaves them out of the
Budget table. Anything that sums or compares budget limits must skip negatives. Builds from before
it read the sentinel as a -$1 budget, always over.

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

**The legacy importers run once per iCloud account, never per install.** Trips, Fuel and Explore
still copy out of their old SwiftData stores (`*LegacyMigration`), whose records live on in iCloud,
so every fresh install finds them again. Keyed only on UserDefaults and a name match, each reinstall
re-copied whatever hadn't synced down yet or had been renamed since — the user's cars duplicated on
every install. Now: `LegacyMigrationLedger` (UserDefaults **and** iCloud key-value storage), never
copy into a store that already holds anything, and never copy after `CloudKitImportGate` timed out
(`Outcome.mayCopyLegacyData`) — try next launch. Garage's "Merge Duplicate Cars" (`FuelDuplicates`)
folds the copies already made; it keeps a car this person shared, never touches a partner's.

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
`<Module>TrackerModule` and a row in `BhavikApp.startSharedChangeNotifications` — with its share-root
entity name, which iCloud's alert subscriptions read — (plus
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
scene (⌘,). A `⌘0`–`⌘9` Trackers menu reaches the key window's `HomeView` selection through
`.focusedSceneValue(\.trackerSelection, …)` / `@FocusedBinding` (a Scene's `.commands` sits outside
the `WindowGroup`; the notification it used before switched every open window). The Mac never shows a
module's Home tab. Don't move this into Core — it's the two platforms genuinely wanting different
navigation, and it belongs where the hub itself lives.

- **A screen a Mac module pushes gets none of the module's environment.** Its
  `navigationDestination` is hosted by the split view's own navigation, above the module's root, so
  it saw the phone layout, the Mac's default form style and **Trips' `managedObjectContext`**: a
  Finance month crashed on open fetching Finance entities from the Trips store. `HomeView` sets
  `\.moduleLayout`, `.formStyle(.grouped)`, the selected tracker's context
  (`macModuleContext`) and the share-sheet host (`presentsShareSheetsWithoutOutcome()`; on the
  detail column, a guide's and a past trip's Share buttons called the do-nothing default) on the
  `NavigationSplitView` itself. A module that injects anything else at
  its root and pushes screens needs it added there too.
- Mac-only modifiers in a module go through Core like the iOS ones: `tableRowBackgroundsPlain()`
  (`alternatingRowBackgrounds` is macOS-only and broke the iOS build), `moduleSubtitle(_:)` (not
  `navigationSubtitle`, iOS 26+), `readableWidthInSidebar()`. Editor sheets root in Core's
  `SheetStack`, not `NavigationStack`: a bare Mac sheet takes its `Form`'s cramped ideal size.
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

**Never point `-derivedDataPath` or `--scratch-path` at `/tmp`.** Nothing ever cleans it: 147 such
build folders (`wf5-mac`, `warn-dd`, `trips-ai-dd`, …, 0.1–1G each) filled 33G of the Mac's disk by
October 2026. Use the default DerivedData, or the session's scratchpad directory, and delete any
one-off build folder once its run is done.

Swift Testing only — no XCTest, no `@Suite`, no classes. **Views are deliberately untested: extract
logic into a value type and leave the view declarative.**

- SwiftData tests use the package's local `makeContext()` with `isStoredInMemoryOnly: true` and are
  `@MainActor`. No test may touch CloudKit.
- Live API tests must be gated — `@Test(.enabled(if: cred != nil, "Set TMDB_KEY_FILE to run …"))` —
  so a missing key reports a named skip and can never read as a pass. CI has no credentials.
- `#expect(throws: SomeError.someCase)` needs the error type `Equatable`. `CarrierError` is;
  `TMDBError` is not, which is why TV tests can only assert `.self`.

Debug launch arguments, all `#if DEBUG`: `-InitializeCloudKitSchema YES`, `-InMemoryStores YES`
(the whole app on in-memory stores, no CloudKit — see *Working on this Mac* below), plus
the module seeders that are the only way to get a simulator into a state worth looking at —
`-TVSeedShows` (no-ops if any `Show` exists; with no TMDB key it makes one offline "Sample Show"), `-FuelSeedCSV`, `-ParcelSeed`,
`-TripSeed`, `-ExploreSeed`, `-PointsSeed`, `-FinanceSeed` (each no-ops once its store has a record).
(The Points seed, like the others behind `CloudKitImportGate`, waits up to 60 s on a simulator.) Seeders run from the module
root view's `.task`, so nothing happens until the module is opened. `-WeatherStub YES` injects
`StubWeatherProvider` at the app root — the only way to see weather on a simulator today. `-CloudSyncRefreshAfter <seconds>` runs one Refresh from iCloud after launch and prints its outcome.
`-InMemoryStores YES -SharedChangeProbe finance` posts a made-up partner's burst of eight Finance edits as a real
notification 8 s after launch (leave Finance first: a notification about the tracker on screen is held back); add
`-SharedChangeProbeTap YES` to also tap it — injected simulator touches never reach a notification banner — which
opens Finance with the list of changes (`SharedChangeDigest`) over it.
`-InMemoryStores YES -TVSeedShows YES -TVEpisodeAlertProbe YES` [`-TVEpisodeAlertProbeQuit YES`] prints TV's
new-episode alert plan at launch, after one TMDB refresh that ignores the 12-hour ledger (none without a key — the
offline "Sample Show" then has a third season airing over the next weeks to plan from); it refuses the real store.
`-TripAdvisorStub YES` swaps Trips' Apple Intelligence advisor and Apple Maps place search for
`StubTripAdvisor`/`StubPlaceSearcher` at the app root, the same way: same answers every run,
offline, on hardware with no Apple Intelligence. `-TripAdvisorProbe YES` (add `-TripAdvisorProbeQuit YES`
to quit after) opens **only in-memory stores**, like the schema launch, and prints the whole Trips
engine run on a made-up Rome trip: `PlanCheck`, the brief the model sees, a streamed review from the
real on-device model, and a "Suggest Places" run against Apple Maps. It's the way to check the real
model on a Mac without touching real iCloud data (it answers on the iOS 27 simulator too): run the built binary directly
(`…/Multitrack.app/Contents/MacOS/Multitrack -TripAdvisorProbe YES -TripAdvisorProbeQuit YES`) and read stdout.
Finance has the same pair: `-FinanceAdvisorStub YES` (`StubFinanceAdvisor` at the app root, every scene) and
`-FinanceAdvisorProbe YES` [`-FinanceAdvisorProbeQuit YES`] — in-memory stores, seeds them, prints `MonthCheck`,
the `ReportBrief`, a streamed review, Ask answers (including an investment question it must refuse) and the year
in review, and writes both HTML reports to `Caches/FinanceAdvisorProbe/`. `-FinanceOpenReport YES` /
`-FinanceOpenReview YES` present the reported month's report / review sheet once Finance opens, after the
seed (report wins if both). `-FinanceSeed` makes **twelve months**: eleven finished with transactions, the
current one open with cash only — so the Summary and the report land on *last* month (`reportedMonth`), as
designed. It is built to set off most `MonthCheck` findings; keep it that way when changing either.
`-MacOpenTracker <module>[/<section>]` (Mac, e.g. `fuel/trends`) opens a tracker at launch,
navigation only: the one way to reach a tracker's Mac layout from a script without Accessibility access.
`trips/next[/<face>]` opens the nearest trip not yet over; `-MacOpenFirstItem YES` then opens the first
month, guide, order or Points account (screens only a double-click reaches), two seconds in.
**Debug is its own app: `com.bhavikjain.trackers.dev`, "Multitrack Dev"** (`project.yml`, per-config). With
the release bundle id, a Mac Debug build shared the TestFlight app's sandbox container, so the same
Core Data stores, while syncing with iCloud **Development**; the first TestFlight build to open those
stores crashed three times: "Cannot replace assigned container ID <… environment=Sandbox> with
<… environment=Production>". Now Debug has its own container, keychain and key-value store, and syncs
only with Development (same iCloud container), so it never sees or touches real data. Never give Debug
the release bundle id back. The `.dev` App ID needs WeatherKit enabled in the developer portal like the
release one, or Debug shows no weather.

## Working on this Mac — what cost an afternoon (October 2026)

- **Xcode has no Apple ID signed in here, and the simulator isn't signed in to iCloud.** So
  `xcodebuild` can't sign the Mac app ("No Accounts" / "No profiles for
  'com.bhavikjain.trackers.dev'") — not with `-allowProvisioningUpdates`, not outside the sandbox.
  Nothing that needs iCloud (sharing, notifications from a partner, iCloud alerts) can be
  exercised on the simulator: the Notification Status page there says nothing is shared.
- **Schema ritual: `scripts/cloudkit/init-schema.sh`.** The Mac still has an Apple Development
  certificate and a Mac development profile — for the *release* app ID only. Xcode refuses that
  profile under manual signing ("is Xcode managed, but signing settings require a manually managed
  profile"), so the script builds with `CODE_SIGNING_ALLOWED=NO` and signs by hand with resolved
  entitlements plus `application-identifier`/`team-identifier`. The release ID is safe for *this*
  launch only (in-memory stores; the "never give Debug the release bundle id" rule is about normal
  launches). Two traps it handles: with the release ID the run inherited the TestFlight app's saved
  window state and opened **no window**, so the initializer (which runs from the window) never
  started — `-ApplePersistenceIgnoreState YES` fixes it; and `print` to a file is buffered until
  exit — `NSUnbufferedIO=YES`. **Deploy Schema Changes to Production is Console-only** (no API;
  `cktool` only imports into Development), and GitHub runners can't sign in to iCloud, so neither
  half can be a workflow. Never run TestFlight for a schema change before that deploy.
- **Looking at the Mac UI without signing:** build `bhavik-macOS` with `CODE_SIGNING_ALLOWED=NO`,
  `codesign --force --deep -s -` it, and run the binary directly with
  `-InMemoryStores YES -FinanceSeed YES -MacOpenTracker finance/months -MacOpenFirstItem YES`.
  Its windows belong to `com.bhavikjain.trackers.dev`. The TestFlight Mac app
  (`/Applications/Multitrack.app`, `com.bhavikjain.trackers`) is usually running too — never drive
  it; with a release-ID build both answer to the same bundle id, so find the window by PID.
  Accessibility-injected Return types `"\n"` rather than pressing the key, so it can't confirm
  `onSubmit` focus moves.
- **Package tests:** `swift test` fails at CodeSign of the `.xctest` in this checkout. Run
  `xcodebuild test -scheme <Package> -destination 'platform=iOS Simulator,id=<UDID>'` from the
  package folder; README's `iPhone 17 Pro` doesn't exist here — take a booted one from
  `xcrun simctl list devices available | grep Booted`.
- **After switching branches, `xcodegen generate`** — the generated project still lists the other
  branch's files ("Build input file cannot be found").
- **Simulator driving:** screenshots lag a second or two behind a tap, so wait before deciding a tap
  missed; scrolling minimises the tab bar to one floating button, so scroll back up before tapping
  a tab. Opening Finance asks for notification permission (the monthly reminder).
- **Merging:** auto-merge is disabled on the repo. Check `gh pr view N --json statusCheckRollup`,
  then `gh pr merge N --merge` (merge commits, as the history has), then
  `gh workflow run TestFlight --ref main`.

## CI and release — what README doesn't say

**A `v*` tag does not run tests**, and `testflight.yml` has **no test gate of its own**. Build number
is `github.run_number + 100` (`BUILD_OFFSET`), passed only as `CURRENT_PROJECT_VERSION` on the
archive command line; marketing version is hardcoded `"1.0"` in `project.yml`, and a tag name does
not change it.

`testflight.yml` also uploads the **Mac app to TestFlight** (job `mac`, Universal Purchase: same bundle id,
same App Store Connect app, macOS platform added there). It can't development-sign a Mac archive: a
Mac development profile only covers registered Macs, and signing manually without a profile is refused
because CloudKit and push need one. So it archives with `CODE_SIGNING_ALLOWED=NO`, signs the app **ad hoc
with `App-macOS.entitlements` resolved by hand** (unsigned, it would carry no entitlements and the export
would ship it without its sandbox or CloudKit), and lets the `app-store-connect` export re-sign it through
the API key. A new Mac entitlement therefore needs no workflow change, but a new `$(…)` variable in that
file needs adding to the job's `sed`. The Mac App Store also needs `LSApplicationCategoryType` and a full
Mac icon set (`mac-*.png` in `AppIcon`).

**The Developer ID `.dmg` route (`mac-release.yml`) is retired** — TestFlight replaced it. If it's ever
revived from git history: cloud-managed signing does **not** cover Developer ID (it fails with `Cloud
signing permission error`), so it needs an exported certificate as a secret, a notary step (a Developer
ID export is signed but not notarized, and Gatekeeper refuses it elsewhere), and a provisioning profile
made fresh each run, because a profile's entitlements freeze when it's generated.

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

## Trips' Apple Intelligence: Swift decides, the model only words

It all lives in `Packages/TripTracker`: `Models/PlanCheck.swift` (the plain review, with fixes),
`TripBrief`, `PlanReview`, `SuggestionCandidates`, `AdvisorPresentation`, and `Intelligence/` (the
`TripAdvising`/`PlaceSearching` protocols, `FoundationModelsTripAdvisor`, the stubs, the probe). The
UI is Review Plan (`TripReviewSheet`: the phone's + menu on Plan, a toolbar button on the Mac), Suggest
Places (`PlaceSuggestionsSheet`, from Ideas and from Nearby's "Find More Around Day N") and the Mac
inspector's Suggestions section.

**Swift computes every fact and every fix; the model only ranks and phrases them, and picks places
by number from Swift's MapKit list.** Each rule is a failure seen on the real model: left to judge, it
answered six real problems with "No change needed", turned a 30-minute overlap into two stops "on Day
1", suggested places on another continent, and looped ~70 tool calls. `PlanReview.isFaithful` still
throws out any note that loses a figure or a place, falling back to the check's own words. Views never
show an error: every failure falls back to the plain check or the nearest places.

- FoundationModels is weak-linked; every use is behind `@available`/`#available(iOS 26.0, macOS 26.0, *)`.
  Views see only `TripAdvising`, which has no FoundationModels types.
- The **Trips** switch under Settings' **Apple Intelligence** section (default on) is stored by
  `App/Sources/TripsIntelligenceStore.swift`; the section itself, Trips' and Finance's rows together, is
  `AppleIntelligenceSection` in `App/Sources/FinanceIntelligenceStore.swift`. The store is synced through `NSUbiquitousKeyValueStore` like `TrackerLayoutStore`, and reaches Trips only as
  `\.tripAdvisorEnabled`, set at the app root. Views go by `advisor.availability(isEnabled:)`; off is
  `.turnedOff`, which means no model UI, no prewarm and nothing sent to the model. The plain plan
  check stays. The switch is hidden where the model can never run (`showsSetting`: below 26, or
  ineligible hardware).
- On a simulator use `-TripAdvisorStub YES`. `-TripAdvisorProbe YES` exercises the real model without
  touching real data (see Tests above).

## Finance report and review: the same rule as Trips

`Packages/FinanceTracker/Sources/FinanceTracker/Report/` builds the month (or year) report:
`FinanceReportData.build(scope:household:filter:live:deviceName:)` is a `Sendable` snapshot with every
figure already computed and formatted; `MonthCheck` / `YearCheck` turn it into `ReportFinding`s, each
with Swift's own `plainText` plus the `figures` and `names` that must survive into any rewording (a
test holds every one to appearing verbatim in its `plainText`); `FinanceReportHTML.render` is a pure
function to one self-contained page (CSP `default-src 'none'`, no script, no fonts, no network; light
and dark; section ids `brief`, `networth`, … `fixing` that the viewer's Jump to Section and the Mac
sidebar scroll to). `Intelligence/` mirrors Trips: `ReportBrief` numbers the facts, the model
(`FoundationModelsFinanceAdvisor`, weak-linked, `#available(iOS 26.0, macOS 26.0, *)`) only ranks and
words them, `ReportReview.isFaithful` drops any note that loses a figure or a name, adds a number of
its own, borrows another fact's name, dismisses or sounds like investment advice, and the check's own
words stand in. Ask answers go through `AskReply` the same way — a number not in the brief and the
answer becomes "I can only answer from this report's figures." plus the nearest facts. Views see only
`FinanceAdvising`; every failure falls back to `ReportReview.plain`, never an error.

- Reports follow the same guardrails as the Summary: a report opens on `FinanceHome.reportedMonth`, an
  open month is valued at `MetalPriceFeed` live prices and the page says so, and "No budget"
  (`limit == -1`) is an unbudgeted chip, never a budget row. Under an owner filter, balances and spending
  follow the paying account's owner but **budgets stay household-wide** (`budgetsAreHouseholdWide`) — a
  household limit is never compared with one person's spend.
- **The review is cached locally only** (`ReportReviewCache`: `Application Support/FinanceReviews`, one JSON
  per scope and owner, keyed by the brief's fingerprint, notes by fact number). Never Core Data or
  iCloud: a synced write fires the partner's iCloud alert subscription — every Summary visit would
  alert them. Notes are keyed by **fact number, not finding id**, because some finding ids carry a Core
  Data object URI that changes when a temporary id becomes permanent; keyed by id, a cached review lost
  its notes the moment the month entry saved.
- **The in-app browser is Core's `HTMLDocumentView`, a `WKWebView` wrapper — not iOS 26's SwiftUI
  `WebView`**, because the app targets iOS 18 / macOS 15. It loads the string with no base URL into a
  non-persistent store and cancels every navigation but the first load and `#anchors`; http(s)/mailto
  links go to `openURL`. `HTMLDocumentExport` paginates PDFs to US Letter and prints, always in light
  appearance with print media — the report's light palette must be complete and its print CSS keeps
  `print-color-adjust: exact`, or bars vanish from PDFs. On macOS AppKit calls the print operation's
  `didRun` on its own thread: the delegate is nonisolated behind a lock, because a main-actor one
  trapped at the end of every PDF export. Core's other `WebPage` (`SafariView.swift`) is unrelated.
- Preferences: `App/Sources/FinanceIntelligenceStore.swift` (key-value store + UserDefaults mirror, like
  `TripsIntelligenceStore`) feeds `\.financeAdvisorEnabled` and `\.financeReportPreferences` through
  `FinanceAppEnvironment`, which is on **every scene** — main window, Mac Settings, Mac report window.
  Settings' Apple Intelligence section is now `AppleIntelligenceSection` (Trips and Finance rows, each
  hidden by its advisor's `showsSetting`).
- The Mac report is a scene of its own: `WindowGroup(id: FinanceTrackerModule.reportWindowID, for:
  FinanceReportWindowValue.self)` opened through `presentsReport(_:)`; on the phone the same modifier is a
  `fullScreenCover`. A window outside the split view gets nothing from `HomeView`, so the scene sets the
  Finance context, `.sidebar` layout, form style and share host itself. Its shortcut is **⇧⌘R**: ⌘R is
  View ▸ Refresh from iCloud, and the menu command takes the key first.
- **Report-ready notification** rides on `SharedChangeNotifier`: Finance's describer is wrapped in
  `FinanceReportReady.watching`, which posts "September's report is ready" for an *imported update*
  that sets `closedAt` (closed under 3 days ago; inserts and reopenings never), once per close (a
  UserDefaults ledger), gated on "Notify when a report is ready". The tap carries
  `SharedChangeNotifications.destinationUserInfoKey` ("finance.report:2026-09") through
  `SharedChangeNotificationRouter.destinationToOpen` to `FinanceReportRouter.shared.pending`, which
  `FinanceRootView` presents. It reads no persistent history of its own, so the notifier's purge cutoff
  is unchanged; iCloud's server alerts still get the plain describer. It fires for the person's own
  other device too, and alongside the ordinary "closed September" shared-change notice — on purpose.

## TV's new-episode alerts

`Packages/TVTracker/Sources/TVTracker/Alerts/` (`EpisodeAlertPlanner` decides, `TVEpisodeAlerts` schedules,
`EpisodeAlertStore` holds the synced switch, time and muted TMDB ids) and `Refresh/` (`EpisodeMerge`,
`TVEpisodeRefresher`). Before it, episode lists were fetched only when a show was added, so nothing new ever arrived.

- **Local notifications share iOS's 64 pending per app**, and it drops the furthest silently: Finance's month
  reminder holds 12, TV at most 40 (`maximumAlerts`). Anything new that schedules ahead has to fit beside them, and a
  reschedule removes only its own prefix (`tv.newEpisode.`, `finance.monthStart.`).
- A reminder carries `SharedChangeNotifications.reminderUserInfoKey`: Core's delegate still routes its tap (module
  `tv`, destination `tv.upnext`, which `EpisodeAlertsRoot` turns into the Up Next tab) and holds it back while TV is on
  screen, but never logs it in `SharedChangeActivityLog`, which Notification Status reads as the shared-change pipeline.
- **TMDB's air dates are midnight UTC** (`TMDBDate`): read in local time they're the evening before anywhere west of
  Greenwich, and every alert came a day early. `EpisodeAlertPlanner.airDay` reads a midnight-UTC date in UTC.
- The refresh ledger (once per show per 12 h) is UserDefaults, deliberately **not** a property on `Show`: that would
  be a CloudKit schema change and a write synced to every device twice a day. The merge matches by (season, number),
  never deletes, never touches watched state, and re-derives status only for a completed show that gained episodes
  — re-deriving every show turned one set to Watching by hand, nothing ticked off, into "Haven't started".
- iOS's `BGAppRefreshTask` (`com.bhavikjain.trackers.tv-refresh`) is registered in `App/Sources/TVEpisodeAlertsLaunch.swift`
  from `BhavikApp.init()` — registration after launch finishes is an exception, and so is an identifier missing from
  `BGTaskSchedulerPermittedIdentifiers` in project.yml (with `fetch` in `UIBackgroundModes`). Its callbacks are
  `@Sendable`: the scheduler calls them off the main thread, and Swift 6 traps a main-actor closure there. iOS runs it
  at its own discretion (never after a force-quit or in Low Power Mode), and refuses the request on a simulator; on a
  device, pausing in the debugger and running `e -l objc -- (void)[[BGTaskScheduler sharedScheduler]
  _simulateLaunchForTaskWithIdentifier:@"com.bhavikjain.trackers.tv-refresh"]` launches it.

## Known-stale things in the tree

Don't trust these comments, and don't "fix" the code they describe.

- `TVTrackerModule.apiKeyDefaultsKey`, `ParcelTrackerModule.fedExKeyDefaultsKey` /
  `fedExSecretDefaultsKey` and their doc comments say "user defaults". They are **iCloud Keychain
  account names** — credentials go through `Core/SyncedSecret.swift`.
- CloudKit pushes are on: `aps-environment` in `App.entitlements`, `com.apple.developer.aps-environment`
  in `App-macOS.entitlements` (both `development`; export rewrites them from the profile), plus
  `UIBackgroundModes: [remote-notification]` and `registerForRemoteNotifications()` in
  `ShareAcceptDelegate.swift`. Until they were added a partner's change only arrived at the next
  launch or foreground, minutes later. Uploads have no "now" either: Core's `CloudExportKeeper` holds
  the app open (a background task, at most 25 s) after each save until an upload that started after it
  finishes — left at once, the change used to wait for the next launch. Silent-push delivery is still at the system's discretion and
  the one `BGTaskScheduler` task is TV's episode refresh (see *TV's new-episode alerts*), which iOS also runs only when
  it sees fit, so don't promise instant sync or background parcel tracking. What *does* reach a force-quit or rebooted device is iCloud's own alert
  (`SharedChangeServerAlerts`: CloudKit subscriptions with a visible `notificationInfo`, IDs prefixed
  `multitrack.alert.`) — fixed text only, and CloudKit sends it to the account's other devices for the
  user's own edits too. **Never set `collapseIDKey` on them**: CloudKit refuses the whole subscription
  ("cannot add collapseId to this subscription type"), and until October 2026 that meant no iCloud
  alert had ever been saved for anyone. `-InMemoryStores YES -AlertSubscriptionProbe YES` on a build
  signed like `scripts/cloudkit/init-schema.sh` signs one saves the real subscriptions to
  Development, prints CloudKit's answer, and deletes them. Never touch a subscription without that prefix: Core Data's silent ones live
  beside them. (`SyncedSecret.swift` cites "a background parcel refresh" for
  `kSecAttrAccessibleAfterFirstUnlock` — fiction, but the choice is right: ThisDeviceOnly won't sync.
  And it's load-bearing now: TV's background episode refresh reads the TMDB key while the phone is locked.)
- There is no "sync now" in `NSPersistentCloudKitContainer`. Core's `CloudSyncMonitor` (injected at
  the app root) re-posts the app's did-become-active notification — at most once a minute, or
  `dasd` rate-limits all syncing for hours — then waits, bounded, for a real import event. A list
  gets pull-to-refresh with `.refreshesFromCloud()`; don't hand-roll a `.refreshable` that sleeps.
  Never "force" a sync by removing and re-adding stores: every managed object a view holds dies.
- **Never call `NSPersistentCloudKitContainer`'s sharing API on the main thread.** Each call
  (`fetchShares`, `share`, `persistUpdatedShare`, `fetchParticipants`, `acceptShareInvitations`)
  waits synchronously for the container's executor, which iCloud's own exports hold: TestFlight
  build 16 deadlocked on Share and was killed (0x8BADF00D). Use Core's `…InBackground` forms
  (`CloudShareCalls.swift`), and `SharingStatusResolver.badgeStatus(for:in:)` for any "Shared"
  badge — it answers from `SharingStatusCache` and looks up off the main thread. The synchronous
  `status(for:in:)` is only for Finance's rare owned-share checks, which must not act on a stale
  answer. Notification delegate methods use the completion-handler forms, answered on the main
  thread: the `async` forms ran on Swift's cooperative pool and crashed every notification tap.
- `CSVParser.swift`'s `case "\n", "\r\n", "\r":` only *looks* redundant. Swift folds CRLF into a
  single `Character`, so `"\r\n"` matches neither neighbour. Delete it and a Windows-exported CSV
  arrives as one enormous field and parses to zero rows — breaking both importers.
