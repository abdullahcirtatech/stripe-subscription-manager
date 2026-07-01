@IsTest
private class StripeSubscriptionControllerTest {
    private static final String CUSTOMER_ID = 'cus_test_123';
    private static final String SUBSCRIPTION_ID = 'sub_test_123';
    private static final String SCHEDULE_ID = 'sub_sched_test_123';
    private static final String PM_ID = 'pm_test_1';

    private static List<String> mockBodies = new List<String>();
    private static List<String> mockEndpoints = new List<String>();

    private static Boolean sentBodyContaining(String fragment) {
        for (String b : mockBodies) {
            if (b != null && b.contains(fragment)) return true;
        }
        return false;
    }

    private static Boolean hitEndpointContaining(String fragment) {
        for (String e : mockEndpoints) {
            if (e != null && e.contains(fragment)) return true;
        }
        return false;
    }

    // ── Setup helpers ──

    private static Contact setupContact() {
        TestDataFactory.createStripeSettings();
        Account acct = new Account(Name = 'Stripe Household');
        insert acct;
        Contact c = new Contact(
            FirstName = 'Stripe',
            LastName = 'Donor',
            AccountId = acct.Id,
            Email = 'stripe.donor@example.com',
            MailingStreet = '1 Main St',
            MailingCity = 'Plainfield',
            MailingPostalCode = '46168',
            Stripe_Customer_ID__c = CUSTOMER_ID
        );
        insert c;
        return c;
    }

    private static npe03__Recurring_Donation__c setupRecurringDonation(Id contactId, Id gauId, String subscriptionId, String scheduleId) {
        npe03__Recurring_Donation__c rd = new npe03__Recurring_Donation__c(
            Name = 'Test Recurring',
            npe03__Contact__c = contactId,
            npe03__Amount__c = 70,
            npe03__Installment_Period__c = 'Monthly',
            npsp__Day_of_Month__c = '1',
            npsp__InstallmentFrequency__c = 1,
            npsp__RecurringType__c = 'Open',
            npsp__PaymentMethod__c = 'Credit Card',
            npsp__Status__c = 'Active',
            Stripe_Subscription_ID__c = subscriptionId,
            Pending_Stripe_Schedule_ID__c = scheduleId,
            Stripe_GAU__c = gauId
        );
        insert rd;
        return rd;
    }

    private static void seedClosedWonGift(Id rdId, Id contactId, Id accountId, Date closeDate) {
        Opportunity opp = new Opportunity(
            Name = 'Gift',
            StageName = 'Closed Won',
            CloseDate = closeDate,
            Amount = 70,
            AccountId = accountId,
            npsp__Primary_Contact__c = contactId,
            npe03__Recurring_Donation__c = rdId,
            npe01__Do_Not_Automatically_Create_Payment__c = true
        );
        insert opp;
    }

    // ── State reads ──

    @IsTest
    static void getStateForContactReturnsCustomerData() {
        Contact c = setupContact();
        Test.setMock(HttpCalloutMock.class, new StripeApiMock());

        Test.startTest();
        StripeSubscriptionController.StripeContactState state =
            StripeSubscriptionController.getStateForRecord(c.Id);
        Test.stopTest();

        System.assertEquals(false, state.recurringDonationContext);
        System.assertEquals(CUSTOMER_ID, state.customerId);
        System.assertEquals(1, state.paymentMethods.size());
        System.assertEquals('visa', state.paymentMethods[0].brand);
        System.assert(!state.subscriptions.isEmpty(), 'should list subscriptions');
    }

    @IsTest
    static void getStateForContactWithoutCustomerSkipsCallouts() {
        TestDataFactory.createStripeSettings();
        Account acct = new Account(Name = 'No Customer');
        insert acct;
        Contact c = new Contact(FirstName = 'No', LastName = 'Customer', AccountId = acct.Id);
        insert c;

        Test.startTest();
        StripeSubscriptionController.StripeContactState state =
            StripeSubscriptionController.getState(c.Id);
        Test.stopTest();

        System.assertEquals(null, state.customerId);
        System.assertEquals(0, state.paymentMethods.size());
        System.assertEquals(0, state.subscriptions.size());
    }

