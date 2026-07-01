@IsTest
private class StripeWebhookControllerTest {
    private static final String SECRET = 'whsec_test_secret';
    private static final String SUBSCRIPTION_ID = 'sub_test_123';
    private static final String CUSTOMER_ID = 'cus_test_123';
    private static final String PAYMENT_INTENT_ID = 'pi_test_123';

    @IsTest
    static void paidInvoiceCreatesOpportunityForSubsequentTransaction() {
        Contact contact = setupContactWithStripeCustomer();
        npsp__General_Accounting_Unit__c gau = new npsp__General_Accounting_Unit__c(Name = 'Webhook GAU');
        insert gau;

        npe03__Recurring_Donation__c rd = setupRecurringDonation(contact.Id, gau.Id);
        seedHistoricalPaidTransaction(rd.Id, contact.Id, contact.AccountId);
        Test.setMock(HttpCalloutMock.class, new StripeWebhookMock(false, gau.Id));

        RestContext.request = signedRequest(invoicePaidPayload());
        RestContext.response = new RestResponse();

        Test.startTest();
        StripeWebhookController.handlePost();
        Test.stopTest();

        System.assertEquals(
            null,
            StripeWebhookController.lastHandledError,
            'Handled webhook error at step ' + StripeWebhookController.lastProcessingStep
        );
        System.assertEquals(
            null,
            StripeWebhookController.lastUnhandledError,
            'Unhandled webhook error at step ' + StripeWebhookController.lastProcessingStep
        );
        System.assertEquals(200, RestContext.response.statusCode);

        Opportunity opp = [
            SELECT Id, Amount, StageName, CloseDate, AccountId,
                   npsp__Primary_Contact__c, npe03__Recurring_Donation__c,
                   stripe_payment_id__c, Stripe_Recurring_Invoice__c,
                   Stripe_receipt_url__c
            FROM Opportunity
            WHERE stripe_payment_id__c = :PAYMENT_INTENT_ID
            LIMIT 1
        ];
        System.assertEquals(25, opp.Amount);
        System.assertEquals('Closed Won', opp.StageName);
        System.assertEquals(rd.Id, opp.npe03__Recurring_Donation__c);
        System.assertEquals(contact.Id, opp.npsp__Primary_Contact__c);
        System.assertEquals('https://invoice.stripe.test/in_test_123', opp.Stripe_Recurring_Invoice__c);
        System.assertEquals('https://invoice.stripe.test/in_test_123', opp.Stripe_receipt_url__c);

        npsp__Allocation__c allocation = [
            SELECT Id, npsp__Opportunity__c, npsp__General_Accounting_Unit__c, npsp__Amount__c, npsp__Percent__c
            FROM npsp__Allocation__c
            WHERE npsp__Opportunity__c = :opp.Id
            LIMIT 1
        ];
        System.assertEquals(gau.Id, allocation.npsp__General_Accounting_Unit__c);
        System.assertEquals(25, allocation.npsp__Amount__c);
        System.assertEquals(100, allocation.npsp__Percent__c);

        rd = [
            SELECT Stripe_Receipt_URL__c, npe03__Last_Payment_Date__c
            FROM npe03__Recurring_Donation__c
            WHERE Id = :rd.Id
        ];
        System.assertEquals('https://invoice.stripe.test/in_test_123', rd.Stripe_Receipt_URL__c);
        System.assertNotEquals(null, rd.npe03__Last_Payment_Date__c);
    }

    @IsTest
    static void paidInvoiceIgnoredWithoutHistoricalPaidTransaction() {
        Contact contact = setupContactWithStripeCustomer();
        setupRecurringDonation(contact.Id, null);
        Test.setMock(HttpCalloutMock.class, new StripeWebhookMock(false, null));

        RestContext.request = signedRequest(invoicePaidPayload());
        RestContext.response = new RestResponse();

        Test.startTest();
        StripeWebhookController.handlePost();
        Test.stopTest();

        System.assertEquals(
            null,
            StripeWebhookController.lastHandledError,
            'Handled webhook error at step ' + StripeWebhookController.lastProcessingStep
        );
        System.assertEquals(
            null,
            StripeWebhookController.lastUnhandledError,
            'Unhandled webhook error at step ' + StripeWebhookController.lastProcessingStep
        );
        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals(0, [
            SELECT COUNT()
            FROM Opportunity
            WHERE stripe_payment_id__c = :PAYMENT_INTENT_ID
        ]);
    }

