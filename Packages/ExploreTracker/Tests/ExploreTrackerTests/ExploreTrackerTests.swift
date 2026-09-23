import Core
import CoreData
import Foundation
import MapKit
import ObjectiveC
import Testing
@testable import ExploreTracker

/// Associated-object key for tying a returned context's lifetime to the
/// container that built it — see `makeContext()`. `objc_setAssociatedObject`
/// only ever uses this variable's fixed address, as a `&`-taken pointer, never
/// its value — `nonisolated(unsafe)` is safe here for exactly that reason.
private nonisolated(unsafe) var associatedContainerKey: UInt8 = 0

@MainActor
private func makeContext() throws -> NSManagedObjectContext {
    // A fresh, uniquely-named container per call, not one fixed name shared by
    // every test: Swift Testing runs test functions in parallel by default,
    // and two containers built from the same name resolve to the same default
    // store URL — even the in-memory store type keeps that URL as the
    // coordinator's registration key, so two tests racing to add their own
    // in-memory store "at" it corrupted each other's data intermittently.
    let container = CloudSharedStore.makeContainer(
        name: "ExploreStoreTests-\(UUID().uuidString)",
        model: GuideModel.make(),
        containerID: "iCloud.com.bhavikjain.trackers.tests",
        inMemory: true
    )
    let context = container.viewContext
    // Apple's own documented gotcha: nothing else keeps `container` alive once
    // this function returns just its `viewContext` — a context does NOT retain
    // its own container — so without this, ARC was free to deallocate it right
    // after `makeContext()` returned, and every test reading back through the
    // context afterward (which is all of them) was working against a
    // half-torn-down store. Tying its lifetime to the context it handed out
    // fixes that without changing every test's signature.
    objc_setAssociatedObject(context, &associatedContainerKey, container, .OBJC_ASSOCIATION_RETAIN)
    return context
}

@MainActor
@discardableResult
private func addPlace(
    _ name: String,
    _ category: PlaceCategory,
    to guide: SharedGuide,
    in context: NSManagedObjectContext,
    at point: GeoPoint? = nil,
    rating: Int? = nil,
    addedAt: Date = .now
) -> SharedGuidePlace {
    let place = SharedGuidePlace(context: context, name: name, category: category, latitude: point?.latitude, longitude: point?.longitude)
    place.addedAt = addedAt
    place.guide = guide
    if let rating {
        place.setTried(true)
        place.rating = rating
    }
    return place
}

// MARK: - Region derived from places

@Test func anEmptyGuideHasNoRegion() {
    #expect(GuideRegion.enclosing([]) == nil)
}

@Test func aSinglePlaceGetsTheDefaultSpanCentredOnIt() throws {
    let yasaka = GeoPoint(latitude: 35.0036, longitude: 135.7786)
    let region = try #require(GuideRegion.enclosing([yasaka]))
    #expect(region.center == yasaka)
    #expect(region.latitudeDelta == GuideRegion.singlePlaceSpan)
    #expect(region.longitudeDelta == GuideRegion.singlePlaceSpan)
}

@Test func severalPlacesGetAPaddedBoundingBoxCentredBetweenTheExtremes() throws {
    let points = [
        GeoPoint(latitude: 35.00, longitude: 135.76),
        GeoPoint(latitude: 35.02, longitude: 135.80),
        GeoPoint(latitude: 35.01, longitude: 135.77),
    ]
    let region = try #require(GuideRegion.enclosing(points))
    #expect(abs(region.center.latitude - 35.01) < 1e-9)
    #expect(abs(region.center.longitude - 135.78) < 1e-9)
    #expect(abs(region.latitudeDelta - 0.02 * GuideRegion.padding) < 1e-9)
    #expect(abs(region.longitudeDelta - 0.04 * GuideRegion.padding) < 1e-9)
}

@Test func placesAcrossTheStreetStillGetAUsableSpan() throws {
    let region = try #require(GuideRegion.enclosing([
        GeoPoint(latitude: 37.7850, longitude: -122.4024),
        GeoPoint(latitude: 37.7851, longitude: -122.4025),
    ]))
    #expect(region.latitudeDelta == GuideRegion.minimumSpan)
    #expect(region.longitudeDelta == GuideRegion.minimumSpan)
}