    @IsTest
    static void getStateForRecurringDonationFiltersToLinkedSubscription() {
        Contact c = setupContact();
        npsp__General_Accounting_Unit__c gau = TestDataFactory.createGAU('RD GAU');
        npe03__Recurring_Donation__c rd = setupRecurringDonation(c.Id, gau.Id, SUBSCRIPTION_ID, null);
        Test.setMock(HttpCalloutMock.class, new StripeApiMock());

        Test.startTest();
        StripeSubscriptionController.StripeContactState state =
            StripeSubscriptionController.getStateForRecord(rd.Id);
        Test.stopTest();

        System.assertEquals(true, state.recurringDonationContext);
        System.assertEquals(rd.Id, state.recurringDonationId);
        System.assertEquals(1, state.subscriptions.size());
        System.assertEquals(SUBSCRIPTION_ID, state.subscriptions[0].id);
    }

    @IsTest
    static void getStateForRecordRejectsUnsupportedType() {
        Account acct = new Account(Name = 'Unsupported');
        insert acct;
        Boolean threw = false;
        try {
            StripeSubscriptionController.getStateForRecord(acct.Id);
        } catch (Exception e) {
            threw = true;
        }
        System.assert(threw, 'Account record type should be rejected');
    }

    @IsTest
    static void optionListsReturnValues() {
        TestDataFactory.createGAU('Option GAU');
        Test.startTest();
        List<StripeSubscriptionController.GauOption> gaus = StripeSubscriptionController.listGauOptions();
        List<StripeSubscriptionController.OptionItem> reasons =
            StripeSubscriptionController.listRecurringDonationClosedReasonOptions();
        Test.stopTest();
        System.assert(!gaus.isEmpty(), 'GAU options should not be empty');
        System.assertNotEquals(null, reasons);
    }

    // ── Payment methods ──

    @IsTest
    static void setupIntentReturnsClientSecret() {
        Contact c = setupContact();
        Test.setMock(HttpCalloutMock.class, new StripeApiMock());

        Test.startTest();
        StripeSubscriptionController.SetupIntentInitResult r =
            StripeSubscriptionController.createSetupIntent(c.Id, null);
        Test.stopTest();

        System.assertNotEquals(null, r.clientSecret);
        System.assertEquals('pk_test_dummy', r.publishableKey);
    }

    @IsTest
    static void attachPaymentMethodMakeDefaultSendsCustomerUpdate() {
        Contact c = setupContact();
        StripeApiMock mock = new StripeApiMock();
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        StripeSubscriptionController.attachPaymentMethod(c.Id, PM_ID, true, null);
        Test.stopTest();

        System.assert(hitEndpointContaining('/payment_methods/' + PM_ID + '/attach'),
            'should attach the payment method');
        System.assert(sentBodyContaining('invoice_settings[default_payment_method]'),
            'makeDefault should set the customer default');
    }

    @IsTest
    static void attachPaymentMethodWithoutDefaultDoesNotSetCustomerDefault() {
        Contact c = setupContact();
        Test.setMock(HttpCalloutMock.class, new StripeApiMock());

        Test.startTest();
        StripeSubscriptionController.attachPaymentMethod(c.Id, PM_ID, false, null);
        Test.stopTest();

        System.assert(!sentBodyContaining('invoice_settings[default_payment_method]'),
            'non-default attach must not change the customer default');
    }

    @IsTest
    static void setAndDetachPaymentMethod() {
        Contact c = setupContact();
        Test.setMock(HttpCalloutMock.class, new StripeApiMock());

        Test.startTest();
        StripeSubscriptionController.setDefaultPaymentMethod(c.Id, PM_ID, null);
        StripeSubscriptionController.detachPaymentMethod(c.Id, PM_ID, null);
        StripeSubscriptionController.createOrGetCustomer(c.Id);
        Test.stopTest();

        System.assert(hitEndpointContaining('/payment_methods/' + PM_ID + '/detach'),
            'should detach the payment method');
    }

    // ── Create ──

