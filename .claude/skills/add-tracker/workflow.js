export const meta = {
  name: 'add-tracker',
  description: 'Scaffold a new Multitrack tracker module, wire it into the app, update docs, build iOS+Mac, and review',
  whenToUse: 'Run from the /add-tracker skill once the module design (spec) has been agreed with the user.',
  phases: [
    { title: 'Scaffold', detail: 'write the package, models, views and tests; get its tests green' },
    { title: 'Wire', detail: 'app shell wiring and docs, in parallel' },
    { title: 'Build', detail: 'xcodegen, iOS + Mac builds, package tests, fix errors' },
    { title: 'Review', detail: 'independent correctness review of the whole change' },
  ],
}

// args: { repoRoot, packageName, displayName, caseName, icon, storage: 'swiftdata'|'coredata',
//         referenceModule, seedArg, spec }
const a = args || {}
const required = ['repoRoot', 'packageName', 'displayName', 'caseName', 'icon', 'storage', 'referenceModule', 'seedArg', 'spec']
const missing = required.filter(k => !a[k])
if (missing.length) {
  throw new Error(`add-tracker workflow is missing args: ${missing.join(', ')} — pass args as a JSON object, not a string`)
}
const isCoreData = a.storage === 'coredata'
const MODULE = a.packageName.replace(/Tracker$/, '') + 'TrackerModule'

const CONTEXT = `
Repo root: ${a.repoRoot}. You are adding a new tracker module to Multitrack.
- Package / library / test target: ${a.packageName} (at Packages/${a.packageName}); namespace enum: ${MODULE}.
- On-screen name: "${a.displayName}". SelectedModule case: \`${a.caseName}\`. SF Symbol: "${a.icon}".
- Storage: ${isCoreData
    ? `CORE DATA on CloudSharedStore (shareable via CKShare), modelled on Packages/${a.referenceModule}. Hand-built \`<Thing>Model.make()\`, \`Shared*\` NSManagedObject classes, one CKShare root entity. NO \`models\` array, NOT in AppSchema.models. Needs its own container in BhavikApp.init() (both the -InitializeCloudKitSchema in-memory branch and the real branch), a ShareAcceptRouter registration with prefix "CD_<root entity name>", env keys \`\\.<caseName>ManagedObjectContext\` / \`\\.<caseName>PersistentContainer\` added to Core's ModuleManagedObjectContexts.swift / ModulePersistentContainers.swift, and an entry in CloudKitSchemaInitializer.coreDataModels().`
    : `SWIFTDATA, modelled on Packages/${a.referenceModule}. @Models in the module's \`models\` array, added to the AppSchema.models sum in BhavikApp.swift. Follow CLAUDE.md's CloudKit rules exactly (inline defaults, inverse only on the to-many side, no .unique, enums as xxxRaw strings, predicates on stored properties only).`}
- Debug seeder launch argument: -${a.seedArg} (debug-only, no-op once data exists, runs from the root view's .task).

Agreed design spec:
${a.spec}
`

phase('Scaffold')
const scaffold = await agent(`${CONTEXT}
Create Packages/${a.packageName} by studying Packages/${a.referenceModule} closely and mirroring its structure, idioms and comment style (read its Package.swift, module enum, models, root view, list/detail/editor views, peek, seeder and tests first).
Requirements:
- Package.swift like the reference (iOS 18 / macOS 15, depends only on ../Core, a test target).
- ${MODULE} with \`accent\` (a ModuleAccent whose colour differs from every existing module — grep the other *TrackerModule.swift files), \`rootView(...)\`, \`homePeek(...)\` (a ModulePeekCard) and a testable \`homeDetail\` string.
- Root view obeys CLAUDE.md "Module chrome": TabView(selection:) over String values, first tab \`Tab("Home", systemImage: "house", value: ModuleTab.home) { Color.clear }\`, then .tint(accent), .minimizesTabBarOnScroll(), .dismissesOnHomeTab($selection, restoringTo: "<its own first real tab>").
- Zero \`#if os(...)\` in the package; iOS-only modifiers go through Core's MacCompat shims, with \`import Core // Only reached on macOS, …\` where Core is imported only for those.
- ${isCoreData ? 'Every mutation ends in saveIfNeeded(); new child objects are assigned to the same store as their parent (see how the reference module does it); read-only share participants get edit affordances hidden via SharingStatusResolver.canEdit; a Share button presents ShareSheetRequest via \\.presentShareSheet.' : 'Predicates and sort descriptors touch stored properties only.'}
- Logic lives in value types / model methods, not views. Swift Testing tests (no XCTest, no @Suite) cover it: ${isCoreData ? 'an in-memory CloudSharedStore.makeContainer(name: unique per test, …, inMemory: true) per test' : 'a local makeContext() with isStoredInMemoryOnly: true, @MainActor'}. Time-dependent functions take \`asOf now: Date = .now\`. Strings with counts use Core's counted(_:_:plural:).
Then run the package's tests: pick a simulator UDID from \`xcrun simctl list devices available | grep -E "^\\s+iPhone" | tail -1\`, run \`xcodebuild test -scheme ${a.packageName} -destination "platform=iOS Simulator,id=<UDID>"\` in the package directory, and fix until "Test run with N tests … passed". Do not touch App/, project.yml or other packages${isCoreData ? ' — except adding the two env keys to Core, which you should do now since the package needs them' : ''}.
Return: the public API the app shell needs (exact signatures), the root entity/record type name if Core Data, file list, and the test result line you saw.`, { label: 'scaffold-package', phase: 'Scaffold' })