@MainActor
@Test func theGuideRegionIgnoresPlacesAddedByHandAndItsCentreIsWhereWeatherComesFrom() throws {
    let context = try makeContext()
    let guide = SharedGuide(context: context, name: "Kyoto", areaLabel: "Kyoto, Japan")
    addPlace("Somewhere I was told about", .places, to: guide, in: context)
    #expect(GuideSummary.summarize(guide).region == nil)

    addPlace("Yasaka Shrine", .places, to: guide, in: context, at: GeoPoint(latitude: 35.0036, longitude: 135.7786))
    addPlace("Kiyomizu-dera", .places, to: guide, in: context, at: GeoPoint(latitude: 34.9949, longitude: 135.7850))
    let summary = GuideSummary.summarize(guide)
    let center = try #require(summary.region?.center)
    #expect(abs(center.latitude - (35.0036 + 34.9949) / 2) < 1e-9)
    #expect(abs(center.longitude - (135.7786 + 135.7850) / 2) < 1e-9)
}

// MARK: - Category guessed from Apple Maps

@Test(arguments: [
    (MKPointOfInterestCategory.restaurant, PlaceCategory.foodAndDrinks),
    (.cafe, .foodAndDrinks),
    (.bakery, .foodAndDrinks),
    (.winery, .foodAndDrinks),
    (.nightlife, .foodAndDrinks),
    (.museum, .places),
    (.park, .places),
    (.landmark, .places),
    (.store, .places),
    (.amusementPark, .activities),
    (.hiking, .activities),
    (.theater, .activities),
    (.spa, .activities),
])
func guessesCategoryFromMapsPointOfInterest(_ poi: MKPointOfInterestCategory, _ expected: PlaceCategory) {
    #expect(PlaceCategory.guess(from: poi) == expected)
}

@Test func anUncategorisedResultIsFiledUnderPlaces() {
    #expect(PlaceCategory.guess(from: nil) == .places)
}

@MainActor
@Test func anUnknownStoredCategoryFallsBackToPlaces() throws {
    let context = try makeContext()
    let place = SharedGuidePlace(context: context, name: "x", category: .activities)
    place.categoryRaw = "somethingNewer"
    #expect(place.category == .places)
}

// MARK: - Counts

@MainActor
@Test func countsPlacesPerCategoryAndTried() throws {
    let context = try makeContext()
    let guide = SharedGuide(context: context, name: "Gion & Higashiyama", areaLabel: "Kyoto, Japan")
    addPlace("Duck noodles", .foodAndDrinks, to: guide, in: context)
    addPlace("Kagizen", .foodAndDrinks, to: guide, in: context, rating: 5)
    addPlace("Pontocho", .foodAndDrinks, to: guide, in: context, rating: 0)
    addPlace("Yasaka", .places, to: guide, in: context)
    addPlace("Tea ceremony", .activities, to: guide, in: context, rating: 4)

    let summary = GuideSummary.summarize(guide)
    #expect(summary.placeCount == 5)
    #expect(summary.triedCount == 3)
    #expect(summary.count(of: .foodAndDrinks) == 3)
    #expect(summary.count(of: .places) == 1)
    #expect(summary.count(of: .activities) == 1)
    #expect(summary.detailLine == "Kyoto, Japan · 5 places · 3 tried")
    #expect(summary.categoryChips.map(\.text) == ["3 food & drinks", "1 place", "1 activity"])
}

@MainActor
@Test func summaryLinesReadNaturallyAtTheEdges() throws {
    let context = try makeContext()
    let empty = SharedGuide(context: context, name: "Empty", areaLabel: "")
    let untried = SharedGuide(context: context, name: "Big Sur drive", areaLabel: "California")
    addPlace("Bixby Bridge", .places, to: untried, in: context)

    #expect(GuideSummary.summarize(empty).detailLine == "No places yet")
    #expect(GuideSummary.summarize(empty).categoryChips.isEmpty)
    #expect(GuideSummary.summarize(untried).detailLine == "California · 1 place · none tried yet")
    #expect(GuideSummary.summarize(untried).peekDetail == "California · none tried yet")
}