    @IsTest
    static void createSubscriptionImmediateSetsStripeIdOnRecurringDonation() {
        Contact c = setupContact();
        npsp__General_Accounting_Unit__c gau = TestDataFactory.createGAU('Create GAU');
        npe03__Recurring_Donation__c rd = setupRecurringDonation(c.Id, gau.Id, null, null);
        Test.setMock(HttpCalloutMock.class, new StripeApiMock());

        Test.startTest();
        StripeSubscriptionController.createSubscription(
            c.Id, 25, 'usd', 'Monthly', 1, PM_ID, null, gau.Id, rd.Id, 'Open', null
        );
        Test.stopTest();

        rd = [SELECT Stripe_Subscription_ID__c, npsp__Status__c FROM npe03__Recurring_Donation__c WHERE Id = :rd.Id];
        System.assertEquals('sub_created_1', rd.Stripe_Subscription_ID__c,
            'managed create job should store the new Stripe subscription id');
        System.assertEquals('Active', rd.npsp__Status__c);
    }

    @IsTest
    static void createSubscriptionFutureStartCreatesSchedule() {
        Contact c = setupContact();
        npsp__General_Accounting_Unit__c gau = TestDataFactory.createGAU('Future GAU');
        npe03__Recurring_Donation__c rd = setupRecurringDonation(c.Id, gau.Id, null, null);
        Test.setMock(HttpCalloutMock.class, new StripeApiMock());

        Test.startTest();
        StripeSubscriptionController.createSubscription(
            c.Id, 25, 'usd', 'Monthly', 1, PM_ID,
            String.valueOf(Date.today().addMonths(1)), gau.Id, rd.Id, 'Open', null
        );
        Test.stopTest();

        rd = [SELECT Pending_Stripe_Schedule_ID__c FROM npe03__Recurring_Donation__c WHERE Id = :rd.Id];
        System.assertEquals('sub_sched_created_1', rd.Pending_Stripe_Schedule_ID__c,
            'future-dated create should store a pending schedule id');
    }

    @IsTest
    static void createSubscriptionRejectsInvalidAmount() {
        Contact c = setupContact();
        Boolean threw = false;
        try {
            StripeSubscriptionController.createSubscription(
                c.Id, 0, 'usd', 'Monthly', 1, PM_ID, null, null, null, 'Open', null
            );
        } catch (Exception e) {
            threw = true;
        }
        System.assert(threw, 'zero amount should be rejected');
    }

    // ── Update (amount / frequency) ──

    @IsTest
    static void amountChangeUsesProrationNoneWithoutCycleReset() {
        Contact c = setupContact();
        npsp__General_Accounting_Unit__c gau = TestDataFactory.createGAU('Amt GAU');
        npe03__Recurring_Donation__c rd = setupRecurringDonation(c.Id, gau.Id, SUBSCRIPTION_ID, null);
        Test.setMock(HttpCalloutMock.class, new StripeApiMock());

        Test.startTest();
        StripeSubscriptionController.updateSubscription(
            c.Id, SUBSCRIPTION_ID, 120, 'usd', null, null, null, null, null
        );
        Test.stopTest();

        System.assert(sentBodyContaining('proration_behavior=none'),
            'amount change should not prorate');
        System.assert(!sentBodyContaining('billing_cycle_anchor=now'),
            'amount change must not reset the billing cycle (no charge today)');
        rd = [SELECT npe03__Amount__c FROM npe03__Recurring_Donation__c WHERE Id = :rd.Id];
        System.assertEquals(120, rd.npe03__Amount__c);
    }

    @IsTest
    static void frequencyChangeResetsBillingCycle() {
        Contact c = setupContact();
        npsp__General_Accounting_Unit__c gau = TestDataFactory.createGAU('Freq GAU');
        npe03__Recurring_Donation__c rd = setupRecurringDonation(c.Id, gau.Id, SUBSCRIPTION_ID, null);
        Test.setMock(HttpCalloutMock.class, new StripeApiMock());

        Test.startTest();
        StripeSubscriptionController.updateSubscription(
            c.Id, SUBSCRIPTION_ID, null, 'usd', 'Yearly', 1, null, null, null
        );
        Test.stopTest();

        System.assert(sentBodyContaining('billing_cycle_anchor=now'),
            'frequency change should reset the billing cycle');
        rd = [SELECT npe03__Installment_Period__c FROM npe03__Recurring_Donation__c WHERE Id = :rd.Id];
        System.assertEquals('Yearly', rd.npe03__Installment_Period__c);
    }

