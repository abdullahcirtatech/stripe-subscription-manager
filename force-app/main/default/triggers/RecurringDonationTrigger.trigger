trigger RecurringDonationTrigger on npe03__Recurring_Donation__c (after update) {
    if (!Trigger.isAfter || !Trigger.isUpdate) return;
    if (Test.isRunningTest() && !StripeSubscriptionController.isRecurringDonationTriggerTestModeEnabled()) return;
    if (StripeSubscriptionController.isRecurringDonationTriggerSuppressed()) return;

    List<StripeSubscriptionController.RecurringDonationSyncRequest> requests =
        new List<StripeSubscriptionController.RecurringDonationSyncRequest>();

    for (npe03__Recurring_Donation__c currentRow : Trigger.new) {
        npe03__Recurring_Donation__c previousRow = Trigger.oldMap.get(currentRow.Id);
        if (String.isBlank(currentRow.Stripe_Subscription_ID__c) || currentRow.npe03__Contact__c == null) continue;

        Boolean amountChanged = currentRow.npe03__Amount__c != previousRow.npe03__Amount__c;
        Boolean periodChanged = currentRow.npe03__Installment_Period__c != previousRow.npe03__Installment_Period__c;
        Boolean frequencyChanged = currentRow.npsp__InstallmentFrequency__c != previousRow.npsp__InstallmentFrequency__c;
        Boolean dayChanged = currentRow.npsp__Day_of_Month__c != previousRow.npsp__Day_of_Month__c;
        Boolean nextPaymentDateChanged = currentRow.npe03__Next_Payment_Date__c != previousRow.npe03__Next_Payment_Date__c;
        Boolean statusChanged = currentRow.npsp__Status__c != previousRow.npsp__Status__c;
        Boolean recurringTypeChanged = currentRow.npsp__RecurringType__c != previousRow.npsp__RecurringType__c;
        Boolean installmentsChanged = currentRow.npe03__Installments__c != previousRow.npe03__Installments__c;

        if (statusChanged && currentRow.npsp__Status__c == 'Closed') {
            StripeSubscriptionController.RecurringDonationSyncRequest request =
                new StripeSubscriptionController.RecurringDonationSyncRequest();
            request.recurringDonationId = currentRow.Id;
            request.contactId = currentRow.npe03__Contact__c;
            request.subscriptionId = currentRow.Stripe_Subscription_ID__c;
            request.action = 'cancel';
            request.closeReason = currentRow.npsp__ClosedReason__c;
            requests.add(request);
            continue;
        }

        if (amountChanged || periodChanged || frequencyChanged || recurringTypeChanged || installmentsChanged) {
            StripeSubscriptionController.RecurringDonationSyncRequest request =
                new StripeSubscriptionController.RecurringDonationSyncRequest();
            request.recurringDonationId = currentRow.Id;
            request.contactId = currentRow.npe03__Contact__c;
            request.subscriptionId = currentRow.Stripe_Subscription_ID__c;
            request.action = 'amount_frequency';
            request.amount = currentRow.npe03__Amount__c;
            request.installmentPeriod = currentRow.npe03__Installment_Period__c;
            request.installmentFrequency = currentRow.npsp__InstallmentFrequency__c == null
                ? null
                : Integer.valueOf(String.valueOf(currentRow.npsp__InstallmentFrequency__c));
            request.recurringType = currentRow.npsp__RecurringType__c;
            request.installments = currentRow.npe03__Installments__c == null
                ? null
                : Integer.valueOf(String.valueOf(currentRow.npe03__Installments__c));
            requests.add(request);
        }

        if (dayChanged || nextPaymentDateChanged) {
            StripeSubscriptionController.RecurringDonationSyncRequest request =
                new StripeSubscriptionController.RecurringDonationSyncRequest();
            request.recurringDonationId = currentRow.Id;
            request.contactId = currentRow.npe03__Contact__c;
            request.subscriptionId = currentRow.Stripe_Subscription_ID__c;
            request.action = 'gift_day';
            request.dayOfMonth = currentRow.npsp__Day_of_Month__c;
            request.nextGiftDate = currentRow.npe03__Next_Payment_Date__c == null
                ? null
                : String.valueOf(currentRow.npe03__Next_Payment_Date__c);
            requests.add(request);
        }
    }

    if (!requests.isEmpty()) {
        System.enqueueJob(new StripeSubscriptionController.RecurringDonationSyncJob(requests));
    }
}