@Test func categoryCountsUseSingularsAndPlurals() {
    #expect(PlaceCategory.foodAndDrinks.countText(1) == "1 food & drink")
    #expect(PlaceCategory.foodAndDrinks.countText(6) == "6 food & drinks")
    #expect(PlaceCategory.places.countText(1) == "1 place")
    #expect(PlaceCategory.activities.countText(2) == "2 activities")
}

@MainActor
@Test func overviewAndHomeDetailCountGuidesAndPlaces() throws {
    let context = try makeContext()
    #expect(GuideSummary.homeDetail(for: []) == "No guides yet")
    #expect(GuideSummary.overview([]) == "")

    let kyoto = SharedGuide(context: context, name: "Kyoto")
    let soma = SharedGuide(context: context, name: "SoMa")
    addPlace("A", .places, to: kyoto, in: context)
    addPlace("B", .places, to: kyoto, in: context)
    addPlace("C", .foodAndDrinks, to: soma, in: context)

    let summaries = GuideSummary.all([kyoto, soma], pinDates: [:])
    #expect(GuideSummary.overview(summaries) == "2 guides · 3 places")
    #expect(GuideSummary.homeDetail(for: Array(summaries.prefix(1))).hasPrefix("1 guide · "))
}

@MainActor
@Test func guidesAreListedNewestFirst() throws {
    let context = try makeContext()
    let older = SharedGuide(context: context, name: "Older")
    older.createdAt = Date(timeIntervalSince1970: 1_000)
    let newer = SharedGuide(context: context, name: "Newer")
    newer.createdAt = Date(timeIntervalSince1970: 2_000)
    #expect(GuideSummary.all([older, newer], pinDates: [:]).map(\.name) == ["Newer", "Older"])
}

@MainActor
@Test func weatherCaptionUsesTheTownOnly() throws {
    let id = try PersistentIdentifierFixture.make()
    #expect(GuideSummary(id: id, name: "", areaLabel: "Kyoto, Japan", placeCount: 0, triedCount: 0, counts: [:], region: nil).weatherCaption == "Weather in Kyoto now")
    #expect(GuideSummary(id: id, name: "", areaLabel: "", placeCount: 0, triedCount: 0, counts: [:], region: nil).weatherCaption == "Weather here now")
}

/// An `NSManagedObjectID` for building a `GuideSummary` by hand.
private enum PersistentIdentifierFixture {
    @MainActor
    static func make() throws -> NSManagedObjectID {
        let context = try makeContext()
        let guide = SharedGuide(context: context, name: "fixture")
        return guide.objectID
    }
}

// MARK: - Ordering within a category

@Test func toTryComesFirstInTheOrderAddedThenTriedByRating() {
    let base = Date(timeIntervalSince1970: 0)
    let keys = [
        PlaceOrdering.Key(name: "Tried unrated", isTried: true, rating: 0, addedAt: base),
        PlaceOrdering.Key(name: "Tried 3", isTried: true, rating: 3, addedAt: base),
        PlaceOrdering.Key(name: "To try, added second", isTried: false, rating: 0, addedAt: base.addingTimeInterval(60)),
        PlaceOrdering.Key(name: "Tried 5", isTried: true, rating: 5, addedAt: base.addingTimeInterval(120)),
        PlaceOrdering.Key(name: "To try, added first", isTried: false, rating: 0, addedAt: base),
    ]
    let ordered = keys.sorted(by: PlaceOrdering.precedes).map(\.name)
    #expect(ordered == ["To try, added first", "To try, added second", "Tried 5", "Tried 3", "Tried unrated"])
}

