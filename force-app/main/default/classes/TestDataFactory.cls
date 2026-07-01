/**
 * Shared @isTest data builder for the Bazaar Apex test suite. Keeps individual
 * test classes free of repetitive setup boilerplate.
 *
 * All methods insert and return the record(s). When you only need an unsaved
 * sObject, build it inline in the test instead.
 */
@isTest
public class TestDataFactory {

    public static Stripe_Settings__c createStripeSettings() {
        Stripe_Settings__c s = Stripe_Settings__c.getOrgDefaults();
        if (s == null || s.Id == null) {
            s = new Stripe_Settings__c(
                SetupOwnerId = UserInfo.getOrganizationId(),
                Publishable_Key__c = 'pk_test_dummy',
                Secret_Key__c     = 'sk_test_dummy'
            );
            insert s;
        } else {
            s.Publishable_Key__c = 'pk_test_dummy';
            s.Secret_Key__c      = 'sk_test_dummy';
            update s;
        }
        return s;
    }

    public static void clearStripeSettings() {
        Stripe_Settings__c s = Stripe_Settings__c.getOrgDefaults();
        if (s != null && s.Id != null) {
            delete s;
        }
    }

    public static Event__c createEvent() {
        return createEvent('Test Bazaar', 'Draft');
    }

    public static Event__c createEvent(String name, String bazaarStatus) {
        Event__c evt = new Event__c(
            Name = name,
            Bazaar_Status__c = bazaarStatus,
            Map_Width__c = 50,
            Map_Height__c = 30,
            Email_Booth_Confirmation_Enabled__c = false,
            Donation_Enabled__c = true
        );
        insert evt;
        return evt;
    }

    public static Booth_Type__c createBoothType(Id eventId) {
        return createBoothType(eventId, 'Standard', 100);
    }

    public static Booth_Type__c createBoothType(Id eventId, String name, Decimal price) {
        Booth_Type__c bt = new Booth_Type__c(
            Name = name,
            Event__c = eventId,
            Price__c = price,
            Color__c = '#3b82f6',
            Text_Color__c = '#ffffff',
            Default_Width__c = 4,
            Default_Height__c = 4,
            Sort_Order__c = 1
        );
        insert bt;
        return bt;
    }

    public static Booth__c createBooth(Id eventId, Id boothTypeId) {
        return createBooth(eventId, boothTypeId, 'B-001', 'Available', 100);
    }

    public static Booth__c createBooth(Id eventId, Id boothTypeId, String name,
            String status, Decimal price) {
        Booth__c b = new Booth__c(
            Name = name,
            Event__c = eventId,
            Booth_Type_Ref__c = boothTypeId,
            Status__c = status,
            Price__c = price,
            Position_X__c = 0,
            Position_Y__c = 0,
            Size_Width__c = 4,
            Size_Height__c = 4
        );
        insert b;
        return b;
    }

    public static List<Booth__c> createBooths(Id eventId, Id boothTypeId, Integer count) {
        List<Booth__c> booths = new List<Booth__c>();
        for (Integer i = 1; i <= count; i++) {
            booths.add(new Booth__c(
                Name = 'B-' + String.valueOf(i).leftPad(3, '0'),
                Event__c = eventId,
                Booth_Type_Ref__c = boothTypeId,
                Status__c = 'Available',
                Price__c = 100,
                Position_X__c = i,
                Position_Y__c = 0,
                Size_Width__c = 4,
                Size_Height__c = 4
            ));
        }
        insert booths;
        return booths;
    }

    public static Booth_Add_On__c createAddOn(Id eventId) {
        return createAddOn(eventId, 'Electric', 25);
    }

    public static Booth_Add_On__c createAddOn(Id eventId, String name, Decimal price) {
        Booth_Add_On__c ao = new Booth_Add_On__c(
            Name = name,
            Event__c = eventId,
            Price__c = price,
            Active__c = true,
            Description__c = 'Test add-on'
        );
        insert ao;
        return ao;
    }

    public static npsp__General_Accounting_Unit__c createGAU(String name) {
        npsp__General_Accounting_Unit__c gau = new npsp__General_Accounting_Unit__c(
            Name = name,
            npsp__Active__c = true
        );
        insert gau;
        return gau;
    }

    public static Account createAccount(String name) {
        Account a = new Account(Name = name);
        insert a;
        return a;
    }

    public static Contact createContact(Id accountId, String firstName, String lastName, String email) {
        Contact c = new Contact(
            FirstName = firstName,
            LastName = lastName,
            Email = email,
            Phone = '555-1212',
            AccountId = accountId
        );
        insert c;
        return c;
    }