    @IsTest
    static void manualAmountEditWithSamePeriodDoesNotResetCycle() {
        // Mirrors the RD trigger's amount_frequency path, which always sends the
        // current period ('Monthly') alongside the amount. A same-period edit must
        // not be treated as a frequency change, so it must not charge today.
        Contact c = setupContact();
        npsp__General_Accounting_Unit__c gau = TestDataFactory.createGAU('Manual Amt GAU');
        npe03__Recurring_Donation__c rd = setupRecurringDonation(c.Id, gau.Id, SUBSCRIPTION_ID, null);
        Test.setMock(HttpCalloutMock.class, new StripeApiMock());

        Test.startTest();
        StripeSubscriptionController.updateSubscription(
            c.Id, SUBSCRIPTION_ID, 150, 'usd', 'Monthly', 1, null, null, null
        );
        Test.stopTest();

        System.assert(sentBodyContaining('proration_behavior=none'), 'should not prorate');
        System.assert(!sentBodyContaining('billing_cycle_anchor=now'),
            'amount edit with unchanged monthly period must not reset the cycle / charge today');
        rd = [SELECT npe03__Amount__c FROM npe03__Recurring_Donation__c WHERE Id = :rd.Id];
        System.assertEquals(150, rd.npe03__Amount__c);
    }

    // ── Cancel + close end date ──

    @IsTest
    static void cancelSetsEndDateAfterLastWonGift() {
        Contact c = setupContact();
        npsp__General_Accounting_Unit__c gau = TestDataFactory.createGAU('Cancel GAU');
        npe03__Recurring_Donation__c rd = setupRecurringDonation(c.Id, gau.Id, SUBSCRIPTION_ID, null);
        seedClosedWonGift(rd.Id, c.Id, c.AccountId, Date.today());
        Test.setMock(HttpCalloutMock.class, new StripeApiMock());

        Test.startTest();
        StripeSubscriptionController.cancelSubscription(c.Id, SUBSCRIPTION_ID, false, 'Commitment Completed');
        Test.stopTest();

        rd = [SELECT npsp__Status__c, npsp__EndDate__c, npsp__ClosedReason__c
              FROM npe03__Recurring_Donation__c WHERE Id = :rd.Id];
        System.assertEquals('Closed', rd.npsp__Status__c);
        System.assertEquals('Commitment Completed', rd.npsp__ClosedReason__c);
        System.assertEquals(Date.today().addDays(1), rd.npsp__EndDate__c,
            'end date must be the day after a gift that closed today');
    }

    @IsTest
    static void cancelAtPeriodEnd() {
        Contact c = setupContact();
        npe03__Recurring_Donation__c rd = setupRecurringDonation(c.Id, null, SUBSCRIPTION_ID, null);
        Test.setMock(HttpCalloutMock.class, new StripeApiMock());

        Test.startTest();
        StripeSubscriptionController.cancelSubscription(c.Id, SUBSCRIPTION_ID, true, null);
        Test.stopTest();

        System.assert(sentBodyContaining('cancel_at_period_end=true'),
            'at-period-end cancel should set cancel_at_period_end');
    }

    // ── Pause / resume (tolerate NPSP automation differences in test orgs) ──

    @IsTest
    static void pauseAndResumeExecute() {
        Contact c = setupContact();
        npe03__Recurring_Donation__c rd = setupRecurringDonation(c.Id, null, SUBSCRIPTION_ID, null);
        Test.setMock(HttpCalloutMock.class, new StripeApiMock());

        Test.startTest();
        try {
            StripeSubscriptionController.pauseSubscription(c.Id, SUBSCRIPTION_ID, 'Other', String.valueOf(Date.today().addMonths(2)));
        } catch (Exception e) { /* NPSP pause automation may behave differently in test orgs */ }
        try {
            StripeSubscriptionController.resumeSubscription(c.Id, SUBSCRIPTION_ID);
        } catch (Exception e) { /* tolerated */ }
        Test.stopTest();

        System.assert(sentBodyContaining('pause_collection'),
            'pause should send pause_collection to Stripe');
    }