@MainActor
@Test func aGuideListsOneCategoryInOrder() throws {
    let context = try makeContext()
    let guide = SharedGuide(context: context, name: "Kyoto")
    let base = Date(timeIntervalSince1970: 0)
    addPlace("Kagizen", .foodAndDrinks, to: guide, in: context, rating: 5, addedAt: base)
    addPlace("Duck noodles", .foodAndDrinks, to: guide, in: context, addedAt: base.addingTimeInterval(10))
    addPlace("Yasaka", .places, to: guide, in: context, addedAt: base)
    addPlace("Pontocho", .foodAndDrinks, to: guide, in: context, rating: 2, addedAt: base.addingTimeInterval(5))

    #expect(guide.places(in: .foodAndDrinks).map(\.name) == ["Duck noodles", "Kagizen", "Pontocho"])
    #expect(guide.places(in: .activities).isEmpty)
}

// MARK: - Tried state

@MainActor
@Test func untryingAPlaceClearsItsRatingAndDate() throws {
    let context = try makeContext()
    let place = SharedGuidePlace(context: context, name: "Kagizen", category: .foodAndDrinks)
    let day = Date(timeIntervalSince1970: 1_000_000)
    place.setTried(true, asOf: day)
    place.rating = 4
    #expect(place.triedAt == day)

    place.setTried(true, asOf: day.addingTimeInterval(86_400))
    #expect(place.triedAt == day, "Re-ticking a tried place keeps the first date")

    place.setTried(false)
    #expect(!place.isTried)
    #expect(place.rating == 0)
    #expect(place.triedAt == nil)
}

@MainActor
@Test func deletingAGuideDeletesItsPlaces() throws {
    let context = try makeContext()
    let guide = SharedGuide(context: context, name: "Kyoto")
    addPlace("Yasaka", .places, to: guide, in: context)
    addPlace("Kagizen", .foodAndDrinks, to: guide, in: context)
    try context.save()

    context.delete(guide)
    try context.save()
    #expect(try context.count(for: SharedGuidePlace.fetchRequest()) == 0)
}

// MARK: - Distance and walking time

private let metric = Locale(identifier: "en_JP")
private let us = Locale(identifier: "en_US")
private let uk = Locale(identifier: "en_GB")
private let germany = Locale(identifier: "de_DE")

@Test func formatsShortDistancesInMetresToTheNearestTen() {
    #expect(WalkingEstimate(metres: 653).distanceText(locale: metric) == "650 m")
    #expect(WalkingEstimate(metres: 3).distanceText(locale: metric) == "10 m")
}

@Test func formatsLongerDistancesInKilometresWithTheLocalesDecimal() {
    #expect(WalkingEstimate(metres: 1_234).distanceText(locale: metric) == "1.2 km")
    #expect(WalkingEstimate(metres: 1_234).distanceText(locale: germany) == "1,2 km")
}

@Test func formatsMilesWhereMilesAreUsed() {
    #expect(WalkingEstimate(metres: 650).distanceText(locale: us) == "0.4 mi")
    #expect(WalkingEstimate(metres: 650).distanceText(locale: uk) == "0.4 mi")
    #expect(WalkingEstimate(metres: 90).distanceText(locale: us) == "300 ft")
}

@Test func walkingTimeIsAtAboutFiveKilometresAnHour() {
    #expect(WalkingEstimate(metres: 650).walkingMinutes == 8)
    #expect(WalkingEstimate(metres: 20).walkingMinutes == 1)
    #expect(WalkingEstimate(metres: 5_000).walkingMinutes == 60)
    #expect(WalkingEstimate(metres: 5_000).walkingText == "1 hr walk")
    #expect(WalkingEstimate(metres: 5_500).walkingText == "1 hr 6 min walk")
}

@Test func theCardLineMatchesTheMockupAndDropsTheWalkWhenItIsTooFar() {
    #expect(WalkingEstimate(metres: 650).summary(locale: metric) == "650 m from you · about 8 min walk")
    #expect(WalkingEstimate(metres: 25_000).summary(locale: metric) == "25.0 km from you")
}