    @IsTest
    static void paidInvoiceCreatesFirstOpportunityForSalesforceCreatedSubscription() {
        Contact contact = setupContactWithStripeCustomer();
        npsp__General_Accounting_Unit__c gau = new npsp__General_Accounting_Unit__c(Name = 'First Gift GAU');
        insert gau;

        npe03__Recurring_Donation__c rd = setupRecurringDonation(contact.Id, gau.Id);
        Test.setMock(HttpCalloutMock.class, new StripeWebhookMock(true, gau.Id));

        RestContext.request = signedRequest(invoicePaidPayload());
        RestContext.response = new RestResponse();

        Test.startTest();
        StripeWebhookController.handlePost();
        Test.stopTest();

        System.assertEquals(
            null,
            StripeWebhookController.lastHandledError,
            'Handled webhook error at step ' + StripeWebhookController.lastProcessingStep
        );
        System.assertEquals(
            null,
            StripeWebhookController.lastUnhandledError,
            'Unhandled webhook error at step ' + StripeWebhookController.lastProcessingStep
        );
        Opportunity opp = [
            SELECT Id, Amount, StageName, npe03__Recurring_Donation__c
            FROM Opportunity
            WHERE stripe_payment_id__c = :PAYMENT_INTENT_ID
            LIMIT 1
        ];
        System.assertEquals(25, opp.Amount);
        System.assertEquals('Closed Won', opp.StageName);
        System.assertEquals(rd.Id, opp.npe03__Recurring_Donation__c);

        npsp__Allocation__c allocation = [
            SELECT npsp__General_Accounting_Unit__c, npsp__Amount__c
            FROM npsp__Allocation__c
            WHERE npsp__Opportunity__c = :opp.Id
            LIMIT 1
        ];
        System.assertEquals(gau.Id, allocation.npsp__General_Accounting_Unit__c);
        System.assertEquals(25, allocation.npsp__Amount__c);
    }

    @IsTest
    static void invalidSignatureReturnsBadRequest() {
        insert new Stripe_Settings__c(
            SetupOwnerId = UserInfo.getOrganizationId(),
            Publishable_Key__c = 'pk_test_dummy',
            Secret_Key__c = 'sk_test_dummy',
            Webhook_Secret__c = SECRET
        );

        String payload = invoicePaidPayload();
        RestRequest req = new RestRequest();
        req.httpMethod = 'POST';
        req.requestUri = '/services/apexrest/stripe/webhook';
        req.requestBody = Blob.valueOf(payload);
        req.addHeader('Stripe-Signature', 't=123,v1=bad');
        RestContext.request = req;
        RestContext.response = new RestResponse();

        StripeWebhookController.handlePost();

        System.assertEquals(400, RestContext.response.statusCode);
    }

    @IsTest
    static void failedInvoiceMarksRecurringDonationLapsed() {
        Contact contact = setupContactWithStripeCustomer();
        npe03__Recurring_Donation__c rd = setupRecurringDonation(contact.Id, null);
        Test.setMock(HttpCalloutMock.class, new StripeWebhookMock(false, null));

        RestContext.request = signedRequest(invoiceFailedPayload());
        RestContext.response = new RestResponse();

        StripeWebhookController.handlePost();

        rd = [
            SELECT npsp__Status__c, npsp__ClosedReason__c
            FROM npe03__Recurring_Donation__c
            WHERE Id = :rd.Id
        ];
        System.assertEquals('Lapsed', rd.npsp__Status__c);
        System.assertEquals(null, rd.npsp__ClosedReason__c);
    }

    @IsTest
    static void subscriptionUpdatedPausesRecurringDonation() {
        Contact contact = setupContactWithStripeCustomer();
        npe03__Recurring_Donation__c rd = setupRecurringDonation(contact.Id, null);
        Test.setMock(HttpCalloutMock.class, new StripeWebhookMock(false, null));

        RestContext.request = signedRequest(subscriptionEventPayload('customer.subscription.updated', 'active', true));
        RestContext.response = new RestResponse();

        StripeWebhookController.handlePost();

        System.assertEquals(200, RestContext.response.statusCode);
        rd = [
            SELECT npsp__Status__c, Stripe_Payment_Method_ID__c, npe03__Amount__c,
                   npe03__Installment_Period__c, npsp__InstallmentFrequency__c
            FROM npe03__Recurring_Donation__c
            WHERE Id = :rd.Id
        ];
        System.assertEquals('Paused', rd.npsp__Status__c);
        System.assertEquals('pm_test_123', rd.Stripe_Payment_Method_ID__c);
        System.assertEquals(25, rd.npe03__Amount__c);
        System.assertEquals('Monthly', rd.npe03__Installment_Period__c);
        System.assertEquals(1, rd.npsp__InstallmentFrequency__c);
    }

