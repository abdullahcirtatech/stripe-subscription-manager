# The trigger — `RecurringDonationTrigger`

This handles the Salesforce-to-Stripe direction for manual edits. When someone changes a Recurring Donation on the record itself — not through the component — this trigger notices and pushes the change out to Stripe so the subscription doesn't drift from what staff just changed. It's the mirror image of the [webhook](./WEBHOOK.md), which handles the other direction.

- Runs on `npe03__Recurring_Donation__c`, `after update`
- Does the actual work in `StripeSubscriptionController.RecurringDonationSyncJob` (a Queueable), which calls `processRecurringDonationSyncRequest`

## When it fires

For each updated RD, it only acts if all of these are true:

- it's an update (not an insert or delete),
- we're not in a test (`Test.isRunningTest()` bails out early),
- sync isn't suppressed (`StripeSubscriptionController.isRecurringDonationTriggerSuppressed()` is false), and
- the row has both a `Stripe_Subscription_ID__c` and a Contact.

The suppress check is the important one. Anything the controller or the webhook writes goes through `updateRecurringDonationBypassed`, which flips the suppress flag, so the trigger skips those writes. Only a real person editing the record gets through. That's what stops Stripe and Salesforce from bouncing updates back and forth forever.

## What it looks at, and what it sends

For each changed row the trigger builds one or more `RecurringDonationSyncRequest`s, drops them into a single `RecurringDonationSyncJob`, and the job runs `processRecurringDonationSyncRequest` on each one.

| What changed on the RD | Action | Controller call | Result |
|------------------------|--------|-----------------|--------|
| `npsp__Status__c` → Closed | `cancel` | `cancelSubscription(atPeriodEnd=false, closeReason)` | Cancels the subscription in Stripe right away and finishes closing the RD (End Date handled). This wins — if the row is being closed, nothing else gets queued for it. |
| `npe03__Amount__c` | `amount_frequency` | `updateSubscription(amount, period, freq, type, installments)` | Amount only means no charge today. We figure out the interval hasn't changed by normalizing it first, so an amount edit doesn't accidentally trigger a charge. |
| `npe03__Installment_Period__c` / `npsp__InstallmentFrequency__c` / `npsp__RecurringType__c` / `npe03__Installments__c` | `amount_frequency` | same call | Cadence changed, so it charges today and resets the cycle — same as hitting "change frequency" in the component. |
| `npsp__Day_of_Month__c` / `npe03__Next_Payment_Date__c` | `gift_day` | `updateSubscriptionGiftDay(safe future date)` | Builds a future-dated replacement `subscription_schedule`, no charge. A past or today date gets rolled forward to the next valid day so Stripe doesn't reject it. |

A couple of things worth knowing:

- One save that touches several fields can queue both an `amount_frequency` and a `gift_day` request. They're handled separately.
- If the save closes the RD, that's all that happens — the cancel short-circuits everything else on the row.

## It matches the component

A manual edit lands the same way the equivalent button in `stripeSubscriptionManager` would:

- Amount → no charge, new amount next gift.
- Frequency / period / type / installments → charges today, resets the cycle.
- Gift day / next date → replacement schedule on a safe future date.
- Status → Closed → immediate cancel with a safe End Date.

## When something goes wrong

The push runs in a Queueable *after* the RD save has already committed, so:

- The user's save always goes through first. The Stripe call happens right after, asynchronously.
- If the Stripe side fails inside the job, it's logged — the job doesn't undo the RD save. The [webhook](./WEBHOOK.md) will bring the RD back in line off Stripe on the next event anyway.
- `gift_day` never ships a past-or-today date (it's rolled forward first), so you don't hit the "must be in the future" error.

Architecture is in [README.md](./README.md), the inbound direction is in [WEBHOOK.md](./WEBHOOK.md), and the manual-edit scenarios are in [SCENARIOS.md](./SCENARIOS.md) §F.