@Test func distanceBetweenTwoCoordinatesIsGreatCircle() {
    // Yasaka Shrine to Kiyomizu-dera: about 1.1 km apart.
    let estimate = WalkingEstimate(
        from: GeoPoint(latitude: 35.0036, longitude: 135.7786),
        to: GeoPoint(latitude: 34.9949, longitude: 135.7850)
    )
    #expect(estimate.metres > 1_050 && estimate.metres < 1_150)
    #expect(estimate.distanceText(locale: metric) == "1.1 km")
    #expect(estimate.prefersWalkingDirections)
}

@Test func farPlacesGetDefaultRatherThanWalkingDirections() {
    #expect(WalkingEstimate(metres: 2_999).prefersWalkingDirections)
    #expect(!WalkingEstimate(metres: 3_001).prefersWalkingDirections)
}

// MARK: - Debug seed

#if DEBUG
@MainActor
@Test func debugSeedFillsAnEmptyStoreOnceWithRealCoordinates() throws {
    let context = try makeContext()
    ExploreDebugSeed.run(context: context)
    ExploreDebugSeed.run(context: context)

    let guides = try context.fetch(SharedGuide.fetchRequest())
    #expect(guides.count == 3)
    for guide in guides {
        #expect((5...12).contains(guide.allPlaces.count))
        #expect(GuideSummary.summarize(guide).region != nil)
        #expect(guide.allPlaces.contains { $0.isTried })
    }
    #expect(GuideSummary.all(guides, pinDates: [:]).first?.name == "Gion & Higashiyama")
}
#endif

// MARK: - Pinning

/// A context plus the pin API over its container's private store — the same
/// way `GuideListView` builds one from `\.explorePersistentContainer`.
@MainActor
private func makePins() throws -> (context: NSManagedObjectContext, pins: GuidePins) {
    let context = try makeContext()
    let container = try #require(objc_getAssociatedObject(context, &associatedContainerKey) as? NSPersistentCloudKitContainer)
    return (context, GuidePins(context: context, container: container))
}

@MainActor
private func pinRows(in context: NSManagedObjectContext) throws -> [GuidePin] {
    try context.fetch(GuidePin.fetchRequest())
}

@MainActor
@Test func pinnedGuidesComeFirstInTheOrderTheyWerePinned() throws {
    let (context, pins) = try makePins()
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    let oldest = SharedGuide(context: context, name: "Oldest")
    oldest.createdAt = base
    let middle = SharedGuide(context: context, name: "Middle")
    middle.createdAt = base.addingTimeInterval(100)
    let newest = SharedGuide(context: context, name: "Newest")
    newest.createdAt = base.addingTimeInterval(200)

    // Unpinned: newest first.
    #expect(GuideSummary.all([oldest, middle, newest], pinDates: GuidePins.pinDates(in: context)).map(\.name)
            == ["Newest", "Middle", "Oldest"])

    // Pin Oldest, then Middle: both jump above Newest, in the order pinned.
    pins.setPinned(true, oldest, asOf: base.addingTimeInterval(1_000))
    pins.setPinned(true, middle, asOf: base.addingTimeInterval(2_000))
    try context.save()
    let ordered = GuideSummary.all([newest, middle, oldest], pinDates: GuidePins.pinDates(in: context))
    #expect(ordered.map(\.name) == ["Oldest", "Middle", "Newest"])
    #expect(ordered.map(\.isPinned) == [true, true, false])
}

@MainActor
@Test func repinningKeepsTheOriginalDateAndUnpinningClearsIt() throws {
    let (context, pins) = try makePins()
    let guide = SharedGuide(context: context, name: "Kyoto")
    let first = Date(timeIntervalSince1970: 1_800_000_000)

    pins.setPinned(true, guide, asOf: first)
    pins.setPinned(true, guide, asOf: first.addingTimeInterval(500))
    #expect(pins.pinnedAt(for: guide) == first, "Pinning again must not move it behind later pins")
    #expect(try pinRows(in: context).count == 1)

    pins.setPinned(false, guide)
    #expect(pins.pinnedAt(for: guide) == nil)
    #expect(!pins.isPinned(guide))
}