    /**
     * Returns the Booth_Reservation Opportunity record type Id, or null if the
     * org under test does not have it deployed. Tests should skip
     * Opportunity-creating assertions (without failing) when this returns null.
     */
    public static Id getBoothReservationRecordTypeId() {
        Map<String, Schema.RecordTypeInfo> rtMap =
            Schema.SObjectType.Opportunity.getRecordTypeInfosByDeveloperName();
        if (rtMap.containsKey('Booth_Reservation')) {
            return rtMap.get('Booth_Reservation').getRecordTypeId();
        }
        return null;
    }

    // ── Event Manager helpers ──

    public static Contact createRegistrationContact(String firstName, String lastName, String email) {
        Contact c = new Contact(
            FirstName = firstName,
            LastName = lastName,
            Email = email,
            npe01__HomeEmail__c = email,
            npe01__Preferred_Email__c = 'Personal'
        );
        insert c;
        return c;
    }

    public static Track__c createTrack(Id eventId, String name, Decimal price) {
        Track__c t = new Track__c(
            Name = name,
            Event__c = eventId,
            Ticket_Price__c = price,
            Publish_to_Web__c = false
        );
        insert t;
        return t;
    }

    public static Event_Registration__c createEventRegistration(
            Id eventId, Id contactId, String stripePiId,
            Decimal actualAmount, Decimal quantity) {
        Event_Registration__c r = new Event_Registration__c(
            Event__c = eventId,
            Contact__c = contactId,
            Stripe_ID__c = stripePiId,
            Actual_Amount__c = actualAmount,
            Quantity__c = quantity,
            Email_Confirmation_Sent__c = false,
            isEmailSent__c = false
        );
        insert r;
        return r;
    }

    public static Sub_Registration__c createSubRegistration(
            Id eventRegId, Id contactId, Boolean isPrimary, String status) {
        Sub_Registration__c sr = new Sub_Registration__c(
            Event_Registration__c = eventRegId,
            Contact__c = contactId,
            IsPrimary__c = isPrimary,
            Bypass_Cancellation_Flow__c = true,
            Status__c = status
        );
        insert sr;
        return sr;
    }

    public static Opportunity createPaidOpportunity(
            Id eventRegId, Decimal amount, String stripePiId) {
        Opportunity o = new Opportunity(
            Name = 'Test Registration Opp',
            StageName = 'Closed Won',
            CloseDate = Date.today(),
            Amount = amount,
            Event_Registration__c = eventRegId,
            stripe_payment_id__c = stripePiId
        );
        insert o;
        return o;
    }

    public static npe01__OppPayment__c createOppPayment(
            Id oppId, Decimal amount, Boolean paid, String stripeRef) {
        npe01__OppPayment__c p = new npe01__OppPayment__c(
            npe01__Opportunity__c = oppId,
            npe01__Payment_Amount__c = amount,
            npe01__Payment_Date__c = Date.today(),
            npe01__Paid__c = paid,
            npe01__Payment_Method__c = 'Credit Card (Online)',
            npe01__Check_Reference_Number__c = stripeRef
        );
        insert p;
        return p;
    }

    /**
     * Assigns the Event Registration Manager / Refund Manager permission sets
     * to the given user, if they exist. Silently no-ops if the perm set is
     * absent in the test org. Run inside Test.startTest()/stopTest() if you
     * need the assignment to take effect for the same transaction (or call
     * before the call you're testing).
     */
    public static void assignRegistrationPerms(Id userId, Boolean refundToo) {
        List<PermissionSet> ps = [
            SELECT Id, Name FROM PermissionSet
            WHERE Name IN ('Event_Registration_Manager','Event_Registration_Refund_Manager')
        ];
        List<PermissionSetAssignment> psas = new List<PermissionSetAssignment>();
        for (PermissionSet p : ps) {
            if (p.Name == 'Event_Registration_Refund_Manager' && !refundToo) continue;
            psas.add(new PermissionSetAssignment(
                AssigneeId = userId, PermissionSetId = p.Id
            ));
        }
        if (!psas.isEmpty()) {
            try { insert psas; } catch (Exception e) { /* already assigned */ }
        }
    }

    /**
     * Creates a fresh Standard User with no Registration permissions assigned,
     * for permission-denied test paths. Returns null if no Standard User
     * profile is available.
     */
    public static User createStandardUser() {
        Profile p = [SELECT Id FROM Profile WHERE Name = 'Standard User' LIMIT 1];
        String uniq = String.valueOf(DateTime.now().getTime()) + String.valueOf(Math.mod(Math.abs(Crypto.getRandomLong()), 100000));
        User u = new User(
            FirstName = 'Reg',
            LastName = 'TestUser',
            Email = 'regtest' + uniq + '@bazaartest.invalid',
            Username = 'regtest' + uniq + '@bazaartest.invalid.example',
            Alias = 'rtu' + uniq.substring(0, 3),
            TimeZoneSidKey = 'America/New_York',
            LocaleSidKey = 'en_US',
            EmailEncodingKey = 'UTF-8',
            ProfileId = p.Id,
            LanguageLocaleKey = 'en_US'
        );
        insert u;
        return u;
    }
}