# Scenarios

Every scenario the Stripe Subscription Manager supports and what it does on each side. Component is `stripeSubscriptionManager`, on the Contact and Recurring Donation record pages (or as a record action). Shorthand: RD = `npe03__Recurring_Donation__c`, Opp = Opportunity, PM = payment method.

Quick reminder on the Recurring Donation view: it shows the four stat tiles (total given, installments to date, when it started, next charge) and lets staff edit the amount, frequency, and next installment date inline by clicking the row, update the card inline, and pause/resume/cancel inline. Every one of these calls the same controller method the wizard would, so the Stripe and Salesforce effects are identical no matter how it was triggered. In this view the Stripe customer is looked up from the subscription or schedule, not from a Contact field.

## A. Payment methods (Contact view)

### A1. Add a card
- **UI:** *Add Payment Method* on the Contact, or *Update payment method → Add new card* on the RD. The Stripe Payment Element and Address Element collect the card and billing address, then *Save Card*.
- **Stripe:** a SetupIntent is created (`createSetupIntent`), the card is confirmed with `stripe.confirmSetup` and attached to the customer. It's only set as the customer default when it was added from the customer-level "Add Payment Method" button — not when you're adding it for one specific subscription.
- **Salesforce:** nothing directly, the card lives in Stripe. `Contact.Stripe_Customer_ID__c` gets created if the contact didn't have a Stripe customer yet.

### A2. Set default card
- **Stripe:** `invoice_settings.default_payment_method` on the customer.
- **Salesforce:** nothing.

### A3. Remove a card
- **Stripe:** the card is detached from the customer.
- **Salesforce:** nothing. (Worth a warning: any subscription counting on that card can fail unless another one is set.)

## B. Create a subscription (Contact view)

Creating runs in a background job, so the new subscription and RD show up a few seconds after you submit. Hit Refresh if you don't see it yet.

The wizard runs *Details* → *Confirm* → *Processing* → *Success*. Details collects amount, installment period (Monthly/Quarterly/Yearly/Weekly), gift type (Open-ended or Fixed), number of gifts when Fixed, an optional start date, and a required GAU; the card is whichever one is selected in the payment-methods list. "Create Subscription" stays disabled until amount, a card, and a GAU are set (plus a valid count when Fixed). Success resets the form for the next donation.

### B1. Immediate, open-ended
- **Stripe:** a new recurring Price plus a Subscription (`charge_automatically`), with metadata `sf_created=true`, `sf_rd_id`, `sf_gau_id`. First invoice charges right away.
- **Salesforce:** RD created/linked (`Stripe_Subscription_ID__c`), Active, amount and cadence set, GAU allocation created. The first gift Opp comes in through the `invoice.paid` webhook.

### B2. Future start date
- **Stripe:** a future-dated `subscription_schedule` — nothing charges until the start date.
- **Salesforce:** RD stores `Pending_Stripe_Schedule_ID__c`; `Stripe_Subscription_ID__c` stays null until the schedule activates.

### B3. Fixed number of gifts
- **Stripe:** a `subscription_schedule` with `end_behavior=cancel` and `iterations = installments`.
- **Salesforce:** RD `RecurringType = Fixed`, `Installments` set.

## C. Managing a live subscription (Recurring Donation view)

### C1. Change amount — no charge today
- **Stripe:** a new Price with the new amount goes into the subscription item, `proration_behavior=none`, billing cycle unchanged.
- **Salesforce:** RD amount updated. New amount kicks in on the next scheduled gift.

### C2. Change frequency — charges today
- **Stripe:** new Price at the new interval plus `billing_cycle_anchor=now`, so it invoices immediately and resets the cycle.
- **Salesforce:** RD installment period/frequency and next payment date updated. Next charge is today plus one new interval.
- **UI copy:** "This charges $X today and bills <cadence> after that (next charge <date>)."

### C3. Change gift date — no charge today
- **Stripe:** the current subscription is canceled and a future-dated replacement `subscription_schedule` is created for the day you picked (same card). The schedule is built with a **freshly minted price** mirroring the current amount/cadence rather than reusing the old price id — the old price may be archived in Stripe, and referencing an inactive price would fail with a 400.
- **Salesforce:** RD stores `Previous_Stripe_Subscription_ID__c` (the retired sub) and `Pending_Stripe_Schedule_ID__c` (the new schedule), and moves into the pending-schedule state.
- The day you pick resolves to the next future occurrence — never a date in the past.