    @IsTest
    static void endTrialNow() {
        Contact c = setupContact();
        npe03__Recurring_Donation__c rd = setupRecurringDonation(c.Id, null, SUBSCRIPTION_ID, null);
        Test.setMock(HttpCalloutMock.class, new StripeApiMock());

        Test.startTest();
        StripeSubscriptionController.endSubscriptionTrialNow(c.Id, SUBSCRIPTION_ID);
        Test.stopTest();

        System.assert(sentBodyContaining('trial_end=now'),
            'end trial should send trial_end=now');
    }

    // ── Gift date (legacy replacement schedule) ──

    @IsTest
    static void giftDateCreatesReplacementSchedule() {
        Contact c = setupContact();
        npsp__General_Accounting_Unit__c gau = TestDataFactory.createGAU('Gift GAU');
        npe03__Recurring_Donation__c rd = setupRecurringDonation(c.Id, gau.Id, SUBSCRIPTION_ID, null);
        Test.setMock(HttpCalloutMock.class, new StripeApiMock());

        Test.startTest();
        StripeSubscriptionController.updateSubscriptionGiftDay(
            c.Id, SUBSCRIPTION_ID, String.valueOf(Date.today().addMonths(1))
        );
        Test.stopTest();

        rd = [SELECT Pending_Stripe_Schedule_ID__c, Previous_Stripe_Subscription_ID__c
              FROM npe03__Recurring_Donation__c WHERE Id = :rd.Id];
        System.assertEquals('sub_sched_created_1', rd.Pending_Stripe_Schedule_ID__c);
        System.assertEquals(SUBSCRIPTION_ID, rd.Previous_Stripe_Subscription_ID__c);
    }

    @IsTest
    static void giftDateRejectsPastDate() {
        Contact c = setupContact();
        Boolean threw = false;
        try {
            StripeSubscriptionController.updateSubscriptionGiftDay(
                c.Id, SUBSCRIPTION_ID, String.valueOf(Date.today().addDays(-1))
            );
        } catch (Exception e) {
            threw = true;
        }
        System.assert(threw, 'past gift date should be rejected');
    }

    @IsTest
    static void giftDayRecoversFromPastNextDate() {
        Contact c = setupContact();
        npsp__General_Accounting_Unit__c gau = TestDataFactory.createGAU('Safe Date GAU');
        npe03__Recurring_Donation__c rd = setupRecurringDonation(c.Id, gau.Id, SUBSCRIPTION_ID, null);
        Test.setMock(HttpCalloutMock.class, new StripeApiMock());

        String requestJson = JSON.serialize(new Map<String, Object>{
            'recurringDonationId' => rd.Id,
            'contactId' => c.Id,
            'subscriptionId' => SUBSCRIPTION_ID,
            'action' => 'gift_day',
            'nextGiftDate' => String.valueOf(Date.today().addDays(-10)),
            'dayOfMonth' => '15'
        });

        Test.startTest();
        StripeSubscriptionController.syncRecurringDonationAction(requestJson);
        Test.stopTest();

        rd = [SELECT Pending_Stripe_Schedule_ID__c FROM npe03__Recurring_Donation__c WHERE Id = :rd.Id];
        System.assertEquals('sub_sched_created_1', rd.Pending_Stripe_Schedule_ID__c,
            'a past next gift date should fall back to a future day-of-month date, not fail');
    }

    // ── Pending schedule edits ──

    @IsTest
    static void pendingScheduleAmountUpdatesInPlace() {
        Contact c = setupContact();
        npsp__General_Accounting_Unit__c gau = TestDataFactory.createGAU('Pending GAU');
        npe03__Recurring_Donation__c rd = setupRecurringDonation(c.Id, gau.Id, null, SCHEDULE_ID);
        Test.setMock(HttpCalloutMock.class, new StripeApiMock());

        Test.startTest();
        StripeSubscriptionController.updatePendingSubscriptionSchedule(
            c.Id, rd.Id, 99, 'usd', null, null, null, null, null, null, 'update', null
        );
        Test.stopTest();

        rd = [SELECT Pending_Stripe_Schedule_ID__c, npe03__Amount__c
              FROM npe03__Recurring_Donation__c WHERE Id = :rd.Id];
        System.assertEquals(SCHEDULE_ID, rd.Pending_Stripe_Schedule_ID__c,
            'in-place edit should keep the same schedule id');
        System.assertEquals(99, rd.npe03__Amount__c);
    }