    @IsTest
    static void subscriptionDeletedClosesRecurringDonation() {
        Contact contact = setupContactWithStripeCustomer();
        npe03__Recurring_Donation__c rd = setupRecurringDonation(contact.Id, null);
        Test.setMock(HttpCalloutMock.class, new StripeWebhookMock(false, null));

        RestContext.request = signedRequest(subscriptionEventPayload('customer.subscription.deleted', 'canceled', false));
        RestContext.response = new RestResponse();

        StripeWebhookController.handlePost();

        System.assertEquals(200, RestContext.response.statusCode);
        rd = [
            SELECT npsp__Status__c, npsp__ClosedReason__c, npsp__EndDate__c
            FROM npe03__Recurring_Donation__c
            WHERE Id = :rd.Id
        ];
        System.assertEquals('Closed', rd.npsp__Status__c);
        System.assertEquals('Unknown', rd.npsp__ClosedReason__c);
        System.assertNotEquals(null, rd.npsp__EndDate__c);
    }

    @IsTest
    static void subscriptionUpdatedPeriodEndCancelSetsRecurringDonationEndDate() {
        Contact contact = setupContactWithStripeCustomer();
        npe03__Recurring_Donation__c rd = setupRecurringDonation(contact.Id, null);
        Test.setMock(HttpCalloutMock.class, new StripeWebhookMock(false, null));

        RestContext.request = signedRequest(subscriptionEventPayload('customer.subscription.updated', 'active', false, true));
        RestContext.response = new RestResponse();

        StripeWebhookController.handlePost();

        rd = [
            SELECT npsp__Status__c, npsp__EndDate__c
            FROM npe03__Recurring_Donation__c
            WHERE Id = :rd.Id
        ];
        System.assertEquals('Active', rd.npsp__Status__c);
        System.assertNotEquals(null, rd.npsp__EndDate__c);
    }

    @IsTest
    static void subscriptionCreatedCreatesRecurringDonationFromCustomer() {
        Contact contact = setupContactWithStripeCustomer();
        Test.setMock(HttpCalloutMock.class, new StripeWebhookMock(false, null));

        RestContext.request = signedRequest(subscriptionEventPayload('customer.subscription.created', 'active', false));
        RestContext.response = new RestResponse();

        StripeWebhookController.handlePost();

        System.assertEquals(200, RestContext.response.statusCode);
        npe03__Recurring_Donation__c rd = [
            SELECT Id, npe03__Contact__c, npsp__Status__c, Stripe_Subscription_ID__c,
                   npe03__Amount__c, npe03__Installment_Period__c
            FROM npe03__Recurring_Donation__c
            WHERE Stripe_Subscription_ID__c = :SUBSCRIPTION_ID
            LIMIT 1
        ];
        System.assertEquals(contact.Id, rd.npe03__Contact__c);
        System.assertEquals('Active', rd.npsp__Status__c);
        System.assertEquals(25, rd.npe03__Amount__c);
        System.assertEquals('Monthly', rd.npe03__Installment_Period__c);
    }

    @IsTest
    static void subscriptionCreatedPausedCreatesPausedRecurringDonation() {
        setupContactWithStripeCustomer();
        Test.setMock(HttpCalloutMock.class, new StripeWebhookMock(false, null));

        RestContext.request = signedRequest(subscriptionEventPayload('customer.subscription.created', 'active', true));
        RestContext.response = new RestResponse();

        StripeWebhookController.handlePost();

        npe03__Recurring_Donation__c rd = [
            SELECT npsp__Status__c
            FROM npe03__Recurring_Donation__c
            WHERE Stripe_Subscription_ID__c = :SUBSCRIPTION_ID
            LIMIT 1
        ];
        System.assertEquals('Paused', rd.npsp__Status__c);
    }

    // ── Webhook: additional coverage ──

