# The webhook — `StripeWebhookController`

This is the Stripe-to-Salesforce direction. The component and the trigger push changes *out* to Stripe; this endpoint takes Stripe's events and brings them *back* into Salesforce — recording gifts, keeping the Recurring Donations current, and closing or lapsing them when Stripe says so.

- Endpoint: `POST /services/apexrest/stripe/webhook`
- Class: `StripeWebhookController` (`global`, `@RestResource`, `@HttpPost handlePost`)
- Stripe API version: 2022-11-15

## Security and request handling

Every request gets its signature checked — the `Stripe-Signature` header, HMAC-SHA256 over `t.payload` using `Stripe_Settings__c.Webhook_Secret__c`. Two things to note there:

- It accepts more than one `v1` signature, so events keep validating while you're rotating the webhook secret.
- There's a 5-minute timestamp tolerance to cut down on replay attacks. (We skip that check under test.)

Responses:

- `200 {"received":true}` — handled, or it was an event type we don't care about.
- `400` — signature was missing/bad, or the timestamp was too old.
- `500` — something unexpected blew up.

Anything that isn't a 2xx makes Stripe retry the event on its own backoff, so a transient hiccup sorts itself out.

Loop prevention: for the length of the handler we set `setRecurringDonationSyncSuppressed(true)`, and every RD write goes through `updateRecurringDonationBypassed`. That means the RD updates the webhook makes don't re-fire `RecurringDonationTrigger`, so Stripe and Salesforce don't end up updating each other in circles.

One more thing: if the `sf_rd_id` or `sf_gau_id` metadata is malformed, we handle it quietly. We don't want a bad id to 500 the webhook, because then Stripe just retries it forever.

## The events we listen to

Set the Stripe endpoint (Dashboard → Developers → Webhooks) to send exactly these:

```
invoice.paid
invoice.payment_failed
customer.subscription.created
customer.subscription.updated
customer.subscription.deleted
```

Anything else comes back `200` and we ignore it.

## What happens per event

### `invoice.paid` — record the gift

1. Figure out the subscription from the invoice and fetch it from Stripe.
2. Work out whether Salesforce created it (`salesforceCreated`) from the subscription's `sf_created` metadata, and if it's not there, fall back to the *schedule's* metadata — future-start and fixed-gift subscriptions carry it on the schedule, not the subscription.
3. Scope check: if the subscription wasn't created by Salesforce, we skip it unless the RD already has a paid transaction — that way we only pick up the *later* charges on subs that originated elsewhere. Subs we created are always in scope, and if there's no RD yet we make one from the invoice.
4. Pin down the gateway payment id: try `payment_intent`, then `charge`, then the invoice id — first one that isn't blank.
5. Upsert the Opportunity (Closed Won). This is idempotent — we match first on `stripe_payment_id__c`, and if that misses, on (RD + close date + amount). Sets amount, close date, primary contact, account, campaign, and the receipt URLs.
6. Upsert the GAU allocation at 100%.
7. NPSP creates the Payment (`npe01__OppPayment__c`) off the Closed Won Opp (in production).
8. Update the RD's `Stripe_Receipt_URL__c` and `npe03__Last_Payment_Date__c`.

### `invoice.payment_failed`

Set the RD to Lapsed (`npsp__Status__c = 'Lapsed'`).

### `customer.subscription.created`

Create or sync the RD from the subscription. We match on `sf_rd_id` metadata first, then the pending schedule id, and if neither hits we make a new RD for the customer's linked Contact. There are guards so we don't end up with duplicate RDs on schedule-backed subs.

### `customer.subscription.updated`

Refresh the RD from the subscription. For most fields Stripe wins and we just overwrite: `npe03__Amount__c`, `npe03__Installment_Period__c`, `npsp__InstallmentFrequency__c`, `npsp__Day_of_Month__c`, `npe03__Next_Payment_Date__c`, `npsp__EndDate__c`, and the status.

Two fields we deliberately don't blow away:

- Payment method (`Stripe_Payment_Method_ID__c`) — only updated when the subscription actually comes back with a `default_payment_method`. If it doesn't (say the sub bills off the customer default), we leave what's there. We learned the hard way that renewals were nulling this out.
- GAU (`Stripe_GAU__c`) — only set when the RD doesn't already have one. If it's already filled in, we don't touch it.

Status mapping: `active` / `trialing` → Active; `past_due` / `unpaid` / `incomplete` → Lapsed; `canceled` / `incomplete_expired` → Closed. If the sub is paused (`pause_collection`), the RD goes to Paused.

### `customer.subscription.deleted`

RD → Closed (status plus `npsp__EndDate__c`).

## A renewal is two events, not one

When a monthly gift renews, Stripe fires both:

- `invoice.paid` — the new gift (Opp + Payment).
- `customer.subscription.updated` — the RD refresh (period rolled forward).

So an RD that already exists and has been gifted before both records the new gift *and* cleans up any stale Stripe fields on the same cycle.

## Config recap

1. `Stripe_Settings__c.Webhook_Secret__c` = the endpoint's signing secret (`whsec_...`).
2. Remote Site Setting for `https://api.stripe.com` — the webhook calls back to fetch the subscription/schedule. (Remote Site, not a Named Credential; the callout hardcodes the URL and sets its own auth header.)
3. The endpoint has to be publicly reachable. It's an Apex REST resource, so expose it through a **Site** and enable the `StripeWebhookController` class for that site's **guest user** (plus read/write on the objects/fields it writes). Stripe calls it with no Salesforce session — the signature check is what keeps it safe. Public URL: `https://<your-site-domain>/services/apexrest/stripe/webhook`.
4. Endpoint pinned to API version 2022-11-15, subscribed to the five events above.
5. We use the `Subscription` Opportunity record type for the gift Opp, falling back to `Donation` and then the org default.

## One caveat about the API version

The webhook reads `invoice.subscription`, `invoice.payment_intent`, and `invoice.charge` off the top level of the event, which is fine on 2022-11-15. If the account or endpoint ever gets bumped past the 2025 "basil" version, those fields move around (`invoice.parent.subscription_details.subscription`, and so on) and both those reads and the schedule `iterations` usage need another look.

Same events show up in the combined list in [SCENARIOS.md](./SCENARIOS.md) §E, and the overall architecture is in [README.md](./README.md).