phase('Wire')
const [wiring, docs] = await parallel([
  () => agent(`${CONTEXT}
The package now exists. Its author reports:
${scaffold}

Wire it into the app shell, mirroring how ${isCoreData ? 'Explore' : 'Orders (ParcelTracker)'} is wired. Follow every item in CLAUDE.md's "Adding a whole module" list:
project.yml \`packages:\` and the \`&appDependencies\` anchor; ${isCoreData ? 'BhavikApp.swift container (both branches), ShareAcceptRouter registration, the two .environment(...) keys on the WindowGroup, and CloudKitSchemaInitializer.coreDataModels()' : 'the AppSchema.models sum in BhavikApp.swift'}; HomeView.swift (imports, ${isCoreData ? 'a ManagedObjectFetch started from its own .task(id:)' : 'an @Query'}, a new SelectedModule case placed LAST with accent and icon, moduleContent, detail(for:), peek(for:)); AppSettingsView.swift (a trackerDetail arm with counts); .github/workflows/tests.yml package loop. Grep App/Sources for any other exhaustive switch over SelectedModule and add arms.
Do not edit Packages/ or the .xcodeproj, and don't build — a later stage does. Return files changed and anything you were unsure of.`, { label: 'wire-app-shell', phase: 'Wire' }),
  () => agent(`${CONTEXT}
The package now exists. Its author reports:
${scaffold}

Update documentation only: README.md (module count words, the module table row, the Layout block, the debug launch arguments list, and — if Core Data — where README lists the CKShare modules) and .claude/CLAUDE.md (module count and the module lists in parentheses, ⌘1–⌘N count, the debug launch args list${isCoreData ? ', the list of hand-built Core Data models' : ''}). Read both files fully first; keep their terse tone. Don't touch code. Return a short summary.`, { label: 'update-docs', phase: 'Wire' }),
])

phase('Build')
const BUILD_SCHEMA = {
  type: 'object',
  properties: {
    iosBuild: { type: 'string', enum: ['pass', 'fail'] },
    macBuild: { type: 'string', enum: ['pass', 'fail'] },
    packageTests: { type: 'string', enum: ['pass', 'fail', 'not-run'] },
    coreTests: { type: 'string', enum: ['pass', 'fail', 'not-run'] },
    fixes: { type: 'array', items: { type: 'string' } },
    remainingErrors: { type: 'array', items: { type: 'string' } },
  },
  required: ['iosBuild', 'macBuild', 'packageTests', 'coreTests', 'fixes', 'remainingErrors'],
}
const build = await agent(`${CONTEXT}
Earlier stages reported:
--- scaffold ---
${scaffold}
--- wiring ---
${wiring}
Make everything compile and pass. From ${a.repoRoot}: \`xcodegen generate\`; pick a simulator UDID as above; \`xcodebuild build -project bhavik-ios.xcodeproj -scheme bhavik-ios -destination "platform=iOS Simulator,id=<UDID>" -quiet\`; \`xcodebuild build -project bhavik-ios.xcodeproj -scheme bhavik-macOS -destination "platform=macOS" CODE_SIGNING_ALLOWED=NO -quiet\`; then \`xcodebuild test\` for Packages/${a.packageName} and Packages/Core. Build once without -quiet and fix any warnings from the new package's files. Fix errors in App/Sources, project.yml or the new package, respecting CLAUDE.md (no #if os in feature packages, never edit the .xcodeproj). Rerun until green or truly stuck; use long timeouts. Report honestly — never claim a pass you didn't see.`, { label: 'build-and-fix', phase: 'Build', schema: BUILD_SCHEMA })

phase('Review')
const FINDINGS = {
  type: 'object',
  properties: {
    findings: {
      type: 'array',
      items: {
        type: 'object',
        properties: {
          file: { type: 'string' },
          line: { type: 'integer' },
          severity: { type: 'string', enum: ['high', 'medium', 'low'] },
          summary: { type: 'string' },
          failureScenario: { type: 'string' },
          suggestedFix: { type: 'string' },
        },
        required: ['file', 'severity', 'summary', 'failureScenario', 'suggestedFix'],
      },
    },
  },
  required: ['findings'],
}
const review = await agent(`${CONTEXT}
Review the whole change for correctness defects: \`git -C ${a.repoRoot} status\` and \`git diff\`, and read every file under Packages/${a.packageName} (untracked). Check against CLAUDE.md: the CloudKit model rules (a violation is a fatalError at launch, not a compile error), completeness of the "Adding a whole module" list, the Module chrome rule, the macOS rules, and the test rules. ${isCoreData ? 'For Core Data also check cross-store relationships on new objects, saveIfNeeded after every mutation, read-only participant gating, and that both BhavikApp branches build the container.' : ''}
Only report real defects with a concrete failure scenario; skip style nits. Do not edit files.`, { label: 'review', phase: 'Review', schema: FINDINGS, effort: 'high' })

return { scaffold, wiring, docs, build, review }