    @IsTest
    static void invoicePaidCreatesRecurringDonationWhenMissing() {
        Contact contact = setupContactWithStripeCustomer();
        npsp__General_Accounting_Unit__c gau = new npsp__General_Accounting_Unit__c(Name = 'Auto RD GAU');
        insert gau;
        // No RD exists yet: a Salesforce-created subscription's paid invoice should
        // create the recurring donation from the invoice, then record the gift.
        Test.setMock(HttpCalloutMock.class, new StripeWebhookMock(true, gau.Id));

        RestContext.request = signedRequest(invoicePaidPayload());
        RestContext.response = new RestResponse();

        Test.startTest();
        StripeWebhookController.handlePost();
        Test.stopTest();

        System.assertEquals(null, StripeWebhookController.lastUnhandledError,
            'Unhandled webhook error at step ' + StripeWebhookController.lastProcessingStep);
        npe03__Recurring_Donation__c rd = [
            SELECT Id, npe03__Contact__c, Stripe_Subscription_ID__c
            FROM npe03__Recurring_Donation__c
            WHERE Stripe_Subscription_ID__c = :SUBSCRIPTION_ID
            LIMIT 1
        ];
        System.assertEquals(contact.Id, rd.npe03__Contact__c);
        System.assertEquals(1, [
            SELECT COUNT()
            FROM Opportunity
            WHERE stripe_payment_id__c = :PAYMENT_INTENT_ID
        ]);
    }

    @IsTest
    static void unhandledErrorReturnsServerError() {
        insertSettings();
        // A valid signature over an unparseable body reaches JSON.deserializeUntyped,
        // which throws - the generic catch must return 500 (so Stripe retries).
        String payload = 'this-is-not-json';
        RestRequest req = new RestRequest();
        req.httpMethod = 'POST';
        req.requestUri = '/services/apexrest/stripe/webhook';
        req.requestBody = Blob.valueOf(payload);
        req.addHeader('Stripe-Signature', signature(payload));
        RestContext.request = req;
        RestContext.response = new RestResponse();

        StripeWebhookController.handlePost();

        System.assertEquals(500, RestContext.response.statusCode);
        System.assertNotEquals(null, StripeWebhookController.lastUnhandledError);
    }

    @IsTest
    static void missingSignatureHeaderReturnsBadRequest() {
        insertSettings();
        RestRequest req = new RestRequest();
        req.httpMethod = 'POST';
        req.requestUri = '/services/apexrest/stripe/webhook';
        req.requestBody = Blob.valueOf(invoicePaidPayload());
        RestContext.request = req;
        RestContext.response = new RestResponse();

        StripeWebhookController.handlePost();

        System.assertEquals(400, RestContext.response.statusCode);
    }

    @IsTest
    static void malformedSignatureHeaderReturnsBadRequest() {
        insertSettings();
        RestRequest req = new RestRequest();
        req.httpMethod = 'POST';
        req.requestUri = '/services/apexrest/stripe/webhook';
        req.requestBody = Blob.valueOf(invoicePaidPayload());
        // A timestamp with no v1 signature is an invalid header.
        req.addHeader('Stripe-Signature', 't=123');
        RestContext.request = req;
        RestContext.response = new RestResponse();

        StripeWebhookController.handlePost();

        System.assertEquals(400, RestContext.response.statusCode);
    }

    @IsTest
    static void missingWebhookSecretReturnsServerError() {
        // No Stripe_Settings__c configured: verifySignature should fail as a server error.
        RestRequest req = new RestRequest();
        req.httpMethod = 'POST';
        req.requestUri = '/services/apexrest/stripe/webhook';
        req.requestBody = Blob.valueOf(invoicePaidPayload());
        req.addHeader('Stripe-Signature', 't=123,v1=whatever');
        RestContext.request = req;
        RestContext.response = new RestResponse();

        StripeWebhookController.handlePost();

        System.assertEquals(500, RestContext.response.statusCode);
    }

    @IsTest
    static void subscriptionUpdatedPastDueMarksLapsed() {
        Contact contact = setupContactWithStripeCustomer();
        npe03__Recurring_Donation__c rd = setupRecurringDonation(contact.Id, null);
        Test.setMock(HttpCalloutMock.class, new StripeWebhookMock(false, null));

        RestContext.request = signedRequest(subscriptionEventPayload('customer.subscription.updated', 'past_due', false));
        RestContext.response = new RestResponse();

        StripeWebhookController.handlePost();

        rd = [SELECT npsp__Status__c FROM npe03__Recurring_Donation__c WHERE Id = :rd.Id];
        System.assertEquals('Lapsed', rd.npsp__Status__c);
    }