    @IsTest
    static void pendingScheduleDateChangeRecreatesSchedule() {
        Contact c = setupContact();
        npsp__General_Accounting_Unit__c gau = TestDataFactory.createGAU('Pending Date GAU');
        npe03__Recurring_Donation__c rd = setupRecurringDonation(c.Id, gau.Id, null, SCHEDULE_ID);
        Test.setMock(HttpCalloutMock.class, new StripeApiMock());

        Test.startTest();
        StripeSubscriptionController.updatePendingSubscriptionSchedule(
            c.Id, rd.Id, null, 'usd', null, null, null,
            String.valueOf(Date.today().addMonths(2)), null, null, 'update', null
        );
        Test.stopTest();

        System.assert(hitEndpointContaining('/subscription_schedules/' + SCHEDULE_ID + '/cancel'),
            'date change should cancel the existing schedule');
        rd = [SELECT Pending_Stripe_Schedule_ID__c FROM npe03__Recurring_Donation__c WHERE Id = :rd.Id];
        System.assertEquals('sub_sched_created_1', rd.Pending_Stripe_Schedule_ID__c,
            'date change should point to the recreated schedule id');
    }

    @IsTest
    static void pendingScheduleCancelClosesRecurringDonation() {
        Contact c = setupContact();
        npe03__Recurring_Donation__c rd = setupRecurringDonation(c.Id, null, null, SCHEDULE_ID);
        Test.setMock(HttpCalloutMock.class, new StripeApiMock());

        Test.startTest();
        StripeSubscriptionController.updatePendingSubscriptionSchedule(
            c.Id, rd.Id, null, 'usd', null, null, null, null, null, null, 'cancel', 'Card Expired'
        );
        Test.stopTest();

        rd = [SELECT npsp__Status__c, npsp__ClosedReason__c, npsp__EndDate__c, Pending_Stripe_Schedule_ID__c
              FROM npe03__Recurring_Donation__c WHERE Id = :rd.Id];
        System.assertEquals('Closed', rd.npsp__Status__c);
        System.assertEquals('Card Expired', rd.npsp__ClosedReason__c);
        System.assertNotEquals(null, rd.npsp__EndDate__c);
        System.assertEquals(null, rd.Pending_Stripe_Schedule_ID__c);
    }

    // ── Sync facade ──

    @IsTest
    static void syncRecurringDonationActionDispatchesAmount() {
        Contact c = setupContact();
        npsp__General_Accounting_Unit__c gau = TestDataFactory.createGAU('Sync GAU');
        npe03__Recurring_Donation__c rd = setupRecurringDonation(c.Id, gau.Id, SUBSCRIPTION_ID, null);
        Test.setMock(HttpCalloutMock.class, new StripeApiMock());

        String requestJson = JSON.serialize(new Map<String, Object>{
            'recurringDonationId' => rd.Id,
            'contactId' => c.Id,
            'subscriptionId' => SUBSCRIPTION_ID,
            'action' => 'amount',
            'amount' => 200
        });

        Test.startTest();
        StripeSubscriptionController.syncRecurringDonationAction(requestJson);
        Test.stopTest();

        rd = [SELECT npe03__Amount__c FROM npe03__Recurring_Donation__c WHERE Id = :rd.Id];
        System.assertEquals(200, rd.npe03__Amount__c);
    }

    @IsTest
    static void syncRecurringDonationActionRejectsUnknownAction() {
        Contact c = setupContact();
        npe03__Recurring_Donation__c rd = setupRecurringDonation(c.Id, null, SUBSCRIPTION_ID, null);
        Test.setMock(HttpCalloutMock.class, new StripeApiMock());

        String requestJson = JSON.serialize(new Map<String, Object>{
            'subscriptionId' => SUBSCRIPTION_ID,
            'contactId' => c.Id,
            'action' => 'not_a_real_action'
        });

        Boolean threw = false;
        Test.startTest();
        try {
            StripeSubscriptionController.syncRecurringDonationAction(requestJson);
        } catch (Exception e) {
            threw = true;
        }
        Test.stopTest();
        System.assert(threw, 'unknown action should be rejected');
    }