@MainActor
@Test func pinningNeverTouchesTheGuideAndLandsInThePrivateStore() throws {
    let (context, pins) = try makePins()
    let guide = SharedGuide(context: context, name: "Kyoto")
    try context.save()

    pins.setPinned(true, guide)
    #expect(!guide.hasChanges, "A pin is its own record — the (possibly shared) guide must stay untouched")
    #expect(guide.pinnedAt == nil)
    try context.save()

    let pin = try #require(try pinRows(in: context).first)
    #expect(pin.guideIdentifier == guide.identifier)
    #expect(pin.objectID.persistentStore == pins.privateStore)
}

@MainActor
@Test func duplicatePinRowsOrderByTheEarliest() throws {
    let (context, pins) = try makePins()
    let base = Date(timeIntervalSince1970: 1_800_000_000)
    let kyoto = SharedGuide(context: context, name: "Kyoto")
    let soma = SharedGuide(context: context, name: "SoMa")
    pins.setPinned(true, soma, asOf: base.addingTimeInterval(200))
    // Two devices each pinned Kyoto before syncing: one before SoMa, one after.
    _ = GuidePin(context: context, guideIdentifier: kyoto.identifier, pinnedAt: base.addingTimeInterval(300))
    _ = GuidePin(context: context, guideIdentifier: kyoto.identifier, pinnedAt: base.addingTimeInterval(100))
    try context.save()

    let dates = GuidePins.pinDates(in: context)
    #expect(dates[kyoto.identifier] == base.addingTimeInterval(100))
    #expect(pins.pinnedAt(for: kyoto) == base.addingTimeInterval(100))
    #expect(GuideSummary.all([soma, kyoto], pinDates: dates).map(\.name) == ["Kyoto", "SoMa"])
}

@MainActor
@Test func unpinningRemovesEveryDuplicateRow() throws {
    let (context, pins) = try makePins()
    let guide = SharedGuide(context: context, name: "Kyoto")
    let other = SharedGuide(context: context, name: "SoMa")
    for offset in 0..<3 {
        _ = GuidePin(context: context, guideIdentifier: guide.identifier, pinnedAt: .now.addingTimeInterval(Double(offset)))
    }
    pins.setPinned(true, other)
    try context.save()

    pins.setPinned(false, guide)
    try context.save()
    #expect(!pins.isPinned(guide), "A surviving duplicate would re-pin it")
    #expect(try pinRows(in: context).map(\.guideIdentifier) == [other.identifier])
}

@MainActor
@Test func migratingRetiredPinsIsIdempotentAndClearsTheOldField() throws {
    let (context, pins) = try makePins()
    let pinnedAt = Date(timeIntervalSince1970: 1_800_000_000)
    let pinned = SharedGuide(context: context, name: "Kyoto")
    pinned.pinnedAt = pinnedAt
    let unpinned = SharedGuide(context: context, name: "SoMa")
    try context.save()
    #expect(pins.hasRetiredPinsToMigrate())

    pins.migrateRetiredPinnedAt()
    pins.migrateRetiredPinnedAt()

    let rows = try pinRows(in: context)
    #expect(rows.count == 1)
    #expect(rows.first?.guideIdentifier == pinned.identifier)
    #expect(rows.first?.pinnedAt == pinnedAt)
    #expect(pinned.pinnedAt == nil)
    #expect(!pins.isPinned(unpinned))
    #expect(!pins.hasRetiredPinsToMigrate())

    // Unpinned afterwards: running again (a later launch) must not revive it.
    pins.setPinned(false, pinned)
    try context.save()
    pins.migrateRetiredPinnedAt()
    #expect(try pinRows(in: context).isEmpty)
}

@MainActor
@Test func migratingARetiredPinKeepsAPinThatAlreadyExists() throws {
    let (context, pins) = try makePins()
    let guide = SharedGuide(context: context, name: "Kyoto")
    let earlier = Date(timeIntervalSince1970: 1_700_000_000)
    guide.pinnedAt = Date(timeIntervalSince1970: 1_800_000_000)
    // Another device already migrated it and that pin has synced in.
    _ = GuidePin(context: context, guideIdentifier: guide.identifier, pinnedAt: earlier)
    try context.save()

    pins.migrateRetiredPinnedAt()
    #expect(try pinRows(in: context).count == 1)
    #expect(pins.pinnedAt(for: guide) == earlier)
}

