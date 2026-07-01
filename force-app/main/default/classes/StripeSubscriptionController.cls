public without sharing class StripeSubscriptionController {
    private static final String API_BASE = 'https://api.stripe.com/v1';
    private static final String CONTACT_CUSTOMER_FIELD = 'Stripe_Customer_ID__c';
    private static final String STRIPE_BUSINESS_TIMEZONE = 'America/Chicago';
    private static Boolean skipRecurringDonationTrigger = false;
    private static Boolean suppressRecurringDonationSync = false;

    public class PaymentMethodInfo {
        @AuraEnabled public String id;
        @AuraEnabled public String brand;
        @AuraEnabled public String last4;
        @AuraEnabled public Integer expMonth;
        @AuraEnabled public Integer expYear;
        @AuraEnabled public Boolean isDefault;
    }

    public class SubscriptionInfo {
        @AuraEnabled public String id;
        @AuraEnabled public String status;
        @AuraEnabled public String priceId;
        @AuraEnabled public Decimal amount;
        @AuraEnabled public String currencyCode;
        @AuraEnabled public String interval;
        @AuraEnabled public Integer intervalCount;
        @AuraEnabled public Long currentPeriodStart;
        @AuraEnabled public Long currentPeriodEnd;
        @AuraEnabled public Long cancelAt;
        @AuraEnabled public Long canceledAt;
        @AuraEnabled public Long endedAt;
        @AuraEnabled public Long pauseResumesAt;
        @AuraEnabled public Boolean cancelAtPeriodEnd;
        @AuraEnabled public Boolean collectionPaused;
        @AuraEnabled public String defaultPaymentMethod;
        @AuraEnabled public Id recurringDonationId;
        @AuraEnabled public String recurringType;
        @AuraEnabled public Integer installments;
        @AuraEnabled public String previousStripeSubscriptionId;
    }

    private class SubscriptionScheduleSummary {
        Boolean isFixed;
        Integer installments;
    }

    public class StripeContactState {
        @AuraEnabled public Id contactId;
        @AuraEnabled public Id recurringDonationId;
        @AuraEnabled public String recurringDonationName;
        @AuraEnabled public Boolean recurringDonationContext;
        @AuraEnabled public String customerId;
        @AuraEnabled public String customerName;
        @AuraEnabled public String contactName;
        @AuraEnabled public String contactEmail;
        @AuraEnabled public String contactPhone;
        @AuraEnabled public String contactMailingStreet;
        @AuraEnabled public String contactMailingCity;
        @AuraEnabled public String contactMailingState;
        @AuraEnabled public String contactMailingPostalCode;
        @AuraEnabled public String contactMailingCountry;
        @AuraEnabled public List<PaymentMethodInfo> paymentMethods;
        @AuraEnabled public List<SubscriptionInfo> subscriptions;
        @AuraEnabled public Decimal recurringAmount;
        @AuraEnabled public String recurringInstallmentPeriod;
        @AuraEnabled public Integer recurringInstallmentFrequency;
        @AuraEnabled public String recurringDayOfMonth;
        @AuraEnabled public Date recurringNextPaymentDate;
        @AuraEnabled public Date recurringLastPaymentDate;
        @AuraEnabled public String recurringStatus;
        @AuraEnabled public String recurringClosedReason;
        @AuraEnabled public Date recurringEndDate;
        @AuraEnabled public String recurringStripeSubscriptionId;
        @AuraEnabled public String recurringPreviousStripeSubscriptionId;
        @AuraEnabled public String recurringPendingStripeScheduleId;
        @AuraEnabled public String recurringStripePaymentMethodId;
        @AuraEnabled public String recurringType;
        @AuraEnabled public Integer recurringInstallments;
        @AuraEnabled public Decimal recurringPaidAmount;
        @AuraEnabled public Integer recurringPaidInstallments;
        @AuraEnabled public Date recurringStartDate;
    }

    public class SetupIntentInitResult {
        @AuraEnabled public String customerId;
        @AuraEnabled public String clientSecret;
        @AuraEnabled public String publishableKey;
    }

    public class GauOption {
        @AuraEnabled public String id;
        @AuraEnabled public String name;
    }
    public class OptionItem {
        @AuraEnabled public String value;
        @AuraEnabled public String label;
    }

    private class CustomerRef {
        String customerId;
        Boolean needsContactSave;
    }

    public class RecurringDonationSyncRequest {
        @AuraEnabled public Id recurringDonationId;
        @AuraEnabled public Id contactId;
        @AuraEnabled public String subscriptionId;
        @AuraEnabled public String action;
        @AuraEnabled public String actionName;
        @AuraEnabled public Decimal amount;
        @AuraEnabled public String installmentPeriod;
        @AuraEnabled public Integer installmentFrequency;
        @AuraEnabled public String dayOfMonth;
        @AuraEnabled public String nextGiftDate;
        @AuraEnabled public String closeReason;
        @AuraEnabled public String recurringType;
        @AuraEnabled public Integer installments;
        @AuraEnabled public String paymentMethodId;
        @AuraEnabled public String resumeDate;
    }

    private class ManagedCreateRequest {
        Id contactId;
        Id recurringDonationId;
        String customerId;
        Decimal amount;
        String currencyCode;
        String interval;
        Integer intervalCount;
        String paymentMethodId;
        Date startDate;
        String gauId;
        String recurringType;
        Integer installments;
    }

    public class StripeManagedCreateJob implements Queueable, Database.AllowsCallouts {
        private final ManagedCreateRequest request;

        public StripeManagedCreateJob(ManagedCreateRequest request) {
            this.request = request;
        }

        public void execute(QueueableContext context) {
            if (request == null || request.recurringDonationId == null || request.contactId == null) {
                return;
            }

            Integer useIntervalCount = normalizeIntervalCount(request.intervalCount);
            FixedDonationConfig fixedConfig = buildFixedDonationConfig(
                request.recurringType,
                request.installments,
                0
            );

            String customerId = request.customerId;
            if (String.isBlank(customerId)) {
                CustomerRef customer = getOrCreateCustomerRef(request.contactId);
                saveContactCustomerIdIfNeeded(request.contactId, customer);
                customerId = customer.customerId;
            }
            if (String.isBlank(customerId)) {
                return;
            }

            String effectivePmId = request.paymentMethodId;
            if (String.isNotBlank(effectivePmId)) {
                // Attach the card and use it for this subscription (set as the
                // subscription's default_payment_method below). The customer-wide
                // default is left untouched unless the user explicitly sets it.
                callStripe(
                    'POST',
                    '/payment_methods/' + encPath(effectivePmId) + '/attach',
                    'customer=' + enc(customerId)
                );
            }

            String priceId = createRecurringPrice(
                request.amount,
                request.currencyCode,
                request.interval,
                useIntervalCount,
                request.gauId
            );

            if (request.startDate != null && request.startDate > Date.today()) {
                enqueueManagedScheduleCreate(
                    customerId,
                    request.contactId,
                    request.recurringDonationId,
                    priceId,
                    effectivePmId,
                    request.startDate,
                    request.gauId,
                    request.interval,
                    useIntervalCount,
                    fixedConfig,
                    request.amount,
                    request.recurringType,
                    request.installments
                );
                return;
            }

            if (fixedConfig != null && fixedConfig.isFixed) {
                enqueueManagedImmediateFixedCreate(
                    customerId,
                    request.contactId,
                    request.recurringDonationId,
                    priceId,
                    effectivePmId,
                    request.gauId,
                    fixedConfig,
                    request.amount,
                    request.interval,
                    useIntervalCount,
                    request.recurringType,
                    request.installments,
                    request.startDate
                );
                return;
            }

            String body = 'customer=' + enc(customerId)
                + '&items[0][price]=' + enc(priceId)
                + '&collection_method=charge_automatically'
                + '&metadata[sf_created]=true'
                + '&metadata[sf_source]=' + enc('salesforce_component')
                + '&metadata[sf_contact_id]=' + enc(String.valueOf(request.contactId))
                + '&metadata[sf_rd_id]=' + enc(String.valueOf(request.recurringDonationId));

            if (String.isNotBlank(effectivePmId)) {
                body += '&default_payment_method=' + enc(effectivePmId);
            }
            if (String.isNotBlank(request.gauId)) {
                body += '&metadata[sf_gau_id]=' + enc(request.gauId);
            }

            Map<String, Object> created = parseResponse(callStripe('POST', '/subscriptions', body), 200);
            String createdSubscriptionId = (String) created.get('id');
            Date nextPaymentDate = epochDate(toLong(created.get('current_period_end')), request.startDate);

            syncRecurringDonationAfterManagedCreate(
                request.recurringDonationId,
                createdSubscriptionId,
                request.amount,
                request.interval,
                useIntervalCount,
                nextPaymentDate,
                request.recurringType,
                request.installments
            );
            if (String.isNotBlank(request.gauId)) {
                saveSelectedGauToRecurringDonation(createdSubscriptionId, request.gauId, request.recurringDonationId);
            }
        }
    }

    public class StripeSubscriptionDeleteJob implements Queueable, Database.AllowsCallouts {
        private final String subscriptionId;

        public StripeSubscriptionDeleteJob(String subscriptionId) {
            this.subscriptionId = subscriptionId;
        }

        public void execute(QueueableContext context) {
            if (String.isBlank(subscriptionId)) {
                return;
            }
            parseResponse(callStripe('DELETE', '/subscriptions/' + encPath(subscriptionId), null), 200);
        }
    }

    // Pushes manual Recurring Donation edits to Stripe asynchronously. Enqueued by
    // RecurringDonationTrigger; kept here so the component's Stripe logic lives in a
    // single Apex class.
    public class RecurringDonationSyncJob implements Queueable, Database.AllowsCallouts {
        private final List<RecurringDonationSyncRequest> requests;

        public RecurringDonationSyncJob(List<RecurringDonationSyncRequest> requests) {
            this.requests = requests == null
                ? new List<RecurringDonationSyncRequest>()
                : new List<RecurringDonationSyncRequest>(requests);
        }

        public void execute(QueueableContext context) {
            for (RecurringDonationSyncRequest request : requests) {
                processRecurringDonationSyncRequest(request);
            }
        }
    }

    @AuraEnabled(cacheable=false)
    public static StripeContactState getState(Id contactId) {
        if (contactId == null) throw new AuraHandledException('Contact Id is required.');

        StripeContactState state = new StripeContactState();
        state.contactId = contactId;
        Contact c = [
            SELECT Id, FirstName, LastName, Email, MobilePhone, Phone,
                   MailingStreet, MailingCity, MailingState, MailingStateCode,
                   MailingPostalCode, MailingCountry, MailingCountryCode
            FROM Contact
            WHERE Id = :contactId
            LIMIT 1
        ];
        state.contactName = String.join(new List<String>{c.FirstName, c.LastName}, ' ').trim();
        state.contactEmail = c.Email;
        state.contactPhone = c.Phone;
        state.contactMailingStreet = c.MailingStreet;
        state.contactMailingCity = c.MailingCity;
        state.contactMailingState = String.isNotBlank(c.MailingStateCode) ? c.MailingStateCode : c.MailingState;
        state.contactMailingPostalCode = c.MailingPostalCode;
        state.contactMailingCountry = String.isNotBlank(c.MailingCountryCode) ? c.MailingCountryCode : c.MailingCountry;
        state.customerId = getContactCustomerId(contactId);
        loadStripeStateForCustomer(state, state.customerId);
        return state;
    }

    private static void loadStripeStateForCustomer(StripeContactState state, String customerId) {
        state.customerId = customerId;
        state.paymentMethods = new List<PaymentMethodInfo>();
        state.subscriptions = new List<SubscriptionInfo>();

        if (String.isBlank(customerId)) return;

        state.customerName = retrieveCustomerName(customerId);
        state.paymentMethods = listPaymentMethodsInternal(customerId);
        state.subscriptions = listSubscriptionsInternal(customerId);
    }

    @AuraEnabled(cacheable=false)
    public static StripeContactState getStateForRecord(Id recordId) {
        if (recordId == null) throw new AuraHandledException('Record Id is required.');
        Schema.SObjectType recordType = recordId.getSObjectType();
        if (recordType == Contact.SObjectType) {
            StripeContactState state = getState(recordId);
            state.recurringDonationContext = false;
            return state;
        }
        if (recordType == npe03__Recurring_Donation__c.SObjectType) {
            return getStateForRecurringDonation(recordId);
        }
        throw new AuraHandledException('Unsupported record type: use Contact or Recurring Donation.');
    }

    @AuraEnabled(cacheable=false)
    public static StripeContactState getStateForRecurringDonation(Id recurringDonationId) {
        if (recurringDonationId == null) throw new AuraHandledException('Recurring Donation Id is required.');

        npe03__Recurring_Donation__c rd = [
            SELECT Id, Name, npe03__Contact__c, Stripe_Subscription_ID__c, Previous_Stripe_Subscription_ID__c, Pending_Stripe_Schedule_ID__c,
                   Stripe_Payment_Method_ID__c,
                   npe03__Amount__c, npe03__Installment_Period__c,
                   npsp__InstallmentFrequency__c, npsp__Day_of_Month__c,
                   npe03__Next_Payment_Date__c, npe03__Last_Payment_Date__c, npsp__Status__c,
                   npsp__ClosedReason__c, npsp__EndDate__c,
                   npsp__RecurringType__c, npe03__Installments__c,
                   npe03__Paid_Amount__c, npe03__Total_Paid_Installments__c, npsp__StartDate__c
            FROM npe03__Recurring_Donation__c
            WHERE Id = :recurringDonationId
            LIMIT 1
        ];
        // The managed Recurring Donation always sources its Stripe customer from the
        // subscription itself, never from a saved Contact field. When a Contact is
        // linked we still load it (for name/billing-address autofill), but the
        // customer, payment methods and subscriptions come from Stripe.
        StripeContactState state = rd.npe03__Contact__c != null
            ? getState(rd.npe03__Contact__c)
            : new StripeContactState();
        String customerId = null;
        if (String.isNotBlank(rd.Stripe_Subscription_ID__c)) {
            customerId = resolveCustomerIdFromSubscription(rd.Stripe_Subscription_ID__c);
        } else if (String.isNotBlank(rd.Pending_Stripe_Schedule_ID__c)) {
            customerId = resolveCustomerIdFromSchedule(rd.Pending_Stripe_Schedule_ID__c);
        }
        loadStripeStateForCustomer(state, customerId);
        state.contactId = rd.npe03__Contact__c;
        state.recurringDonationId = rd.Id;
        state.recurringDonationName = rd.Name;
        state.recurringDonationContext = true;
        state.recurringAmount = rd.npe03__Amount__c;
        state.recurringInstallmentPeriod = rd.npe03__Installment_Period__c;
        state.recurringInstallmentFrequency = rd.npsp__InstallmentFrequency__c == null
            ? null
            : Integer.valueOf(String.valueOf(rd.npsp__InstallmentFrequency__c));
        state.recurringDayOfMonth = rd.npsp__Day_of_Month__c;
        state.recurringNextPaymentDate = rd.npe03__Next_Payment_Date__c;
        state.recurringLastPaymentDate = rd.npe03__Last_Payment_Date__c;
        state.recurringStatus = rd.npsp__Status__c;
        state.recurringClosedReason = rd.npsp__ClosedReason__c;
        state.recurringEndDate = rd.npsp__EndDate__c;
        state.recurringStripeSubscriptionId = rd.Stripe_Subscription_ID__c;
        state.recurringPreviousStripeSubscriptionId = rd.Previous_Stripe_Subscription_ID__c;
        state.recurringPendingStripeScheduleId = rd.Pending_Stripe_Schedule_ID__c;
        state.recurringStripePaymentMethodId = rd.Stripe_Payment_Method_ID__c;
        state.recurringType = rd.npsp__RecurringType__c;
        state.recurringInstallments = rd.npe03__Installments__c == null
            ? null
            : Integer.valueOf(String.valueOf(rd.npe03__Installments__c));
        state.recurringPaidAmount = rd.npe03__Paid_Amount__c;
        state.recurringPaidInstallments = rd.npe03__Total_Paid_Installments__c == null
            ? null
            : Integer.valueOf(String.valueOf(rd.npe03__Total_Paid_Installments__c));
        state.recurringStartDate = rd.npsp__StartDate__c;

        if (String.isBlank(rd.Stripe_Subscription_ID__c)) {
            state.subscriptions = new List<SubscriptionInfo>();
            return state;
        }

        List<SubscriptionInfo> filtered = new List<SubscriptionInfo>();
        for (SubscriptionInfo sub : state.subscriptions) {
            if (sub.id == rd.Stripe_Subscription_ID__c) {
                filtered.add(sub);
                break;
            }
        }
        state.subscriptions = filtered;
        return state;
    }

    @AuraEnabled(cacheable=true)
    public static List<GauOption> listGauOptions() {
        List<GauOption> out = new List<GauOption>();
        for (npsp__General_Accounting_Unit__c gau : [
            SELECT Id, Name
            FROM npsp__General_Accounting_Unit__c
            ORDER BY Name
            LIMIT 500
        ]) {
            GauOption option = new GauOption();
            option.id = gau.Id;
            option.name = gau.Name;
            out.add(option);
        }
        return out;
    }

    @AuraEnabled(cacheable=true)
    public static List<OptionItem> listRecurringDonationClosedReasonOptions() {
        List<OptionItem> out = new List<OptionItem>();
        Schema.DescribeFieldResult d = npe03__Recurring_Donation__c.npsp__ClosedReason__c.getDescribe();
        for (Schema.PicklistEntry p : d.getPicklistValues()) {
            if (!p.isActive()) continue;
            OptionItem item = new OptionItem();
            item.value = p.getValue();
            item.label = p.getLabel();
            out.add(item);
        }
        return out;
    }

    @AuraEnabled
    public static String createOrGetCustomer(Id contactId) {
        CustomerRef customer = getOrCreateCustomerRef(contactId);
        saveContactCustomerIdIfNeeded(contactId, customer);
        return customer.customerId;
    }

    @AuraEnabled
    public static SetupIntentInitResult createSetupIntent(Id contactId, String customerId) {
        CustomerRef customer = resolveCustomerRef(contactId, customerId);
        String body = 'customer=' + enc(customer.customerId)
            + '&automatic_payment_methods[enabled]=true'
            + '&usage=off_session';
        Map<String, Object> json = parseResponse(callStripe('POST', '/setup_intents', body), 200);
        saveContactCustomerIdIfNeeded(contactId, customer);

        SetupIntentInitResult r = new SetupIntentInitResult();
        r.customerId = customer.customerId;
        r.clientSecret = (String) json.get('client_secret');
        r.publishableKey = getPublishableKey();
        return r;
    }

    @AuraEnabled
    public static StripeContactState attachPaymentMethod(Id contactId, String paymentMethodId, Boolean makeDefault, String customerId) {
        if (String.isBlank(paymentMethodId)) throw new AuraHandledException('Payment method id is required.');

        CustomerRef customer = resolveCustomerRef(contactId, customerId);
        callStripe('POST', '/payment_methods/' + encPath(paymentMethodId) + '/attach', 'customer=' + enc(customer.customerId));

        if (makeDefault == true) {
            setCustomerDefaultPaymentMethod(customer.customerId, paymentMethodId);
        }

        saveContactCustomerIdIfNeeded(contactId, customer);
        return localState(contactId, customer.customerId);
    }

    @AuraEnabled
    public static StripeContactState setDefaultPaymentMethod(Id contactId, String paymentMethodId, String customerId) {
        if (String.isBlank(paymentMethodId)) throw new AuraHandledException('Payment method id is required.');

        CustomerRef customer = resolveCustomerRef(contactId, customerId);
        setCustomerDefaultPaymentMethod(customer.customerId, paymentMethodId);
        saveContactCustomerIdIfNeeded(contactId, customer);
        return localState(contactId, customer.customerId);
    }

    @AuraEnabled
    public static StripeContactState detachPaymentMethod(Id contactId, String paymentMethodId, String customerId) {
        if (String.isBlank(paymentMethodId)) throw new AuraHandledException('Payment method id is required.');

        String effectiveCustomerId = String.isNotBlank(customerId)
            ? customerId
            : (contactId != null ? getContactCustomerId(contactId) : null);
        callStripe('POST', '/payment_methods/' + encPath(paymentMethodId) + '/detach', null);
        return localState(contactId, effectiveCustomerId);
    }

    @AuraEnabled
    public static StripeContactState createSubscription(
        Id contactId,
        Decimal amount,
        String currencyCode,
        String interval,
        Integer intervalCount,
        String paymentMethodId,
        String startDate,
        String gauId,
        Id recurringDonationId,
        String recurringType,
        Integer installments
    ) {
        if (amount == null || amount <= 0) throw new AuraHandledException('Amount must be greater than zero.');
        Date parsedStartDate = parseStartDate(startDate);
        Integer useIntervalCount = normalizeIntervalCount(intervalCount);
        CustomerRef customer = getOrCreateCustomerRef(contactId);
        saveContactCustomerIdIfNeeded(contactId, customer);
        Id effectiveRecurringDonationId = recurringDonationId;
        if (effectiveRecurringDonationId == null) {
            Date draftNextPaymentDate = parsedStartDate != null
                ? parsedStartDate
                : Date.today();
            effectiveRecurringDonationId = createRecurringDonationRecord(
                contactId,
                amount,
                interval,
                useIntervalCount,
                draftNextPaymentDate,
                recurringType,
                installments,
                gauId
            );
        }

        ManagedCreateRequest request = new ManagedCreateRequest();
        request.contactId = contactId;
        request.recurringDonationId = effectiveRecurringDonationId;
        request.customerId = customer.customerId;
        request.amount = amount;
        request.currencyCode = currencyCode;
        request.interval = interval;
        request.intervalCount = useIntervalCount;
        request.paymentMethodId = paymentMethodId;
        request.startDate = parsedStartDate;
        request.gauId = gauId;
        request.recurringType = recurringType;
        request.installments = installments;
        System.enqueueJob(new StripeManagedCreateJob(request));

        return localState(contactId, customer.customerId);
    }

    private static void saveSelectedGauToRecurringDonation(String subscriptionId, String gauId, Id recurringDonationId) {
        if (String.isBlank(gauId)) return;
        if (recurringDonationId != null) {
            update new npe03__Recurring_Donation__c(
                Id = recurringDonationId,
                Stripe_GAU__c = gauId
            );
            upsertRecurringDonationAllocation(recurringDonationId, gauId);
            return;
        }
        if (String.isBlank(subscriptionId)) return;
        List<npe03__Recurring_Donation__c> rows = [
            SELECT Id
            FROM npe03__Recurring_Donation__c
            WHERE Stripe_Subscription_ID__c = :subscriptionId
            LIMIT 1
        ];
        if (rows.isEmpty()) return;
        update new npe03__Recurring_Donation__c(
            Id = rows[0].Id,
            Stripe_GAU__c = gauId
        );
        upsertRecurringDonationAllocation(rows[0].Id, gauId);
    }

    private static Id createRecurringDonationRecord(
        Id contactId,
        Decimal amount,
        String interval,
        Integer intervalCount,
        Date nextPaymentDate,
        String recurringType,
        Integer installments,
        String gauId
    ) {
        Contact c = [
            SELECT Id, Name, AccountId
            FROM Contact
            WHERE Id = :contactId
            LIMIT 1
        ];
        npe03__Recurring_Donation__c rd = new npe03__Recurring_Donation__c();
        rd.Name = 'Stripe Subscription - ' + c.Name;
        rd.npe03__Contact__c = c.Id;
        rd.npe03__Amount__c = amount;
        rd.npe03__Installment_Period__c = npspInstallmentPeriod(interval);
        rd.npsp__InstallmentFrequency__c = normalizeIntervalCount(intervalCount);
        rd.npsp__Day_of_Month__c = nextPaymentDate == null ? null : npspDayOfMonth(startDateEpoch(nextPaymentDate));
        rd.npe03__Next_Payment_Date__c = nextPaymentDate;
        rd.npsp__Status__c = 'Active';
        rd.npsp__StartDate__c = nextPaymentDate;
        rd.npe03__Date_Established__c = Date.today();
        rd.npsp__PaymentMethod__c = 'Credit Card';
        rd.npsp__RecurringType__c = String.isBlank(recurringType) ? 'Open' : recurringType;
        rd.npe03__Installments__c = rd.npsp__RecurringType__c == 'Fixed' ? installments : null;
        rd.Stripe_GAU__c = gauId;
        rd.npsp__DisableFirstInstallment__c = true;
        insert rd;
        upsertRecurringDonationAllocation(rd.Id, gauId);
        return rd.Id;
    }

    private static void upsertRecurringDonationAllocation(Id recurringDonationId, Id gauId) {
        if (recurringDonationId == null || gauId == null) return;

        List<npsp__Allocation__c> existing = [
            SELECT Id
            FROM npsp__Allocation__c
            WHERE npsp__Recurring_Donation__c = :recurringDonationId
            LIMIT 1
        ];
        if (!existing.isEmpty()) return;

        insert new npsp__Allocation__c(
            npsp__Recurring_Donation__c = recurringDonationId,
            npsp__General_Accounting_Unit__c = gauId,
            npsp__Percent__c = 100,
            npsp__Amount__c = null
        );
    }

    @AuraEnabled
    public static StripeContactState updateSubscription(
        Id contactId,
        String subscriptionId,
        Decimal amount,
        String currencyCode,
        String interval,
        Integer intervalCount,
        String paymentMethodId,
        String recurringType,
        Integer installments
    ) {
        if (String.isBlank(subscriptionId)) throw new AuraHandledException('Subscription id is required.');

        CustomerRef customer = resolveCustomerRefForSubscription(contactId, subscriptionId);
        String effectivePmId = paymentMethodId;
        Integer useIntervalCount = normalizeIntervalCount(intervalCount);
        FixedDonationConfig fixedConfig = getFixedDonationConfigBySubscriptionId(subscriptionId, recurringType, installments);

        if (String.isNotBlank(effectivePmId)) {
            // Attach to the customer so the card is usable, but set it only as this
            // subscription's default (via default_payment_method in the update body
            // below) rather than overriding the customer-wide default, which would
            // silently change the card other subscriptions bill to.
            callStripe('POST', '/payment_methods/' + encPath(effectivePmId) + '/attach', 'customer=' + enc(customer.customerId));
        }

        Map<String, Object> sub = parseResponse(callStripe('GET', '/subscriptions/' + encPath(subscriptionId), null), 200);
        Map<String, Object> itemsObj = (Map<String, Object>) sub.get('items');
        List<Object> itemData = itemsObj == null ? null : (List<Object>) itemsObj.get('data');
        if (itemData == null || itemData.isEmpty()) {
            throw new AuraHandledException('Subscription has no items and cannot be updated.');
        }

        Map<String, Object> firstItem = (Map<String, Object>) itemData[0];
        String subItemId = (String) firstItem.get('id');
        Map<String, Object> currentPrice = (Map<String, Object>) firstItem.get('price');
        Map<String, Object> currentRecurring = currentPrice == null ? null : (Map<String, Object>) currentPrice.get('recurring');
        String currentInterval = currentRecurring == null ? null : (String) currentRecurring.get('interval');
        Integer currentIntervalCount = currentRecurring == null ? 1 : toInt(currentRecurring.get('interval_count'));
        String effectiveInterval = String.isBlank(interval)
            ? currentInterval
            : interval;
        Integer effectiveIntervalCount = intervalCount == null
            ? currentIntervalCount
            : useIntervalCount;
        effectiveIntervalCount = normalizeStripeIntervalCount(effectiveInterval, effectiveIntervalCount);
        // Compare against the normalized Stripe interval ('month'/'week'/'year'), not
        // the raw input: callers (e.g. the RD trigger) pass NPSP period strings like
        // 'Monthly', which would never equal Stripe's 'month' and would otherwise make
        // an amount-only edit look like a frequency change and charge the donor today.
        Boolean intervalChanged = String.isNotBlank(interval)
            && (
                currentInterval != stripeInterval(effectiveInterval)
                || normalizeStripeIntervalCount(currentInterval, currentIntervalCount) != effectiveIntervalCount
            );

        String newPriceId = null;
        if ((amount != null && amount > 0) || intervalChanged) {
            Decimal effectiveAmount = amount != null && amount > 0
                ? amount
                : amountFromStripePrice(currentPrice);
            newPriceId = createRecurringPrice(effectiveAmount, currencyCode, effectiveInterval, effectiveIntervalCount, null);
        } else if (currentPrice != null) {
            newPriceId = (String) currentPrice.get('id');
        }

        if (fixedConfig != null && fixedConfig.isFixed) {
            configureFixedInstallmentSchedule(
                subscriptionId,
                newPriceId,
                fixedConfig.remainingInstallments,
                effectivePmId,
                null
            );
        } else {
            Boolean priceChanging = newPriceId != null && ((amount != null && amount > 0) || intervalChanged);
            String body = 'items[0][id]=' + enc(subItemId);
            if (priceChanging) {
                body += '&items[0][price]=' + enc(newPriceId);
            }
            if (String.isNotBlank(effectivePmId)) {
                body += '&default_payment_method=' + enc(effectivePmId);
            }

            if (priceChanging) {
                // Never prorate the mid-cycle difference onto the charge.
                body += '&proration_behavior=none';
                if (intervalChanged) {
                    // Frequency change: reset the billing cycle to now. Stripe charges
                    // the new amount today and the next charge becomes today + the new
                    // interval. Amount-only changes keep the existing next gift date
                    // (no anchor reset, so no charge today).
                    body += '&billing_cycle_anchor=now';
                }
            }

            sub = parseResponse(callStripe('POST', '/subscriptions/' + encPath(subscriptionId), body), 200);
        }
        syncRecurringDonationAfterManagedUpdate(
            subscriptionId,
            amount,
            effectiveInterval,
            effectiveIntervalCount,
            toLong(sub.get('current_period_start')),
            toLong(sub.get('current_period_end')),
            recurringType,
            installments
        );
        saveContactCustomerIdIfNeeded(contactId, customer);
        return localState(contactId, customer.customerId);
    }

    // Legacy pending-schedule / replacement-subscription path.
    // This supports older or alternate Stripe flows that create a future
    // subscription schedule before a live subscription exists.
    // The recurring-donation wizard no longer depends on this path.
    // Do not remove until future-start / pending-schedule flows are confirmed unused.
    @AuraEnabled
    public static StripeContactState updatePendingSubscriptionSchedule(
        Id contactId,
        Id recurringDonationId,
        Decimal amount,
        String currencyCode,
        String interval,
        Integer intervalCount,
        String paymentMethodId,
        String nextGiftDate,
        String recurringType,
        Integer installments,
        String action,
        String closeReason
    ) {
        if (recurringDonationId == null) throw new AuraHandledException('Recurring Donation Id is required.');

        npe03__Recurring_Donation__c rd = [
            SELECT Id, npe03__Contact__c, Pending_Stripe_Schedule_ID__c,
                   Previous_Stripe_Subscription_ID__c, Stripe_Subscription_ID__c,
                   npe03__Amount__c, npe03__Installment_Period__c,
                   npsp__InstallmentFrequency__c, npe03__Next_Payment_Date__c,
                   npsp__RecurringType__c, npe03__Installments__c, Stripe_GAU__c
            FROM npe03__Recurring_Donation__c
            WHERE Id = :recurringDonationId
            LIMIT 1
        ];
        if (String.isBlank(rd.Pending_Stripe_Schedule_ID__c)) {
            throw new AuraHandledException('This recurring donation has no pending Stripe schedule.');
        }

        // Always source the customer from the pending schedule rather than a saved
        // Contact field, mirroring the subscription-driven manage flow.
        Map<String, Object> scheduleForCustomer = parseResponse(
            callStripe('GET', '/subscription_schedules/' + encPath(rd.Pending_Stripe_Schedule_ID__c), null),
            200
        );
        CustomerRef customer = new CustomerRef();
        customer.customerId = stringValue(scheduleForCustomer.get('customer'));
        customer.needsContactSave = false;
        String contactMetaParam = rd.npe03__Contact__c == null
            ? ''
            : '&metadata[sf_contact_id]=' + enc(String.valueOf(rd.npe03__Contact__c));
        String phaseContactMetaParam = rd.npe03__Contact__c == null
            ? ''
            : '&phases[0][metadata][sf_contact_id]=' + enc(String.valueOf(rd.npe03__Contact__c));
        String normalizedAction = String.isBlank(action) ? 'update' : action.trim().toLowerCase();
        if (normalizedAction == 'cancel') {
            parseResponse(
                callStripe('POST', '/subscription_schedules/' + encPath(rd.Pending_Stripe_Schedule_ID__c) + '/cancel', null),
                200
            );
            updateRecurringDonationBypassed(new npe03__Recurring_Donation__c(
                Id = rd.Id,
                Stripe_Subscription_ID__c = null,
                Pending_Stripe_Schedule_ID__c = null,
                npsp__Status__c = 'Closed',
                npsp__ClosedReason__c = String.isBlank(closeReason) ? 'Unknown' : closeReason,
                npsp__EndDate__c = closeEndDateForRecurringDonation(rd.Id),
                npe03__Next_Payment_Date__c = null
            ));
            return pendingScheduleState(contactId, customer.customerId, recurringDonationId);
        }

        Map<String, Object> schedule = parseResponse(
            callStripe('GET', '/subscription_schedules/' + encPath(rd.Pending_Stripe_Schedule_ID__c), null),
            200
        );
        List<Object> phases = (List<Object>) schedule.get('phases');
        if (phases == null || phases.isEmpty()) {
            throw new AuraHandledException('Pending Stripe schedule has no phases.');
        }
        Map<String, Object> firstPhase = (Map<String, Object>) phases[0];
        List<Object> items = (List<Object>) firstPhase.get('items');
        if (items == null || items.isEmpty()) {
            throw new AuraHandledException('Pending Stripe schedule has no items.');
        }
        Map<String, Object> firstItem = (Map<String, Object>) items[0];
        String currentPriceId = stringValue(firstItem.get('price'));

        Decimal effectiveAmount = amount != null && amount > 0 ? amount : rd.npe03__Amount__c;
        String effectiveInterval = String.isBlank(interval)
            ? stripeInterval(rd.npe03__Installment_Period__c)
            : interval;
        Integer effectiveIntervalCount = intervalCount == null
            ? normalizeIntervalCount(rd.npsp__InstallmentFrequency__c == null ? 1 : Integer.valueOf(String.valueOf(rd.npsp__InstallmentFrequency__c)))
            : normalizeIntervalCount(intervalCount);
        String effectiveRecurringType = String.isBlank(recurringType) ? rd.npsp__RecurringType__c : recurringType;
        Integer effectiveInstallments = installments == null
            ? (rd.npe03__Installments__c == null ? null : Integer.valueOf(String.valueOf(rd.npe03__Installments__c)))
            : installments;
        Date effectiveNextGiftDate = parseStartDate(nextGiftDate);
        if (effectiveNextGiftDate == null) {
            effectiveNextGiftDate = rd.npe03__Next_Payment_Date__c;
        }
        if (effectiveNextGiftDate == null) {
            throw new AuraHandledException('Next gift date is required.');
        }

        Map<String, Object> defaultSettings = (Map<String, Object>) schedule.get('default_settings');
        String existingPmId = defaultSettings == null ? null : stringValue(defaultSettings.get('default_payment_method'));
        String effectivePmId = String.isNotBlank(paymentMethodId) ? paymentMethodId : existingPmId;

        String targetPriceId = currentPriceId;
        if (amount != null || !String.isBlank(interval) || intervalCount != null) {
            targetPriceId = createRecurringPrice(
                effectiveAmount,
                currencyCode,
                effectiveInterval,
                effectiveIntervalCount,
                rd.Stripe_GAU__c
            );
        }

        FixedDonationConfig fixedConfig = buildFixedDonationConfig(
            effectiveRecurringType,
            effectiveInstallments,
            0
        );

        // Attach a newly chosen card so the schedule can reference it.
        if (String.isNotBlank(paymentMethodId)) {
            callStripe(
                'POST',
                '/payment_methods/' + encPath(paymentMethodId) + '/attach',
                'customer=' + enc(customer.customerId)
            );
        }

        // A not-yet-started schedule's start date cannot be moved in place, so a
        // gift-date change (nextGiftDate provided) cancels the schedule and recreates
        // it at the new date. Amount, frequency and payment-method changes are applied
        // in place, keeping the same schedule id.
        Boolean changingStartDate = String.isNotBlank(nextGiftDate);
        String scheduleId = rd.Pending_Stripe_Schedule_ID__c;
        String iterationsParam = fixedConfig != null && fixedConfig.isFixed
            ? '&phases[0][iterations]=' + fixedConfig.installments
            : '&phases[0][iterations]=1';
        String pmParams = '';
        if (String.isNotBlank(effectivePmId)) {
            pmParams = '&default_settings[default_payment_method]=' + enc(effectivePmId)
                + '&phases[0][default_payment_method]=' + enc(effectivePmId);
        }
        String gauParams = '';
        if (String.isNotBlank(rd.Stripe_GAU__c)) {
            gauParams = '&metadata[sf_gau_id]=' + enc(rd.Stripe_GAU__c)
                + '&phases[0][metadata][sf_gau_id]=' + enc(rd.Stripe_GAU__c);
        }
        String phaseMetadata = '&phases[0][metadata][sf_created]=true'
            + '&phases[0][metadata][sf_source]=' + enc('salesforce_component')
            + phaseContactMetaParam
            + '&phases[0][metadata][sf_rd_id]=' + enc(String.valueOf(rd.Id));

        if (changingStartDate) {
            parseResponse(
                callStripe('POST', '/subscription_schedules/' + encPath(scheduleId) + '/cancel', null),
                200
            );
            String createBody = 'customer=' + enc(customer.customerId)
                + '&start_date=' + String.valueOf(startDateEpoch(effectiveNextGiftDate))
                + '&end_behavior=' + enc(fixedConfig != null && fixedConfig.isFixed ? 'cancel' : 'release')
                + '&default_settings[collection_method]=charge_automatically'
                + '&default_settings[billing_cycle_anchor]=automatic'
                + '&metadata[sf_created]=true'
                + '&metadata[sf_source]=' + enc('salesforce_component')
                + contactMetaParam
                + '&metadata[sf_rd_id]=' + enc(String.valueOf(rd.Id))
                + '&phases[0][items][0][price]=' + enc(targetPriceId)
                + '&phases[0][items][0][quantity]=1'
                + phaseMetadata + pmParams + gauParams + iterationsParam;
            Map<String, Object> recreatedSchedule = parseResponse(
                callStripe('POST', '/subscription_schedules', createBody),
                200
            );
            scheduleId = (String) recreatedSchedule.get('id');
        } else {
            String scheduleBody = 'end_behavior=' + enc(fixedConfig != null && fixedConfig.isFixed ? 'cancel' : 'release')
                + '&phases[0][start_date]=' + String.valueOf(startDateEpoch(effectiveNextGiftDate))
                + '&phases[0][items][0][price]=' + enc(targetPriceId)
                + '&phases[0][items][0][quantity]=1'
                + phaseMetadata + pmParams + gauParams + iterationsParam;
            parseResponse(
                callStripe('POST', '/subscription_schedules/' + encPath(scheduleId), scheduleBody),
                200
            );
        }

        updateRecurringDonationBypassed(new npe03__Recurring_Donation__c(
            Id = rd.Id,
            Pending_Stripe_Schedule_ID__c = scheduleId,
            Stripe_Subscription_ID__c = null,
            npe03__Amount__c = effectiveAmount,
            npe03__Installment_Period__c = npspInstallmentPeriod(effectiveInterval),
            npsp__InstallmentFrequency__c = normalizeIntervalCount(effectiveIntervalCount),
            npe03__Next_Payment_Date__c = effectiveNextGiftDate,
            npsp__Day_of_Month__c = npspDayOfMonth(startDateEpoch(effectiveNextGiftDate)),
            npsp__RecurringType__c = String.isBlank(effectiveRecurringType) ? 'Open' : effectiveRecurringType,
            npe03__Installments__c = effectiveRecurringType == 'Fixed' ? effectiveInstallments : null,
            Stripe_Payment_Method_ID__c = effectivePmId
        ));
        return pendingScheduleState(contactId, customer.customerId, recurringDonationId);
    }

    // Legacy billing-date replacement path.
    // This creates a future replacement Stripe schedule, stores
    // Previous_Stripe_Subscription_ID__c and Pending_Stripe_Schedule_ID__c,
    // and then retires the old live subscription.
    // The recurring-donation wizard no longer uses this path and instead
    // uses the direct sync action path for gift-date changes.
    // Retain only while non-recurring-donation replacement flows still need it.
    @AuraEnabled
    public static StripeContactState updateSubscriptionGiftDay(
        Id contactId,
        String subscriptionId,
        String nextGiftDate
    ) {
        if (String.isBlank(subscriptionId)) throw new AuraHandledException('Subscription id is required.');
        Date parsedNextGiftDate = parseStartDate(nextGiftDate);
        if (parsedNextGiftDate == null) {
            throw new AuraHandledException('Next gift date is required.');
        }
        if (parsedNextGiftDate <= Date.today()) {
            throw new AuraHandledException('Next gift date must be in the future.');
        }

        Map<String, Object> subscription = parseResponse(
            callStripe('GET', '/subscriptions/' + encPath(subscriptionId), null),
            200
        );
        Map<String, Object> itemsObj = (Map<String, Object>) subscription.get('items');
        List<Object> itemData = itemsObj == null ? null : (List<Object>) itemsObj.get('data');
        if (itemData == null || itemData.isEmpty()) {
            throw new AuraHandledException('Subscription has no items.');
        }
        Map<String, Object> firstItem = (Map<String, Object>) itemData[0];
        String existingPriceId = stringValue(firstItem.get('price'));
        Map<String, Object> currentPrice = (firstItem.get('price') instanceof Map<String, Object>)
            ? (Map<String, Object>) firstItem.get('price')
            : null;
        String customerId = stringValue(subscription.get('customer'));
        String defaultPaymentMethod = stringValue(subscription.get('default_payment_method'));

        npe03__Recurring_Donation__c rd = [
            SELECT Id, npe03__Contact__c, Stripe_Subscription_ID__c, Previous_Stripe_Subscription_ID__c,
                   Pending_Stripe_Schedule_ID__c, npe03__Amount__c, npe03__Installment_Period__c,
                   npsp__InstallmentFrequency__c, npsp__RecurringType__c, npe03__Installments__c, Stripe_GAU__c
            FROM npe03__Recurring_Donation__c
            WHERE Stripe_Subscription_ID__c = :subscriptionId
            LIMIT 1
        ];

        FixedDonationConfig fixedConfig = getFixedDonationConfig(rd.Id);

        // Recreate the price for the new schedule rather than reusing the
        // subscription's current price. That price may have been archived in
        // Stripe (e.g. after an earlier amount change or product cleanup), and
        // Stripe rejects new subscriptions/schedules that reference an inactive
        // price with a 400 "marked as inactive" error. Mint a fresh active price
        // that mirrors the current amount, currency, and billing interval.
        String priceId = existingPriceId;
        if (currentPrice != null) {
            Decimal priceAmount = amountFromStripePrice(currentPrice);
            String priceCurrency = stringValue(currentPrice.get('currency'));
            Map<String, Object> currentRecurring = (currentPrice.get('recurring') instanceof Map<String, Object>)
                ? (Map<String, Object>) currentPrice.get('recurring')
                : null;
            String priceInterval = currentRecurring == null ? null : stringValue(currentRecurring.get('interval'));
            Integer priceIntervalCount = currentRecurring == null ? null : toInt(currentRecurring.get('interval_count'));
            if (priceAmount != null && priceAmount > 0) {
                priceId = createRecurringPrice(
                    priceAmount,
                    String.isBlank(priceCurrency) ? 'usd' : priceCurrency,
                    priceInterval,
                    priceIntervalCount,
                    rd.Stripe_GAU__c
                );
            }
        }

        String contactMetaParam = rd.npe03__Contact__c == null
            ? ''
            : '&metadata[sf_contact_id]=' + enc(String.valueOf(rd.npe03__Contact__c));
        String phaseContactMetaParam = rd.npe03__Contact__c == null
            ? ''
            : '&phases[0][metadata][sf_contact_id]=' + enc(String.valueOf(rd.npe03__Contact__c));
        String scheduleBody = 'customer=' + enc(customerId)
            + '&start_date=' + String.valueOf(startDateEpoch(parsedNextGiftDate))
            + '&default_settings[collection_method]=charge_automatically'
            + '&default_settings[billing_cycle_anchor]=automatic'
            + '&metadata[sf_created]=true'
            + '&metadata[sf_source]=' + enc('salesforce_component')
            + contactMetaParam
            + '&metadata[sf_rd_id]=' + enc(String.valueOf(rd.Id))
            + '&phases[0][metadata][sf_created]=true'
            + '&phases[0][metadata][sf_source]=' + enc('salesforce_component')
            + phaseContactMetaParam
            + '&phases[0][metadata][sf_rd_id]=' + enc(String.valueOf(rd.Id))
            + '&phases[0][items][0][price]=' + enc(priceId)
            + '&phases[0][items][0][quantity]=1';
        if (String.isNotBlank(defaultPaymentMethod)) {
            scheduleBody += '&default_settings[default_payment_method]=' + enc(defaultPaymentMethod);
            scheduleBody += '&phases[0][default_payment_method]=' + enc(defaultPaymentMethod);
        }
        if (String.isNotBlank(rd.Stripe_GAU__c)) {
            scheduleBody += '&metadata[sf_gau_id]=' + enc(rd.Stripe_GAU__c);
            scheduleBody += '&phases[0][metadata][sf_gau_id]=' + enc(rd.Stripe_GAU__c);
        }
        if (fixedConfig != null && fixedConfig.isFixed) {
            scheduleBody += '&end_behavior=cancel'
                + '&phases[0][iterations]=' + fixedConfig.remainingInstallments;
        } else {
            scheduleBody += '&end_behavior=release'
                + '&phases[0][iterations]=1';
        }

        Map<String, Object> createdSchedule = parseResponse(
            callStripe('POST', '/subscription_schedules', scheduleBody),
            200
        );
        String scheduleId = (String) createdSchedule.get('id');

        updateRecurringDonationBypassed(new npe03__Recurring_Donation__c(
            Id = rd.Id,
            Previous_Stripe_Subscription_ID__c = subscriptionId,
            Stripe_Subscription_ID__c = null,
            Pending_Stripe_Schedule_ID__c = scheduleId,
            npe03__Next_Payment_Date__c = parsedNextGiftDate,
            npsp__Day_of_Month__c = npspDayOfMonth(startDateEpoch(parsedNextGiftDate)),
            npsp__Status__c = 'Active',
            npsp__ClosedReason__c = null,
            npsp__EndDate__c = null
        ));
        System.enqueueJob(new StripeSubscriptionDeleteJob(subscriptionId));
        return pendingScheduleState(contactId, customerId, rd.Id);
    }

    @AuraEnabled
    public static StripeContactState endSubscriptionTrialNow(
        Id contactId,
        String subscriptionId
    ) {
        if (String.isBlank(subscriptionId)) throw new AuraHandledException('Subscription id is required.');

        Map<String, Object> updated = parseResponse(
            callStripe(
                'POST',
                '/subscriptions/' + encPath(subscriptionId),
                'trial_end=now&proration_behavior=none'
            ),
            200
        );

        Long currentPeriodEnd = toLong(updated.get('current_period_end'));
        saveRecurringDonationGiftDay(
            subscriptionId,
            String.valueOf(epochDate(currentPeriodEnd, Date.today()).day()),
            epochDate(currentPeriodEnd, Date.today())
        );
        saveRecurringDonationResumedStatus(subscriptionId);
        return localState(contactId, getContactCustomerId(contactId));
    }

    @AuraEnabled
    public static StripeContactState cancelSubscription(Id contactId, String subscriptionId, Boolean atPeriodEnd, String closeReason) {
        if (String.isBlank(subscriptionId)) throw new AuraHandledException('Subscription id is required.');

        if (atPeriodEnd == true) {
            parseResponse(
                callStripe('POST', '/subscriptions/' + encPath(subscriptionId), 'cancel_at_period_end=true'),
                200
            );
        } else {
            parseResponse(callStripe('DELETE', '/subscriptions/' + encPath(subscriptionId), null), 200);
        }
        if (String.isNotBlank(closeReason)) {
            saveClosedReasonForRecurringDonation(subscriptionId, closeReason);
        }
        saveRecurringDonationStatus(subscriptionId, 'Closed');

        return localState(contactId, getContactCustomerId(contactId));
    }

    private static void saveClosedReasonForRecurringDonation(String subscriptionId, String closeReason) {
        if (String.isBlank(subscriptionId) || String.isBlank(closeReason)) return;
        List<npe03__Recurring_Donation__c> rows = [
            SELECT Id
            FROM npe03__Recurring_Donation__c
            WHERE Stripe_Subscription_ID__c = :subscriptionId
            LIMIT 1
        ];
        if (rows.isEmpty()) return;
        update new npe03__Recurring_Donation__c(
            Id = rows[0].Id,
            npsp__ClosedReason__c = closeReason
        );
    }

    private static void pauseRecurringDonationViaNpsp(String subscriptionId, String closeReason, Date resumeDate) {
        Id recurringDonationId = getRecurringDonationIdBySubscriptionId(subscriptionId);
        if (recurringDonationId == null) return;

        Date startDate = Date.today();
        Date endDate = resumeDate == null ? startDate.addYears(1).addDays(-1) : resumeDate.addDays(-1);
        Map<Id, Object> pauseData = new Map<Id, Object>{
            recurringDonationId => new Map<String, Object>{
                'startDate' => startDate,
                'endDate' => endDate,
                'statusReason' => closeReason,
                'unPause' => false
            }
        };
        invokeNpspPauseApi(pauseData, recurringDonationId);
        updateRecurringDonationBypassed(new npe03__Recurring_Donation__c(
            Id = recurringDonationId,
            npsp__Status__c = 'Active',
            npsp__ClosedReason__c = null
        ));
    }

    private static void resumeRecurringDonationViaNpsp(String subscriptionId) {
        Id recurringDonationId = getRecurringDonationIdBySubscriptionId(subscriptionId);
        if (recurringDonationId == null) return;

        Map<Id, Object> pauseData = new Map<Id, Object>{
            recurringDonationId => new Map<String, Object>{
                'unPause' => true
            }
        };
        invokeNpspPauseApi(pauseData, recurringDonationId);
    }

    private static Id getRecurringDonationIdBySubscriptionId(String subscriptionId) {
        if (String.isBlank(subscriptionId)) return null;
        List<npe03__Recurring_Donation__c> rows = [
            SELECT Id
            FROM npe03__Recurring_Donation__c
            WHERE Stripe_Subscription_ID__c = :subscriptionId
            LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0].Id;
    }

    private static Id getContactIdBySubscriptionId(String subscriptionId) {
        if (String.isBlank(subscriptionId)) return null;
        List<npe03__Recurring_Donation__c> rows = [
            SELECT npe03__Contact__c
            FROM npe03__Recurring_Donation__c
            WHERE Stripe_Subscription_ID__c = :subscriptionId
            LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0].npe03__Contact__c;
    }

    private static void invokeNpspPauseApi(Map<Id, Object> pauseData, Id recurringDonationId) {
        try {
            Type callableType = Type.forName('npsp', 'Callable_API');
            if (callableType == null) {
                throw new AuraHandledException('NPSP Callable API is not available in this org.');
            }

            Callable api = (Callable) callableType.newInstance();
            Object rawResponse = api.call('rd2.pause', new Map<String, Object>{ 'PauseData' => pauseData });
            Map<String, Object> response = (Map<String, Object>) JSON.deserializeUntyped(String.valueOf(rawResponse));
            Map<String, Object> row = response == null
                ? null
                : (Map<String, Object>) response.get(String.valueOf(recurringDonationId));

            if (row != null && row.containsKey('isSuccess') && row.get('isSuccess') != null && !(Boolean) row.get('isSuccess')) {
                throw new AuraHandledException('NPSP pause automation failed: ' + String.valueOf(row.get('error')));
            }
        } catch (AuraHandledException ex) {
            throw ex;
        } catch (Exception ex) {
            throw new AuraHandledException('NPSP pause automation failed: ' + ex.getMessage());
        }
    }

    @AuraEnabled
    public static StripeContactState pauseSubscription(Id contactId, String subscriptionId, String closeReason, String resumeDate) {
        if (String.isBlank(subscriptionId)) throw new AuraHandledException('Subscription id is required.');
        if (contactId == null) {
            contactId = getContactIdBySubscriptionId(subscriptionId);
        }
        if (contactId == null) throw new AuraHandledException('Contact Id is required.');
        Date parsedResumeDate = String.isBlank(resumeDate) ? null : parseStartDate(resumeDate);
        if (parsedResumeDate != null && parsedResumeDate <= Date.today()) {
            throw new AuraHandledException('Resume date must be in the future.');
        }

        String body = 'pause_collection[behavior]=void';
        if (parsedResumeDate != null) {
            body += '&pause_collection[resumes_at]=' + String.valueOf(startDateEpoch(parsedResumeDate));
        }
        parseResponse(
            callStripe('POST', '/subscriptions/' + encPath(subscriptionId), body),
            200
        );
        pauseRecurringDonationViaNpsp(subscriptionId, closeReason, parsedResumeDate);
        return localState(contactId, getContactCustomerId(contactId));
    }

    @AuraEnabled
    public static StripeContactState resumeSubscription(Id contactId, String subscriptionId) {
        if (String.isBlank(subscriptionId)) throw new AuraHandledException('Subscription id is required.');

        parseResponse(
            callStripe('POST', '/subscriptions/' + encPath(subscriptionId), 'pause_collection='),
            200
        );
        resumeRecurringDonationViaNpsp(subscriptionId);
        return localState(contactId, getContactCustomerId(contactId));
    }

    public static Boolean isRecurringDonationTriggerSuppressed() {
        return skipRecurringDonationTrigger || suppressRecurringDonationSync;
    }

    public static void setRecurringDonationSyncSuppressed(Boolean suppressed) {
        suppressRecurringDonationSync = suppressed == true;
    }

    // The trigger skips itself under test by default (its async job does callouts).
    // A test can flip this on to exercise the trigger's own request-building logic;
    // processRecurringDonationSyncRequest still no-ops in test, so no callout fires.
    @TestVisible
    private static Boolean recurringDonationTriggerTestMode = false;

    public static Boolean isRecurringDonationTriggerTestModeEnabled() {
        return recurringDonationTriggerTestMode;
    }

    // Primary recurring-donation wizard sync entry point.
    // The RD wizard should route its required actions through this facade
    // so Stripe + Salesforce updates happen through one orchestration path,
    // even though the underlying implementation still delegates to action-specific methods.
    @AuraEnabled
    public static StripeContactState syncRecurringDonationAction(String requestJson) {
        if (String.isBlank(requestJson)) throw new AuraHandledException('Sync request is required.');
        RecurringDonationSyncRequest request = (RecurringDonationSyncRequest) JSON.deserialize(
            requestJson,
            RecurringDonationSyncRequest.class
        );
        if (request == null) throw new AuraHandledException('Sync request is required.');
        if (String.isBlank(request.action) && String.isNotBlank(request.actionName)) {
            request.action = request.actionName;
        }
        if (String.isBlank(request.action)) throw new AuraHandledException('Action is required.');
        if (String.isBlank(request.subscriptionId)) throw new AuraHandledException('Subscription id is required.');
        if (request.contactId == null) {
            request.contactId = getContactIdBySubscriptionId(request.subscriptionId);
        }

        String normalizedAction = request.action.trim().toLowerCase();
        if (normalizedAction == 'amount') {
            return updateSubscription(
                request.contactId,
                request.subscriptionId,
                request.amount,
                'usd',
                null,
                null,
                null,
                null,
                null
            );
        }
        if (normalizedAction == 'frequency') {
            return updateSubscription(
                request.contactId,
                request.subscriptionId,
                null,
                'usd',
                request.installmentPeriod,
                request.installmentFrequency,
                null,
                null,
                null
            );
        }
        if (normalizedAction == 'gift_day') {
            Date safeDate = safeFutureGiftDate(request.subscriptionId, request.nextGiftDate, request.dayOfMonth);
            if (safeDate == null) {
                throw new AuraHandledException('Could not determine a future gift date.');
            }
            return updateSubscriptionGiftDay(
                request.contactId,
                request.subscriptionId,
                String.valueOf(safeDate)
            );
        }
        if (normalizedAction == 'pause') {
            return pauseSubscription(
                request.contactId,
                request.subscriptionId,
                request.closeReason,
                request.resumeDate
            );
        }
        if (normalizedAction == 'resume') {
            return resumeSubscription(request.contactId, request.subscriptionId);
        }
        if (normalizedAction == 'cancel') {
            return cancelSubscription(request.contactId, request.subscriptionId, false, request.closeReason);
        }
        if (normalizedAction == 'payment_method') {
            return updateSubscription(
                request.contactId,
                request.subscriptionId,
                null,
                'usd',
                null,
                null,
                request.paymentMethodId,
                null,
                null
            );
        }
        if (normalizedAction == 'gift_count') {
            return updateSubscription(
                request.contactId,
                request.subscriptionId,
                null,
                'usd',
                null,
                null,
                null,
                request.recurringType,
                request.installments
            );
        }
        throw new AuraHandledException('Unsupported recurring donation action: ' + request.action);
    }

    public static void processRecurringDonationSyncRequest(RecurringDonationSyncRequest request) {
        if (Test.isRunningTest()) return;
        if (request == null || String.isBlank(request.subscriptionId) || String.isBlank(request.action)) return;

        if (request.action == 'cancel') {
            cancelSubscription(request.contactId, request.subscriptionId, false, request.closeReason);
            return;
        }
        if (request.action == 'amount_frequency') {
            updateSubscription(
                request.contactId,
                request.subscriptionId,
                request.amount,
                'usd',
                request.installmentPeriod,
                request.installmentFrequency,
                null,
                request.recurringType,
                request.installments
            );
            return;
        }
        if (request.action == 'gift_day') {
            // Manual RD edits can leave the next payment date today or in the past;
            // resolve a strictly-future date so the gift-day update doesn't silently
            // fail in this async job.
            Date safeDate = safeFutureGiftDate(request.subscriptionId, request.nextGiftDate, request.dayOfMonth);
            if (safeDate == null) {
                return;
            }
            updateSubscriptionGiftDay(
                request.contactId,
                request.subscriptionId,
                String.valueOf(safeDate)
            );
            return;
        }
    }

    private class FixedDonationConfig {
        Boolean isFixed;
        Integer installments;
        Integer remainingInstallments;
    }

    private static List<PaymentMethodInfo> listPaymentMethodsInternal(String customerId) {
        List<PaymentMethodInfo> out = new List<PaymentMethodInfo>();

        Map<String, Object> customer = parseResponse(callStripe('GET', '/customers/' + encPath(customerId), null), 200);
        String defaultPm = null;
        Map<String, Object> invoiceSettings = (Map<String, Object>) customer.get('invoice_settings');
        if (invoiceSettings != null) defaultPm = (String) invoiceSettings.get('default_payment_method');

        Map<String, Object> json = parseResponse(
            callStripe('GET', '/payment_methods?customer=' + enc(customerId) + '&type=card', null),
            200
        );

        List<Object> data = (List<Object>) json.get('data');
        if (data == null) return out;

        for (Object row : data) {
            Map<String, Object> pm = (Map<String, Object>) row;
            Map<String, Object> card = (Map<String, Object>) pm.get('card');

            PaymentMethodInfo info = new PaymentMethodInfo();
            info.id = (String) pm.get('id');
            info.brand = card == null ? null : (String) card.get('brand');
            info.last4 = card == null ? null : (String) card.get('last4');
            info.expMonth = card == null ? null : toInt(card.get('exp_month'));
            info.expYear = card == null ? null : toInt(card.get('exp_year'));
            info.isDefault = info.id == defaultPm;

            out.add(info);
        }

        return out;
    }

    private static List<SubscriptionInfo> listSubscriptionsInternal(String customerId) {
        List<SubscriptionInfo> out = new List<SubscriptionInfo>();

        Map<String, Object> json = parseResponse(
            callStripe('GET', '/subscriptions?customer=' + enc(customerId) + '&status=all&limit=25', null),
            200
        );

        List<Object> data = (List<Object>) json.get('data');
        if (data == null) return out;

        for (Object row : data) {
            Map<String, Object> sub = (Map<String, Object>) row;
            SubscriptionInfo info = new SubscriptionInfo();
            info.id = (String) sub.get('id');
            info.status = (String) sub.get('status');
            info.cancelAtPeriodEnd = (Boolean) sub.get('cancel_at_period_end');
            info.currentPeriodStart = toLong(sub.get('current_period_start'));
            info.currentPeriodEnd = toLong(sub.get('current_period_end'));
            info.cancelAt = toLong(sub.get('cancel_at'));
            info.canceledAt = toLong(sub.get('canceled_at'));
            info.endedAt = toLong(sub.get('ended_at'));
            Map<String, Object> pauseCollection = (Map<String, Object>) sub.get('pause_collection');
            info.collectionPaused = pauseCollection != null;
            info.pauseResumesAt = pauseCollection == null ? null : toLong(pauseCollection.get('resumes_at'));
            info.defaultPaymentMethod = (String) sub.get('default_payment_method');

            Map<String, Object> itemsObj = (Map<String, Object>) sub.get('items');
            List<Object> itemData = itemsObj == null ? null : (List<Object>) itemsObj.get('data');
            if (itemData != null && !itemData.isEmpty()) {
                Map<String, Object> firstItem = (Map<String, Object>) itemData[0];
                Map<String, Object> price = (Map<String, Object>) firstItem.get('price');
                if (price != null) {
                    info.priceId = (String) price.get('id');
                    Integer unitAmount = toInt(price.get('unit_amount'));
                    info.amount = unitAmount == null ? null : (Decimal.valueOf(unitAmount) / 100);
                    info.currencyCode = (String) price.get('currency');
                    Map<String, Object> recurring = (Map<String, Object>) price.get('recurring');
                    info.interval = recurring == null ? null : (String) recurring.get('interval');
                    info.intervalCount = recurring == null ? null : toInt(recurring.get('interval_count'));
                }
            }

            SubscriptionScheduleSummary scheduleSummary = summarizeSubscriptionSchedule(
                stringValue(sub.get('schedule'))
            );
            if (scheduleSummary != null && scheduleSummary.isFixed) {
                info.recurringType = 'Fixed';
                info.installments = scheduleSummary.installments;
            }

            out.add(info);
        }

        applyRecurringDonationIds(out);
        return out;
    }

    private static void applyRecurringDonationIds(List<SubscriptionInfo> subscriptions) {
        if (subscriptions.isEmpty()) return;

        Set<String> subscriptionIds = new Set<String>();
        for (SubscriptionInfo s : subscriptions) {
            if (String.isNotBlank(s.id)) subscriptionIds.add(s.id);
        }
        if (subscriptionIds.isEmpty()) return;

        Map<String, Id> rdByStripeSubId = new Map<String, Id>();
        for (npe03__Recurring_Donation__c rd : [
            SELECT Id, Stripe_Subscription_ID__c, Previous_Stripe_Subscription_ID__c, npsp__RecurringType__c, npe03__Installments__c
            FROM npe03__Recurring_Donation__c
            WHERE Stripe_Subscription_ID__c IN :subscriptionIds
        ]) {
            rdByStripeSubId.put(rd.Stripe_Subscription_ID__c, rd.Id);
        }

        for (SubscriptionInfo s : subscriptions) {
            Id recurringDonationId = rdByStripeSubId.get(s.id);
            s.recurringDonationId = recurringDonationId;
        }

        Map<String, npe03__Recurring_Donation__c> rdBySubscriptionId = new Map<String, npe03__Recurring_Donation__c>();
        for (npe03__Recurring_Donation__c rd : [
            SELECT Id, Stripe_Subscription_ID__c, Previous_Stripe_Subscription_ID__c, npsp__RecurringType__c, npe03__Installments__c
            FROM npe03__Recurring_Donation__c
            WHERE Stripe_Subscription_ID__c IN :subscriptionIds
        ]) {
            rdBySubscriptionId.put(rd.Stripe_Subscription_ID__c, rd);
        }

        for (SubscriptionInfo s : subscriptions) {
            npe03__Recurring_Donation__c rd = rdBySubscriptionId.get(s.id);
            if (rd == null) continue;
            s.recurringType = rd.npsp__RecurringType__c;
            s.installments = rd.npe03__Installments__c == null
                ? null
                : Integer.valueOf(String.valueOf(rd.npe03__Installments__c));
            s.previousStripeSubscriptionId = rd.Previous_Stripe_Subscription_ID__c;
        }
    }

    private static StripeContactState localState(Id contactId, String customerId) {
        StripeContactState state = new StripeContactState();
        state.contactId = contactId;
        state.customerId = customerId;
        state.customerName = null;
        state.paymentMethods = new List<PaymentMethodInfo>();
        state.subscriptions = new List<SubscriptionInfo>();
        return state;
    }

    private static StripeContactState pendingScheduleState(Id contactId, String customerId, Id recurringDonationId) {
        if (recurringDonationId != null) {
            npe03__Recurring_Donation__c rd = [
                SELECT Id, Name, npe03__Contact__c, Stripe_Subscription_ID__c, Previous_Stripe_Subscription_ID__c, Pending_Stripe_Schedule_ID__c,
                       Stripe_Payment_Method_ID__c,
                       npe03__Amount__c, npe03__Installment_Period__c,
                       npsp__InstallmentFrequency__c, npsp__Day_of_Month__c,
                       npe03__Next_Payment_Date__c, npe03__Last_Payment_Date__c, npsp__Status__c,
                       npsp__ClosedReason__c, npsp__EndDate__c,
                       npsp__RecurringType__c, npe03__Installments__c
                FROM npe03__Recurring_Donation__c
                WHERE Id = :recurringDonationId
                LIMIT 1
            ];

            StripeContactState state = localState(rd.npe03__Contact__c, customerId);
            state.recurringDonationId = rd.Id;
            state.recurringDonationName = rd.Name;
            state.recurringDonationContext = true;
            state.recurringAmount = rd.npe03__Amount__c;
            state.recurringInstallmentPeriod = rd.npe03__Installment_Period__c;
            state.recurringInstallmentFrequency = rd.npsp__InstallmentFrequency__c == null
                ? null
                : Integer.valueOf(String.valueOf(rd.npsp__InstallmentFrequency__c));
            state.recurringDayOfMonth = rd.npsp__Day_of_Month__c;
            state.recurringNextPaymentDate = rd.npe03__Next_Payment_Date__c;
            state.recurringLastPaymentDate = rd.npe03__Last_Payment_Date__c;
            state.recurringStatus = rd.npsp__Status__c;
            state.recurringClosedReason = rd.npsp__ClosedReason__c;
            state.recurringEndDate = rd.npsp__EndDate__c;
            state.recurringStripeSubscriptionId = rd.Stripe_Subscription_ID__c;
            state.recurringPreviousStripeSubscriptionId = rd.Previous_Stripe_Subscription_ID__c;
            state.recurringPendingStripeScheduleId = rd.Pending_Stripe_Schedule_ID__c;
            state.recurringStripePaymentMethodId = rd.Stripe_Payment_Method_ID__c;
            state.recurringType = rd.npsp__RecurringType__c;
            state.recurringInstallments = rd.npe03__Installments__c == null
                ? null
                : Integer.valueOf(String.valueOf(rd.npe03__Installments__c));
            return state;
        }

        return localState(contactId, customerId);
    }

    private static String retrieveCustomerName(String customerId) {
        if (String.isBlank(customerId)) return null;
        Map<String, Object> customer = parseResponse(callStripe('GET', '/customers/' + encPath(customerId), null), 200);
        return (String) customer.get('name');
    }

    private static FixedDonationConfig getFixedDonationConfig(Id recurringDonationId) {
        if (recurringDonationId == null) return null;
        List<npe03__Recurring_Donation__c> rows = [
            SELECT Id, npsp__RecurringType__c, npe03__Installments__c
            FROM npe03__Recurring_Donation__c
            WHERE Id = :recurringDonationId
            LIMIT 1
        ];
        if (rows.isEmpty()) return null;
        return toFixedDonationConfig(rows[0], 0);
    }

    private static FixedDonationConfig getFixedDonationConfigBySubscriptionId(
        String subscriptionId,
        String recurringTypeOverride,
        Integer installmentsOverride
    ) {
        if (String.isBlank(subscriptionId)) return null;
        List<npe03__Recurring_Donation__c> rows = [
            SELECT Id, npsp__RecurringType__c, npe03__Installments__c
            FROM npe03__Recurring_Donation__c
            WHERE Stripe_Subscription_ID__c = :subscriptionId
            LIMIT 1
        ];
        if (rows.isEmpty()) {
            return buildFixedDonationConfig(recurringTypeOverride, installmentsOverride, 0);
        }
        Integer paidInstallments = [
            SELECT COUNT()
            FROM npe01__OppPayment__c
            WHERE npe01__Paid__c = true
              AND npe01__Opportunity__r.npe03__Recurring_Donation__c = :rows[0].Id
        ];
        if (String.isNotBlank(recurringTypeOverride) || installmentsOverride != null) {
            return buildFixedDonationConfig(recurringTypeOverride, installmentsOverride, paidInstallments);
        }
        return toFixedDonationConfig(rows[0], paidInstallments);
    }

    private static FixedDonationConfig buildFixedDonationConfig(
        String recurringType,
        Integer installments,
        Integer paidInstallments
    ) {
        FixedDonationConfig config = new FixedDonationConfig();
        config.isFixed = recurringType == 'Fixed' && installments != null && installments > 0;
        config.installments = installments;
        if (config.isFixed) {
            Integer remaining = installments - (paidInstallments == null ? 0 : paidInstallments);
            config.remainingInstallments = remaining <= 0 ? 1 : remaining;
        }
        return config;
    }

    private static FixedDonationConfig toFixedDonationConfig(npe03__Recurring_Donation__c rd, Integer paidInstallments) {
        FixedDonationConfig config = new FixedDonationConfig();
        config.isFixed = rd.npsp__RecurringType__c == 'Fixed' && rd.npe03__Installments__c != null && rd.npe03__Installments__c > 0;
        config.installments = rd.npe03__Installments__c == null ? null : Integer.valueOf(String.valueOf(rd.npe03__Installments__c));
        if (config.isFixed) {
            Integer remaining = config.installments - (paidInstallments == null ? 0 : paidInstallments);
            config.remainingInstallments = remaining <= 0 ? 1 : remaining;
        } else {
            config.remainingInstallments = null;
        }
        return config;
    }

    private static void configureFixedInstallmentSchedule(
        String subscriptionId,
        String priceId,
        Integer installments,
        String paymentMethodId,
        Long phaseStartEpoch
    ) {
        if (String.isBlank(subscriptionId) || String.isBlank(priceId) || installments == null || installments <= 0) return;

        Map<String, Object> subscription = parseResponse(callStripe('GET', '/subscriptions/' + encPath(subscriptionId), null), 200);
        String scheduleId = stringValue(subscription.get('schedule'));
        Long currentPeriodStart = toLong(subscription.get('current_period_start'));
        if (String.isBlank(scheduleId)) {
            Map<String, Object> createdSchedule = parseResponse(
                callStripe('POST', '/subscription_schedules', 'from_subscription=' + enc(subscriptionId)),
                200
            );
            scheduleId = (String) createdSchedule.get('id');
        }

        Long effectivePhaseStart = phaseStartEpoch == null || phaseStartEpoch <= 0
            ? currentPeriodStart
            : phaseStartEpoch;
        String body = 'end_behavior=cancel'
            + '&phases[0][start_date]=' + String.valueOf(effectivePhaseStart == null || effectivePhaseStart <= 0 ? DateTime.now().getTime() / 1000 : effectivePhaseStart)
            + '&phases[0][items][0][price]=' + enc(priceId)
            + '&phases[0][iterations]=' + installments;
        if (String.isNotBlank(paymentMethodId)) {
            body += '&default_settings[default_payment_method]=' + enc(paymentMethodId);
        }
        parseResponse(callStripe('POST', '/subscription_schedules/' + encPath(scheduleId), body), 200);
    }

    private static SubscriptionScheduleSummary summarizeSubscriptionSchedule(String scheduleId) {
        if (String.isBlank(scheduleId)) return null;

        Map<String, Object> schedule = parseResponse(
            callStripe('GET', '/subscription_schedules/' + encPath(scheduleId), null),
            200
        );
        if (schedule == null) return null;

        String endBehavior = (String) schedule.get('end_behavior');
        if (endBehavior != 'cancel') return null;

        List<Object> phases = (List<Object>) schedule.get('phases');
        if (phases == null || phases.isEmpty()) return null;

        Integer totalIterations = 0;
        Boolean hasIterations = false;
        for (Object phaseObj : phases) {
            Map<String, Object> phase = (Map<String, Object>) phaseObj;
            Integer iterations = toInt(phase.get('iterations'));
            if (iterations == null || iterations <= 0) continue;
            hasIterations = true;
            totalIterations += iterations;
        }
        if (!hasIterations) return null;

        SubscriptionScheduleSummary summary = new SubscriptionScheduleSummary();
        summary.isFixed = true;
        summary.installments = totalIterations;
        return summary;
    }

    private static String stripeInterval(String installmentPeriod) {
        String normalized = String.isBlank(installmentPeriod) ? 'Monthly' : installmentPeriod.trim();
        if (normalized.equalsIgnoreCase('Monthly') || normalized.equalsIgnoreCase('month')) return 'month';
        if (normalized.equalsIgnoreCase('Quarterly') || normalized.equalsIgnoreCase('quarter')) return 'month';
        if (normalized.equalsIgnoreCase('Yearly') || normalized.equalsIgnoreCase('year')) return 'year';
        if (normalized.equalsIgnoreCase('Weekly') || normalized.equalsIgnoreCase('week')) return 'week';
        throw new AuraHandledException('Installment Period must be Monthly, Quarterly, Yearly, or Weekly.');
    }

    private static String npspInstallmentPeriod(String stripeInterval) {
        if (String.isBlank(stripeInterval)) return null;
        String normalized = stripeInterval.trim().toLowerCase();
        if (normalized == 'week' || normalized == 'weekly') return 'Weekly';
        if (normalized == 'year' || normalized == 'yearly') return 'Yearly';
        if (normalized == 'quarterly') return 'Monthly';
        if (normalized == 'month' || normalized == 'monthly') return 'Monthly';
        return stripeInterval;
    }

    private static String npspDayOfMonth(Long epochSeconds) {
        Integer day = epochDate(epochSeconds, Date.today()).day();
        return day > 30 ? 'Last_Day' : String.valueOf(day);
    }

    private static Date parseStartDate(String startDate) {
        if (String.isBlank(startDate)) return null;
        try {
            return Date.valueOf(startDate);
        } catch (Exception e) {
            throw new AuraHandledException('Start Date must be a valid date.');
        }
    }

    private static Long startDateEpoch(Date startDate) {
        // Anchor date-only schedule starts to noon in the configured US business
        // timezone so Stripe dashboard rendering does not shift the visible date.
        TimeZone businessTz = TimeZone.getTimeZone(STRIPE_BUSINESS_TIMEZONE);
        DateTime gmtMidnight = DateTime.newInstanceGmt(startDate, Time.newInstance(0, 0, 0, 0));
        Integer offsetMs = businessTz.getOffset(gmtMidnight);
        Integer offsetSeconds = offsetMs == null ? 0 : (offsetMs / 1000);
        DateTime businessNoonUtc = gmtMidnight.addSeconds(-offsetSeconds).addHours(12);
        return businessNoonUtc.getTime() / 1000;
    }

    private static void setCustomerDefaultPaymentMethod(String customerId, String paymentMethodId) {
        String body = 'invoice_settings[default_payment_method]=' + enc(paymentMethodId);
        callStripe('POST', '/customers/' + encPath(customerId), body);
    }

    private static String createRecurringPrice(Decimal amount, String currencyCode, String interval, Integer intervalCount, String gauId) {
        String useCurrency = String.isBlank(currencyCode) ? 'usd' : currencyCode.trim().toLowerCase();
        String useInterval = stripeInterval(interval);
        Integer useIntervalCount = normalizeStripeIntervalCount(interval, intervalCount);
        Integer cents = (amount.setScale(2) * 100).intValue();
        String productName = recurringProductName(gauId, amount);
        String body = 'unit_amount=' + cents
            + '&currency=' + enc(useCurrency)
            + '&recurring[interval]=' + enc(useInterval)
            + '&recurring[interval_count]=' + useIntervalCount
            + '&product_data[name]=' + enc(productName);
        Map<String, Object> price = parseResponse(callStripe('POST', '/prices', body), 200);
        return (String) price.get('id');
    }

    private static String recurringProductName(String gauId, Decimal amount) {
        String gauName = null;
        if (String.isNotBlank(gauId)) {
            List<npsp__General_Accounting_Unit__c> rows = [
                SELECT Name
                FROM npsp__General_Accounting_Unit__c
                WHERE Id = :gauId
                LIMIT 1
            ];
            if (!rows.isEmpty()) {
                gauName = rows[0].Name;
            }
        }

        String baseName = String.isBlank(gauName) ? 'Donation' : gauName;
        Decimal safeAmount = amount == null ? 0 : amount.setScale(2);
        return 'ISNA Recurring ' + baseName + ' - $' + String.valueOf(safeAmount);
    }

    private static void enqueueManagedScheduleCreate(
        String customerId,
        Id contactId,
        Id recurringDonationId,
        String priceId,
        String paymentMethodId,
        Date startDate,
        String gauId,
        String interval,
        Integer intervalCount,
        FixedDonationConfig fixedConfig,
        Decimal amount,
        String recurringType,
        Integer installments
    ) {
        Long startEpoch = startDateEpoch(startDate);
        String durationInterval = stripeInterval(interval);
        String scheduleBody = 'customer=' + enc(customerId)
            + '&start_date=' + String.valueOf(startEpoch)
            + '&default_settings[collection_method]=charge_automatically'
            + '&default_settings[billing_cycle_anchor]=automatic'
            + '&metadata[sf_created]=true'
            + '&metadata[sf_source]=' + enc('salesforce_component')
            + '&metadata[sf_contact_id]=' + enc(String.valueOf(contactId))
            + '&metadata[sf_rd_id]=' + enc(String.valueOf(recurringDonationId))
            + '&phases[0][metadata][sf_created]=true'
            + '&phases[0][metadata][sf_source]=' + enc('salesforce_component')
            + '&phases[0][metadata][sf_contact_id]=' + enc(String.valueOf(contactId))
            + '&phases[0][metadata][sf_rd_id]=' + enc(String.valueOf(recurringDonationId))
            + '&phases[0][items][0][price]=' + enc(priceId)
            + '&phases[0][items][0][quantity]=1';
        if (String.isNotBlank(paymentMethodId)) {
            scheduleBody += '&default_settings[default_payment_method]=' + enc(paymentMethodId);
            scheduleBody += '&phases[0][default_payment_method]=' + enc(paymentMethodId);
        }
        if (String.isNotBlank(gauId)) {
            scheduleBody += '&metadata[sf_gau_id]=' + enc(gauId);
            scheduleBody += '&phases[0][metadata][sf_gau_id]=' + enc(gauId);
        }

        if (fixedConfig != null && fixedConfig.isFixed) {
            scheduleBody += '&end_behavior=cancel'
                + '&phases[0][iterations]=' + fixedConfig.installments;
        } else {
            scheduleBody += '&end_behavior=release'
                + '&phases[0][iterations]=1';
        }

        Map<String, Object> createdSchedule = parseResponse(callStripe('POST', '/subscription_schedules', scheduleBody), 200);
        String scheduleId = (String) createdSchedule.get('id');
        syncRecurringDonationAfterManagedScheduleCreate(
            recurringDonationId,
            scheduleId,
            amount,
            interval,
            intervalCount,
            startDate,
            recurringType,
            installments
        );
        if (String.isNotBlank(gauId)) {
            saveSelectedGauToRecurringDonation(null, gauId, recurringDonationId);
        }
    }

    private static void enqueueManagedImmediateFixedCreate(
        String customerId,
        Id contactId,
        Id recurringDonationId,
        String priceId,
        String paymentMethodId,
        String gauId,
        FixedDonationConfig fixedConfig,
        Decimal amount,
        String interval,
        Integer intervalCount,
        String recurringType,
        Integer installments,
        Date nextPaymentDate
    ) {
        Long startEpoch = DateTime.now().getTime() / 1000;
        String fixedScheduleBody = 'customer=' + enc(customerId)
            + '&start_date=' + String.valueOf(startEpoch)
            + '&end_behavior=cancel'
            + '&default_settings[collection_method]=charge_automatically'
            + '&default_settings[billing_cycle_anchor]=automatic'
            + '&metadata[sf_created]=true'
            + '&metadata[sf_source]=' + enc('salesforce_component')
            + '&metadata[sf_contact_id]=' + enc(String.valueOf(contactId))
            + '&metadata[sf_rd_id]=' + enc(String.valueOf(recurringDonationId))
            + '&phases[0][metadata][sf_created]=true'
            + '&phases[0][metadata][sf_source]=' + enc('salesforce_component')
            + '&phases[0][metadata][sf_contact_id]=' + enc(String.valueOf(contactId))
            + '&phases[0][metadata][sf_rd_id]=' + enc(String.valueOf(recurringDonationId))
            + '&phases[0][items][0][price]=' + enc(priceId)
            + '&phases[0][items][0][quantity]=1'
            + '&phases[0][iterations]=' + fixedConfig.installments;
        if (String.isNotBlank(paymentMethodId)) {
            fixedScheduleBody += '&default_settings[default_payment_method]=' + enc(paymentMethodId);
            fixedScheduleBody += '&phases[0][default_payment_method]=' + enc(paymentMethodId);
        }
        if (String.isNotBlank(gauId)) {
            fixedScheduleBody += '&metadata[sf_gau_id]=' + enc(gauId);
            fixedScheduleBody += '&phases[0][metadata][sf_gau_id]=' + enc(gauId);
        }

        Map<String, Object> createdSchedule = parseResponse(callStripe('POST', '/subscription_schedules', fixedScheduleBody), 200);
        String scheduleId = (String) createdSchedule.get('id');
        syncRecurringDonationAfterManagedScheduleCreate(
            recurringDonationId,
            scheduleId,
            amount,
            interval,
            intervalCount,
            nextPaymentDate == null ? Date.today() : nextPaymentDate,
            recurringType,
            installments
        );
        if (String.isNotBlank(gauId)) {
            saveSelectedGauToRecurringDonation(null, gauId, recurringDonationId);
        }
    }

    private static Integer normalizeIntervalCount(Integer intervalCount) {
        return intervalCount == null || intervalCount <= 0 ? 1 : intervalCount;
    }

    private static Integer normalizeStripeIntervalCount(String interval, Integer intervalCount) {
        Integer count = normalizeIntervalCount(intervalCount);
        if (String.isNotBlank(interval) && interval.trim().equalsIgnoreCase('Quarterly')) {
            return count * 3;
        }
        return count;
    }

    public static void updateRecurringDonationBypassed(npe03__Recurring_Donation__c recurringDonation) {
        Boolean previous = skipRecurringDonationTrigger;
        skipRecurringDonationTrigger = true;
        try {
            update recurringDonation;
        } finally {
            skipRecurringDonationTrigger = previous;
        }
    }

    private static void syncRecurringDonationAfterManagedCreate(
        Id recurringDonationId,
        String subscriptionId,
        Decimal amount,
        String interval,
        Integer intervalCount,
        Date nextPaymentDate,
        String recurringType,
        Integer installments
    ) {
        if (recurringDonationId == null || String.isBlank(subscriptionId)) return;
        Id existingRecurringDonationId = findRecurringDonationIdBySubscriptionId(subscriptionId);
        if (existingRecurringDonationId != null) {
            recurringDonationId = existingRecurringDonationId;
        }
        npe03__Recurring_Donation__c recurringDonation = new npe03__Recurring_Donation__c(
            Id = recurringDonationId,
            Stripe_Subscription_ID__c = subscriptionId,
            npe03__Amount__c = amount,
            npe03__Installment_Period__c = npspInstallmentPeriod(interval),
            npsp__InstallmentFrequency__c = normalizeIntervalCount(intervalCount),
            npe03__Next_Payment_Date__c = nextPaymentDate,
            npsp__Status__c = 'Active',
            npsp__ClosedReason__c = null,
            npsp__EndDate__c = null
        );
        if (String.isNotBlank(recurringType)) {
            recurringDonation.npsp__RecurringType__c = recurringType;
            recurringDonation.npe03__Installments__c = recurringType == 'Fixed' ? installments : null;
        }
        try {
            updateRecurringDonationBypassed(recurringDonation);
        } catch (DmlException ex) {
            if (!isStripeSubscriptionDuplicateError(ex)) {
                throw ex;
            }

            Id winnerRecurringDonationId = findRecurringDonationIdBySubscriptionId(subscriptionId);
            if (winnerRecurringDonationId == null) {
                throw ex;
            }

            npe03__Recurring_Donation__c winnerRecurringDonation = new npe03__Recurring_Donation__c(
                Id = winnerRecurringDonationId,
                Stripe_Subscription_ID__c = subscriptionId,
                npe03__Amount__c = amount,
                npe03__Installment_Period__c = npspInstallmentPeriod(interval),
                npsp__InstallmentFrequency__c = normalizeIntervalCount(intervalCount),
                npe03__Next_Payment_Date__c = nextPaymentDate,
                npsp__Status__c = 'Active',
                npsp__ClosedReason__c = null,
                npsp__EndDate__c = null
            );
            if (String.isNotBlank(recurringType)) {
                winnerRecurringDonation.npsp__RecurringType__c = recurringType;
                winnerRecurringDonation.npe03__Installments__c = recurringType == 'Fixed' ? installments : null;
            }
            updateRecurringDonationBypassed(winnerRecurringDonation);
        }
    }

    private static Id findRecurringDonationIdBySubscriptionId(String subscriptionId) {
        if (String.isBlank(subscriptionId)) return null;
        List<npe03__Recurring_Donation__c> rows = [
            SELECT Id
            FROM npe03__Recurring_Donation__c
            WHERE Stripe_Subscription_ID__c = :subscriptionId
            LIMIT 1
        ];
        return rows.isEmpty() ? null : rows[0].Id;
    }

    private static Boolean isStripeSubscriptionDuplicateError(DmlException ex) {
        if (ex == null || String.isBlank(ex.getMessage())) return false;
        String message = ex.getMessage();
        return message.contains('DUPLICATE_VALUE')
            && message.contains('Stripe_Subscription_ID__c');
    }

    private static void syncRecurringDonationAfterManagedScheduleCreate(
        Id recurringDonationId,
        String scheduleId,
        Decimal amount,
        String interval,
        Integer intervalCount,
        Date nextPaymentDate,
        String recurringType,
        Integer installments
    ) {
        if (recurringDonationId == null || String.isBlank(scheduleId)) return;
        npe03__Recurring_Donation__c recurringDonation = new npe03__Recurring_Donation__c(
            Id = recurringDonationId,
            Stripe_Subscription_ID__c = null,
            Pending_Stripe_Schedule_ID__c = scheduleId,
            npe03__Amount__c = amount,
            npe03__Installment_Period__c = npspInstallmentPeriod(interval),
            npsp__InstallmentFrequency__c = normalizeIntervalCount(intervalCount),
            npsp__Day_of_Month__c = nextPaymentDate == null ? null : npspDayOfMonth(startDateEpoch(nextPaymentDate)),
            npe03__Next_Payment_Date__c = nextPaymentDate,
            npsp__Status__c = 'Active',
            npsp__ClosedReason__c = null,
            npsp__EndDate__c = null
        );
        if (String.isNotBlank(recurringType)) {
            recurringDonation.npsp__RecurringType__c = recurringType;
            recurringDonation.npe03__Installments__c = recurringType == 'Fixed' ? installments : null;
        }
        updateRecurringDonationBypassed(recurringDonation);
    }

    private static void syncRecurringDonationAfterManagedUpdate(
        String subscriptionId,
        Decimal amount,
        String interval,
        Integer intervalCount,
        Long currentPeriodStart,
        Long currentPeriodEnd,
        String recurringType,
        Integer installments
    ) {
        if (String.isBlank(subscriptionId)) return;
        List<npe03__Recurring_Donation__c> rows = [
            SELECT Id
            FROM npe03__Recurring_Donation__c
            WHERE Stripe_Subscription_ID__c = :subscriptionId
            LIMIT 1
        ];
        if (rows.isEmpty()) return;

        npe03__Recurring_Donation__c rd = new npe03__Recurring_Donation__c(Id = rows[0].Id);
        Boolean hasUpdates = false;
        if (amount != null && amount > 0) {
            rd.npe03__Amount__c = amount;
            hasUpdates = true;
        }
        if (String.isNotBlank(interval)) {
            String installmentPeriod = npspInstallmentPeriod(interval);
            rd.npe03__Installment_Period__c = installmentPeriod;
            rd.npsp__InstallmentFrequency__c = normalizeIntervalCount(intervalCount);
            Date nextPaymentDate = epochDate(currentPeriodEnd, null);
            if (nextPaymentDate != null) {
                rd.npe03__Next_Payment_Date__c = nextPaymentDate;
            }
            if (installmentPeriod == 'Monthly') {
                rd.npsp__Day_of_Month__c = npspDayOfMonth(currentPeriodEnd);
            }
            hasUpdates = true;
        }
        if (String.isNotBlank(recurringType)) {
            rd.npsp__RecurringType__c = recurringType;
            rd.npe03__Installments__c = recurringType == 'Fixed' ? installments : null;
            hasUpdates = true;
        }
        if (hasUpdates) {
            updateRecurringDonationBypassed(rd);
        }
    }

    private static void saveRecurringDonationStatus(String subscriptionId, String status) {
        if (String.isBlank(subscriptionId) || String.isBlank(status)) return;
        List<npe03__Recurring_Donation__c> rows = [
            SELECT Id
            FROM npe03__Recurring_Donation__c
            WHERE Stripe_Subscription_ID__c = :subscriptionId
            LIMIT 1
        ];
        if (rows.isEmpty()) return;
        npe03__Recurring_Donation__c rd = new npe03__Recurring_Donation__c(
            Id = rows[0].Id,
            npsp__Status__c = status
        );
        // NPSP requires the end date to be later than the last Closed Won gift's
        // close date, so a close fails if we just use today and a gift closed today.
        if (status == 'Closed') {
            rd.npsp__EndDate__c = closeEndDateForRecurringDonation(rows[0].Id);
        }
        updateRecurringDonationBypassed(rd);
    }

    // End date that satisfies NPSP's rule that a closed recurring donation's end date
    // must be later than its most recent Closed Won opportunity's close date. Uses
    // today unless a won gift closed today or in the future, in which case it uses the
    // day after that gift.
    private static Date closeEndDateForRecurringDonation(Id recurringDonationId) {
        Date endDate = Date.today();
        if (recurringDonationId == null) return endDate;
        List<Opportunity> opps = [
            SELECT CloseDate
            FROM Opportunity
            WHERE npe03__Recurring_Donation__c = :recurringDonationId
              AND IsWon = true
            ORDER BY CloseDate DESC
            LIMIT 1
        ];
        if (!opps.isEmpty() && opps[0].CloseDate != null && opps[0].CloseDate >= endDate) {
            endDate = opps[0].CloseDate.addDays(1);
        }
        return endDate;
    }

    private static void saveRecurringDonationResumedStatus(String subscriptionId) {
        if (String.isBlank(subscriptionId)) return;
        List<npe03__Recurring_Donation__c> rows = [
            SELECT Id
            FROM npe03__Recurring_Donation__c
            WHERE Stripe_Subscription_ID__c = :subscriptionId
            LIMIT 1
        ];
        if (rows.isEmpty()) return;
        updateRecurringDonationBypassed(new npe03__Recurring_Donation__c(
            Id = rows[0].Id,
            npsp__Status__c = 'Active',
            npsp__ClosedReason__c = null
        ));
    }

    private static void saveRecurringDonationGiftDay(String subscriptionId, String dayOfMonth, Date nextPaymentDate) {
        List<npe03__Recurring_Donation__c> rows = [
            SELECT Id
            FROM npe03__Recurring_Donation__c
            WHERE Stripe_Subscription_ID__c = :subscriptionId
            LIMIT 1
        ];
        if (rows.isEmpty()) return;
        npe03__Recurring_Donation__c rd = new npe03__Recurring_Donation__c(
            Id = rows[0].Id,
            npsp__Day_of_Month__c = dayOfMonth
        );
        if (nextPaymentDate != null) {
            rd.npe03__Next_Payment_Date__c = nextPaymentDate;
        }
        updateRecurringDonationBypassed(rd);
    }

    // Returns a strictly-future gift date for the gift-day flow. Prefers the supplied
    // nextGiftDate when it is already in the future; otherwise computes the next
    // occurrence of the day-of-month from today. Returns null when neither yields a
    // future date, so a manual edit with a past/today date doesn't silently fail the
    // downstream "Next gift date must be in the future" check.
    private static Date safeFutureGiftDate(String subscriptionId, String nextGiftDate, String dayOfMonth) {
        Date today = Date.today();
        Date parsed = parseStartDate(nextGiftDate);
        if (parsed != null && parsed > today) {
            return parsed;
        }
        if (String.isNotBlank(dayOfMonth)) {
            Date computed = calculateRecurringNextPaymentDate(subscriptionId, dayOfMonth, today);
            if (computed != null && computed > today) {
                return computed;
            }
        }
        return null;
    }

    private static Date calculateRecurringNextPaymentDate(String subscriptionId, String dayOfMonth, Date fallbackDate) {
        if (String.isBlank(dayOfMonth)) return fallbackDate;

        // Mirror the component's projection: the soonest gift date strictly after
        // today that matches the chosen day. The first gift only needs a future
        // start date; Stripe then continues at the subscription's own interval, so
        // the installment period/frequency do not factor into this first date.
        Date today = fallbackDate == null ? Date.today() : fallbackDate;

        if (dayOfMonth == 'Last_Day') {
            Date thisMonthEnd = Date.newInstance(today.year(), today.month(), 1).addMonths(1).addDays(-1);
            if (thisMonthEnd > today) return thisMonthEnd;
            return Date.newInstance(today.year(), today.month(), 1).addMonths(2).addDays(-1);
        }

        Integer targetDay = Integer.valueOf(dayOfMonth);
        Integer thisMonthLastDay = Date.newInstance(today.year(), today.month(), 1).addMonths(1).addDays(-1).day();
        Date thisCandidate = Date.newInstance(today.year(), today.month(), Math.min(targetDay, thisMonthLastDay));
        if (thisCandidate > today) return thisCandidate;

        Date nextMonthStart = Date.newInstance(today.year(), today.month(), 1).addMonths(1);
        Integer nextMonthLastDay = nextMonthStart.addMonths(1).addDays(-1).day();
        return Date.newInstance(nextMonthStart.year(), nextMonthStart.month(), Math.min(targetDay, nextMonthLastDay));
    }

    private static Date epochDate(Long epochSeconds, Date fallbackDate) {
        if (epochSeconds == null || epochSeconds <= 0) return fallbackDate;
        return DateTime.newInstanceGmt(1970, 1, 1, 0, 0, 0)
            .addSeconds(Integer.valueOf(String.valueOf(epochSeconds)))
            .dateGmt();
    }

    private static String getContactCustomerId(Id contactId) {
        List<Contact> rows = Database.query('SELECT Id,' + CONTACT_CUSTOMER_FIELD + ' FROM Contact WHERE Id = :contactId LIMIT 1');
        if (rows.isEmpty()) return null;
        Object raw = rows[0].get(CONTACT_CUSTOMER_FIELD);
        return raw == null ? null : String.valueOf(raw);
    }

    private static String resolveCustomerIdFromSubscription(String subscriptionId) {
        if (String.isBlank(subscriptionId)) return null;
        Map<String, Object> sub = parseResponse(
            callStripe('GET', '/subscriptions/' + encPath(subscriptionId), null),
            200
        );
        return stringValue(sub.get('customer'));
    }

    private static String resolveCustomerIdFromSchedule(String scheduleId) {
        if (String.isBlank(scheduleId)) return null;
        Map<String, Object> sched = parseResponse(
            callStripe('GET', '/subscription_schedules/' + encPath(scheduleId), null),
            200
        );
        return stringValue(sched.get('customer'));
    }

    private static CustomerRef resolveCustomerRef(Id contactId, String customerId) {
        // Prefer an explicit customer id (e.g. one derived from the managed
        // subscription) so the recurring-donation flow never creates a duplicate
        // customer. Only fall back to the Contact for the contact-page flow, which
        // has no subscription to source the customer from.
        if (String.isNotBlank(customerId)) {
            CustomerRef ref = new CustomerRef();
            ref.customerId = customerId;
            ref.needsContactSave = false;
            return ref;
        }
        if (contactId != null) {
            return getOrCreateCustomerRef(contactId);
        }
        throw new AuraHandledException('A Contact or Stripe customer is required for this action.');
    }

    private static CustomerRef resolveCustomerRefForSubscription(Id contactId, String subscriptionId) {
        CustomerRef ref = new CustomerRef();
        ref.customerId = resolveCustomerIdFromSubscription(subscriptionId);
        ref.needsContactSave = false;
        return ref;
    }

    private static CustomerRef getOrCreateCustomerRef(Id contactId) {
        CustomerRef ref = new CustomerRef();
        ref.customerId = getContactCustomerId(contactId);
        ref.needsContactSave = false;
        if (String.isNotBlank(ref.customerId)) return ref;

        Contact c = [
            SELECT Id, FirstName, LastName, Email, MobilePhone, Phone,
                   MailingStreet, MailingCity, MailingState, MailingStateCode,
                   MailingPostalCode, MailingCountry, MailingCountryCode
            FROM Contact
            WHERE Id = :contactId
            LIMIT 1
        ];
        String fullName = String.join(new List<String>{c.FirstName, c.LastName}, ' ').trim();

        String body = 'name=' + enc(fullName) + '&metadata[salesforce_contact_id]=' + enc((String) c.Id);
        if (String.isNotBlank(c.Email)) body += '&email=' + enc(c.Email);
        String phoneForStripe = String.isNotBlank(c.MobilePhone) ? c.MobilePhone : c.Phone;
        if (String.isNotBlank(phoneForStripe)) body += '&phone=' + enc(phoneForStripe);
        body += stripeAddressParamsFromContact(c);

        Map<String, Object> json = parseResponse(callStripe('POST', '/customers', body), 200);
        ref.customerId = (String) json.get('id');
        ref.needsContactSave = true;
        return ref;
    }

    private static String stripeAddressParamsFromContact(Contact c) {
        if (c == null) return '';

        String body = '';
        if (String.isNotBlank(c.MailingStreet)) {
            body += '&address[line1]=' + enc(c.MailingStreet);
        }
        if (String.isNotBlank(c.MailingCity)) {
            body += '&address[city]=' + enc(c.MailingCity);
        }
        String state = String.isNotBlank(c.MailingStateCode) ? c.MailingStateCode : c.MailingState;
        if (String.isNotBlank(state)) {
            body += '&address[state]=' + enc(state);
        }
        if (String.isNotBlank(c.MailingPostalCode)) {
            body += '&address[postal_code]=' + enc(c.MailingPostalCode);
        }
        String country = String.isNotBlank(c.MailingCountryCode) ? c.MailingCountryCode : c.MailingCountry;
        if (String.isNotBlank(country)) {
            body += '&address[country]=' + enc(country);
        }
        return body;
    }

    private static void saveContactCustomerIdIfNeeded(Id contactId, CustomerRef customer) {
        if (contactId == null) return;
        if (customer == null || customer.needsContactSave != true) return;
        saveContactCustomerId(contactId, customer.customerId);
    }

    private static void saveContactCustomerId(Id contactId, String customerId) {
        SObjectType t = Contact.SObjectType;
        if (!t.getDescribe().fields.getMap().containsKey(CONTACT_CUSTOMER_FIELD)) {
            throw new AuraHandledException('Missing field Contact.' + CONTACT_CUSTOMER_FIELD + '. Create this Text field before using subscriptions.');
        }

        Contact c = new Contact(Id = contactId);
        c.put(CONTACT_CUSTOMER_FIELD, customerId);
        update c;
    }

    private static String getSecretKey() {
        Stripe_Settings__c s = Stripe_Settings__c.getOrgDefaults();
        if (s == null || String.isBlank(s.Secret_Key__c)) {
            throw new AuraHandledException('Stripe Secret Key not configured in Stripe Settings custom setting.');
        }
        return s.Secret_Key__c;
    }

    private static String getPublishableKey() {
        Stripe_Settings__c s = Stripe_Settings__c.getOrgDefaults();
        if (s == null || String.isBlank(s.Publishable_Key__c)) {
            throw new AuraHandledException('Stripe Publishable Key not configured in Stripe Settings custom setting.');
        }
        return s.Publishable_Key__c;
    }

    private static HttpResponse callStripe(String method, String path, String body) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(API_BASE + path);
        req.setMethod(method);
        req.setHeader('Authorization', 'Bearer ' + getSecretKey());
        req.setTimeout(30000);

        if (body != null) {
            req.setHeader('Content-Type', 'application/x-www-form-urlencoded');
            req.setBody(body);
        }

        return new Http().send(req);
    }

    private static Map<String, Object> parseResponse(HttpResponse res, Integer expectedStatus) {
        Map<String, Object> payload = new Map<String, Object>();
        if (String.isNotBlank(res.getBody())) {
            payload = (Map<String, Object>) JSON.deserializeUntyped(res.getBody());
        }

        if (res.getStatusCode() != expectedStatus) {
            Map<String, Object> err = (Map<String, Object>) payload.get('error');
            String msg = err != null ? (String) err.get('message') : res.getBody();
            throw new AuraHandledException('Stripe API error (' + res.getStatusCode() + '): ' + msg);
        }

        return payload;
    }

    private static String enc(String val) {
        return EncodingUtil.urlEncode(val == null ? '' : val, 'UTF-8');
    }

    private static String encPath(String val) {
        return val == null ? '' : val.replace('/', '');
    }

    private static String stringValue(Object value) {
        if (value == null) return null;
        if (value instanceof String) return (String) value;
        if (value instanceof Map<String, Object>) return (String) ((Map<String, Object>) value).get('id');
        return String.valueOf(value);
    }

    private static Decimal amountFromStripePrice(Map<String, Object> price) {
        if (price == null) return null;
        Integer unitAmount = toInt(price.get('unit_amount'));
        return unitAmount == null ? null : (Decimal.valueOf(unitAmount) / 100);
    }

    private static Integer toInt(Object v) {
        if (v == null) return null;
        if (v instanceof Integer) return (Integer) v;
        if (v instanceof Long) return Integer.valueOf(String.valueOf(v));
        if (v instanceof Decimal) return ((Decimal) v).intValue();
        if (v instanceof Double) return Integer.valueOf(String.valueOf(Math.round((Double) v)));
        String raw = String.valueOf(v);
        if (raw.endsWith('.0')) {
            raw = raw.substring(0, raw.length() - 2);
        }
        return Integer.valueOf(raw);
    }

    private static Long toLong(Object v) {
        if (v == null) return null;
        if (v instanceof Long) return (Long) v;
        if (v instanceof Integer) return Long.valueOf(String.valueOf(v));
        if (v instanceof Decimal) return ((Decimal) v).longValue();
        if (v instanceof Double) return Long.valueOf(String.valueOf(Math.round((Double) v)));
        String raw = String.valueOf(v);
        if (raw.endsWith('.0')) {
            raw = raw.substring(0, raw.length() - 2);
        }
        return Long.valueOf(raw);
    }
}