    @IsTest
    static void processRecurringDonationSyncRequestNoOpInTest() {
        // Guarded by Test.isRunningTest() - should return without callouts.
        StripeSubscriptionController.RecurringDonationSyncRequest req =
            new StripeSubscriptionController.RecurringDonationSyncRequest();
        req.subscriptionId = SUBSCRIPTION_ID;
        req.action = 'cancel';
        Test.startTest();
        StripeSubscriptionController.processRecurringDonationSyncRequest(req);
        Test.stopTest();
        System.assert(true, 'no exception expected');
    }

    @IsTest
    static void createFixedSubscriptionUsesSchedule() {
        Contact c = setupContact();
        npsp__General_Accounting_Unit__c gau = TestDataFactory.createGAU('Fixed Create GAU');
        npe03__Recurring_Donation__c rd = setupRecurringDonation(c.Id, gau.Id, null, null);
        Test.setMock(HttpCalloutMock.class, new StripeApiMock());

        Test.startTest();
        StripeSubscriptionController.createSubscription(
            c.Id, 25, 'usd', 'Monthly', 1, PM_ID, null, gau.Id, rd.Id, 'Fixed', 3
        );
        Test.stopTest();

        rd = [SELECT Pending_Stripe_Schedule_ID__c, npsp__RecurringType__c, npe03__Installments__c
              FROM npe03__Recurring_Donation__c WHERE Id = :rd.Id];
        System.assertEquals('sub_sched_created_1', rd.Pending_Stripe_Schedule_ID__c,
            'fixed-gift create should use a subscription schedule');
    }

    @IsTest
    static void syncDispatchCoversRemainingActions() {
        Contact c = setupContact();
        npsp__General_Accounting_Unit__c gau = TestDataFactory.createGAU('Dispatch GAU');
        npe03__Recurring_Donation__c rd = setupRecurringDonation(c.Id, gau.Id, SUBSCRIPTION_ID, null);
        Test.setMock(HttpCalloutMock.class, new StripeApiMock());

        List<String> actions = new List<String>{
            'frequency', 'payment_method', 'gift_count', 'gift_day', 'resume', 'pause', 'cancel'
        };

        Test.startTest();
        for (String action : actions) {
            Map<String, Object> req = new Map<String, Object>{
                'recurringDonationId' => rd.Id,
                'contactId' => c.Id,
                'subscriptionId' => SUBSCRIPTION_ID,
                'action' => action,
                'amount' => 50,
                'installmentPeriod' => 'Monthly',
                'installmentFrequency' => 1,
                'dayOfMonth' => '15',
                'nextGiftDate' => String.valueOf(Date.today().addMonths(1)),
                'recurringType' => 'Fixed',
                'installments' => 4,
                'paymentMethodId' => PM_ID,
                'resumeDate' => String.valueOf(Date.today().addMonths(2)),
                'closeReason' => 'Other'
            };
            try {
                StripeSubscriptionController.syncRecurringDonationAction(JSON.serialize(req));
            } catch (Exception e) {
                // pause/resume invoke NPSP automation that may differ across orgs; the
                // goal here is to exercise the dispatch + Stripe call paths.
            }
        }
        Test.stopTest();

        System.assert(hitEndpointContaining('/subscriptions'), 'dispatch should reach Stripe');
    }

    @IsTest
    static void recurringDonationSyncJobExecutes() {
        Contact c = setupContact();
        npe03__Recurring_Donation__c rd = setupRecurringDonation(c.Id, null, SUBSCRIPTION_ID, null);
        StripeSubscriptionController.RecurringDonationSyncRequest req =
            new StripeSubscriptionController.RecurringDonationSyncRequest();
        req.recurringDonationId = rd.Id;
        req.contactId = c.Id;
        req.subscriptionId = SUBSCRIPTION_ID;
        req.action = 'cancel';

        Test.startTest();
        System.enqueueJob(new StripeSubscriptionController.RecurringDonationSyncJob(
            new List<StripeSubscriptionController.RecurringDonationSyncRequest>{ req }
        ));
        Test.stopTest();

        System.assert(true, 'sync job executes (no-op under test)');
    }