    @IsTest
    static void subscriptionUpdatedMatchesByMetadataRecurringDonationId() {
        Contact contact = setupContactWithStripeCustomer();
        // RD points at a different live subscription; the event carries sf_rd_id in
        // metadata, so it must be matched by metadata rather than by subscription id.
        npe03__Recurring_Donation__c rd = insertRd(contact.Id, 'sub_other_999', null);
        Test.setMock(HttpCalloutMock.class, new StripeWebhookMock(false, null));

        String meta = '{"sf_rd_id":"' + rd.Id + '"}';
        RestContext.request = signedRequest(
            subscriptionMatchPayload('customer.subscription.updated', 'active', SUBSCRIPTION_ID, meta, null)
        );
        RestContext.response = new RestResponse();

        StripeWebhookController.handlePost();

        System.assertEquals(200, RestContext.response.statusCode);
        rd = [SELECT Stripe_Subscription_ID__c, npe03__Amount__c FROM npe03__Recurring_Donation__c WHERE Id = :rd.Id];
        System.assertEquals(SUBSCRIPTION_ID, rd.Stripe_Subscription_ID__c,
            'metadata-matched RD should be re-pointed at the event subscription');
        System.assertEquals(25, rd.npe03__Amount__c);
    }

    @IsTest
    static void subscriptionUpdatedMatchesByPendingScheduleId() {
        Contact contact = setupContactWithStripeCustomer();
        // RD is in the pending-replacement-schedule state; the event has no metadata
        // but names that schedule, so it must be matched by pending schedule id.
        npe03__Recurring_Donation__c rd = insertRd(contact.Id, 'sub_other_888', 'sched_pending_1');
        Test.setMock(HttpCalloutMock.class, new StripeWebhookMock(false, null));

        RestContext.request = signedRequest(
            subscriptionMatchPayload('customer.subscription.updated', 'active', SUBSCRIPTION_ID, null, 'sched_pending_1')
        );
        RestContext.response = new RestResponse();

        Test.startTest();
        StripeWebhookController.handlePost();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode);
        rd = [SELECT Stripe_Subscription_ID__c, Pending_Stripe_Schedule_ID__c
              FROM npe03__Recurring_Donation__c WHERE Id = :rd.Id];
        System.assertEquals(SUBSCRIPTION_ID, rd.Stripe_Subscription_ID__c);
        System.assertEquals(null, rd.Pending_Stripe_Schedule_ID__c);
    }

    @IsTest
    static void subscriptionUpdatedResolvesRecurringDonationFromScheduleMetadata() {
        Contact contact = setupContactWithStripeCustomer();
        npe03__Recurring_Donation__c rd = insertRd(contact.Id, 'sub_other_777', null);
        // Event has no metadata but names a schedule; the schedule carries sf_rd_id,
        // so metadata resolves through the schedule fetch.
        String scheduleBody = '{"metadata":{"sf_rd_id":"' + rd.Id + '"}}';
        Test.setMock(HttpCalloutMock.class, new ScheduleMock(scheduleBody));

        RestContext.request = signedRequest(
            subscriptionMatchPayload('customer.subscription.updated', 'active', SUBSCRIPTION_ID, null, 'sched_meta_1')
        );
        RestContext.response = new RestResponse();

        Test.startTest();
        StripeWebhookController.handlePost();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode);
        rd = [SELECT Stripe_Subscription_ID__c FROM npe03__Recurring_Donation__c WHERE Id = :rd.Id];
        System.assertEquals(SUBSCRIPTION_ID, rd.Stripe_Subscription_ID__c);
    }

    @IsTest
    static void subscriptionCreatedWithUnmatchedScheduleSkips() {
        setupContactWithStripeCustomer();
        Test.setMock(HttpCalloutMock.class, new ScheduleMock('{}'));

        RestContext.request = signedRequest(
            subscriptionMatchPayload('customer.subscription.created', 'active', SUBSCRIPTION_ID, null, 'sched_unmatched')
        );
        RestContext.response = new RestResponse();

        Test.startTest();
        StripeWebhookController.handlePost();
        Test.stopTest();

        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals(0, [
            SELECT COUNT() FROM npe03__Recurring_Donation__c WHERE Stripe_Subscription_ID__c = :SUBSCRIPTION_ID
        ], 'a schedule-backed subscription with no matching RD must not create a duplicate');
    }

    @IsTest
    static void malformedMetadataRecurringDonationIdIsIgnored() {
        setupContactWithStripeCustomer();
        Test.setMock(HttpCalloutMock.class, new StripeWebhookMock(false, null));

        RestContext.request = signedRequest(
            subscriptionMatchPayload('customer.subscription.updated', 'active', SUBSCRIPTION_ID, '{"sf_rd_id":"garbage"}', null)
        );
        RestContext.response = new RestResponse();

        StripeWebhookController.handlePost();

        // A bad id in metadata must not 500 the webhook.
        System.assertEquals(200, RestContext.response.statusCode);
        System.assertEquals(null, StripeWebhookController.lastUnhandledError);
    }

    // ── RecurringDonationTrigger (Salesforce -> Stripe manual edits) ──

    @IsTest
    static void triggerCancelEnqueuesSync() {
        Contact contact = setupContactWithStripeCustomer();
        npe03__Recurring_Donation__c rd = setupRecurringDonation(contact.Id, null);
        enableTrigger();

        Test.startTest();
        rd.npsp__Status__c = 'Closed';
        rd.npsp__ClosedReason__c = 'Commitment Completed';
        rd.npsp__EndDate__c = Date.today().addDays(1);
        update rd;
        Integer jobs = Limits.getQueueableJobs();
        Test.stopTest();

        System.assert(jobs >= 1, 'closing the RD should enqueue a Stripe sync job');
    }

    @IsTest
    static void triggerAmountFrequencyEnqueuesSync() {
        Contact contact = setupContactWithStripeCustomer();
        npe03__Recurring_Donation__c rd = setupRecurringDonation(contact.Id, null);
        enableTrigger();

        Test.startTest();
        rd.npe03__Amount__c = 99;
        update rd;
        Integer jobs = Limits.getQueueableJobs();
        Test.stopTest();

        System.assert(jobs >= 1, 'an amount change should enqueue a Stripe sync job');
    }

    @IsTest
    static void triggerGiftDayEnqueuesSync() {
        Contact contact = setupContactWithStripeCustomer();
        npe03__Recurring_Donation__c rd = setupRecurringDonation(contact.Id, null);
        enableTrigger();

        Test.startTest();
        rd.npsp__Day_of_Month__c = '15';
        update rd;
        Integer jobs = Limits.getQueueableJobs();
        Test.stopTest();

        System.assert(jobs >= 1, 'a gift-day change should enqueue a Stripe sync job');
    }

    @IsTest
    static void triggerSkipsWhenNoSubscriptionId() {
        Contact contact = setupContactWithStripeCustomer();
        npe03__Recurring_Donation__c rd = insertRd(contact.Id, null, null);
        enableTrigger();

        Test.startTest();
        rd.npe03__Amount__c = 42;
        update rd;
        Integer jobs = Limits.getQueueableJobs();
        Test.stopTest();

        System.assertEquals(0, jobs, 'an RD without a Stripe subscription id must not enqueue anything');
    }

    @IsTest
    static void triggerSkipsWhenSuppressed() {
        Contact contact = setupContactWithStripeCustomer();
        npe03__Recurring_Donation__c rd = setupRecurringDonation(contact.Id, null);
        StripeSubscriptionController.recurringDonationTriggerTestMode = true;
        // Leave sync suppressed (as controller/webhook writes do): trigger must no-op.
        StripeSubscriptionController.setRecurringDonationSyncSuppressed(true);

        Test.startTest();
        rd.npe03__Amount__c = 77;
        update rd;
        Integer jobs = Limits.getQueueableJobs();
        Test.stopTest();

        System.assertEquals(0, jobs, 'a suppressed context must not enqueue a sync job');
    }

    private static void enableTrigger() {
        StripeSubscriptionController.recurringDonationTriggerTestMode = true;
        StripeSubscriptionController.setRecurringDonationSyncSuppressed(false);
    }

    private static void insertSettings() {
        insert new Stripe_Settings__c(
            SetupOwnerId = UserInfo.getOrganizationId(),
            Publishable_Key__c = 'pk_test_dummy',
            Secret_Key__c = 'sk_test_dummy',
            Webhook_Secret__c = SECRET
        );
    }

    private static npe03__Recurring_Donation__c insertRd(Id contactId, String subscriptionId, String pendingScheduleId) {
        npe03__Recurring_Donation__c rd = new npe03__Recurring_Donation__c(
            Name = 'Match RD',
            npe03__Contact__c = contactId,
            npe03__Amount__c = 10,
            npe03__Installment_Period__c = 'Monthly',
            npsp__Day_of_Month__c = '1',
            npsp__InstallmentFrequency__c = 1,
            npsp__RecurringType__c = 'Open',
            npsp__PaymentMethod__c = 'Credit Card',
            npsp__Status__c = 'Active',
            Stripe_Subscription_ID__c = subscriptionId,
            Pending_Stripe_Schedule_ID__c = pendingScheduleId
        );
        insert rd;
        return rd;
    }

    private static String subscriptionMatchPayload(
        String eventType,
        String status,
        String subscriptionId,
        String metadataJson,
        String scheduleId
    ) {
        String metaPart = metadataJson == null ? '' : '"metadata":' + metadataJson + ',';
        String schedPart = scheduleId == null ? '' : '"schedule":"' + scheduleId + '",';
        return '{'
            + '"id":"evt_sub_match",'
            + '"type":"' + eventType + '",'
            + '"data":{"object":{'
            + '"id":"' + subscriptionId + '",'
            + '"status":"' + status + '",'
            + schedPart
            + metaPart
            + '"customer":"' + CUSTOMER_ID + '",'
            + '"current_period_start":1780000000,'
            + '"current_period_end":1782592000,'
            + '"items":{"data":[{"price":{'
            + '"unit_amount":2500,'
            + '"recurring":{"interval":"month","interval_count":1}'
            + '}}]}'
            + '}}'
            + '}';
    }

    private class ScheduleMock implements HttpCalloutMock {
        private final String scheduleBody;

        private ScheduleMock(String scheduleBody) {
            this.scheduleBody = scheduleBody;
        }

        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setHeader('Content-Type', 'application/json');
            String endpoint = req.getEndpoint() == null ? '' : req.getEndpoint();
            res.setBody(endpoint.contains('/subscription_schedules/') ? scheduleBody : '{}');
            return res;
        }
    }

    private static void seedHistoricalPaidTransaction(Id recurringDonationId, Id contactId, Id accountId) {
        Opportunity opp = new Opportunity(
            Name = 'Historical Paid Gift',
            StageName = 'Closed Won',
            CloseDate = Date.today().addMonths(-1),
            Amount = 25,
            AccountId = accountId,
            npsp__Primary_Contact__c = contactId,
            npe03__Recurring_Donation__c = recurringDonationId,
            npe01__Do_Not_Automatically_Create_Payment__c = true
        );
        insert opp;

        insert new npe01__OppPayment__c(
            npe01__Opportunity__c = opp.Id,
            npe01__Payment_Amount__c = 25,
            npe01__Paid__c = true,
            npe01__Payment_Method__c = 'Credit Card (Online)',
            npsp__Gateway_Payment_ID__c = 'pi_historical_001'
        );
    }

    private static String invoicePaidPayload() {
        return '{'
            + '"id":"evt_test_123",'
            + '"type":"invoice.paid",'
            + '"data":{"object":{'
            + '"id":"in_test_123",'
            + '"subscription":"' + SUBSCRIPTION_ID + '",'
            + '"customer":"' + CUSTOMER_ID + '",'
            + '"payment_intent":"' + PAYMENT_INTENT_ID + '",'
            + '"amount_paid":2500,'
            + '"created":1780000000,'
            + '"period_start":1780000000,'
            + '"period_end":1782592000,'
            + '"hosted_invoice_url":"https://invoice.stripe.test/in_test_123",'
            + '"lines":{"data":[{"period":{"start":1780000000,"end":1782592000},"price":{'
            + '"unit_amount":2500,'
            + '"recurring":{"interval":"month","interval_count":1}'
            + '}}]},'
            + '"status_transitions":{"paid_at":1780000000}'
            + '}}'
            + '}';
    }

    private static String invoiceFailedPayload() {
        return '{'
            + '"id":"evt_fail_123",'
            + '"type":"invoice.payment_failed",'
            + '"data":{"object":{'
            + '"id":"in_fail_123",'
            + '"subscription":"' + SUBSCRIPTION_ID + '",'
            + '"customer":"' + CUSTOMER_ID + '"'
            + '}}'
            + '}';
    }

    private static String subscriptionEventPayload(String eventType, String status, Boolean paused) {
        return subscriptionEventPayload(eventType, status, paused, false);
    }

    private static String subscriptionEventPayload(String eventType, String status, Boolean paused, Boolean cancelAtPeriodEnd) {
        String pauseJson = paused ? '"pause_collection":{"behavior":"void"},' : '';
        String cancelAtPeriodEndJson = '"cancel_at_period_end":' + String.valueOf(cancelAtPeriodEnd).toLowerCase() + ',';
        return '{'
            + '"id":"evt_sub_test",'
            + '"type":"' + eventType + '",'
            + '"data":{"object":{'
            + '"id":"' + SUBSCRIPTION_ID + '",'
            + '"status":"' + status + '",'
            + pauseJson
            + cancelAtPeriodEndJson
            + '"customer":"' + CUSTOMER_ID + '",'
            + '"default_payment_method":"pm_test_123",'
            + '"current_period_start":1780000000,'
            + '"current_period_end":1782592000,'
            + '"cancel_at":null,'
            + '"ended_at":1782592000,'
            + '"items":{"data":[{"price":{'
            + '"unit_amount":2500,'
            + '"recurring":{"interval":"month","interval_count":1}'
            + '}}]}'
            + '}}'
            + '}';
    }

    private static npe03__Recurring_Donation__c setupRecurringDonation(Id contactId, Id gauId) {
        npe03__Recurring_Donation__c rd = new npe03__Recurring_Donation__c(
            Name = 'Webhook Recurring Donation',
            npe03__Contact__c = contactId,
            npe03__Amount__c = 25,
            npe03__Installment_Period__c = 'Monthly',
            npsp__Day_of_Month__c = '1',
            npsp__InstallmentFrequency__c = 1,
            npsp__RecurringType__c = 'Open',
            npsp__PaymentMethod__c = 'Credit Card',
            npsp__Status__c = 'Active',
            Stripe_Subscription_ID__c = SUBSCRIPTION_ID,
            Stripe_GAU__c = gauId
        );
        insert rd;
        return rd;
    }

    private static Contact setupContactWithStripeCustomer() {
        StripeSubscriptionController.setRecurringDonationSyncSuppressed(true);
        insert new Stripe_Settings__c(
            SetupOwnerId = UserInfo.getOrganizationId(),
            Publishable_Key__c = 'pk_test_dummy',
            Secret_Key__c = 'sk_test_dummy',
            Webhook_Secret__c = SECRET
        );

        Account account = new Account(Name = 'Webhook Household');
        insert account;

        Contact contact = new Contact(
            FirstName = 'Webhook',
            LastName = 'Donor',
            AccountId = account.Id,
            Email = 'webhook@example.com',
            Stripe_Customer_ID__c = CUSTOMER_ID
        );
        insert contact;
        return contact;
    }

    private static RestRequest signedRequest(String payload) {
        RestRequest req = new RestRequest();
        req.httpMethod = 'POST';
        req.requestUri = '/services/apexrest/stripe/webhook';
        req.requestBody = Blob.valueOf(payload);
        req.addHeader('Stripe-Signature', signature(payload));
        return req;
    }

    private static String signature(String payload) {
        String timestamp = '123';
        Blob mac = Crypto.generateMac(
            'HmacSHA256',
            Blob.valueOf(timestamp + '.' + payload),
            Blob.valueOf(SECRET)
        );
        return 't=' + timestamp + ',v1=' + EncodingUtil.convertToHex(mac).toLowerCase();
    }

    private class StripeWebhookMock implements HttpCalloutMock {
        private final Boolean salesforceCreated;
        private final Id gauId;

        private StripeWebhookMock(Boolean salesforceCreated, Id gauId) {
            this.salesforceCreated = salesforceCreated;
            this.gauId = gauId;
        }

        public HttpResponse respond(HttpRequest req) {
            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setHeader('Content-Type', 'application/json');
            String endpoint = req.getEndpoint() == null ? '' : req.getEndpoint();
            if (endpoint.contains('/v1/subscriptions/')) {
                res.setBody(
                    '{'
                    + '"id":"' + SUBSCRIPTION_ID + '",'
                    + '"status":"active",'
                    + '"customer":"' + CUSTOMER_ID + '",'
                    + '"default_payment_method":"pm_test_123",'
                    + '"current_period_start":1780000000,'
                    + '"current_period_end":1782592000,'
                    + '"metadata":{'
                    + '"sf_created":"' + String.valueOf(salesforceCreated).toLowerCase() + '",'
                    + '"sf_gau_id":"' + (gauId == null ? '' : String.valueOf(gauId)) + '"'
                    + '},'
                    + '"items":{"data":[{"price":{'
                    + '"unit_amount":2500,'
                    + '"recurring":{"interval":"month","interval_count":1}'
                    + '}}]}'
                    + '}'
                );
            } else {
                res.setBody('{}');
            }
            return res;
        }
    }
}
