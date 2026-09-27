---
name: add-tracker
description: Scaffold a new tracker module in Multitrack (this repo's SwiftUI + SwiftData/Core Data + CloudKit app) end to end. Works out the design with the user, including whether the data needs sharing (Core Data + CKShare) or not (SwiftData), then runs a multi-agent workflow that builds the package, wires it into every app-shell file CLAUDE.md lists, updates the docs, builds iOS and Mac, and reviews the result. Use it whenever the user wants a new tracker, module or section on the Multitrack home screen, such as "add a tracker for X", "I want to track my Y in the app" or "can we add a Z module", even if they don't say "module". Don't use it for changes to an existing tracker.
argument-hint: "<what the tracker should track>"
---

# Add a tracker module

Invoking this skill is the user's opt-in to a multi-agent Workflow: run `workflow.js` from this
folder through the Workflow tool. It uses about 5 agents. Everything here builds on `.claude/CLAUDE.md`,
which you already have in context. Its "Adding a whole module", "CloudKit is the trap", "Module
chrome" and "macOS" sections are the checklist this skill automates.

## 1. Design it with the user (inline, no agents)

Start from `$ARGUMENTS`. Settle these, asking only about what the request leaves open, in one
AskUserQuestion call if you can:

- **Name.** A display name (on screen, e.g. "Points") and a package name (`<Thing>Tracker`), with
  the namespace `<Thing>TrackerModule` and a `SelectedModule` case in lower camel case. If the
  on-screen name might change later, pick a code name that won't: see the Orders/`ParcelTracker`
  note in CLAUDE.md, because renaming a record type orphans Production data.
- **Sharing.** Should anyone else ever see this data (a partner, family)? That decides the storage,
  and switching later means a migration:
  - **No sharing → SwiftData** (the Gym/TV/Orders pattern). `@Model`s go in the module's `models`
    array and are added to `AppSchema.models`. Reference module: `Packages/ParcelTracker`.
  - **Sharing → Core Data on `CloudSharedStore`** (the Fuel/Explore/Trips/Points pattern). A
    hand-built `<Thing>Model.make()`, `Shared*` `NSManagedObject` classes and one CKShare root
    entity. There is no `models` array and nothing goes into `AppSchema.models`. Reference module:
    `Packages/PointsTracker`, the cleanest example, built this way from the start with no legacy
    SwiftData migration.
- **Data model.** Entities, their fields, and relationships with delete rules. Watch for "by
  person/owner/vehicle" grouping, history over time, and dates that need a warning.
- **Screens.** Its sections (tabs on the phone, sidebar rows on the Mac), what the hub row's one-line detail says, and
  what the long-press peek shows.
- **Accent color and SF Symbol.** They must differ from every existing module; grep the
  `accent` definitions in `Packages/*/Sources/*/*TrackerModule.swift`.

Write the design out as a short spec (entities with fields, tabs, peek, detail string, seeder
contents) and show it to the user before launching anything. The workflow agents only know what
this spec says.

## 2. Run the workflow

If the user asked only for a plan, a dry run or "what would this look like", stop here: show the
spec and the exact `args` below, and don't launch anything. A full run scaffolds a package and edits
about ten app files, so it shouldn't happen as a side effect of a question.

Otherwise call the Workflow tool with `scriptPath` set to the **absolute** path of `workflow.js` in
this skill's folder, and with `args` as a JSON object, not a string (a string reaches the script as
one value and it stops with "missing args"):

```json
{
  "repoRoot": "<absolute repo root>",
  "packageName": "PointsTracker",
  "displayName": "Points",
  "caseName": "points",
  "icon": "star.circle.fill",
  "storage": "coredata",
  "referenceModule": "PointsTracker",
  "seedArg": "PointsSeed",
  "spec": "<the full spec from step 1>"
}
```

`storage` is `"swiftdata"` or `"coredata"`. `referenceModule` is `ParcelTracker` for SwiftData and
`PointsTracker` for Core Data.

The phases are Scaffold (writes the package and its tests, and gets them passing), then Wire and
Docs in parallel, then Build (xcodegen, iOS and Mac builds, package tests, fixes), then Review.

## 3. Close out (inline)

- Check the Review findings yourself against the code before fixing any of them, then fix the ones
  that hold up. Re-run the affected package's tests and the Mac build after the fixes.
- Tell the user plainly what still needs a human, which the workflow can't do:
  1. **The CloudKit schema ritual.** Launch a debug build signed in to iCloud with
     `-InitializeCloudKitSchema YES`, check the new record types in the Development environment,
     then **Deploy Schema Changes** to Production. Until then, TestFlight builds keep the new
     module's data on the device only.
  2. A look at it running, e.g. launch with `-<seedArg> YES`. Views are untested by policy.
- Don't commit unless asked.