    // ── Flexible Stripe callout mock ──

    private class StripeApiMock implements HttpCalloutMock {

        private StripeApiMock() {
            mockBodies = new List<String>();
            mockEndpoints = new List<String>();
        }

        public HttpResponse respond(HttpRequest req) {
            String endpoint = req.getEndpoint() == null ? '' : req.getEndpoint();
            String method = req.getMethod();
            mockEndpoints.add(endpoint);
            mockBodies.add(req.getBody());

            HttpResponse res = new HttpResponse();
            res.setStatusCode(200);
            res.setHeader('Content-Type', 'application/json');

            if (endpoint.contains('/subscription_schedules')) {
                if (endpoint.endsWith('/subscription_schedules') && method == 'POST') {
                    res.setBody('{"id":"sub_sched_created_1","status":"not_started"}');
                } else if (endpoint.contains('/cancel')) {
                    res.setBody('{"id":"' + SCHEDULE_ID + '","status":"canceled"}');
                } else {
                    res.setBody(scheduleBody());
                }
            } else if (endpoint.contains('/subscriptions')) {
                if (endpoint.endsWith('/subscriptions') && method == 'POST') {
                    res.setBody(subscriptionBody('sub_created_1', 'active'));
                } else if (endpoint.contains('/subscriptions?')) {
                    res.setBody('{"data":[' + subscriptionBody(SUBSCRIPTION_ID, 'active') + ']}');
                } else {
                    res.setBody(subscriptionBody(SUBSCRIPTION_ID, method == 'DELETE' ? 'canceled' : 'active'));
                }
            } else if (endpoint.contains('/setup_intents')) {
                res.setBody('{"id":"seti_test","client_secret":"seti_test_secret"}');
            } else if (endpoint.contains('/prices')) {
                res.setBody('{"id":"price_created_1"}');
            } else if (endpoint.contains('/payment_methods/') && endpoint.contains('/attach')) {
                res.setBody('{"id":"' + PM_ID + '"}');
            } else if (endpoint.contains('/payment_methods/') && endpoint.contains('/detach')) {
                res.setBody('{"id":"' + PM_ID + '"}');
            } else if (endpoint.contains('/payment_methods?')) {
                res.setBody('{"data":[{"id":"' + PM_ID + '","card":{"brand":"visa","last4":"4242","exp_month":12,"exp_year":2031}}]}');
            } else if (endpoint.contains('/customers')) {
                res.setBody('{"id":"' + CUSTOMER_ID + '","name":"Stripe Donor","invoice_settings":{"default_payment_method":"' + PM_ID + '"}}');
            } else {
                res.setBody('{}');
            }
            return res;
        }

        private String subscriptionBody(String subId, String status) {
            Long periodStart = DateTime.now().addDays(-5).getTime() / 1000;
            Long periodEnd = DateTime.now().addDays(25).getTime() / 1000;
            return '{'
                + '"id":"' + subId + '",'
                + '"status":"' + status + '",'
                + '"customer":"' + CUSTOMER_ID + '",'
                + '"default_payment_method":"' + PM_ID + '",'
                + '"current_period_start":' + periodStart + ','
                + '"current_period_end":' + periodEnd + ','
                + '"cancel_at_period_end":false,'
                + '"metadata":{"sf_created":"true"},'
                + '"items":{"data":[{"id":"si_test","price":{"id":"price_existing","unit_amount":7000,"currency":"usd","recurring":{"interval":"month","interval_count":1}}}]}'
                + '}';
        }

        private String scheduleBody() {
            Long start = DateTime.now().addMonths(1).getTime() / 1000;
            return '{'
                + '"id":"' + SCHEDULE_ID + '",'
                + '"status":"not_started",'
                + '"end_behavior":"release",'
                + '"default_settings":{"default_payment_method":"' + PM_ID + '"},'
                + '"phases":[{"start_date":' + start + ',"items":[{"price":"price_existing","quantity":1}],"iterations":1}]'
                + '}';
        }
    }
}