@MainActor
@Test func migratingRetiredPinsBackfillsMissingIdentifiersFirst() throws {
    let (context, pins) = try makePins()
    let guide = SharedGuide(context: context, name: "Kyoto", areaLabel: "Kyoto, Japan")
    guide.identifier = "" // As a guide from before the field existed arrives.
    guide.pinnedAt = Date(timeIntervalSince1970: 1_800_000_000)
    try context.save()

    pins.migrateRetiredPinnedAt()
    let expected = GuideIdentity.derived(name: "Kyoto", areaLabel: "Kyoto, Japan", createdAt: guide.createdAt)
    #expect(guide.identifier == expected)
    #expect(try pinRows(in: context).first?.guideIdentifier == expected)
}

// MARK: - Guide identity

@MainActor
@Test func newGuidesGetDistinctRandomIdentifiers() throws {
    let context = try makeContext()
    let first = SharedGuide(context: context, name: "Kyoto")
    let second = SharedGuide(context: context, name: "Kyoto")
    #expect(!first.identifier.isEmpty)
    #expect(first.identifier != second.identifier)
}

@Test func derivedIdentifiersDependOnlyOnContent() {
    let created = Date(timeIntervalSinceReferenceDate: 800_000_000.123_456)
    let identifier = GuideIdentity.derived(name: "Kyoto", areaLabel: "Kyoto, Japan", createdAt: created)

    // The same content always gives the same value — every device, every run.
    #expect(identifier == GuideIdentity.derived(name: "Kyoto", areaLabel: "Kyoto, Japan", createdAt: created))
    // CloudKit hands other devices the date to the millisecond only.
    let throughCloudKit = Date(timeIntervalSinceReferenceDate: 800_000_000.123)
    #expect(identifier == GuideIdentity.derived(name: "Kyoto", areaLabel: "Kyoto, Japan", createdAt: throughCloudKit))
    // A literal value, so a change to the derivation can't pass unnoticed —
    // it would re-key every backfilled guide on devices that haven't run yet.
    #expect(identifier == "derived-e3030801c2c33e2f76e2aa59239081947182fa004507a3b483c8d4ea49397163")

    #expect(identifier != GuideIdentity.derived(name: "Kyoto!", areaLabel: "Kyoto, Japan", createdAt: created))
    #expect(identifier != GuideIdentity.derived(name: "Kyoto", areaLabel: "Japan", createdAt: created))
    #expect(identifier != GuideIdentity.derived(name: "Kyoto", areaLabel: "Kyoto, Japan", createdAt: created + 1))
    // The separator keeps the fields apart: moving text across them changes it.
    #expect(GuideIdentity.derived(name: "ab", areaLabel: "c", createdAt: created)
            != GuideIdentity.derived(name: "a", areaLabel: "bc", createdAt: created))
}

@MainActor
@Test func backfillFillsOnlyEmptyIdentifiersAndIsIdempotent() throws {
    let (context, pins) = try makePins()
    let store = try #require(pins.privateStore)
    let old = SharedGuide(context: context, name: "Kyoto", areaLabel: "Kyoto, Japan")
    old.identifier = ""
    let current = SharedGuide(context: context, name: "SoMa")
    let currentIdentifier = current.identifier
    try context.save()

    // Before the backfill, pins already key to the value it will write.
    let expected = GuideIdentity.derived(name: "Kyoto", areaLabel: "Kyoto, Japan", createdAt: old.createdAt)
    #expect(GuidePins.key(for: old) == expected)

    GuideIdentity.backfill(in: context, store: store)
    GuideIdentity.backfill(in: context, store: store)
    #expect(old.identifier == expected)
    #expect(current.identifier == currentIdentifier)
}
