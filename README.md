# Envelora

Group trip planning across India: plan a trip, seal it into a private **Clan**, then chat, split expenses and play games together.

Everything is in one file, `index.html` (HTML, CSS and vanilla JS, no frameworks). Open it in a browser to run it.

## Demo notes
- **Demo OTP:** `246810`. No SMS or email is actually sent.
- **Payments:** preview mode runs a simulated checkout, and nothing is charged. Set `CONFIG.razorpay.keyId` (public key id only) and provide the server endpoints to enable live Razorpay.
- **Data:** stored in this browser's localStorage under account-scoped keys (`envelora.v1.*`). Every fresh opening starts logged out.
- **Invites:** links work in the same browser until a backend exists. To try joining, open the link in a new tab.
- **Live location, photo cloud storage and cross-device realtime chat** are previews and are labelled as such in the UI.

## Integration points
Search `index.html` for `SUPABASE INTEGRATION POINT` and `RAZORPAY INTEGRATION POINT`. The planned Supabase schema (profiles, trips, trip_days, itinerary_items, clans, clan_members, messages, expenses, expense_splits, packing_items, photos, notifications, payments) is documented in a comment near the top of the script. Payment verification must happen server-side, so never ship the Razorpay secret to the browser.

## Launch mode
Packaged trips and managed trips are hidden by `body.launch-mode .launch-hidden`. Remove the `launch-mode` class from `<body>` to show them.
