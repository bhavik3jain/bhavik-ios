# App Store submission kit

Everything App Store Connect asks for that isn't in the code, ready to paste. Nothing here is needed
for TestFlight's internal testing, which has no review; external TestFlight testing and a public
release both go through App Review.

- `privacy-policy.md` (beside this file) is the privacy policy. The app bundles this same file and
  shows it under Settings › Privacy Policy, so edit it here and both stay in step. App Store Connect
  wants a **URL** for it as well: publish the file as a web page somewhere public (a page on
  thebhavikjain.com, GitHub Pages, a public gist) and paste that link into **App Privacy › Privacy
  Policy URL**. Update the "Effective" date whenever it changes.
- `App/Resources/PrivacyInfo.xcprivacy` is the privacy manifest. It's checked on every upload,
  TestFlight included.

## 1. App Review Information

**Sign-in required:** No. (There are no accounts.)

**Contact information:** your name, phone and multitrack@thebhavikjain.com.

**Notes:** paste the block below (App Store Connect allows 4,000 characters; this is about 2,800).
Replace `[REVIEW TMDB KEY]` first. See "The TMDB key" below for why that's safe and how to make one.

```text
Multitrack is a personal organizer: eight trackers (Trips, Explore, Gym, TV, Orders, Fuel, Points, Finance) behind one home screen. There is no sign-in. Everything is stored on the device and in the user's own iCloud account (CloudKit private database). The developer runs no server and receives no user data.

GETTING STARTED
The app opens empty. Tap a tracker on the home screen, then + to add something. The gear on the home screen opens Settings, where trackers can be hidden and reordered (Customize Trackers).

TV - OPTIONAL TMDB KEY
Show and film search, episode lists and artwork come from The Movie Database (TMDB), using the user's own free TMDB API key. To try it: TV > Watching > gear icon > TV Settings, and paste this key, made for this review only:
[REVIEW TMDB KEY]
Without a key, shows and films can still be added and tracked by hand.

ORDERS - OPTIONAL FEDEX CREDENTIALS
FedEx orders can update on their own with the user's own FedEx developer API key and secret (Orders > Settings). We can't share credentials for that account. Without them, every order is tracked by hand: tap an order to open the carrier's own tracking page in an in-app browser, then set its status. To try it, add an order with a UPS-format number such as 1Z999AA10123456784.

SHARING
Trips, guides, vehicles, TV watch lists and the Points and Finance households can be shared with another iCloud account through CloudKit sharing (the Share button on each). Accepting a share needs a second Apple Account.

FINANCE
A manual net-worth and budget tracker: the user types in their own balances and transactions. It doesn't connect to banks, move money, trade or give financial advice. It shows live gold and silver prices to value metal the user records.

APPLE INTELLIGENCE
On devices with Apple Intelligence, Trips (Review Plan, Suggest Places) and Finance (a month's written review, and "Ask about <month>") use the on-device Foundation Models framework. The app's own code works out every figure and finding; the model only ranks and words them. Any reply carrying a number not in the user's own figures is replaced, and questions asking for investment advice are declined. Nothing is sent off the device for this. It can be turned off in Settings > Apple Intelligence.

PERMISSIONS
Location: asked only when a guide's map or a trip's Nearby list opens, to show distances. Notifications: asked only when the user turns on a reminder or alert (Finance's monthly reminder, TV's new-episode alerts) or shares something. The app never asks at launch.

MAC
The Mac app's Finance > Export to Numbers fills a spreadsheet in Apple's Numbers app through Apple events. It runs only when the user chooses it, and macOS asks for Automation permission first. See the App Sandbox notes for the entitlement it needs.
```

**Attachment (optional):** a short screen recording of the TV and Orders flows saves a round trip if
the reviewer can't get them working.

## 2. The TMDB key

You don't hand the reviewer your own key, and the risk of handing them a review key is small:

- A TMDB API key only reads TMDB's public film and TV data. It can't spend money, can't see your
  TMDB account's lists or ratings, and isn't tied to anything in Multitrack or App Store Connect.
