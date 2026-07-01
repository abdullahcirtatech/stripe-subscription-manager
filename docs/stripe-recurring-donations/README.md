# Stripe Subscription Manager

This is the component and Apex we use to run Stripe subscriptions from inside Salesforce and keep them lined up with NPSP Recurring Donations. Staff open a Contact or a Recurring Donation record and can start a recurring gift, change the amount or how often it charges, swap the card, pause it, or cancel it. Going the other way, Stripe sends us webhooks whenever a payment happens so the gift gets recorded and the donation record stays current.

## What's in it

| Type | Name | What it does |
|------|------|--------------|
| LWC | `stripeSubscriptionManager` | The UI. Works on both the Contact page and the Recurring Donation page, and can be dropped in as a record action. |
| Apex | `StripeSubscriptionController` | Everything the component calls — create, update, cancel, pause, resume, change the gift date, change the card — plus the three background jobs. If you're looking for the Stripe logic, it's here. |
| Apex | `StripeWebhookController` | The inbound endpoint (`/services/apexrest/stripe/webhook`). Takes Stripe events and writes them back into Salesforce. |
| Trigger | `RecurringDonationTrigger` | Catches when someone edits a Recurring Donation by hand and pushes that change out to Stripe (through the controller's background job). |
| Apex tests | `StripeSubscriptionControllerTest`, `StripeWebhookControllerTest` | Coverage. |
| Test util | `TestDataFactory` | Builds the test records. |

### What it depends on

There's a **Hierarchy** custom setting, `Stripe_Settings__c`, with three text fields. Set the Org Default value once it exists:

- `Secret_Key__c` — the Stripe secret key (`sk_...`). Text.
- `Publishable_Key__c` — the publishable key (`pk_...`). Text.
- `Webhook_Secret__c` — the webhook signing secret (`whsec_...`). Text.

`Stripe_Settings__c` itself isn't in this repo either — create the custom setting and its three fields before deploying, since the Apex reads `Stripe_Settings__c.getOrgDefaults()`.

Custom fields we added. None of these ship in this repo — you create them by hand (or from your own metadata) on a new org, and the exact types matter because the Apex references them by API name:

| Object | Field API name | Type | Notes |
|--------|----------------|------|-------|
| Contact | `Stripe_Customer_ID__c` | Text(255) | The donor's Stripe customer id. |
| Recurring Donation (`npe03__Recurring_Donation__c`) | `Stripe_Subscription_ID__c` | Text(255), External ID, **Unique** | The live subscription. |
| Recurring Donation | `Previous_Stripe_Subscription_ID__c` | Text(255) | The sub we retired after a gift-date change. |
| Recurring Donation | `Pending_Stripe_Schedule_ID__c` | Text(255) | A future-dated replacement schedule that hasn't started. |
| Recurring Donation | `Stripe_Payment_Method_ID__c` | Text(255) | The subscription's default payment method. |
| Recurring Donation | `Stripe_GAU__c` | Lookup → `npsp__General_Accounting_Unit__c` | GAU used for the gift allocations. |
| Recurring Donation | `Stripe_Receipt_URL__c` | URL (Text 255 works too) | Latest receipt URL. |
| Opportunity | `stripe_payment_id__c` | Text(255) | Gateway payment id — used as the idempotency key when recording gifts. |
| Opportunity | `Stripe_Recurring_Invoice__c` | URL | Stripe invoice / receipt URL. |
| Opportunity | `Stripe_receipt_url__c` | URL | Receipt URL. (Note the lowercase — it's a separate field from the RD one.) |

Field-level security matters: whoever uses the component (and the guest user that runs the webhook — see setup) needs read/write on these.

The stat tiles read three fields that NPSP already gives you, so there's nothing to create for those: `npe03__Paid_Amount__c` (total given), `npe03__Total_Paid_Installments__c` (installments so far), and `npsp__StartDate__c` (when it started).

NPSP has to be installed — we lean on Enhanced Recurring Donations (RD2), GAUs, Allocations, OppPayments, and the `npsp.Callable_API` for pause/resume. On the front end the card form loads Stripe.js (Payment Element + Address Element) from `https://js.stripe.com`. Everything runs against Stripe API version 2022-11-15.

## How it behaves

### It knows which record it's on

The component figures out which record page it's on from `getStateForRecord`. On a Contact it shows the admin view (cards + subscriptions + create); on a Recurring Donation it shows the manager view. Both are described below.

### The Contact view

This is the admin surface. It has three parts:

**Payment methods.** Lists every card on the Stripe customer with brand, last 4, and expiry. Each card has a **Set Default** button (unless it already is) and a **remove** icon (with a confirm — removing a card can break subscriptions relying on it). **Add Payment Method** opens the Stripe Payment Element + Address Element to save a new card; if the contact has no Stripe customer yet, one is created on first save. The customer id shows as "Will be created automatically" until then.

**Create subscription.** A short wizard: **Details** (amount, installment period — Monthly/Quarterly/Yearly/Weekly, gift type — Open-ended or Fixed, number of gifts if Fixed, optional start date, and a required GAU) → **Confirm** (a read-back of everything) → **Processing** → **Success** (which resets the form so you can add another). The card used is the one selected in the payment-methods list. See the Actions table for what each choice does in Stripe.

**Existing subscriptions.** One card per Stripe subscription with its status, amount, cadence, and a link to open the linked Recurring Donation. The available buttons depend on status:
- **Active** — Change Amount, Change Frequency, Change Billing Date, Set Fixed Gifts (convert an open gift to a fixed number), Change Payment Method, Pause, Cancel.
- **Paused** — Resume, Cancel.

A **Show Canceled** toggle opens a read-only history of canceled subscriptions (these can't be resumed). Each edit is an inline panel with its own confirm; the same Stripe/Salesforce effects as the Actions table apply.

> Most day-to-day editing is meant to happen on the **Recurring Donation** record (below). The Contact view is for setup, card management, and one-off subscription actions — it even tells you to "open the related recurring donation to make changes."

There's also a **Start a new donation** button (on a closed donation) that opens whatever you configured in the `newDonationUrl` / `newDonationFlowApiName` properties in a new tab; if neither is set it just warns.

### The Recurring Donation view

Up top there's the donor name, a one-line summary of the amount and cadence, a status badge (Active / Paused / Closed), a little "synced with Stripe" indicator, a refresh icon to re-pull from Stripe, and — when it's opened as a record action — a Close button.

Under that are four stat tiles: total given, installments to date, when it started, and the next charge (amount and date, pulled live from Stripe).

The amount, the frequency, and the next installment date each show as a row with a pencil. Click the pencil and you edit it right there, with a short preview or warning and a Save/Cancel. No multi-step wizard.

The payment method shows as a card. "Update payment method" opens an inline editor where you either pick a card already on file or add a new one through the Stripe Payment Element and Address Element (the card number never touches Salesforce). Pause, resume, and cancel are inline too.

### Where the Stripe customer comes from

On a Recurring Donation we don't read a customer id off the Contact. We look it up from the subscription or the schedule the RD points at (`resolveCustomerIdFromSubscription` / `resolveCustomerIdFromSchedule`). The linked Contact is only used to prefill the name and billing address.

### What each action actually does

| Action | Charges today? | In Stripe | In Salesforce |
|--------|----------------|-----------|---------------|
| Create subscription | An immediate subscription charges on creation; a future-start or fixed-count gift goes through a `subscription_schedule` instead | New price + subscription (or schedule) | Creates/links the RD (in a background job) |
| Change amount | No | Swaps in a new price with `proration_behavior=none`, leaves the cycle alone | Amount updated, takes effect next gift |
| Change frequency | Yes | New price at the new interval with `billing_cycle_anchor=now` | Cadence + next date updated; next charge is today plus one new interval |
| Change next installment date | No | Cancels the live sub and builds a future-dated `subscription_schedule` to replace it | Stores `Pending_Stripe_Schedule_ID__c` and `Previous_Stripe_Subscription_ID__c` |
| Update payment method | No | Sets the subscription's `default_payment_method` (the customer default is left alone) | Stores `Stripe_Payment_Method_ID__c` |
| Set Fixed Gifts | No | Switches the subscription to a fixed number of gifts (converts to a `subscription_schedule` with `end_behavior=cancel`) | RD `RecurringType = Fixed`, `Installments` set |
| Pause | No | `pause_collection[behavior]=void`, plus `resumes_at` if a date was given | NPSP pause; RD shows paused |
| Resume | No — collection picks back up on the next cycle | Clears `pause_collection` | NPSP unpause |
| Cancel | No | Cancels immediately (`DELETE`) | RD goes Closed with a reason, and the End Date is set carefully (see below) |

Once an RD is sitting on a pending schedule (after a date change), editing the amount, frequency, or card happens in place on that same schedule. But changing the date again means we cancel the schedule and build a new one — Stripe won't let you move the start date of a schedule that hasn't kicked off yet.

About that End Date: NPSP won't let you close an RD with an End Date that lands before its last Closed Won gift. So when we close one, we set the End Date to the day after the last won gift if that gift closed today or later, otherwise just today. That keeps the cancel from tripping the validation.

### Things worth knowing (assumptions and limits)

A few behaviors are baked in — worth knowing before you roll it out:

- **USD only.** The currency is hardcoded to `usd` on every create/update. There's no multi-currency support today; supporting another currency is a code change.
- **Gift-date editing is for active, month-based subscriptions.** You can only change the gift day on an **active** subscription with a Monthly/Quarterly cadence — Weekly and Yearly don't expose it (no meaningful "day of month"), and it's hidden on pending/paused/closed donations. The picker defaults to the day of the current next-charge date (days past the 28th show as "Last day").
- **Day-of-month is 1–28 or "Last day."** Days 29–31 aren't offered, to avoid short-month surprises. Picking a day always resolves to the next *future* occurrence.
- **Frequency editor caps at "every 12."** And it maps NPSP's period/frequency to Stripe's week/month/year (Quarterly = every 3 months).
- **Card entry is all client-side Stripe.js.** The Payment Element loads from `https://js.stripe.com/v3/` (hence the CSP requirement), digital wallets (Apple/Google Pay) are turned off, and 3-D Secure is handled through `confirmSetup` with redirect only if the bank requires it. Card data never reaches Salesforce.
- **Errors are surfaced, not swallowed.** Apex/validation errors (including NPSP page errors and field errors) are pulled out and shown as an error toast + inline message, so a failed action tells the user why.
- **Create is async.** The subscription/RD is built in a background job, so it appears a few seconds after you submit — use Refresh.

### The inbound webhook

`POST /services/apexrest/stripe/webhook`. Signature-verified, 5-minute timestamp tolerance, and it'll accept more than one `v1` signature (so nothing breaks mid-rotation).

| Event | What we do |
|-------|-----------|
| `invoice.paid` | Record the gift: a Closed Won Opportunity plus a GAU allocation, update the RD's receipt URL and last payment date. NPSP creates the Payment from the Opp. |
| `invoice.payment_failed` | Set the RD to Lapsed. |
| `customer.subscription.created` | Create or sync the RD from the subscription. |
| `customer.subscription.updated` | Refresh the RD (amount, cadence, next date, status). We only touch the payment method if Stripe hands one back, and we leave the GAU alone if the RD already has one. |
| `customer.subscription.deleted` | Close the RD. |

Heads up: a normal monthly renewal sends *both* `invoice.paid` (the gift) and `customer.subscription.updated` (the refresh).

The full webhook writeup — security, idempotency, retries, exactly which fields get written — is in [WEBHOOK.md](./WEBHOOK.md).

### Manual edits going the other way

If someone edits the RD's amount, period, frequency, gift day, next payment date, or status straight on the record, `RecurringDonationTrigger` picks it up and pushes it to Stripe through the controller. It's set up to match the component: amount changes don't charge, frequency changes charge now, and date edits get bumped to a real future date so Stripe doesn't reject them.

Details on the trigger — when it fires, what it sends, how we keep it from looping — are in [TRIGGER.md](./TRIGGER.md).

## Using it

1. Add **Stripe Subscription Manager** to a Contact and/or Recurring Donation Lightning record page, or wire it up as a record action. It targets `Contact` and `npe03__Recurring_Donation__c`.
2. There are two optional props — `newDonationUrl` and `newDonationFlowApiName` — for the link behind "Start a new donation."
3. On a Contact you manage cards and create subscriptions. On a Recurring Donation you edit the amount, frequency, next date, and card inline, and pause/resume/cancel.

## Setup checklist

Order matters — the Apex won't compile until the fields and the custom setting exist, so do 1–4 before you deploy.

1. **NPSP** installed with Enhanced Recurring Donations (RD2) turned on. That's where the `Paid_Amount` / `Total_Paid_Installments` / `StartDate` fields and the GAU/Allocation objects come from.
2. **Create the custom setting** `Stripe_Settings__c` (Hierarchy) and its three text fields (`Secret_Key__c`, `Publishable_Key__c`, `Webhook_Secret__c`).
3. **Create the custom fields** from the table above on Contact, Recurring Donation, and Opportunity — matching the API names and types exactly. Set field-level security so the running user (and later the webhook's guest user) can read/write them.
4. **Remote Site Setting** for `https://api.stripe.com`. The callouts hardcode that URL and set the auth header themselves, so it's a Remote Site — not a Named Credential.
5. **CSP Trusted Site** for `https://js.stripe.com` so the payment form can load Stripe.js.
6. **Deploy** the Apex, trigger, and LWC (see below).
7. **Fill in Stripe Settings** (Setup → Custom Settings → `Stripe_Settings__c` → Manage → New, Org Default): `Secret_Key__c`, `Publishable_Key__c`. (`Webhook_Secret__c` comes in step 9.)
8. **Make the webhook reachable.** `StripeWebhookController` is an Apex REST resource at `/services/apexrest/stripe/webhook`, and Stripe calls it with no Salesforce session — so it has to be exposed publicly:
   - Create a **Site** (Setup → Sites), or reuse an existing Force.com / Experience site.
   - In that site's guest-user access, enable the **`StripeWebhookController`** Apex class and give the guest user read/write on the custom fields and objects it touches (Opportunity, Recurring Donation, GAU allocation).
   - The public endpoint is then `https://<your-site-domain>/services/apexrest/stripe/webhook`.
   - This is safe without a login because the class verifies Stripe's HMAC signature on every request and rejects anything that doesn't match.
9. **Register the Stripe webhook** (Dashboard → Developers → Webhooks) pointing at that URL, subscribed to:
   ```
   invoice.paid
   invoice.payment_failed
   customer.subscription.created
   customer.subscription.updated
   customer.subscription.deleted
   ```
   Copy the endpoint's signing secret into `Webhook_Secret__c`, and keep the endpoint pinned to API version 2022-11-15.
10. Give the profiles/permission sets that use the component access to `StripeSubscriptionController`.

## Deploy and test

Do steps 1–5 of the setup checklist first — the classes reference the custom fields and `Stripe_Settings__c`, so the deploy fails to compile if those don't exist yet.

```bash
# Deploy
sf project deploy start --target-org <alias> \
  --metadata LightningComponentBundle:stripeSubscriptionManager \
  --metadata ApexClass:StripeSubscriptionController \
  --metadata ApexClass:StripeWebhookController \
  --metadata ApexTrigger:RecurringDonationTrigger

# Run tests
sf apex run test --target-org <alias> \
  --class-names StripeSubscriptionControllerTest StripeWebhookControllerTest \
  --code-coverage --result-format human
```

Last run: `StripeSubscriptionController` around 80%, `StripeWebhookController` 10/10.

For the exhaustive scenario-by-scenario breakdown see [SCENARIOS.md](./SCENARIOS.md). The inbound side is in [WEBHOOK.md](./WEBHOOK.md), and the manual-edit trigger is in [TRIGGER.md](./TRIGGER.md).