### C4. Change the card
- **Stripe:** the card is attached (if it's new) and set as the *subscription's* `default_payment_method`. The customer default is left alone.
- **Salesforce:** `Stripe_Payment_Method_ID__c` stored.

### C5. Pause
- "Pause for N gifts" figures the resume date from cadence × N. "Resume on date" takes an explicit future date.
- **Stripe:** `pause_collection[behavior]=void` (plus `resumes_at` when you give a date).
- **Salesforce:** NPSP pause invoked; RD shows paused. Summary reads "Paused until <date>".

### C6. Resume
- **Stripe:** `pause_collection` cleared, collection restarts, next charge on the sub's next billing date.
- **Salesforce:** NPSP unpause; status goes back to Active (via the `subscription.updated` that comes along with it).
- **UI copy:** "Resume this donation now? The next gift is scheduled for <date>."

### C7. Cancel
- **Stripe:** subscription canceled immediately (`DELETE`).
- **Salesforce:** RD → Closed, `ClosedReason` set, and `EndDate` set to something later than the last Closed Won gift (day-after if a gift closed today) so the NPSP close validation passes.

### C8. Set Fixed Gifts (convert open → fixed)
- **Available on:** an Active subscription (Contact view, "Set Fixed Gifts").
- **Stripe:** switches to a `subscription_schedule` with `end_behavior=cancel` and the chosen number of gifts.
- **Salesforce:** RD `RecurringType = Fixed`, `Installments` set. No charge today.

### C9. Canceled-subscriptions history (read-only)
- **Contact view** has a **Show Canceled** toggle listing historical canceled subscriptions (status, amount, cadence, dates). These are informational only — a canceled subscription can't be resumed; you'd create a new one.

## D. Editing a pending schedule (after C3)

While the RD is sitting on a pending replacement schedule:

| Edit | What happens |
|------|--------------|
| Amount / Frequency / Payment method | Edited in place on the existing schedule — same `Pending_Stripe_Schedule_ID__c`, no charge. |
| Gift date | The schedule is canceled and a new one is created at the new date, so you get a new schedule id (Stripe won't move the start of a schedule that hasn't started). `Previous_Stripe_Subscription_ID__c` is kept. |
| Cancel the replacement | Schedule canceled in Stripe; RD → Closed with a reason and End Date. |

## E. Inbound webhook (Stripe → Salesforce)

`POST /services/apexrest/stripe/webhook`, signature-verified (5-minute tolerance, accepts multiple `v1` signatures).

### E1. `invoice.paid` (a successful charge or renewal)
- Records the gift: a Closed Won Opportunity plus a GAU allocation; RD receipt URL and last payment date updated; NPSP creates the Payment.
- **Scope check:** for a subscription Salesforce didn't create, the first invoice is skipped unless the RD already has a paid transaction. Subs we created (schedule-based included) are always in scope.

### E2. `invoice.payment_failed`
- RD → Lapsed.

### E3. `customer.subscription.created`
- RD created/synced from the subscription (matched by `sf_rd_id` / pending schedule id, or by customer).

### E4. `customer.subscription.updated`
- RD refreshed from Stripe: amount, installment period/frequency, day of month, next payment date, status, end date.
- The payment method is only updated when Stripe returns one — never blanked.
- The GAU is only filled when the RD has none; an existing one is never overwritten.
- A monthly renewal fires this alongside `invoice.paid`, so the RD tidies itself up each cycle.

### E5. `customer.subscription.deleted`
- RD → Closed (status and end date).

Any other event → `200 {"received":true}`, ignored.

## F. Manual RD edits (Salesforce → Stripe)

Editing the RD record directly fires `RecurringDonationTrigger`, which pushes to Stripe in the background:

| What changed | Action | Result |
|--------------|--------|--------|
| Amount only | `updateSubscription` | No charge — we correctly detect the interval didn't change. |
| Installment period / frequency / type / installments | `updateSubscription` | Charges today (cycle reset), same as the component's frequency change. |
| Day of month / next payment date | `updateSubscriptionGiftDay` | Replacement schedule for a safe future date — a past or today date is rolled forward so it doesn't silently fail. |
| Status → Closed | `cancelSubscription` | Subscription canceled; RD close finalized with an End Date. |

Loop prevention: the controller's writes use a trigger-bypass flag, and the webhook suppresses the trigger while it runs, so updates don't bounce back and forth between Stripe and Salesforce.

## G. Edge cases worth knowing

- Creating a subscription is async, so the new data shows up after the background job runs — use Refresh.
- A renewal is two events: `invoice.paid` (gift) and `customer.subscription.updated` (RD refresh).
- **USD only** — currency is hardcoded; another currency is a code change.
- **Gift-date editing is for active Monthly/Quarterly subscriptions** — Weekly/Yearly don't expose a day-of-month, and the row is hidden on pending/paused/closed donations. The day picker defaults to the current next-charge date (days past the 28th show as "Last day").
- **Day-of-month choices are 1–28 or "Last day"**, and always resolve to the next future occurrence.
- **Frequency editor caps at "every 12"** and maps to Stripe's week/month/year (Quarterly = every 3 months).
- **Card entry is client-side Stripe.js** from `js.stripe.com/v3/` (wallets off; 3-D Secure via `confirmSetup` redirect only if the bank requires it); card data never reaches Salesforce.
- Apex/NPSP errors (page errors, field errors) are surfaced to the user as a toast + inline message.
- The Contact modal's "Stop at Period End" cancel (`atPeriodEnd=true`) currently closes the RD right away even though Stripe keeps the sub active until period end. Minor — the RD wizard always cancels immediately anyway.
- API version: the reads use top-level `invoice.subscription` / `payment_intent` / `charge`, which are valid on 2022-11-15. If the account or endpoint gets upgraded past the 2025 "basil" version, those reads and the schedule `iterations` usage need revisiting.