- The worst case is someone else using it and running into TMDB's rate limit, which only affects
  that key. Deleting or regenerating it ends that.
- Review notes are visible to Apple and to people on your App Store Connect team, not to the public.

So: make a **separate free TMDB account just for App Review** (themoviedb.org › Settings › API),
paste its key into the notes, and regenerate or delete it once the build is approved. Never put in
review notes, or anywhere else, credentials that cost money or control something: your own FedEx
key and secret, the App Store Connect API key (`.p8`), iCloud passwords.

FedEx is different: its credentials belong to your own FedEx developer account and project, so they
stay with you. The notes say plainly that they can't be shared, and show the reviewer the manual
path instead.

## 3. App Sandbox information (Mac only)

For the macOS version, App Store Connect asks you to justify each temporary-exception entitlement.
There's one, `com.apple.security.temporary-exception.apple-events` for `com.apple.Numbers`. Paste:

```text
Finance > Export to Numbers fills the user's own budget spreadsheet in Apple's Numbers app: it opens a copy of the template bundled with the app, grows its tables to the month's transactions and types in the figures. It only targets com.apple.Numbers, only runs when the user chooses Export to Numbers, and macOS asks for Automation permission before the first export. Numbers publishes no scripting access groups, so a com.apple.security.scripting-targets entitlement can't be used instead. Without this exception, every Apple event to Numbers fails with -1743.
```

Before relying on "publishes no scripting access groups", check the current Numbers on a Mac:
`sdef /Applications/Numbers.app | grep -i access-group`. If it prints any, a `scripting-targets`
entitlement (permanent, no exception) may replace this one.

Apple's DTS engineers say App Review rarely approves temporary exceptions. If it's refused, the
options are: ship the Mac App Store build without Export to Numbers (the Python route in
`scripts/finance/` still works), or rework the export as a script attachment (`NSUserScriptTask`
running a script the user places in the app's Application Scripts folder), which needs no
exception. You can also ask App Review in advance through a "Meet with Apple" consultation.

## 4. App Privacy questionnaire

Answer **"No, we do not collect data from this app"** (Data Not Collected). Apple counts data as
collected when it leaves the device in a form the developer or its partners can keep beyond the
request itself. The answer is yours to give; this is the reasoning for it:

- Everything the person enters goes to their own iCloud account, which the developer can't read.
- TMDB and FedEx get search titles and tracking numbers under the person's **own** API keys:
  those are the person's own accounts with those services, not partners of the app.
- The gold and silver price request carries nothing about the person.
- Apple Weather and Apple Maps requests are Apple's own services, used through Apple's frameworks.
- There's no analytics, advertising or crash-reporting SDK, and no tracking.

The manifest's `NSPrivacyCollectedDataTypes` is empty to match. If any of this changes (an
analytics SDK, a server of your own, a shared API key the developer controls), revisit both.

## 5. Other questions App Store Connect asks

- **Export compliance:** already answered by `ITSAppUsesNonExemptEncryption = NO` in both
  Info.plists (HTTPS only).
- **Third-party content:** Yes. TV shows TMDB's metadata and artwork through TMDB's API, with
  TMDB's attribution in TV Settings and on each show and film.
- **Age rating:** nothing objectionable. For "Unrestricted Web Access", No: the in-app browser
  only opens a carrier's tracking page for an order.
- **Category:** Productivity (the Mac target already declares it).

## 6. Before you submit

- [ ] Privacy policy published at a public URL, and that URL in App Store Connect.
- [ ] A review-only TMDB key made and pasted into the notes.
- [ ] Screenshots for each platform you ship (iPhone; Mac if releasing the Mac app).
- [ ] The Mac App Sandbox justification pasted, if the Mac app is going too.
- [ ] Gold and silver prices: the app reads Yahoo Finance's chart endpoint, which is public but
      undocumented, and Yahoo's terms don't grant permission for it (guideline 5.2.2). Consider a
      licensed price source before a public release.
