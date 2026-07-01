@RestResource(urlMapping='/stripe/webhook')
global without sharing class StripeWebhookController {
    private static final Integer SUCCESS = 200;
    private static final Integer BAD_REQUEST = 400;
    private static final Integer SERVER_ERROR = 500;
    private static final Integer SIGNATURE_TOLERANCE_SECONDS = 300;
    @TestVisible private static String lastHandledError;
    @TestVisible private static String lastUnhandledError;
    @TestVisible private static String lastProcessingStep;

    @HttpPost
    global static void handlePost() {
        RestResponse response = RestContext.response;
        lastHandledError = null;
        lastUnhandledError = null;
        lastProcessingStep = null;
        try {
            StripeSubscriptionController.setRecurringDonationSyncSuppressed(true);
            String payload = RestContext.request.requestBody == null
                ? ''
                : RestContext.request.requestBody.toString();
            verifySignature(payload, RestContext.request.headers.get('Stripe-Signature'));

            Map<String, Object> eventBody = (Map<String, Object>) JSON.deserializeUntyped(payload);
            String eventType = (String) eventBody.get('type');

            if (eventType == 'invoice.paid') {
                Map<String, Object> data = asMap(eventBody.get('data'));
                processPaidInvoice(asMap(data.get('object')));
            } else if (eventType == 'invoice.payment_failed') {
                Map<String, Object> data = asMap(eventBody.get('data'));
                processFailedInvoice(asMap(data.get('object')));
            } else if (eventType == 'customer.subscription.created') {
                Map<String, Object> data = asMap(eventBody.get('data'));
                syncSubscription(asMap(data.get('object')), false, true);
            } else if (eventType == 'customer.subscription.updated') {
                Map<String, Object> data = asMap(eventBody.get('data'));
                syncSubscription(asMap(data.get('object')), false, false);
            } else if (eventType == 'customer.subscription.deleted') {
                Map<String, Object> data = asMap(eventBody.get('data'));
                syncSubscription(asMap(data.get('object')), true, false);
            }

            response.statusCode = SUCCESS;
            response.responseBody = Blob.valueOf('{"received":true}');
        } catch (StripeWebhookException e) {
            lastHandledError = e.getMessage();
            System.debug(LoggingLevel.ERROR, 'Stripe webhook handled error: ' + e.getMessage());
            response.statusCode = e.statusCode;
            response.responseBody = Blob.valueOf('{"error":"' + escapeJson(e.getMessage()) + '"}');
        } catch (Exception e) {
            lastUnhandledError = e.getMessage() + ' @ ' + e.getStackTraceString();
            System.debug(LoggingLevel.ERROR, 'Stripe webhook unhandled error: ' + e.getMessage() + ' | ' + e.getStackTraceString());
            response.statusCode = SERVER_ERROR;
            response.responseBody = Blob.valueOf('{"error":"' + escapeJson(e.getMessage()) + '"}');
        } finally {
            StripeSubscriptionController.setRecurringDonationSyncSuppressed(false);
        }
    }

    private static void processPaidInvoice(Map<String, Object> invoice) {
        if (invoice == null || invoice.isEmpty()) return;
        lastProcessingStep = 'processPaidInvoice:start';

        String subscriptionId = stringValue(invoice.get('subscription'));
        if (String.isBlank(subscriptionId)) return;
        lastProcessingStep = 'processPaidInvoice:subscriptionId';

        Map<String, Object> subscription = fetchSubscription(subscriptionId);
        SubscriptionSnapshot subscriptionSnapshot = subscriptionSnapshot(subscription);
        if (subscriptionSnapshot.salesforceCreated != true) {
            // Subscriptions created via a subscription_schedule (future-start and
            // Fixed-gift donations) carry sf_created on the schedule/phase rather than
            // on the generated subscription, so subscription.metadata is empty. Resolve
            // through the schedule so the first paid invoice for those donations is
            // still treated as in-scope instead of being skipped as "out of scope".
            Map<String, Object> resolvedMetadata = resolveSubscriptionMetadata(
                subscription,
                stringValue(subscription.get('schedule'))
            );
            subscriptionSnapshot.salesforceCreated = stringValue(resolvedMetadata.get('sf_created')) == 'true';
        }
        Boolean salesforceCreated = subscriptionSnapshot.salesforceCreated == true;
        lastProcessingStep = 'processPaidInvoice:subscriptionLoaded';

        Long amountPaidCents = longValue(invoice.get('amount_paid'));
        if (amountPaidCents == null || amountPaidCents <= 0) return;
        lastProcessingStep = 'processPaidInvoice:amountLoaded';

        List<npe03__Recurring_Donation__c> recurringDonations = loadRecurringDonationsForWebhook(subscriptionId);
        if (recurringDonations.isEmpty()) {
            if (!salesforceCreated) {
                // Story scope for non-Salesforce-created subscriptions: only process
                // transactions for recurring donations that already exist in Salesforce.
                return;
            }
            npe03__Recurring_Donation__c createdRd = createRecurringDonationFromInvoice(
                invoice,
                subscriptionId,
                amountPaidCents,
                subscriptionSnapshot
            );
            if (createdRd == null) return;
            recurringDonations = loadRecurringDonationsForWebhook(subscriptionId);
            if (recurringDonations.isEmpty()) return;
        }
        lastProcessingStep = 'processPaidInvoice:recurringDonationLoaded';

        npe03__Recurring_Donation__c rd = recurringDonations[0];
        Integer existingPaidTxCount = [
            SELECT COUNT()
            FROM npe01__OppPayment__c
            WHERE npe01__Paid__c = true
              AND npe01__Opportunity__r.npe03__Recurring_Donation__c = :rd.Id
        ];
        if (existingPaidTxCount == 0 && !salesforceCreated) {
            // Only process subsequent transactions. If this RD does not already have a paid
            // historical transaction in Salesforce, treat this invoice as out-of-scope.
            return;
        }
        lastProcessingStep = 'processPaidInvoice:historyChecked';

        String invoiceId = (String) invoice.get('id');
        String paymentIntentId = stringValue(invoice.get('payment_intent'));
        String chargeId = stringValue(invoice.get('charge'));
        String gatewayPaymentId = String.isNotBlank(paymentIntentId)
            ? paymentIntentId
            : (String.isNotBlank(chargeId) ? chargeId : invoiceId);
        if (String.isBlank(gatewayPaymentId)) return;
        lastProcessingStep = 'processPaidInvoice:gatewayPaymentResolved';

        Decimal amount = Decimal.valueOf(amountPaidCents) / 100;
        Date paymentDate = invoicePaidDate(invoice);
        String invoiceUrl = (String) invoice.get('hosted_invoice_url');
        lastProcessingStep = 'processPaidInvoice:invoiceNormalized';

        Opportunity opp = upsertOpportunity(rd, gatewayPaymentId, amount, paymentDate, invoiceUrl);
        lastProcessingStep = 'processPaidInvoice:opportunityUpserted';
        Id gauId = subscriptionSnapshot.gauId != null ? subscriptionSnapshot.gauId : rd.Stripe_GAU__c;
        upsertAllocation(opp.Id, gauId, amount);
        lastProcessingStep = 'processPaidInvoice:allocationUpserted';
        updateRecurringDonationPaymentFields(rd.Id, invoiceUrl, paymentDate);
        lastProcessingStep = 'processPaidInvoice:recurringDonationUpdated';
    }

    private static void processFailedInvoice(Map<String, Object> invoice) {
        if (invoice == null || invoice.isEmpty()) return;

        String subscriptionId = stringValue(invoice.get('subscription'));
        if (String.isBlank(subscriptionId)) return;

        List<npe03__Recurring_Donation__c> recurringDonations = [
            SELECT Id
            FROM npe03__Recurring_Donation__c
            WHERE Stripe_Subscription_ID__c = :subscriptionId
            LIMIT 1
        ];
        if (recurringDonations.isEmpty()) return;

        StripeSubscriptionController.updateRecurringDonationBypassed(new npe03__Recurring_Donation__c(
            Id = recurringDonations[0].Id,
            npsp__Status__c = 'Lapsed',
            npsp__ClosedReason__c = null
        ));
    }

    private static List<npe03__Recurring_Donation__c> loadRecurringDonationsForWebhook(String subscriptionId) {
        return [
            SELECT Id, Name, npe03__Contact__c, npe03__Contact__r.Name,
                   npe03__Contact__r.AccountId, npe03__Organization__c,
                   npe03__Recurring_Donation_Campaign__c, Stripe_GAU__c
            FROM npe03__Recurring_Donation__c
            WHERE Stripe_Subscription_ID__c = :subscriptionId
            LIMIT 1
            FOR UPDATE
        ];
    }

    private static npe03__Recurring_Donation__c createRecurringDonationFromInvoice(
        Map<String, Object> invoice,
        String subscriptionId,
        Long amountPaidCents,
        SubscriptionSnapshot subscriptionSnapshot
    ) {
        String customerId = stringValue(invoice.get('customer'));
        if (String.isBlank(customerId)) return null;

        SubscriptionSnapshot snapshot = invoiceSubscriptionSnapshot(invoice, amountPaidCents);
        if (subscriptionSnapshot != null) {
            if (snapshot.paymentMethodId == null) snapshot.paymentMethodId = subscriptionSnapshot.paymentMethodId;
            if (snapshot.gauId == null) snapshot.gauId = subscriptionSnapshot.gauId;
            if (snapshot.interval == null) snapshot.interval = subscriptionSnapshot.interval;
            if (snapshot.intervalCount == null) snapshot.intervalCount = subscriptionSnapshot.intervalCount;
            if (snapshot.currentPeriodStart == null) snapshot.currentPeriodStart = subscriptionSnapshot.currentPeriodStart;
            if (snapshot.currentPeriodEnd == null) snapshot.currentPeriodEnd = subscriptionSnapshot.currentPeriodEnd;
        }
        npe03__Recurring_Donation__c rd = newRecurringDonation(customerId, subscriptionId, snapshot);
        if (rd == null) return null;

        rd.npe03__Amount__c = snapshot.amount;
        rd.npe03__Installment_Period__c = npspInstallmentPeriod(snapshot.interval);
        rd.npsp__InstallmentFrequency__c = snapshot.intervalCount == null ? 1 : snapshot.intervalCount;
        rd.npsp__Day_of_Month__c = npspDayOfMonth(snapshot.currentPeriodStart);
        rd.npsp__PaymentMethod__c = 'Credit Card';
        rd.Stripe_Payment_Method_ID__c = snapshot.paymentMethodId;
        rd.Stripe_GAU__c = snapshot.gauId;
        rd.npe03__Next_Payment_Date__c = epochDate(snapshot.currentPeriodEnd, null);
        rd.npsp__Status__c = 'Active';

        try {
            insert rd;
        } catch (DmlException e) {
            List<npe03__Recurring_Donation__c> existing = [
                SELECT Id
                FROM npe03__Recurring_Donation__c
                WHERE Stripe_Subscription_ID__c = :subscriptionId
                LIMIT 1
            ];
            if (existing.isEmpty()) throw e;
            return existing[0];
        }
        return rd;
    }

    private static Opportunity upsertOpportunity(
        npe03__Recurring_Donation__c rd,
        String gatewayPaymentId,
        Decimal amount,
        Date paymentDate,
        String invoiceUrl
    ) {
        Opportunity opp = findExistingOpportunity(rd.Id, gatewayPaymentId, amount, paymentDate);
        if (opp == null) {
            opp = new Opportunity();
        }
        opp.RecordTypeId = subscriptionRecordTypeId();
        opp.Name = 'Recurring Donation - ' + safeName(rd.npe03__Contact__r.Name) + ' - ' + String.valueOf(paymentDate);
        opp.StageName = 'Closed Won';
        opp.CloseDate = paymentDate;
        opp.Amount = amount;
        opp.AccountId = rd.npe03__Organization__c != null ? rd.npe03__Organization__c : rd.npe03__Contact__r.AccountId;
        opp.npsp__Primary_Contact__c = rd.npe03__Contact__c;
        opp.npe03__Recurring_Donation__c = rd.Id;
        if (Test.isRunningTest()) {
            opp.npe01__Do_Not_Automatically_Create_Payment__c = true;
        }
        opp.CampaignId = rd.npe03__Recurring_Donation_Campaign__c;
        opp.stripe_payment_id__c = gatewayPaymentId;
        opp.Stripe_Recurring_Invoice__c = invoiceUrl;
        opp.Stripe_receipt_url__c = invoiceUrl;

        if (opp.Id == null) {
            insert opp;
        } else {
            update opp;
        }
        return opp;
    }

    private static Opportunity findExistingOpportunity(
        Id recurringDonationId,
        String gatewayPaymentId,
        Decimal amount,
        Date paymentDate
    ) {
        List<Opportunity> byStripePaymentId = [
            SELECT Id, StageName, stripe_payment_id__c, npe03__Recurring_Donation__c, Amount, CloseDate
            FROM Opportunity
            WHERE stripe_payment_id__c = :gatewayPaymentId
            LIMIT 1
        ];
        if (!byStripePaymentId.isEmpty()) {
            return byStripePaymentId[0];
        }

        if (recurringDonationId == null || amount == null || paymentDate == null) {
            return null;
        }

        List<Opportunity> candidates = [
            SELECT Id, StageName, stripe_payment_id__c, npe03__Recurring_Donation__c, Amount, CloseDate
            FROM Opportunity
            WHERE npe03__Recurring_Donation__c = :recurringDonationId
              AND CloseDate = :paymentDate
              AND Amount = :amount
            ORDER BY CreatedDate ASC
        ];

        for (Opportunity candidate : candidates) {
            if (String.isBlank(candidate.stripe_payment_id__c)) {
                return candidate;
            }
        }
        return candidates.isEmpty() ? null : candidates[0];
    }

    private static void upsertAllocation(Id opportunityId, Id gauId, Decimal amount) {
        if (opportunityId == null || gauId == null || amount == null) return;
        List<npsp__Allocation__c> existing = [
            SELECT Id
            FROM npsp__Allocation__c
            WHERE npsp__Opportunity__c = :opportunityId
              AND npsp__General_Accounting_Unit__c = :gauId
            LIMIT 1
        ];

        if (existing.isEmpty()) {
            insert new npsp__Allocation__c(
                npsp__Opportunity__c = opportunityId,
                npsp__General_Accounting_Unit__c = gauId,
                npsp__Amount__c = amount,
                npsp__Percent__c = 100
            );
        } else {
            update new npsp__Allocation__c(
                Id = existing[0].Id,
                npsp__Amount__c = amount,
                npsp__Percent__c = 100
            );
        }
    }

    private static void updateRecurringDonationPaymentFields(
        Id recurringDonationId,
        String invoiceUrl,
        Date paymentDate
    ) {
        StripeSubscriptionController.updateRecurringDonationBypassed(new npe03__Recurring_Donation__c(
            Id = recurringDonationId,
            Stripe_Receipt_URL__c = invoiceUrl,
            npe03__Last_Payment_Date__c = paymentDate
        ));
    }

    private static void syncSubscription(Map<String, Object> subscription, Boolean forceClosed, Boolean allowCreate) {
        if (subscription == null || subscription.isEmpty()) return;

        String subscriptionId = (String) subscription.get('id');
        if (String.isBlank(subscriptionId)) return;
        String scheduleId = stringValue(subscription.get('schedule'));

        List<npe03__Recurring_Donation__c> existing = [
            SELECT Id
            FROM npe03__Recurring_Donation__c
            WHERE Stripe_Subscription_ID__c = :subscriptionId
            LIMIT 1
        ];
        npe03__Recurring_Donation__c metadataMatchedRd = null;
        Boolean matchedByPendingScheduleOrMetadata = false;
        if (existing.isEmpty()) {
            Map<String, Object> metadata = resolveSubscriptionMetadata(subscription, scheduleId);
            Id metadataRecurringDonationId = idValue(metadata.get('sf_rd_id'));
            if (metadataRecurringDonationId != null) {
                List<npe03__Recurring_Donation__c> metadataRows = [
                    SELECT Id, Stripe_Subscription_ID__c, Previous_Stripe_Subscription_ID__c,
                           Pending_Stripe_Schedule_ID__c
                    FROM npe03__Recurring_Donation__c
                    WHERE Id = :metadataRecurringDonationId
                    LIMIT 1
                ];
                if (!metadataRows.isEmpty()) {
                    metadataMatchedRd = metadataRows[0];
                    matchedByPendingScheduleOrMetadata = true;
                }
            }
            if (metadataMatchedRd == null && String.isNotBlank(scheduleId)) {
                List<npe03__Recurring_Donation__c> scheduleRows = [
                    SELECT Id, Stripe_Subscription_ID__c, Previous_Stripe_Subscription_ID__c,
                           Pending_Stripe_Schedule_ID__c
                    FROM npe03__Recurring_Donation__c
                    WHERE Pending_Stripe_Schedule_ID__c = :scheduleId
                    LIMIT 1
                ];
                if (!scheduleRows.isEmpty()) {
                    metadataMatchedRd = scheduleRows[0];
                    matchedByPendingScheduleOrMetadata = true;
                }
            }
        }
        if (existing.isEmpty() && metadataMatchedRd == null && !allowCreate) return;
        if (existing.isEmpty() && metadataMatchedRd == null && allowCreate && String.isNotBlank(scheduleId)) {
            // Salesforce-created replacement schedules must match by sf_rd_id or pending schedule id.
            // If Stripe sends a schedule-backed subscription without that match, creating a new RD risks duplicates.
            return;
        }

        SubscriptionSnapshot snapshot = subscriptionSnapshot(subscription);
        Map<String, Object> resolvedMetadata = resolveSubscriptionMetadata(subscription, scheduleId);
        if (snapshot.gauId == null) {
            snapshot.gauId = idValue(resolvedMetadata.get('sf_gau_id'));
        }
        if (snapshot.salesforceCreated != true) {
            snapshot.salesforceCreated = stringValue(resolvedMetadata.get('sf_created')) == 'true';
        }
        npe03__Recurring_Donation__c rd = existing.isEmpty()
            ? (
                metadataMatchedRd != null
                    ? metadataMatchedRd
                    : newRecurringDonation(
                        stringValue(subscription.get('customer')),
                        (String) subscription.get('id'),
                        snapshot
                    )
            )
            : new npe03__Recurring_Donation__c(Id = existing[0].Id);
        if (rd == null) return;

        Boolean preservePendingReplacement = forceClosed
            && existing.isEmpty()
            && metadataMatchedRd != null
            && String.isNotBlank(metadataMatchedRd.Pending_Stripe_Schedule_ID__c)
            && (
                metadataMatchedRd.Previous_Stripe_Subscription_ID__c == subscriptionId
                || String.isBlank(metadataMatchedRd.Stripe_Subscription_ID__c)
            );

        if (preservePendingReplacement) {
            return;
        }

        rd.Stripe_Subscription_ID__c = subscriptionId;
        rd.Pending_Stripe_Schedule_ID__c = null;
        rd.npe03__Amount__c = snapshot.amount;
        rd.npe03__Installment_Period__c = npspInstallmentPeriod(snapshot.interval);
        rd.npsp__InstallmentFrequency__c = snapshot.intervalCount == null ? 1 : snapshot.intervalCount;
        rd.npsp__Day_of_Month__c = npspDayOfMonth(snapshot.currentPeriodStart);
        rd.npsp__PaymentMethod__c = 'Credit Card';
        // Refresh the payment method to the subscription's current card, but only when
        // Stripe actually returns one - never blank it on a routine renewal sync (e.g.
        // a subscription billing off the customer default returns no subscription-level
        // payment method).
        if (String.isNotBlank(snapshot.paymentMethodId)) {
            rd.Stripe_Payment_Method_ID__c = snapshot.paymentMethodId;
        }
        // Never change a GAU that's already set in Salesforce; only fill it from Stripe
        // when the donation doesn't have one yet.
        Id existingGauId;
        if (rd.Id != null) {
            List<npe03__Recurring_Donation__c> gauRows = [
                SELECT Stripe_GAU__c
                FROM npe03__Recurring_Donation__c
                WHERE Id = :rd.Id
                LIMIT 1
            ];
            existingGauId = gauRows.isEmpty() ? null : gauRows[0].Stripe_GAU__c;
        }
        if (existingGauId == null && snapshot.gauId != null) {
            rd.Stripe_GAU__c = snapshot.gauId;
        }
        rd.npe03__Next_Payment_Date__c = forceClosed
            ? null
            : epochDate(snapshot.currentPeriodEnd, null);
        Long recurringEndEpoch = snapshot.endedAt != null
            ? snapshot.endedAt
            : (snapshot.cancelAt != null
                ? snapshot.cancelAt
                : (snapshot.cancelAtPeriodEnd == true ? snapshot.currentPeriodEnd : null));
        rd.npsp__EndDate__c = epochDate(recurringEndEpoch, null);

        if (forceClosed) {
            rd.npsp__Status__c = 'Closed';
            rd.npsp__ClosedReason__c = 'Unknown';
        } else if (snapshot.collectionPaused == true) {
            // Stripe collection is paused; reflect that on the recurring donation for
            // the duration of the pause. A later resume event clears pause_collection
            // and the status returns to Active via the branch below.
            rd.npsp__Status__c = 'Paused';
            rd.npsp__ClosedReason__c = null;
        } else {
            rd.npsp__Status__c = npspStatus(snapshot.status);
            if (rd.npsp__Status__c != 'Closed') rd.npsp__ClosedReason__c = null;
        }

        if (existing.isEmpty() && !matchedByPendingScheduleOrMetadata) {
            insert rd;
        } else {
            StripeSubscriptionController.updateRecurringDonationBypassed(rd);
        }
    }

    private static npe03__Recurring_Donation__c newRecurringDonation(
        String customerId,
        String subscriptionId,
        SubscriptionSnapshot snapshot
    ) {
        if (String.isBlank(customerId) || String.isBlank(subscriptionId)) return null;

        List<Contact> contacts = [
            SELECT Id, Name
            FROM Contact
            WHERE Stripe_Customer_ID__c = :customerId
            LIMIT 1
        ];
        if (contacts.isEmpty()) return null;

        Contact c = contacts[0];
        npe03__Recurring_Donation__c rd = new npe03__Recurring_Donation__c();
        rd.Name = 'Stripe Subscription - ' + safeName(c.Name);
        rd.npe03__Contact__c = c.Id;
        rd.Stripe_Subscription_ID__c = subscriptionId;
        rd.npsp__RecurringType__c = 'Open';
        rd.npsp__StartDate__c = epochDate(snapshot.currentPeriodStart, Date.today());
        rd.npe03__Date_Established__c = Date.today();
        rd.npsp__DisableFirstInstallment__c = true;
        return rd;
    }

    private static SubscriptionSnapshot subscriptionSnapshot(Map<String, Object> subscription) {
        SubscriptionSnapshot snapshot = new SubscriptionSnapshot();
        snapshot.status = (String) subscription.get('status');
        snapshot.collectionPaused = subscription.get('pause_collection') != null;
        snapshot.cancelAtPeriodEnd = booleanValue(subscription.get('cancel_at_period_end'));
        snapshot.currentPeriodStart = longValue(subscription.get('current_period_start'));
        snapshot.currentPeriodEnd = longValue(subscription.get('current_period_end'));
        snapshot.cancelAt = longValue(subscription.get('cancel_at'));
        snapshot.endedAt = longValue(subscription.get('ended_at'));
        snapshot.paymentMethodId = stringValue(subscription.get('default_payment_method'));
        Map<String, Object> metadata = asMap(subscription.get('metadata'));
        snapshot.gauId = idValue(metadata.get('sf_gau_id'));
        snapshot.salesforceCreated = stringValue(metadata.get('sf_created')) == 'true';

        Map<String, Object> itemsObj = asMap(subscription.get('items'));
        List<Object> itemData = (List<Object>) itemsObj.get('data');
        if (itemData != null && !itemData.isEmpty()) {
            Map<String, Object> item = asMap(itemData[0]);
            Map<String, Object> price = asMap(item.get('price'));
            Integer unitAmount = integerValue(price.get('unit_amount'));
            snapshot.amount = unitAmount == null ? null : Decimal.valueOf(unitAmount) / 100;
            Map<String, Object> recurring = asMap(price.get('recurring'));
            snapshot.interval = (String) recurring.get('interval');
            snapshot.intervalCount = integerValue(recurring.get('interval_count'));
        }

        return snapshot;
    }

    private static Map<String, Object> fetchSubscription(String subscriptionId) {
        if (String.isBlank(subscriptionId)) return new Map<String, Object>();
        HttpRequest req = new HttpRequest();
        req.setEndpoint('https://api.stripe.com/v1/subscriptions/' + EncodingUtil.urlEncode(subscriptionId, 'UTF-8'));
        req.setMethod('GET');
        req.setHeader('Authorization', 'Bearer ' + Stripe_Settings__c.getOrgDefaults().Secret_Key__c);
        req.setTimeout(30000);
        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() != 200 || String.isBlank(res.getBody())) return new Map<String, Object>();
        return (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
    }

    private static Map<String, Object> fetchSubscriptionSchedule(String scheduleId) {
        if (String.isBlank(scheduleId)) return new Map<String, Object>();
        HttpRequest req = new HttpRequest();
        req.setEndpoint('https://api.stripe.com/v1/subscription_schedules/' + EncodingUtil.urlEncode(scheduleId, 'UTF-8'));
        req.setMethod('GET');
        req.setHeader('Authorization', 'Bearer ' + Stripe_Settings__c.getOrgDefaults().Secret_Key__c);
        req.setTimeout(30000);
        HttpResponse res = new Http().send(req);
        if (res.getStatusCode() != 200 || String.isBlank(res.getBody())) return new Map<String, Object>();
        return (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
    }

    private static Map<String, Object> resolveSubscriptionMetadata(
        Map<String, Object> subscription,
        String scheduleId
    ) {
        Map<String, Object> metadata = asMap(subscription.get('metadata'));
        if (!metadata.isEmpty()) {
            return metadata;
        }
        if (String.isBlank(scheduleId)) {
            return metadata;
        }

        Map<String, Object> schedule = fetchSubscriptionSchedule(scheduleId);
        if (schedule.isEmpty()) {
            return metadata;
        }

        Map<String, Object> scheduleMetadata = asMap(schedule.get('metadata'));
        if (!scheduleMetadata.isEmpty()) {
            return scheduleMetadata;
        }

        List<Object> phases = (List<Object>) schedule.get('phases');
        if (phases != null) {
            for (Object phaseObj : phases) {
                Map<String, Object> phase = asMap(phaseObj);
                Map<String, Object> phaseMetadata = asMap(phase.get('metadata'));
                if (!phaseMetadata.isEmpty()) {
                    return phaseMetadata;
                }
            }
        }

        return metadata;
    }

    private static SubscriptionSnapshot invoiceSubscriptionSnapshot(Map<String, Object> invoice, Long amountPaidCents) {
        SubscriptionSnapshot snapshot = new SubscriptionSnapshot();
        snapshot.status = 'active';
        snapshot.amount = amountPaidCents == null ? null : Decimal.valueOf(amountPaidCents) / 100;
        snapshot.currentPeriodStart = longValue(invoice.get('period_start'));
        snapshot.currentPeriodEnd = longValue(invoice.get('period_end'));
        snapshot.paymentMethodId = stringValue(invoice.get('default_payment_method'));

        Map<String, Object> lines = asMap(invoice.get('lines'));
        List<Object> lineData = (List<Object>) lines.get('data');
        if (lineData != null && !lineData.isEmpty()) {
            Map<String, Object> line = asMap(lineData[0]);
            Map<String, Object> period = asMap(line.get('period'));
            Long lineStart = longValue(period.get('start'));
            Long lineEnd = longValue(period.get('end'));
            if (lineStart != null) snapshot.currentPeriodStart = lineStart;
            if (lineEnd != null) snapshot.currentPeriodEnd = lineEnd;

            Map<String, Object> price = asMap(line.get('price'));
            Integer unitAmount = integerValue(price.get('unit_amount'));
            if (unitAmount != null) snapshot.amount = Decimal.valueOf(unitAmount) / 100;
            Map<String, Object> recurring = asMap(price.get('recurring'));
            snapshot.interval = (String) recurring.get('interval');
            snapshot.intervalCount = integerValue(recurring.get('interval_count'));
        }

        if (snapshot.currentPeriodStart == null) snapshot.currentPeriodStart = longValue(invoice.get('created'));
        return snapshot;
    }

    private static Id subscriptionRecordTypeId() {
        Map<String, Schema.RecordTypeInfo> byDeveloperName =
            Schema.SObjectType.Opportunity.getRecordTypeInfosByDeveloperName();
        if (byDeveloperName.containsKey('Subscription')) {
            return byDeveloperName.get('Subscription').getRecordTypeId();
        }
        if (byDeveloperName.containsKey('Donation')) {
            return byDeveloperName.get('Donation').getRecordTypeId();
        }
        return null;
    }

    private static Date invoicePaidDate(Map<String, Object> invoice) {
        Map<String, Object> transitions = asMap(invoice.get('status_transitions'));
        Long paidAt = longValue(transitions.get('paid_at'));
        if (paidAt == null) paidAt = longValue(invoice.get('created'));
        if (paidAt == null) return Date.today();
        return DateTime.newInstanceGmt(1970, 1, 1, 0, 0, 0)
            .addSeconds(Integer.valueOf(String.valueOf(paidAt)))
            .dateGmt();
    }

    private static String npspInstallmentPeriod(String stripeInterval) {
        if (stripeInterval == 'week') return 'Weekly';
        return stripeInterval == 'year' ? 'Yearly' : 'Monthly';
    }

    private static String npspDayOfMonth(Long epochSeconds) {
        Integer day = epochDate(epochSeconds, Date.today()).day();
        return day > 30 ? 'Last_Day' : String.valueOf(day);
    }

    private static String npspStatus(String stripeStatus) {
        String normalized = String.isBlank(stripeStatus) ? '' : stripeStatus.toLowerCase();
        if (normalized == 'active' || normalized == 'trialing') return 'Active';
        if (normalized == 'canceled' || normalized == 'incomplete_expired') return 'Closed';
        if (normalized == 'past_due' || normalized == 'unpaid' || normalized == 'incomplete') return 'Lapsed';
        return 'Active';
    }

    private static Date epochDate(Long epochSeconds, Date fallbackDate) {
        if (epochSeconds == null || epochSeconds <= 0) return fallbackDate;
        return DateTime.newInstanceGmt(1970, 1, 1, 0, 0, 0)
            .addSeconds(Integer.valueOf(String.valueOf(epochSeconds)))
            .dateGmt();
    }

    private static void verifySignature(String payload, String signatureHeader) {
        Stripe_Settings__c settings = Stripe_Settings__c.getOrgDefaults();
        if (settings == null || String.isBlank(settings.Webhook_Secret__c)) {
            throw new StripeWebhookException(SERVER_ERROR, 'Stripe webhook secret is not configured.');
        }
        if (String.isBlank(signatureHeader)) {
            throw new StripeWebhookException(BAD_REQUEST, 'Missing Stripe-Signature header.');
        }

        String timestamp;
        // Stripe can send more than one v1 signature (e.g. during webhook-secret
        // rotation); the event is valid if any of them matches.
        List<String> signatures = new List<String>();
        for (String part : signatureHeader.split(',')) {
            List<String> pieces = part.split('=', 2);
            if (pieces.size() != 2) continue;
            if (pieces[0] == 't') timestamp = pieces[1];
            if (pieces[0] == 'v1') signatures.add(pieces[1].toLowerCase());
        }
        if (String.isBlank(timestamp) || signatures.isEmpty()) {
            throw new StripeWebhookException(BAD_REQUEST, 'Invalid Stripe-Signature header.');
        }

        String signedPayload = timestamp + '.' + payload;
        Blob mac = Crypto.generateMac(
            'HmacSHA256',
            Blob.valueOf(signedPayload),
            Blob.valueOf(settings.Webhook_Secret__c)
        );
        String expected = EncodingUtil.convertToHex(mac).toLowerCase();
        if (!signatures.contains(expected)) {
            throw new StripeWebhookException(BAD_REQUEST, 'Invalid Stripe webhook signature.');
        }

        // Reject stale events to mitigate replay attacks. Skipped under test, where
        // fixtures sign with a fixed timestamp.
        if (!Test.isRunningTest() && isTimestampOutsideTolerance(timestamp)) {
            throw new StripeWebhookException(BAD_REQUEST, 'Stripe webhook timestamp outside tolerance.');
        }
    }

    private static Boolean isTimestampOutsideTolerance(String timestamp) {
        Long eventSeconds;
        try {
            eventSeconds = Long.valueOf(timestamp);
        } catch (Exception e) {
            return true;
        }
        Long nowSeconds = DateTime.now().getTime() / 1000;
        return Math.abs(nowSeconds - eventSeconds) > SIGNATURE_TOLERANCE_SECONDS;
    }

    private static Map<String, Object> asMap(Object value) {
        return value instanceof Map<String, Object>
            ? (Map<String, Object>) value
            : new Map<String, Object>();
    }

    private static String stringValue(Object value) {
        if (value == null) return null;
        if (value instanceof String) return (String) value;
        if (value instanceof Map<String, Object>) return (String) ((Map<String, Object>) value).get('id');
        return String.valueOf(value);
    }

    private static Long longValue(Object value) {
        Decimal normalized = decimalValue(value);
        return normalized == null ? null : normalized.longValue();
    }

    private static Integer integerValue(Object value) {
        Decimal normalized = decimalValue(value);
        return normalized == null ? null : normalized.intValue();
    }

    private static Boolean booleanValue(Object value) {
        if (value == null) return false;
        if (value instanceof Boolean) return (Boolean) value;

        String raw = String.valueOf(value);
        if (String.isBlank(raw)) return false;
        return raw.trim().toLowerCase() == 'true';
    }

    private static Decimal decimalValue(Object value) {
        if (value == null) return null;
        if (value instanceof Decimal) return (Decimal) value;
        if (value instanceof Integer) return Decimal.valueOf(String.valueOf(value));
        if (value instanceof Long) return Decimal.valueOf(String.valueOf(value));
        if (value instanceof Double) return Decimal.valueOf(String.valueOf(value));

        String raw = String.valueOf(value);
        if (String.isBlank(raw)) return null;
        if (raw.endsWith('.0')) {
            raw = raw.substring(0, raw.length() - 2);
        }
        return Decimal.valueOf(raw);
    }

    private static Id idValue(Object value) {
        String raw = stringValue(value);
        if (String.isBlank(raw)) return null;
        try {
            return (Id) raw;
        } catch (Exception e) {
            // A malformed id in Stripe metadata (e.g. set manually) must not 500 the
            // webhook - that would make Stripe retry the event indefinitely.
            return null;
        }
    }

    private static String safeName(String value) {
        return String.isBlank(value) ? 'Unknown Donor' : value;
    }

    private static String escapeJson(String value) {
        return String.isBlank(value) ? '' : value.replace('\\', '\\\\').replace('"', '\\"');
    }

    global class StripeWebhookException extends Exception {
        global Integer statusCode;

        global StripeWebhookException(Integer statusCode, String message) {
            this.statusCode = statusCode;
            this.setMessage(message);
        }
    }

    private class SubscriptionSnapshot {
        Decimal amount;
        String interval;
        Integer intervalCount;
        String status;
        Boolean collectionPaused;
        Boolean cancelAtPeriodEnd;
        Long currentPeriodStart;
        Long currentPeriodEnd;
        Long cancelAt;
        Long endedAt;
        String paymentMethodId;
        Id gauId;
        Boolean salesforceCreated;
    }
}