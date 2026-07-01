import { LightningElement, api, wire } from 'lwc';
import { ShowToastEvent } from 'lightning/platformShowToastEvent';
import { CloseActionScreenEvent } from 'lightning/actions';
import { getObjectInfo, getPicklistValues } from 'lightning/uiObjectInfoApi';
import CONTACT_OBJECT from '@salesforce/schema/Contact';
import CONTACT_MAILING_COUNTRY_CODE from '@salesforce/schema/Contact.MailingCountryCode';
import CONTACT_MAILING_STATE_CODE from '@salesforce/schema/Contact.MailingStateCode';

import getStateForRecord from '@salesforce/apex/StripeSubscriptionController.getStateForRecord';
import attachPaymentMethod from '@salesforce/apex/StripeSubscriptionController.attachPaymentMethod';
import setDefaultPaymentMethod from '@salesforce/apex/StripeSubscriptionController.setDefaultPaymentMethod';
import createSubscription from '@salesforce/apex/StripeSubscriptionController.createSubscription';
import updateSubscription from '@salesforce/apex/StripeSubscriptionController.updateSubscription';
import updateSubscriptionGiftDay from '@salesforce/apex/StripeSubscriptionController.updateSubscriptionGiftDay';
import updatePendingSubscriptionSchedule from '@salesforce/apex/StripeSubscriptionController.updatePendingSubscriptionSchedule';
import cancelSubscription from '@salesforce/apex/StripeSubscriptionController.cancelSubscription';
import pauseSubscription from '@salesforce/apex/StripeSubscriptionController.pauseSubscription';
import resumeSubscription from '@salesforce/apex/StripeSubscriptionController.resumeSubscription';
import endSubscriptionTrialNow from '@salesforce/apex/StripeSubscriptionController.endSubscriptionTrialNow';
import createSetupIntent from '@salesforce/apex/StripeSubscriptionController.createSetupIntent';
import detachPaymentMethod from '@salesforce/apex/StripeSubscriptionController.detachPaymentMethod';
import listRecurringDonationClosedReasonOptions from '@salesforce/apex/StripeSubscriptionController.listRecurringDonationClosedReasonOptions';
import syncRecurringDonationAction from '@salesforce/apex/StripeSubscriptionController.syncRecurringDonationAction';

export default class StripeSubscriptionManager extends LightningElement {
    _recordId;
    initialized = false;
    @api newDonationUrl;
    @api newDonationFlowApiName;

    @api
    get recordId() {
        return this._recordId;
    }
    set recordId(value) {
        this._recordId = value;
        if (value && !this.initialized) {
            this.initialized = true;
            this.refresh();
        }
    }

    customerId;
    customerName;
    customerContactId;
    contactName;
    contactEmail;
    contactPhone;
    contactMailingStreet;
    contactMailingCity;
    contactMailingState;
    contactMailingPostalCode;
    contactMailingCountry;
    isRecurringDonationContext = false;
    hasLoadedState = false;
    paymentMethods = [];
    subscriptions = [];
    canceledSubscriptions = [];
    errorMessage;
    isBusy = false;
    // Set while the Stripe Payment Element is being submitted/confirmed. Kept
    // separate from isBusy on purpose: isBusy hides the schedule summary (which
    // unmounts the inline card iframe), so flipping it during confirmSetup would
    // detach the element and make the Stripe promise hang forever.
    cardSaving = false;
    showAddPaymentMethodModal = false;
    showCanceledSubscriptionsModal = false;
    pendingCreateSubscription = false;
    createStage = 'form';
    createSuccessMessage;

    amount = 10;
    installmentPeriod = 'Monthly';
    startDate;
    selectedGauId;
    selectedGauName;
    selectedPmForSub;
    pendingCancel;
    pendingPaymentMethodDelete;
    selectedCloseReason;
    closeReasonOptions = [];
    pendingAction;
    pendingActionSubscriptionId;
    pendingDefaultPaymentMethodId;
    actionStage = 'summary';
    successMessage;

    recurringAmount;
    recurringDonationName;
    recurringInstallmentPeriod;
    recurringInstallmentFrequency;
    recurringDayOfMonth;
    recurringNextPaymentDate;
    recurringLastPaymentDate;
    recurringStatus;
    recurringClosedReason;
    recurringEndDate;
    recurringStripeSubscriptionId;
    recurringPreviousStripeSubscriptionId;
    recurringPendingStripeScheduleId;
    recurringStripePaymentMethodId;
    recurringType = 'Open';
    recurringInstallments;
    recurringPaidAmount;
    recurringPaidInstallments;
    recurringStartDate;

    editingAmount = false;
    editingFrequency = false;
    editingGiftDay = false;
    editingPause = false;
    editFrequencyUnit = 'month';
    editFrequencyCount = '1';

    actionAmount;
    actionInstallmentPeriod = 'Monthly';
    actionInstallmentFrequency = 1;
    actionDayOfMonth;
    actionPaymentMethodId;
    actionInstallments;
    pauseMode = 'gifts';
    pauseGiftCount = '1';
    pauseResumeDate;
    addPaymentMethodTarget = 'customer';
    createRecurringType = 'Open';
    createInstallments;

    inlineUpdates = {};
    editingPaymentMethod = false;
    addingNewCard = false;
    editingCancel = false;
    stripe;
    elements;
    cardElement;
    paymentElement;
    addressElement;
    stripeScriptLoaded = false;
    setupIntentClientSecret;
    cardElementInitPromise;
    cardElementInitFailed = false;
    billingName;
    billingEmail;
    billingPhone;
    billingStreet;
    billingCity;
    billingState;
    billingPostalCode;
    billingCountry;
    contactObjectInfo;
    mailingCountryOptions = [];
    mailingStateOptions = [];
    mailingStateControllerValues = {};

    @wire(getObjectInfo, { objectApiName: CONTACT_OBJECT })
    wiredContactObjectInfo({ data }) {
        if (!data) return;
        this.contactObjectInfo = data;
    }

    @wire(getPicklistValues, {
        recordTypeId: '$contactDefaultRecordTypeId',
        fieldApiName: CONTACT_MAILING_COUNTRY_CODE
    })
    wiredMailingCountryValues({ data }) {
        if (!data) return;
        this.mailingCountryOptions = (data.values || []).map((item) => ({
            label: item.label,
            value: item.value
        }));
        this.prefillBillingDetails();
    }

    @wire(getPicklistValues, {
        recordTypeId: '$contactDefaultRecordTypeId',
        fieldApiName: CONTACT_MAILING_STATE_CODE
    })
    wiredMailingStateValues({ data }) {
        if (!data) return;
        this.mailingStateControllerValues = data.controllerValues || {};
        this.mailingStateOptions = data.values || [];
        this.prefillBillingDetails();
    }

    connectedCallback() {}

    get contactDefaultRecordTypeId() {
        return this.contactObjectInfo?.defaultRecordTypeId;
    }

    get customerDisplay() {
        return this.customerId || 'Will be created automatically';
    }

    get shouldShowInitialLoader() {
        return !this.hasLoadedState;
    }

    get shouldShowContactContext() {
        return this.hasLoadedState && !this.isRecurringDonationContext;
    }

    get shouldShowRecurringDonationContext() {
        return this.hasLoadedState && this.isRecurringDonationContext;
    }

    get customerNameDisplay() {
        return this.customerName || 'No Stripe customer yet';
    }

    get recurringDonationDisplay() {
        return this.recurringDonationName || this.recurringDonationId || this.recordId || 'Recurring Donation';
    }

    get hasPaymentMethods() {
        return this.paymentMethods.length > 0;
    }

    get hasSubscriptions() {
        return this.subscriptions.length > 0;
    }

    get hasCanceledSubscriptions() {
        return this.canceledSubscriptions.length > 0;
    }

    get canceledToggleLabel() {
        return 'Show Canceled';
    }

    get selectedPaymentMethodLabel() {
        const pm = this.paymentMethods.find((item) => item.id === this.selectedPmForSub);
        return pm ? `${pm.brandLabel} **** ${pm.last4}` : 'Select a saved payment method';
    }

    get createConfirmAmountLabel() {
        return Number(this.amount || 0).toFixed(2);
    }

    get createConfirmCadenceLabel() {
        return this.installmentPeriod || 'Monthly';
    }

    get createConfirmStartDateLabel() {
        return this.startDate || 'Immediately';
    }

    get isFutureCreateStartDate() {
        return !!this.startDate;
    }

    get createConfirmGauLabel() {
        return this.selectedGauName || this.selectedGauId || 'No GAU selected';
    }

    get createConfirmGiftTypeLabel() {
        return this.createRecurringType === 'Fixed'
            ? `Fixed - ${this.createInstallments || 'No count set'} gifts`
            : 'Open-ended';
    }

    get disableCreateSubscription() {
        return this.isBusy
            || !this.selectedPmForSub
            || !this.amount
            || !this.selectedGauId
            || (this.isCreateFixedType && !this.hasValidCreateInstallments);
    }
    get actionContactId() {
        if (this.customerContactId) return this.customerContactId;
        // In recurring-donation context the recordId is the RD, not a Contact, so
        // never fall back to it; the server resolves the Stripe customer from the
        // subscription when no Contact is linked.
        if (this.isRecurringDonationContext) return null;
        return this.recordId;
    }

    get showCancelConfirm() {
        return !!this.pendingCancel;
    }

    get showDeletePaymentMethodConfirm() {
        return !!this.pendingPaymentMethodDelete;
    }

    get showCreateConfirm() {
        return this.pendingCreateSubscription === true;
    }

    get createStepOneClass() {
        return this.createStepClass('form');
    }

    get createStepTwoClass() {
        return this.createStepClass('confirm');
    }

    get createStepThreeClass() {
        return this.createStepClass('processing');
    }

    get createStepFourClass() {
        return this.createStepClass('success');
    }

    get showCreateFormStep() {
        return this.createStage === 'form' && !this.isBusy;
    }

    get showCreateConfirmStep() {
        return this.createStage === 'confirm' && !this.isBusy;
    }

    get showCreateProcessingStep() {
        return this.createStage === 'processing';
    }

    get showCreateSuccessStep() {
        return this.createStage === 'success' && !this.isBusy;
    }

    get showOverlayBusySpinner() {
        return (this.isBusy || this.cardSaving) && !this.showCreateProcessingStep && !this.showProcessingStep;
    }

    get isSavingCard() {
        return this.isBusy || this.cardSaving;
    }

    get currentRecurringSubscription() {
        return this.subscriptions[0] || this.canceledSubscriptions[0] || null;
    }

    get managedSubscription() {
        if (this.isRecurringDonationContext) {
            return this.currentRecurringSubscription;
        }
        return this.subscriptions.find((sub) => sub.id === this.pendingActionSubscriptionId) || null;
    }

    // Legacy pending-schedule state retained for non-recurring-donation flows.
    // This represents older or alternate Stripe flows where Salesforce stores
    // a future replacement schedule before a live subscription exists.
    // The recurring-donation wizard should not depend on this state anymore.
    get hasPendingReplacementSchedule() {
        return !!this.recurringPendingStripeScheduleId;
    }

    get canUseLiveSubscriptionActions() {
        return !!this.managedSubscription?.id && !this.hasPendingReplacementSchedule;
    }

    // Legacy pending-schedule action branch.
    // Keep this available only for non-recurring-donation contexts that still
    // edit pending Stripe schedules. The recurring-donation wizard should use
    // the direct sync action path instead of this fallback.
    get canUsePendingScheduleActions() {
        return this.hasPendingReplacementSchedule && !!this.recurringDonationId;
    }

    get recurringHeaderName() {
        return this.contactName || this.customerName || this.recurringDonationName || 'Recurring donation';
    }

    get recurringHeaderCadence() {
        const sub = this.currentRecurringSubscription;
        let normalized;
        let count;
        if (sub && sub.interval) {
            normalized = String(sub.interval).toLowerCase();
            count = Number(sub.intervalCount || 1);
        } else {
            const period = (this.recurringInstallmentPeriod || 'Monthly').toLowerCase();
            count = Number(this.recurringInstallmentFrequency || 1);
            normalized = period === 'weekly' ? 'week'
                : period === 'yearly' ? 'year'
                : period === 'quarterly' ? 'quarter'
                : 'month';
        }
        if (normalized === 'weekly') normalized = 'week';
        if (normalized === 'monthly') normalized = 'month';
        if (normalized === 'yearly') normalized = 'year';
        if (!Number.isFinite(count) || count <= 1) return normalized;
        return `${count} ${normalized}s`;
    }

    get recurringHeaderSummary() {
        return `${this.recurringSummaryAmountLabel} / ${this.recurringHeaderCadence}`;
    }

    get isSyncedWithStripe() {
        return !!this.recurringStripeSubscriptionId || !!this.currentRecurringSubscription?.id;
    }

    get recurringTotalGivenLabel() {
        if (this.recurringPaidAmount === null || this.recurringPaidAmount === undefined) return '$0.00';
        return this.formatUsd(this.recurringPaidAmount);
    }

    get recurringGiftsToDateLabel() {
        return this.recurringPaidInstallments ? String(this.recurringPaidInstallments) : '0';
    }

    get recurringStartedLabel() {
        const parsed = this.parseDateOnly(this.recurringStartDate);
        if (!parsed) return 'Not started';
        return parsed.toLocaleDateString(undefined, { month: 'short', year: 'numeric' });
    }

    get recurringNextChargeDate() {
        const periodEnd = Number(this.currentRecurringSubscription?.currentPeriodEnd);
        if (Number.isFinite(periodEnd) && periodEnd > 0) {
            return new Date(periodEnd * 1000);
        }
        return this.parseDateOnly(this.recurringNextPaymentDate);
    }

    get recurringNextChargeAmountCompact() {
        const sub = this.currentRecurringSubscription;
        const amount = sub ? sub.amount : this.recurringAmount;
        if (amount === null || amount === undefined) return '';
        const n = Number(amount);
        return `$${n.toFixed(2)}`;
    }

    get recurringNextChargeLabel() {
        const amount = this.recurringNextChargeAmountCompact;
        const date = this.recurringNextChargeDate;
        const shortDate = date ? date.toLocaleDateString(undefined, { month: 'short', day: 'numeric' }) : null;
        if (!amount && !shortDate) return 'No upcoming charge';
        if (!shortDate) return amount;
        if (!amount) return shortDate;
        return `${amount} \u00B7 ${shortDate}`;
    }

    get recurringSummaryAmountLabel() {
        if (this.hasPendingReplacementSchedule) {
            if (this.recurringAmount === null || this.recurringAmount === undefined) return 'Amount unavailable';
            return this.formatAmount(this.recurringAmount, 'usd');
        }
        if (this.currentRecurringSubscription) {
            return this.formatAmount(
                this.currentRecurringSubscription.amount,
                this.currentRecurringSubscription.currencyCode
            );
        }
        if (this.recurringAmount === null || this.recurringAmount === undefined) return 'Amount unavailable';
        return this.formatAmount(this.recurringAmount, 'usd');
    }

    get recurringSummaryFrequencyLabel() {
        if (this.hasPendingReplacementSchedule) {
            const period = this.recurringInstallmentPeriod || 'Monthly';
            const count = Number(this.recurringInstallmentFrequency || 1);
            if (count <= 1) return period;
            return `Every ${count} ${period.toLowerCase() === 'yearly' ? 'years' : period.toLowerCase() === 'weekly' ? 'weeks' : 'months'}`;
        }
        if (this.currentRecurringSubscription) {
            return this.currentRecurringSubscription.cadenceLabel || 'Frequency unavailable';
        }
        const period = this.recurringInstallmentPeriod || 'Monthly';
        const count = Number(this.recurringInstallmentFrequency || 1);
        if (count <= 1) return period;
        return `Every ${count} ${period.toLowerCase() === 'yearly' ? 'years' : period.toLowerCase() === 'weekly' ? 'weeks' : 'months'}`;
    }

    get recurringSummaryNextGiftDateLabel() {
        // Prefer the live Stripe subscription's next billing date. The recurring
        // donation field (npe03__Next_Payment_Date__c) is recomputed asynchronously
        // by NPSP after an action, so it can lag right after resume/amount/etc.;
        // the Stripe value is updated synchronously and refreshes immediately.
        const stripeLabel = this.realDateLabel(this.currentRecurringSubscription?.currentPeriodEndLabel);
        if (stripeLabel) return stripeLabel;
        const parsed = this.parseDateOnly(this.recurringNextPaymentDate);
        if (parsed) return this.formatLongDate(parsed);
        return this.recurringNextPaymentDate || 'No next installment date';
    }

    get recurringPausedUntilLabel() {
        return this.realDateLabel(this.currentRecurringSubscription?.pauseResumesAtLabel)
            || this.recurringNextPaymentDate
            || 'No resume date';
    }

    get recurringSummaryEndDateLabel() {
        if (this.hasPendingReplacementSchedule) {
            return this.recurringEndDate || 'Not scheduled';
        }
        if (this.currentRecurringSubscription) {
            if (this.currentRecurringSubscription.endedAtLabel && this.currentRecurringSubscription.endedAtLabel !== 'N/A') {
                return this.currentRecurringSubscription.endedAtLabel;
            }
            if (this.currentRecurringSubscription.cancelAtLabel && this.currentRecurringSubscription.cancelAtLabel !== 'N/A') {
                return this.currentRecurringSubscription.cancelAtLabel;
            }
            if (this.currentRecurringSubscription.cancelAtPeriodEnd === true) {
                return this.currentRecurringSubscription.currentPeriodEndLabel || 'Scheduled at period end';
            }
            return 'Not scheduled';
        }
        return this.recurringEndDate || 'Not scheduled';
    }

    get recurringStatusBadgeLabel() {
        if (this.isRecurringPaused) return 'Paused';
        if (this.isRecurringClosed) return 'Closed';
        return 'Active';
    }

    get recurringStatusBadgeClass() {
        if (this.isRecurringPaused) {
            return this.statusClass('paused', true);
        }
        if (this.isRecurringClosed) {
            return this.statusClass('closed', false);
        }
        return this.statusClass('active', false);
    }

    get isRecurringActive() {
        if (this.hasPendingReplacementSchedule) return false;
        if (this.currentRecurringSubscription) {
            const normalized = (this.currentRecurringSubscription.status || '').toLowerCase();
            return (normalized === 'active' || normalized === 'trialing')
                && this.currentRecurringSubscription.collectionPaused !== true;
        }
        const normalized = (this.recurringStatus || '').toLowerCase();
        return normalized === 'active' || normalized === 'trialing';
    }

    get isRecurringTrialing() {
        if (this.hasPendingReplacementSchedule) return false;
        if (this.currentRecurringSubscription) {
            const normalized = (this.currentRecurringSubscription.status || '').toLowerCase();
            return normalized === 'trialing' && this.currentRecurringSubscription.collectionPaused !== true;
        }
        return (this.recurringStatus || '').toLowerCase() === 'trialing';
    }

    get isRecurringStrictlyActive() {
        if (this.hasPendingReplacementSchedule) return false;
        if (this.currentRecurringSubscription) {
            const normalized = (this.currentRecurringSubscription.status || '').toLowerCase();
            return normalized === 'active' && this.currentRecurringSubscription.collectionPaused !== true;
        }
        return (this.recurringStatus || '').toLowerCase() === 'active';
    }

    get canChangeRecurringBillingDate() {
        if (this.currentRecurringSubscription) {
            const normalized = (this.currentRecurringSubscription.status || '').toLowerCase();
            return normalized === 'active' && this.currentRecurringSubscription.collectionPaused !== true;
        }
        const normalized = (this.recurringStatus || '').toLowerCase();
        return normalized === 'active';
    }

    get isRecurringPaused() {
        if (this.hasPendingReplacementSchedule) return false;
        if (this.currentRecurringSubscription) {
            return this.currentRecurringSubscription.collectionPaused === true;
        }
        return (this.recurringStatus || '').toLowerCase() === 'paused';
    }

    get isRecurringClosed() {
        if (this.currentRecurringSubscription) {
            return this.isCanceledStatus(this.currentRecurringSubscription.status);
        }
        return (this.recurringStatus || '').toLowerCase() === 'closed';
    }

    get showActionPanel() {
        return !!this.pendingAction;
    }

    get showScheduleSummary() {
        return !this.pendingAction && !this.isBusy;
    }

    get showUpdateStep() {
        return !!this.pendingAction && this.actionStage === 'update' && !this.isBusy;
    }

    get showConfirmStep() {
        return !!this.pendingAction && this.actionStage === 'confirm' && !this.isBusy;
    }

    get showProcessingStep() {
        return !!this.pendingAction && this.actionStage === 'processing';
    }

    get wizardStepOneClass() {
        return this.stepClass('summary');
    }

    get wizardStepTwoClass() {
        return this.stepClass('update');
    }

    get wizardStepThreeClass() {
        return this.stepClass('confirm');
    }

    get wizardStepFourClass() {
        return this.stepClass('processing');
    }

    get isAmountAction() {
        return this.pendingAction === 'amount';
    }

    get isFrequencyAction() {
        return this.pendingAction === 'frequency';
    }

    get isGiftDateAction() {
        return this.pendingAction === 'giftDate';
    }

    get isPauseAction() {
        return this.pendingAction === 'pause';
    }

    get isResumeAction() {
        return this.pendingAction === 'resume';
    }

    get isCancelAction() {
        return this.pendingAction === 'cancel';
    }

    get isPaymentMethodAction() {
        return this.pendingAction === 'paymentMethod';
    }

    get isGiftCountAction() {
        return this.pendingAction === 'giftCount';
    }

    get isEndTrialNowAction() {
        return this.pendingAction === 'endTrialNow';
    }

    get recurringSummaryTypeLabel() {
        if (this.isRecurringDonationContext && this.recurringType) {
            return this.recurringType === 'Fixed'
                ? 'Fixed number of gifts'
                : 'Open-ended';
        }
        if (this.currentRecurringSubscription) {
            return this.currentRecurringSubscription.recurringType === 'Fixed'
                ? 'Fixed number of gifts'
                : 'Open-ended';
        }
        return this.recurringType === 'Fixed' ? 'Fixed number of gifts' : 'Open-ended';
    }

    get recurringSummaryInstallmentsLabel() {
        if (this.isRecurringDonationContext && this.recurringType === 'Fixed') {
            return this.recurringInstallments ? `${this.recurringInstallments}` : 'Not set';
        }
        if (this.isRecurringDonationContext && this.recurringType !== 'Fixed') {
            return 'Not limited';
        }
        if (this.currentRecurringSubscription) {
            if (this.currentRecurringSubscription.recurringType !== 'Fixed') return 'Not limited';
            return this.currentRecurringSubscription.installments ? `${this.currentRecurringSubscription.installments}` : 'Not set';
        }
        if (this.recurringType !== 'Fixed') return 'Not limited';
        return this.recurringInstallments ? `${this.recurringInstallments}` : 'Not set';
    }

    get isCreateFixedType() {
        return this.createRecurringType === 'Fixed';
    }

    get hasValidCreateInstallments() {
        return Number(this.createInstallments) > 0;
    }

    get disableGiftCountSave() {
        return this.isBusy
            || (!this.managedSubscription?.id && !this.canUsePendingScheduleActions)
            || !this.actionInstallments
            || Number(this.actionInstallments) <= 0;
    }

    get fixedGiftActionLabel() {
        if (this.hasPendingReplacementSchedule) {
            return this.recurringType === 'Fixed' ? 'Change Gift Count' : 'Set Fixed Gifts';
        }
        return this.managedSubscription?.recurringType === 'Fixed' || this.currentRecurringSubscription?.recurringType === 'Fixed'
            ? 'Change Gift Count'
            : 'Set Fixed Gifts';
    }

    get recurringSummaryPaymentMethodLabel() {
        if (this.currentRecurringSubscription) {
            return this.currentRecurringSubscription.defaultPaymentMethodDisplay || 'Customer default';
        }
        if (this.recurringStripePaymentMethodId) {
            return this.paymentMethodDisplay(this.recurringStripePaymentMethodId);
        }
        return 'Customer default';
    }

    get activeScheduleActionsVisible() {
        return !this.hasPendingReplacementSchedule && this.isRecurringActive && !this.isRecurringPaused && !this.isRecurringClosed;
    }

    get pendingScheduleActionsVisible() {
        return this.hasPendingReplacementSchedule && !this.isRecurringPaused && !this.isRecurringClosed;
    }

    get pausedScheduleActionsVisible() {
        return this.isRecurringPaused;
    }

    get closedScheduleActionsVisible() {
        return this.isRecurringClosed;
    }

    get showManageStatusActions() {
        return this.activeScheduleActionsVisible || this.pendingScheduleActionsVisible || this.pausedScheduleActionsVisible;
    }

    // Inline edit availability for the gift detail rows. The pencils only appear
    // in states where the schedule can actually be changed (active or pending).
    get giftRowsEditable() {
        return this.activeScheduleActionsVisible || this.pendingScheduleActionsVisible;
    }

    // Day-of-month editing only makes sense for month-based cadences, and the
    // next installment date can only be changed on active subscriptions.
    get canEditGiftDay() {
        if (!this.canChangeRecurringBillingDate) {
            return false;
        }
        const sub = this.currentRecurringSubscription;
        if (sub && sub.interval) {
            return String(sub.interval).toLowerCase() === 'month';
        }
        const period = (this.recurringInstallmentPeriod || '').toLowerCase();
        return period === 'monthly' || period === 'quarterly';
    }

    // Day-of-month that matches the currently displayed "Next installment date".
    // The summary label prefers the live Stripe period-end date, so seed the
    // picklist from the same source before falling back to the recurring
    // donation's stored values. Days past the 28th aren't offered individually,
    // so map them to "Last day" to keep a valid selection.
    get nextInstallmentDayOfMonth() {
        let day = null;
        const stripeEnd = Number(this.currentRecurringSubscription?.currentPeriodEnd);
        if (Number.isFinite(stripeEnd) && stripeEnd > 0) {
            day = new Date(stripeEnd * 1000).getDate();
        }
        if (!day) {
            const derived = this.deriveDayOfMonthFromNextGiftDate();
            if (derived) day = Number(derived);
        }
        if (!day && this.recurringDayOfMonth) {
            const stored = Number(this.recurringDayOfMonth);
            day = Number.isFinite(stored) ? stored : null;
        }
        if (!day || !Number.isFinite(day) || day <= 0) {
            return this.recurringDayOfMonth || null;
        }
        return day > 28 ? 'Last_Day' : String(day);
    }

    get editFrequencyUnitOptions() {
        return [
            { label: 'weeks', value: 'week' },
            { label: 'months', value: 'month' },
            { label: 'years', value: 'year' }
        ];
    }

    get editFrequencyCountOptions() {
        return Array.from({ length: 12 }, (_, index) => {
            const count = index + 1;
            return { label: String(count), value: String(count) };
        });
    }

    startEditAmount() {
        this.cancelInlineEdit();
        this.successMessage = null;
        this.actionAmount = this.managedSubscription?.amount ?? this.recurringAmount;
        this.editingAmount = true;
    }

    startEditFrequency() {
        this.cancelInlineEdit();
        this.successMessage = null;
        this.seedFrequencyEditFromState();
        this.editingFrequency = true;
    }

    startEditGiftDay() {
        this.cancelInlineEdit();
        this.successMessage = null;
        this.actionDayOfMonth = this.nextInstallmentDayOfMonth;
        this.editingGiftDay = true;
    }

    cancelInlineEdit() {
        this.editingAmount = false;
        this.editingFrequency = false;
        this.editingGiftDay = false;
        this.editingPause = false;
        if (this.editingPaymentMethod || this.addingNewCard) {
            this.teardownStripeElements();
        }
        this.editingPaymentMethod = false;
        this.addingNewCard = false;
        this.editingCancel = false;
    }

    get showManageButtons() {
        return !this.editingPause && !this.editingCancel;
    }

    startEditCancel() {
        this.cancelInlineEdit();
        this.successMessage = null;
        this.selectedCloseReason = null;
        this.ensureClosedReasonOptionsLoaded();
        this.editingCancel = true;
    }

    get cancelEditorTitle() {
        return this.pendingScheduleActionsVisible ? 'Cancel replacement' : 'Cancel donation';
    }

    async saveCancelInline() {
        if (this.disableCancelConfirm) return;
        await this.confirmRecurringCancel();
        this.editingCancel = false;
    }

    startEditPause() {
        this.cancelInlineEdit();
        this.successMessage = null;
        this.pauseMode = 'gifts';
        this.pauseGiftCount = '1';
        this.pauseResumeDate = this.defaultFuturePauseResumeDate();
        this.editingPause = true;
    }

    async savePauseInline() {
        if (this.disablePauseConfirm) return;
        await this.confirmRecurringPause();
        this.editingPause = false;
    }

    get hasSavedPaymentMethods() {
        return Array.isArray(this.paymentMethods) && this.paymentMethods.length > 0;
    }

    startEditPaymentMethod() {
        this.cancelInlineEdit();
        this.successMessage = null;
        this.addPaymentMethodTarget = 'subscription';
        this.actionPaymentMethodId = this.managedSubscription?.defaultPaymentMethod || null;
        // Jump straight to adding a card when there is nothing saved to pick from.
        this.addingNewCard = !this.hasSavedPaymentMethods;
        this.editingPaymentMethod = true;
        if (this.addingNewCard) {
            this.prefillBillingDetails(true);
        }
    }

    startAddNewCard() {
        this.cardElementInitFailed = false;
        this.prefillBillingDetails(true);
        this.addingNewCard = true;
    }

    cancelAddNewCard() {
        this.teardownStripeElements();
        this.addingNewCard = false;
    }

    get paymentMethodSaveLabel() {
        return this.addingNewCard ? 'Save card' : 'Save';
    }

    get disablePaymentMethodInlineSave() {
        if (this.isBusy || this.cardSaving) return true;
        if (this.addingNewCard) return false;
        return !this.actionPaymentMethodId;
    }

    async savePaymentMethodInline() {
        if (this.addingNewCard) {
            await this.handleSaveCard();
            return;
        }
        if (!this.actionPaymentMethodId) return;
        await this.saveRecurringPaymentMethodChange();
        this.editingPaymentMethod = false;
    }

    // Translate the stored NPSP period + frequency into the friendly
    // "Every N <unit>" model. Quarterly is expressed as every 3 months.
    seedFrequencyEditFromState() {
        const sub = this.currentRecurringSubscription;
        let normalized;
        let count;
        if (sub && sub.interval) {
            normalized = String(sub.interval).toLowerCase();
            count = Number(sub.intervalCount || 1);
        } else {
            const period = (this.recurringInstallmentPeriod || 'Monthly').toLowerCase();
            count = Number(this.recurringInstallmentFrequency || 1);
            if (period === 'weekly') {
                normalized = 'week';
            } else if (period === 'yearly') {
                normalized = 'year';
            } else if (period === 'quarterly') {
                normalized = 'month';
                count = 3 * count;
            } else {
                normalized = 'month';
            }
        }
        if (normalized === 'weekly') normalized = 'week';
        if (normalized === 'monthly') normalized = 'month';
        if (normalized === 'yearly') normalized = 'year';
        if (!['week', 'month', 'year'].includes(normalized)) normalized = 'month';
        if (!Number.isFinite(count) || count < 1) count = 1;
        if (count > 12) count = 12;
        this.editFrequencyUnit = normalized;
        this.editFrequencyCount = String(count);
        this.applyFrequencyEditToAction();
    }

    // Keep the shared action fields in sync with the inline selections so the
    // existing frequency getters (warning text, projected next charge) update live.
    applyFrequencyEditToAction() {
        this.actionInstallmentPeriod = this.editFrequencyUnit === 'week'
            ? 'Weekly'
            : this.editFrequencyUnit === 'year'
                ? 'Yearly'
                : 'Monthly';
        this.actionInstallmentFrequency = Number(this.editFrequencyCount || 1);
    }

    onEditFrequencyUnit(e) {
        this.editFrequencyUnit = e.detail.value;
        this.applyFrequencyEditToAction();
    }
    onEditFrequencyCount(e) {
        this.editFrequencyCount = e.detail.value;
        this.applyFrequencyEditToAction();
    }

    get inlineFrequencyWarning() {
        return this.frequencyConfirmMessage;
    }

    get inlineGiftDayNote() {
        return this.giftDateConfirmMessage;
    }

    // Sanity-check preview shown while editing the amount so a money change is never blind.
    get inlineAmountPreview() {
        const amount = Number(this.actionAmount);
        if (!Number.isFinite(amount) || amount <= 0) return '';
        return `Next charge: ${this.formatUsd(amount)} on ${this.recurringSummaryNextGiftDateLabel}. No charge today.`;
    }

    // Static help text shown while editing each row so donors/staff understand
    // exactly what a change affects before saving.
    get amountEditHelp() {
        return 'Sets the amount charged for each future installment. Nothing is charged today; the new amount applies starting with the next installment.';
    }

    get frequencyEditHelp() {
        return 'Sets how often this donation is charged (for example, every month or every 3 months). Future installments are rescheduled to match the new cadence.';
    }

    get giftDayEditHelp() {
        return 'Sets the day of the month this donation is charged. The next installment date moves to the day you choose. Pick "Last day" to always bill on the final day of the month.';
    }

    get amountRowAriaLabel() {
        return `Amount, ${this.recurringSummaryAmountLabel}. Click to edit.`;
    }

    get frequencyRowAriaLabel() {
        return `Frequency, ${this.recurringSummaryFrequencyLabel}. Click to edit.`;
    }

    get giftDayRowAriaLabel() {
        return `Next installment date, ${this.recurringSummaryNextGiftDateLabel}. Click to edit the charge day.`;
    }

    get totalGivenTooltip() {
        return `Total amount paid so far across ${this.recurringGiftsToDateLabel} installment(s) on this schedule. Individual installment amounts may differ if the donation amount changed over time.`;
    }

    async saveAmountInline() {
        await this.saveRecurringAmountChange();
        this.editingAmount = false;
    }

    async saveFrequencyInline() {
        this.applyFrequencyEditToAction();
        await this.saveRecurringFrequencyChange();
        this.editingFrequency = false;
    }

    async saveGiftDayInline() {
        await this.saveRecurringGiftDateChange();
        this.editingGiftDay = false;
    }

    get hasNewDonationUrl() {
        return !!this.newDonationUrl;
    }

    get actionTitle() {
        if (this.isAmountAction) return 'Change amount';
        if (this.isFrequencyAction) return 'Change frequency';
        if (this.isGiftDateAction) return 'Change gift date';
        if (this.isPauseAction) return 'Pause Recurring Donation';
        if (this.isResumeAction) return 'Resume donation';
        if (this.isCancelAction) return 'Cancel donation';
        if (this.isPaymentMethodAction) return 'Change payment method';
        if (this.isGiftCountAction) return this.fixedGiftActionLabel;
        if (this.isEndTrialNowAction) return 'Cancel trial and charge now';
        return 'Update donation';
    }

    get actionConfirmTitle() {
        return this.isCancelAction ? 'Confirm cancellation' : this.actionTitle;
    }

    get confirmSecondaryLabel() {
        return this.isCancelAction ? 'Keep donation' : 'Back';
    }

    get confirmPrimaryLabel() {
        if (this.isCancelAction) return 'Cancel donation';
        if (this.isResumeAction) return 'Resume donation';
        if (this.isPauseAction) return 'Pause Recurring Donation';
        return 'Confirm change';
    }

    get confirmPrimaryVariant() {
        return this.isCancelAction ? 'destructive' : 'brand';
    }

    get currentAmountSentence() {
        return `Current amount: ${this.recurringSummaryAmountLabel}`;
    }

    get amountConfirmMessage() {
        return `New amount ${this.formatUsd(this.actionAmount)}, starting ${this.recurringSummaryNextGiftDateLabel}. No charge today.`;
    }

    get frequencyConfirmMessage() {
        if (this.canUsePendingScheduleActions) {
            return `Updates the scheduled donation to be billed ${this.actionFrequencyLabel} from ${this.recurringSummaryNextGiftDateLabel}. No charge today.`;
        }
        return `This charges ${this.recurringSummaryAmountLabel} today and bills ${this.actionFrequencyLabel} after that (next charge ${this.projectedFrequencyNextChargeLabel}).`;
    }

    get actionFrequencyLabel() {
        const period = this.actionInstallmentPeriod || 'Monthly';
        const everyN = Number(this.actionInstallmentFrequency || 1);
        const normalized = period.toLowerCase();
        if (!Number.isFinite(everyN) || everyN <= 1) {
            return normalized;
        }
        const unit = normalized === 'yearly' ? 'years'
            : normalized === 'weekly' ? 'weeks'
            : normalized === 'quarterly' ? 'quarters'
            : 'months';
        return `every ${everyN} ${unit}`;
    }

    // Projected next charge after a frequency change. Stripe resets the cycle to now
    // and charges today, so the next charge is today + the new interval.
    get projectedFrequencyNextChargeLabel() {
        const period = (this.actionInstallmentPeriod || 'Monthly').toLowerCase();
        const everyN = Number(this.actionInstallmentFrequency || 1) || 1;
        return this.addFrequencyPeriod(this.todayDateOnly(), period, everyN).toLocaleDateString();
    }

    addFrequencyPeriod(dateValue, period, everyN) {
        const next = new Date(dateValue.getTime());
        if (period === 'weekly') {
            next.setDate(next.getDate() + (7 * everyN));
        } else if (period === 'yearly') {
            next.setFullYear(next.getFullYear() + everyN);
        } else if (period === 'quarterly') {
            next.setMonth(next.getMonth() + (3 * everyN));
        } else {
            next.setMonth(next.getMonth() + everyN);
        }
        return next;
    }

    get giftDateSelectionLabel() {
        if (!this.actionDayOfMonth) return 'the selected day';
        if (this.actionDayOfMonth === 'Last_Day') return 'the last day';
        const day = Number(this.actionDayOfMonth);
        if (!Number.isFinite(day) || day <= 0) return 'the selected day';
        return `the ${this.ordinalDay(day)}`;
    }

    get giftDateConfirmMessage() {
        if (this.canUsePendingScheduleActions) {
            return `Updates the scheduled start date to ${this.projectedGiftDateChangeLabel}. No charge today.`;
        }
        return `This creates a replacement Stripe subscription that will start on ${this.projectedGiftDateChangeLabel}. No charge today.`;
    }

    get pauseConfirmMessage() {
        return `Pause until ${this.pauseResumeDateLabel}?`;
    }

    get resumeConfirmMessage() {
        const nextGift = this.resumeNextGiftDateLabel;
        if (nextGift) {
            return `Resume this donation now? The next installment is scheduled for ${nextGift}.`;
        }
        return `Resume this donation now? Collection restarts today (${this.todayLabel}).`;
    }

    // Projected next gift date if the donor resumes today: Stripe collects on the
    // subscription's next billing-cycle boundary (current_period_end). Returns null
    // when that boundary is missing or already passed, so the copy can fall back.
    get resumeNextGiftDateLabel() {
        const periodEnd = Number(this.currentRecurringSubscription?.currentPeriodEnd);
        if (!Number.isFinite(periodEnd) || periodEnd <= 0) return null;
        const nowSeconds = Math.floor(new Date().getTime() / 1000);
        if (periodEnd <= nowSeconds) return null;
        return new Date(periodEnd * 1000).toLocaleDateString();
    }

    get todayLabel() {
        return this.todayDateOnly().toLocaleDateString();
    }

    get cancelConfirmMessage() {
        return `Cancel this recurring donation? No future charges - the last installment on ${this.recurringLastPaymentDateLabel} stands.`;
    }

    get paymentMethodConfirmMessage() {
        return `Use ${this.paymentMethodDisplay(this.actionPaymentMethodId)} for this recurring donation.`;
    }

    get giftCountConfirmMessage() {
        return `Collect ${this.actionInstallments || 0} total gifts before ending automatically.`;
    }

    get actionConfirmMessage() {
        if (this.isAmountAction) return this.amountConfirmMessage;
        if (this.isFrequencyAction) return this.frequencyConfirmMessage;
        if (this.isGiftDateAction) return this.giftDateConfirmMessage;
        if (this.isPauseAction) return this.pauseConfirmMessage;
        if (this.isResumeAction) return this.resumeConfirmMessage;
        if (this.isCancelAction) return this.cancelConfirmMessage;
        if (this.isPaymentMethodAction) return this.paymentMethodConfirmMessage;
        if (this.isGiftCountAction) return this.giftCountConfirmMessage;
        if (this.isEndTrialNowAction) return 'End the trial and charge now?';
        return 'Confirm this change?';
    }

    get pauseResumeDateValue() {
        if (this.isPauseUntilDate) return this.pauseResumeDate || null;
        const count = Number(this.pauseGiftCount || 1);
        const base = this.parseDateOnly(this.recurringNextPaymentDate) || new Date();
        const period = (this.recurringInstallmentPeriod || 'Monthly').toLowerCase();
        const frequency = Number(this.recurringInstallmentFrequency || 1);
        const d = new Date(base.getTime());
        if (period === 'weekly') {
            d.setDate(d.getDate() + (7 * frequency * count));
        } else if (period === 'yearly') {
            d.setFullYear(d.getFullYear() + (frequency * count));
        } else {
            d.setMonth(d.getMonth() + (frequency * count));
        }
        return this.toDateInputValue(d);
    }

    get pauseResumeDateLabel() {
        return this.pauseResumeDateValue || this.recurringSummaryNextGiftDateLabel;
    }

    get minimumPauseResumeDate() {
        const tomorrow = this.todayDateOnly();
        tomorrow.setDate(tomorrow.getDate() + 1);
        return this.toDateInputValue(tomorrow);
    }

    get recurringLastPaymentDateLabel() {
        return this.recurringLastPaymentDate || 'the last successful installment date';
    }

    get actionWarningVisible() {
        return this.isFrequencyAction || this.isGiftDateAction;
    }

    get actionSuccessMessage() {
        return this.successMessage || 'The donation has been updated.';
    }

    get recurringTypeOptions() {
        return [
            { label: 'Open-ended', value: 'Open' },
            { label: 'Fixed number of gifts', value: 'Fixed' }
        ];
    }

    get recurringClosedDetail() {
        if (!this.isRecurringClosed) return '';
        const reason = this.recurringClosedReason || 'No reason recorded';
        if (this.currentRecurringSubscription) {
            if (this.currentRecurringSubscription.endedAtLabel && this.currentRecurringSubscription.endedAtLabel !== 'N/A') {
                return `Closed ${this.currentRecurringSubscription.endedAtLabel} \u00B7 ${reason}`;
            }
            if (this.currentRecurringSubscription.canceledAtLabel && this.currentRecurringSubscription.canceledAtLabel !== 'N/A') {
                return `Closed ${this.currentRecurringSubscription.canceledAtLabel} \u00B7 ${reason}`;
            }
        }
        const ended = this.recurringEndDate || 'date unavailable';
        return `Closed ${ended} \u00B7 ${reason}`;
    }

    get recurringReplacementMessage() {
        if (!this.recurringPreviousStripeSubscriptionId) return '';
        return `This is a replacement Stripe subscription created after changing the billing date from ${this.recurringPreviousStripeSubscriptionId}.`;
    }

    get recurringPendingScheduleMessage() {
        if (!this.recurringPendingStripeScheduleId) return '';
        return `A future Stripe subscription schedule has been created and will start on ${this.recurringNextPaymentDate || 'the selected billing date'}. Schedule ID: ${this.recurringPendingStripeScheduleId}.`;
    }

    get projectedGiftDateChangeValue() {
        if (!this.actionDayOfMonth) return null;
        // Project the soonest future occurrence of the chosen gift day, measured
        // from today. The first gift just needs a strictly-future start date
        // (Stripe then continues at the subscription's own interval), and Apex
        // rejects any next gift date that is not after today.
        const today = this.todayDateOnly();

        if (this.actionDayOfMonth === 'Last_Day') {
            const thisMonthEnd = new Date(today.getFullYear(), today.getMonth() + 1, 0);
            if (thisMonthEnd > today) {
                return this.toDateInputValue(thisMonthEnd);
            }
            const nextMonthEnd = new Date(today.getFullYear(), today.getMonth() + 2, 0);
            return this.toDateInputValue(nextMonthEnd);
        }

        const targetDay = Number(this.actionDayOfMonth);
        if (!Number.isFinite(targetDay) || targetDay <= 0) return null;

        const thisMonthLastDay = new Date(today.getFullYear(), today.getMonth() + 1, 0).getDate();
        const thisCandidate = new Date(
            today.getFullYear(),
            today.getMonth(),
            Math.min(targetDay, thisMonthLastDay)
        );
        if (thisCandidate > today) {
            return this.toDateInputValue(thisCandidate);
        }

        const nextMonthLastDay = new Date(today.getFullYear(), today.getMonth() + 2, 0).getDate();
        const nextCandidate = new Date(
            today.getFullYear(),
            today.getMonth() + 1,
            Math.min(targetDay, nextMonthLastDay)
        );
        return this.toDateInputValue(nextCandidate);
    }

    get projectedGiftDateChangeLabel() {
        return this.projectedGiftDateChangeValue || 'the selected billing date';
    }

    get billingDateActionHelpText() {
        return 'Close the current Stripe subscription and create a new future-dated subscription for the selected billing date. The recurring donation stays the same and keeps a reference to the old Stripe subscription id.';
    }

    get frequencyImmediateChargeWarning() {
        return `This charges the card today and bills ${this.actionFrequencyLabel} after that (next charge ${this.projectedFrequencyNextChargeLabel}).`;
    }

    get giftDateImmediateChargeWarning() {
        const amountLabel = this.isRecurringDonationContext
            ? this.recurringSummaryAmountLabel
            : this.formatAmount(this.managedSubscription?.amount, this.managedSubscription?.currencyCode);
        return `This charges the card ${amountLabel} today to move the gift date to ${this.giftDateSelectionLabel}.`;
    }

    get disableAmountSave() {
        return this.isBusy || (!this.managedSubscription?.id && !this.canUsePendingScheduleActions) || !this.actionAmount;
    }

    get disableFrequencySave() {
        return this.isBusy
            || (!this.managedSubscription?.id && !this.canUsePendingScheduleActions)
            || !this.actionInstallmentPeriod
            || !this.actionInstallmentFrequency;
    }

    get disableGiftDateSave() {
        return this.isBusy || (!this.managedSubscription?.id && !this.canUsePendingScheduleActions) || !this.actionDayOfMonth;
    }

    get disablePaymentMethodSave() {
        return this.isBusy
            || (!this.managedSubscription?.id && !this.canUsePendingScheduleActions)
            || !this.actionPaymentMethodId;
    }

    get cancelModalTitle() {
        return this.pendingCancel?.atPeriodEnd ? 'Stop Subscription at Period End' : 'Cancel Subscription Now';
    }

    get cancelModalMessage() {
        return this.pendingCancel?.atPeriodEnd
            ? 'Stripe will keep this subscription active until the current billing period ends.'
            : 'Stripe will cancel this subscription immediately. This action should be used carefully.';
    }

    get cancelConfirmLabel() {
        return this.pendingCancel?.atPeriodEnd ? 'Stop at Period End' : 'Cancel Now';
    }
    get disableCancelConfirm() {
        return this.isBusy;
    }

    get disablePauseConfirm() {
        return this.isBusy
            || (this.isPauseForGifts && !this.pauseGiftCount)
            || (this.isPauseUntilDate && !this.isFutureDate(this.pauseResumeDate));
    }

    get paymentMethodOptions() {
        const opts = [{ label: 'No specific method', value: '' }];
        this.paymentMethods.forEach((pm) => {
            const def = pm.isDefault ? ' [Default]' : '';
            opts.push({ label: `${pm.brandLabel} ****${pm.last4}${def}`, value: pm.id });
        });
        return opts;
    }

    get paymentMethodSelectionOptions() {
        return this.paymentMethods.map((pm) => {
            const def = pm.isDefault ? ' [Default]' : '';
            return { label: `${pm.brandLabel} ****${pm.last4}${def}`, value: pm.id };
        });
    }

    get installmentPeriodOptions() {
        return [
            { label: 'Monthly', value: 'Monthly' },
            { label: 'Quarterly', value: 'Quarterly' },
            { label: 'Yearly', value: 'Yearly' },
            { label: 'Weekly', value: 'Weekly' }
        ];
    }

    get dayOfMonthOptions() {
        const days = Array.from({ length: 28 }, (_, index) => {
            const day = index + 1;
            return { label: String(day), value: String(day) };
        });
        return [...days, { label: 'Last day', value: 'Last_Day' }];
    }

    get pauseModeOptions() {
        return [
            { label: 'Pause for a number of installments', value: 'gifts' },
            { label: 'Resume on a specific date', value: 'date' }
        ];
    }

    get pauseGiftCountOptions() {
        return Array.from({ length: 12 }, (_, index) => {
            const count = index + 1;
            const label = count === 1 ? '1 installment' : `${count} installments`;
            return { label, value: String(count) };
        });
    }

    get billingCountryOptions() {
        return this.withCurrentOption(
            this.mailingCountryOptions,
            this.billingCountry || this.contactMailingCountry
        );
    }

    get billingStateOptions() {
        if (!this.billingCountry) {
            return this.withCurrentOption([], this.billingState || this.contactMailingState);
        }
        const controllerValue = this.mailingStateControllerValues[this.billingCountry];
        if (controllerValue === undefined || controllerValue === null) {
            return this.withCurrentOption([], this.billingState || this.contactMailingState);
        }
        const filtered = (this.mailingStateOptions || [])
            .filter((item) => !item.validFor || item.validFor.includes(controllerValue))
            .map((item) => ({
                label: item.label,
                value: item.value
            }));
        return this.withCurrentOption(filtered, this.billingState || this.contactMailingState);
    }

    withCurrentOption(options, currentValue) {
        const rows = options || [];
        if (!currentValue) return rows;
        const exists = rows.some((item) => item.value === currentValue);
        if (exists) return rows;
        return [{ label: currentValue, value: currentValue }, ...rows];
    }

    get isPauseForGifts() {
        return this.pauseMode === 'gifts';
    }

    get isPauseUntilDate() {
        return this.pauseMode === 'date';
    }

    async ensureClosedReasonOptionsLoaded() {
        if (this.closeReasonOptions.length) return;
        const rows = await listRecurringDonationClosedReasonOptions();
        this.closeReasonOptions = (rows || []).map((row) => ({
            label: row.label,
            value: row.value
        }));
    }

    async refresh() {
        if (!this.recordId) return;
        this.isBusy = true;
        this.errorMessage = null;
        try {
            await this.ensureClosedReasonOptionsLoaded();
            const state = await getStateForRecord({ recordId: this.recordId });
            this.hasLoadedState = true;
            this.customerContactId = state.contactId;
            this.isRecurringDonationContext = state.recurringDonationContext === true;
            this.recurringDonationId = state.recurringDonationId;
            this.recurringDonationName = state.recurringDonationName;
            this.customerId = state.customerId;
            this.customerName = state.customerName;
            this.contactName = state.contactName;
            this.contactEmail = state.contactEmail;
            this.contactPhone = state.contactPhone;
            this.contactMailingStreet = state.contactMailingStreet;
            this.contactMailingCity = state.contactMailingCity;
            this.contactMailingState = state.contactMailingState;
            this.contactMailingPostalCode = state.contactMailingPostalCode;
            this.contactMailingCountry = state.contactMailingCountry;
            this.prefillBillingDetails(true);
            this.recurringAmount = state.recurringAmount;
            this.recurringInstallmentPeriod = state.recurringInstallmentPeriod;
            this.recurringInstallmentFrequency = state.recurringInstallmentFrequency;
            this.recurringDayOfMonth = state.recurringDayOfMonth;
            this.recurringNextPaymentDate = state.recurringNextPaymentDate;
            this.recurringLastPaymentDate = state.recurringLastPaymentDate;
            this.recurringStatus = state.recurringStatus;
            this.recurringClosedReason = state.recurringClosedReason;
            this.recurringEndDate = state.recurringEndDate;
            this.recurringStripeSubscriptionId = state.recurringStripeSubscriptionId;
            this.recurringPreviousStripeSubscriptionId = state.recurringPreviousStripeSubscriptionId;
            this.recurringPendingStripeScheduleId = state.recurringPendingStripeScheduleId;
            this.recurringStripePaymentMethodId = state.recurringStripePaymentMethodId;
            this.recurringType = state.recurringType || 'Open';
            this.recurringInstallments = state.recurringInstallments;
            this.recurringPaidAmount = state.recurringPaidAmount;
            this.recurringPaidInstallments = state.recurringPaidInstallments;
            this.recurringStartDate = state.recurringStartDate;
            this.paymentMethods = (state.paymentMethods || []).map((pm) => ({
                ...pm,
                brandLabel: this.formatBrand(pm.brand),
                tileClass: this.paymentMethodTileClass(pm)
            }));
            const selectedStillExists = this.paymentMethods.some((pm) => pm.id === this.selectedPmForSub);
            if ((!this.selectedPmForSub || !selectedStillExists) && this.paymentMethods.length) {
                const defaultPm = this.paymentMethods.find((pm) => pm.isDefault);
                this.selectedPmForSub = (defaultPm || this.paymentMethods[0]).id;
                this.paymentMethods = this.paymentMethods.map((pm) => ({
                    ...pm,
                    tileClass: this.paymentMethodTileClass(pm)
                }));
            }
            const allSubscriptions = (state.subscriptions || []).map((s) => ({
                ...s,
                cadenceLabel: this.cadenceLabel(s.interval, s.intervalCount),
                currentPeriodStartLabel: this.tsLabel(s.currentPeriodStart),
                currentPeriodEndLabel: this.tsLabel(s.currentPeriodEnd),
                pauseResumesAtLabel: this.tsLabel(s.pauseResumesAt),
                cancelAtLabel: this.tsLabel(s.cancelAt),
                canceledAtLabel: this.tsLabel(s.canceledAt),
                endedAtLabel: this.tsLabel(s.endedAt),
                installmentPeriod: this.installmentPeriodFromInterval(s.interval),
                amountLabel: this.formatAmount(s.amount, s.currencyCode),
                statusLabel: s.collectionPaused ? 'Paused' : s.status,
                statusClass: this.statusClass(s.status, s.collectionPaused),
                defaultPaymentMethodDisplay: this.paymentMethodDisplay(s.defaultPaymentMethod),
                replacementMessage: s.previousStripeSubscriptionId
                    ? `This is a replacement Stripe subscription created after changing the billing date from ${s.previousStripeSubscriptionId}.`
                    : '',
                lifecycleDateLabel: this.lifecycleDateLabel(s),
                pauseActionLabel: s.collectionPaused ? 'Resume' : 'Pause',
                isPaused: s.collectionPaused === true,
                recurringDonationUrl: s.recurringDonationId ? `/${s.recurringDonationId}` : null,
                hasRecurringDonationLink: !!s.recurringDonationId,
                recurringType: s.recurringType || 'Open',
                installments: s.installments
            }));
            this.subscriptions = allSubscriptions.filter((s) => !this.isCanceledStatus(s.status));
            this.canceledSubscriptions = allSubscriptions.filter((s) => this.isCanceledStatus(s.status));
            this.decorateSubscriptionActionState();
            if (this.isRecurringDonationContext) {
                this.actionAmount = this.currentRecurringSubscription?.amount ?? this.recurringAmount;
                this.actionInstallmentPeriod = this.currentRecurringSubscription?.installmentPeriod || this.recurringInstallmentPeriod || 'Monthly';
                this.actionInstallmentFrequency = this.currentRecurringSubscription?.intervalCount || this.recurringInstallmentFrequency || 1;
                this.createRecurringType = this.currentRecurringSubscription?.recurringType || this.recurringType || 'Open';
                this.createInstallments = this.currentRecurringSubscription?.installments ?? this.recurringInstallments;
            }
        } catch (e) {
            this.hasLoadedState = true;
            this.handleError(e);
        } finally {
            this.isBusy = false;
        }
    }

    handleCreateSubscription() {
        this.pendingCreateSubscription = true;
        this.createStage = 'confirm';
    }

    closeCreateConfirm() {
        this.pendingCreateSubscription = false;
        this.createStage = 'form';
    }

    async confirmCreateSubscription() {
        this.createStage = 'processing';
        await this.executeCreateSubscription();
    }

    async executeCreateSubscription() {
        this.isBusy = true;
        try {
            const isFutureStart = !!this.startDate;
            await createSubscription({
                contactId: this.actionContactId,
                amount: Number(this.amount),
                interval: this.installmentPeriod,
                intervalCount: 1,
                currencyCode: 'usd',
                paymentMethodId: this.selectedPmForSub,
                startDate: this.startDate || null,
                gauId: this.selectedGauId,
                recurringDonationId: this.isRecurringDonationContext ? this.recordId : null,
                recurringType: this.createRecurringType,
                installments: this.createRecurringType === 'Fixed' ? Number(this.createInstallments) : null
            });
            this.toast(
                'Success',
                isFutureStart
                    ? 'Future Stripe subscription schedule created. The first charge will happen on the selected start date.'
                    : 'Subscription created.',
                'success'
            );
            await this.refresh();
            this.createSuccessMessage = isFutureStart
                ? 'Future Stripe subscription schedule created. The first charge will happen on the selected start date.'
                : 'Subscription created.';
            this.resetCreateForm();
            this.createStage = 'success';
        } catch (e) {
            this.createStage = 'confirm';
            this.handleError(e);
        } finally {
            this.isBusy = false;
        }
    }

    async handleUpdateSubscription(event) {
        const subId = event.target.dataset.subid;
        const upd = this.inlineUpdates[subId] || {};
        this.isBusy = true;
        try {
            await updateSubscription({
                contactId: this.actionContactId,
                subscriptionId: subId,
                amount: upd.newAmount ? Number(upd.newAmount) : null,
                interval: upd.newInstallmentPeriod || null,
                intervalCount: 1,
                currencyCode: 'usd',
                paymentMethodId: upd.newPm,
                recurringType: null,
                installments: null
            });
            this.toast('Success', 'Subscription updated.', 'success');
            await this.refresh();
        } catch (e) {
            this.handleError(e);
        } finally {
            this.isBusy = false;
        }
    }

    async handleCancelAtPeriodEnd(event) {
        this.pendingCancel = { subscriptionId: event.target.dataset.subid, atPeriodEnd: true };
        this.selectedCloseReason = null;
    }

    async handleCancelNow(event) {
        this.pendingCancel = { subscriptionId: event.target.dataset.subid, atPeriodEnd: false };
        this.selectedCloseReason = null;
    }

    async confirmCancelSubscription() {
        if (!this.pendingCancel) return;
        const { subscriptionId, atPeriodEnd } = this.pendingCancel;
        this.isBusy = true;
        try {
            await cancelSubscription({
                contactId: this.actionContactId,
                subscriptionId,
                atPeriodEnd,
                closeReason: this.selectedCloseReason
            });
            this.toast('Success', atPeriodEnd ? 'Subscription will stop at period end.' : 'Subscription canceled now.', 'success');
            this.pendingCancel = null;
            this.selectedCloseReason = null;
            await this.refresh();
        } catch (e) {
            this.handleError(e);
        } finally {
            this.isBusy = false;
        }
    }

    closeCancelConfirm() {
        this.pendingCancel = null;
        this.selectedCloseReason = null;
    }

    openPaymentMethodDeleteConfirm(e) {
        this.pendingPaymentMethodDelete = e.currentTarget.dataset.pmid;
    }

    openSetDefaultPaymentMethodConfirm(e) {
        this.pendingDefaultPaymentMethodId = e.currentTarget.dataset.pmid;
    }

    closeSetDefaultPaymentMethodConfirm() {
        this.pendingDefaultPaymentMethodId = null;
    }

    async confirmSetDefaultPaymentMethod() {
        if (!this.pendingDefaultPaymentMethodId) return;
        this.isBusy = true;
        try {
            await setDefaultPaymentMethod({
                contactId: this.customerContactId || null,
                paymentMethodId: this.pendingDefaultPaymentMethodId,
                customerId: this.customerId
            });
            this.pendingDefaultPaymentMethodId = null;
            this.toast('Success', 'Default payment method updated.', 'success');
            await this.refresh();
        } catch (e) {
            this.handleError(e);
        } finally {
            this.isBusy = false;
        }
    }

    closePaymentMethodDeleteConfirm() {
        this.pendingPaymentMethodDelete = null;
    }

    async confirmDeletePaymentMethod() {
        if (!this.pendingPaymentMethodDelete) return;
        const paymentMethodId = this.pendingPaymentMethodDelete;
        this.isBusy = true;
        try {
            await detachPaymentMethod({
                contactId: this.customerContactId || null,
                paymentMethodId,
                customerId: this.customerId
            });
            if (this.selectedPmForSub === paymentMethodId) {
                this.selectedPmForSub = null;
            }
            this.pendingPaymentMethodDelete = null;
            this.toast('Success', 'Payment method removed.', 'success');
            await this.refresh();
        } catch (e) {
            this.handleError(e);
        } finally {
            this.isBusy = false;
        }
    }

    onAmount(e) { this.amount = e.detail.value; }
    onInstallmentPeriod(e) { this.installmentPeriod = e.detail.value; }
    onStartDate(e) { this.startDate = e.detail.value; }
    onCreateRecurringType(e) {
        this.createRecurringType = e.detail.value;
        if (this.createRecurringType !== 'Fixed') this.createInstallments = null;
    }
    onCreateInstallments(e) { this.createInstallments = e.detail.value; }
    onSelectedGau(e) {
        this.selectedGauId = e.detail.recordId || null;
        this.selectedGauName = e.detail.displayValue || e.detail.recordName || null;
    }
    onBillingName(e) { this.billingName = e.detail.value; }
    onBillingEmail(e) { this.billingEmail = e.detail.value; }
    onBillingPhone(e) { this.billingPhone = e.detail.value; }
    onBillingStreet(e) { this.billingStreet = e.detail.value; }
    onBillingCity(e) { this.billingCity = e.detail.value; }
    onBillingState(e) { this.billingState = e.detail.value; }
    onBillingPostalCode(e) { this.billingPostalCode = e.detail.value; }
    onBillingCountry(e) {
        this.billingCountry = e.detail.value;
        const stateStillValid = this.billingStateOptions.some((item) => item.value === this.billingState);
        if (!stateStillValid) this.billingState = '';
    }

    prefillBillingDetails(force = false) {
        if (force || !this.billingName) this.billingName = this.contactName;
        if (force || !this.billingEmail) this.billingEmail = this.contactEmail;
        if (force || !this.billingPhone) this.billingPhone = this.contactPhone;
        if (force || !this.billingStreet) this.billingStreet = this.contactMailingStreet;
        if (force || !this.billingCity) this.billingCity = this.contactMailingCity;
        if (force || !this.billingCountry || !this.isValidBillingCountry(this.billingCountry)) {
            this.billingCountry = this.normalizeCountry(this.contactMailingCountry);
        }
        if (force || !this.billingState || !this.isValidBillingState(this.billingState)) {
            this.billingState = this.normalizeState(this.contactMailingState);
        }
        if (force || !this.billingPostalCode) this.billingPostalCode = this.contactMailingPostalCode;
    }

    isValidBillingCountry(country) {
        if (!country) return false;
        return this.billingCountryOptions.some((item) => item.value === country);
    }

    isValidBillingState(state) {
        if (!state) return false;
        return this.billingStateOptions.some((item) => item.value === state);
    }

    normalizeCountry(country) {
        if (!country) return '';
        const value = String(country).trim().toLowerCase();
        const match = this.mailingCountryOptions.find((item) => {
            const optionValue = String(item.value || '').trim().toLowerCase();
            const optionLabel = String(item.label || '').trim().toLowerCase();
            return optionValue === value || optionLabel === value;
        });
        return match?.value || String(country).trim();
    }

    normalizeState(state) {
        if (!state) return '';
        const value = String(state).trim();
        const lowered = value.toLowerCase();
        const match = this.billingStateOptions.find((item) => {
            const optionValue = String(item.value || '').trim().toLowerCase();
            const optionLabel = String(item.label || '').trim().toLowerCase();
            return optionValue === lowered || optionLabel === lowered;
        });
        return match?.value || value;
    }
    onSelectedPmForSub(e) { this.selectedPmForSub = e.detail.value; }
    onSelectedCloseReason(e) { this.selectedCloseReason = e.detail.value; }
    onActionAmount(e) { this.actionAmount = e.detail.value; }
    onActionInstallmentPeriod(e) { this.actionInstallmentPeriod = e.detail.value; }
    onActionInstallmentFrequency(e) { this.actionInstallmentFrequency = e.detail.value; }
    onActionDayOfMonth(e) { this.actionDayOfMonth = e.detail.value; }
    onActionPaymentMethod(e) { this.actionPaymentMethodId = e.detail.value; }
    onActionInstallments(e) { this.actionInstallments = e.detail.value; }
    onPauseMode(e) { this.pauseMode = e.detail.value; }
    onPauseGiftCount(e) { this.pauseGiftCount = e.detail.value; }
    onPauseResumeDate(e) { this.pauseResumeDate = e.detail.value; }

    handleSelectPaymentMethod(e) {
        this.selectedPmForSub = e.currentTarget.dataset.pmid;
        this.paymentMethods = this.paymentMethods.map((pm) => ({
            ...pm,
            tileClass: this.paymentMethodTileClass(pm)
        }));
    }

    toggleCanceledSubscriptions() {
        this.showCanceledSubscriptionsModal = true;
    }

    closeCanceledSubscriptionsModal() {
        this.showCanceledSubscriptionsModal = false;
    }

    onInlineAmount(e) { this.setInline(e.target.dataset.subid, 'newAmount', e.detail.value); }
    onInlineInstallmentPeriod(e) { this.setInline(e.target.dataset.subid, 'newInstallmentPeriod', e.detail.value); }
    onInlinePm(e) { this.setInline(e.target.dataset.subid, 'newPm', e.detail.value); }

    setInline(subId, key, value) {
        if (!this.inlineUpdates[subId]) this.inlineUpdates[subId] = {};
        this.inlineUpdates[subId][key] = value;
    }

    cadenceLabel(interval, intervalCount) {
        if (!interval) return '';
        const n = Number(intervalCount || 1);
        const normalized = String(interval).toLowerCase();
        if (normalized === 'year') {
            return n === 1 ? 'Yearly' : `Every ${n} years`;
        }
        if (normalized === 'week') {
            return n === 1 ? 'Weekly' : `Every ${n} weeks`;
        }
        if (normalized === 'month') {
            if (n === 1) return 'Monthly';
            if (n === 3) return 'Quarterly';
            return `Every ${n} months`;
        }
        return n === 1 ? interval : `Every ${n} ${interval}${n > 1 ? 's' : ''}`;
    }

    installmentPeriodFromInterval(interval) {
        if (interval === 'year') return 'Yearly';
        if (interval === 'week') return 'Weekly';
        return 'Monthly';
    }

    tsLabel(ts) {
        if (!ts && ts !== 0) return 'N/A';
        const n = Number(ts);
        if (!Number.isFinite(n) || n <= 0) return 'N/A';
        return this.formatLongDate(new Date(n * 1000));
    }

    // Unambiguous long-form date, e.g. "Jul 26, 2026" (avoids m/d vs d/m confusion).
    formatLongDate(dateValue) {
        if (!dateValue) return null;
        return dateValue.toLocaleDateString('en-US', { month: 'short', day: 'numeric', year: 'numeric' });
    }

    formatBrand(brand) {
        if (!brand) return 'Card';
        return brand.charAt(0).toUpperCase() + brand.slice(1);
    }

    paymentMethodTileClass(pm) {
        const selected = pm.id === this.selectedPmForSub ? ' selected' : '';
        return `method-tile${selected}`;
    }

    statusClass(status, collectionPaused) {
        if (collectionPaused === true) return 'status status-paused';
        const normalized = (status || '').toLowerCase();
        if (normalized === 'active' || normalized === 'trialing') return 'status status-good';
        if (normalized === 'past_due' || normalized === 'unpaid') return 'status status-warning';
        if (normalized === 'canceled' || normalized === 'incomplete_expired') return 'status status-muted';
        return 'status';
    }

    isCanceledStatus(status) {
        const normalized = (status || '').toLowerCase();
        return normalized === 'canceled' || normalized === 'incomplete_expired';
    }

    lifecycleDateLabel(subscription) {
        if (subscription.collectionPaused) {
            const resumesAt = this.realDateLabel(subscription.pauseResumesAtLabel);
            return resumesAt ? `Payment collection paused until ${resumesAt}` : 'Payment collection paused';
        }
        if (this.isCanceledStatus(subscription.status)) {
            if (subscription.endedAt) return `Ended ${this.tsLabel(subscription.endedAt)}`;
            if (subscription.canceledAt) return `Canceled ${this.tsLabel(subscription.canceledAt)}`;
            return 'Canceled';
        }
        if (subscription.cancelAtPeriodEnd && subscription.currentPeriodEnd) {
            return `Ends ${this.tsLabel(subscription.currentPeriodEnd)}`;
        }
        return `Next billing ${this.tsLabel(subscription.currentPeriodEnd)}`;
    }

    realDateLabel(label) {
        return label && label !== 'N/A' ? label : null;
    }

    formatAmount(amount, currencyCode) {
        if (amount === null || amount === undefined) return 'Amount unavailable';
        const currency = (currencyCode || 'usd').toUpperCase();
        const normalizedAmount = Number(amount).toFixed(2);
        if (currency === 'USD') {
            return `$${normalizedAmount}`;
        }
        return `${currency} ${normalizedAmount}`;
    }

    paymentMethodDisplay(paymentMethodId) {
        if (!paymentMethodId) return 'Customer default';
        const pm = this.paymentMethods.find((item) => item.id === paymentMethodId);
        return pm ? `${pm.brandLabel} **** ${pm.last4}` : paymentMethodId;
    }

    parseDateOnly(value) {
        if (!value) return null;
        const raw = String(value);
        const match = raw.match(/^(\d{4})-(\d{2})-(\d{2})/);
        if (!match) return null;
        return new Date(Number(match[1]), Number(match[2]) - 1, Number(match[3]));
    }

    todayDateOnly() {
        const now = new Date();
        return new Date(now.getFullYear(), now.getMonth(), now.getDate());
    }

    isFutureDate(value) {
        const parsed = this.parseDateOnly(value);
        return parsed !== null && parsed > this.todayDateOnly();
    }

    defaultFuturePauseResumeDate() {
        const current = this.parseDateOnly(this.pauseResumeDateValue);
        if (current && current > this.todayDateOnly()) {
            return this.toDateInputValue(current);
        }
        const tomorrow = this.todayDateOnly();
        tomorrow.setDate(tomorrow.getDate() + 1);
        return this.toDateInputValue(tomorrow);
    }

    toDateInputValue(dateValue) {
        if (!dateValue) return null;
        const year = dateValue.getFullYear();
        const month = String(dateValue.getMonth() + 1).padStart(2, '0');
        const day = String(dateValue.getDate()).padStart(2, '0');
        return `${year}-${month}-${day}`;
    }

    ordinalDay(day) {
        const mod10 = day % 10;
        const mod100 = day % 100;
        let suffix = 'th';
        if (mod10 === 1 && mod100 !== 11) suffix = 'st';
        else if (mod10 === 2 && mod100 !== 12) suffix = 'nd';
        else if (mod10 === 3 && mod100 !== 13) suffix = 'rd';
        return `${day}${suffix}`;
    }

    deriveDayOfMonthFromNextGiftDate() {
        if (!this.recurringNextPaymentDate) return null;
        const match = String(this.recurringNextPaymentDate).match(/(\d{4})-(\d{2})-(\d{2})/);
        if (!match) return null;
        const day = Number(match[3]);
        if (!Number.isFinite(day) || day <= 0) return null;
        return String(day);
    }

    formatUsd(value) {
        const normalized = Number(value || 0);
        return `$${normalized.toFixed(2)}`;
    }

    stepClass(step) {
        const order = ['summary', 'update', 'confirm', 'processing'];
        const activeIndex = order.indexOf(this.isBusy && this.pendingAction ? 'processing' : (this.pendingAction ? this.actionStage : 'summary'));
        const stepIndex = order.indexOf(step);
        let cls = 'wizard-step';
        if (stepIndex === activeIndex) cls += ' active';
        if (stepIndex < activeIndex) cls += ' complete';
        return cls;
    }

    createStepClass(step) {
        const order = ['form', 'confirm', 'processing', 'success'];
        const activeIndex = order.indexOf(this.createStage || 'form');
        const stepIndex = order.indexOf(step);
        let cls = 'wizard-step';
        if (stepIndex === activeIndex) cls += ' active';
        if (stepIndex < activeIndex) cls += ' complete';
        return cls;
    }

    handleRefresh() { this.refresh(); }

    handleClose() {
        // Dispatched when this LWC runs as a quick action; harmless no-op otherwise.
        this.dispatchEvent(new CloseActionScreenEvent());
    }

    // Whole-row keyboard support: Enter/Space opens the inline editor for that row.
    onRowKeydown(event) {
        if (event.key !== 'Enter' && event.key !== ' ' && event.key !== 'Spacebar') return;
        event.preventDefault();
        const field = event.currentTarget.dataset.edit;
        if (field === 'amount') this.startEditAmount();
        else if (field === 'frequency') this.startEditFrequency();
        else if (field === 'giftDay') this.startEditGiftDay();
    }

    startNewDonation() {
        const target = this.newDonationUrl || (this.newDonationFlowApiName ? `/flow/${this.newDonationFlowApiName}` : null);
        if (!target) {
            this.toast('Signup flow not configured', 'Set newDonationUrl or newDonationFlowApiName on this component.', 'warning');
            return;
        }
        window.open(target, '_blank', 'noopener');
    }

    openAmountAction() {
        this.pendingActionSubscriptionId = this.resolveActionSubscriptionId(arguments[0]);
        this.pendingAction = 'amount';
        this.actionStage = 'update';
        this.successMessage = null;
        this.actionAmount = this.managedSubscription?.amount ?? this.recurringAmount;
        this.decorateSubscriptionActionState();
    }

    openFrequencyAction() {
        this.pendingActionSubscriptionId = this.resolveActionSubscriptionId(arguments[0]);
        this.pendingAction = 'frequency';
        this.actionStage = 'update';
        this.successMessage = null;
        this.actionInstallmentPeriod = this.isRecurringDonationContext
            ? (this.recurringInstallmentPeriod || 'Monthly')
            : (this.managedSubscription?.installmentPeriod || 'Monthly');
        this.actionInstallmentFrequency = this.isRecurringDonationContext
            ? (this.recurringInstallmentFrequency || 1)
            : Number(this.managedSubscription?.intervalCount || 1);
        this.decorateSubscriptionActionState();
    }

    openGiftDateAction() {
        this.pendingActionSubscriptionId = this.resolveActionSubscriptionId(arguments[0]);
        if (!this.managedSubscription?.id && !this.canUsePendingScheduleActions) return;
        this.pendingAction = 'giftDate';
        this.actionStage = 'update';
        this.successMessage = null;
        this.actionDayOfMonth = this.nextInstallmentDayOfMonth;
        this.decorateSubscriptionActionState();
    }

    openPauseAction() {
        this.pendingActionSubscriptionId = this.resolveActionSubscriptionId(arguments[0]);
        if (!this.managedSubscription?.id) return;
        this.pendingAction = 'pause';
        this.actionStage = 'update';
        this.successMessage = null;
        this.selectedCloseReason = null;
        this.pauseMode = 'gifts';
        this.pauseGiftCount = '1';
        this.pauseResumeDate = this.defaultFuturePauseResumeDate();
        this.decorateSubscriptionActionState();
    }

    openResumeAction() {
        this.pendingActionSubscriptionId = this.resolveActionSubscriptionId(arguments[0]);
        if (!this.managedSubscription?.id) return;
        this.pendingAction = 'resume';
        this.actionStage = 'update';
        this.successMessage = null;
        this.decorateSubscriptionActionState();
    }

    openCancelAction() {
        this.pendingActionSubscriptionId = this.resolveActionSubscriptionId(arguments[0]);
        if (!this.managedSubscription?.id && !this.canUsePendingScheduleActions) return;
        this.pendingAction = 'cancel';
        this.actionStage = 'update';
        this.successMessage = null;
        this.selectedCloseReason = null;
        this.decorateSubscriptionActionState();
    }

    openPaymentMethodAction() {
        this.pendingActionSubscriptionId = this.resolveActionSubscriptionId(arguments[0]);
        if (!this.managedSubscription?.id && !this.canUsePendingScheduleActions) return;
        this.pendingAction = 'paymentMethod';
        this.actionStage = 'update';
        this.successMessage = null;
        this.actionPaymentMethodId = this.managedSubscription?.defaultPaymentMethod || this.selectedPmForSub || null;
        this.decorateSubscriptionActionState();
    }

    openGiftCountAction() {
        this.pendingActionSubscriptionId = this.resolveActionSubscriptionId(arguments[0]);
        if (!this.managedSubscription?.id && !this.canUsePendingScheduleActions) return;
        this.pendingAction = 'giftCount';
        this.actionStage = 'update';
        this.successMessage = null;
        this.actionInstallments = this.isRecurringDonationContext
            ? this.recurringInstallments
            : this.managedSubscription?.installments;
        this.decorateSubscriptionActionState();
    }

    openEndTrialNowAction() {
        this.pendingActionSubscriptionId = this.resolveActionSubscriptionId(arguments[0]);
        if (!this.managedSubscription?.id) return;
        this.pendingAction = 'endTrialNow';
        this.actionStage = 'update';
        this.successMessage = null;
        this.decorateSubscriptionActionState();
    }

    closeActionPanel() {
        this.pendingAction = null;
        this.pendingActionSubscriptionId = null;
        this.actionStage = 'summary';
        this.decorateSubscriptionActionState();
    }

    backToUpdateAction() {
        this.actionStage = 'update';
    }

    goConfirmAction() {
        if (this.isAmountAction && this.disableAmountSave) return;
        if (this.isFrequencyAction && this.disableFrequencySave) return;
        if (this.isGiftDateAction && this.disableGiftDateSave) return;
        if (this.isPaymentMethodAction && this.disablePaymentMethodSave) return;
        if (this.isGiftCountAction && this.disableGiftCountSave) return;
        if (this.isCancelAction && this.disableCancelConfirm) return;
        if (this.isPauseAction && this.disablePauseConfirm) {
            if (this.isPauseUntilDate) {
                this.handleError(new Error('Resume date must be in the future.'));
            }
            return;
        }
        this.actionStage = 'confirm';
    }

    async confirmCurrentAction() {
        this.actionStage = 'processing';
        if (this.isAmountAction) return this.saveRecurringAmountChange();
        if (this.isFrequencyAction) return this.saveRecurringFrequencyChange();
        if (this.isGiftDateAction) return this.saveRecurringGiftDateChange();
        if (this.isPaymentMethodAction) return this.saveRecurringPaymentMethodChange();
        if (this.isGiftCountAction) return this.saveRecurringGiftCountChange();
        if (this.isCancelAction) return this.confirmRecurringCancel();
        if (this.isPauseAction) return this.confirmRecurringPause();
        if (this.isResumeAction) return this.confirmRecurringResume();
        if (this.isEndTrialNowAction) return this.confirmEndTrialNow();
    }

    async executeRecurringDonationSync(action, overrides = {}) {
        return syncRecurringDonationAction({
            requestJson: JSON.stringify({
                recurringDonationId: this.recurringDonationId || null,
                contactId: this.actionContactId || null,
                subscriptionId: this.managedSubscription?.id || null,
                action,
                actionName: action,
                amount: overrides.amount ?? null,
                installmentPeriod: overrides.installmentPeriod ?? null,
                installmentFrequency: overrides.installmentFrequency ?? null,
                dayOfMonth: overrides.dayOfMonth ?? null,
                nextGiftDate: overrides.nextGiftDate ?? null,
                closeReason: overrides.closeReason ?? null,
                recurringType: overrides.recurringType ?? null,
                installments: overrides.installments ?? null,
                paymentMethodId: overrides.paymentMethodId ?? null,
                resumeDate: overrides.resumeDate ?? null
            })
        });
    }

    async saveRecurringAmountChange() {
        if (!this.managedSubscription?.id && !this.canUsePendingScheduleActions) return;
        this.isBusy = true;
        try {
            if (this.canUsePendingScheduleActions) {
                await updatePendingSubscriptionSchedule({
                    contactId: this.actionContactId,
                    recurringDonationId: this.recurringDonationId,
                    amount: Number(this.actionAmount),
                    currencyCode: 'usd',
                    interval: null,
                    intervalCount: null,
                    paymentMethodId: null,
                    nextGiftDate: null,
                    recurringType: null,
                    installments: null,
                    action: 'update',
                    closeReason: null
                });
            } else if (this.isRecurringDonationContext) {
                await this.executeRecurringDonationSync('amount', {
                    amount: Number(this.actionAmount)
                });
            } else {
                await updateSubscription({
                    contactId: this.actionContactId,
                    subscriptionId: this.managedSubscription.id,
                    amount: Number(this.actionAmount),
                    currencyCode: 'usd',
                    interval: null,
                    intervalCount: null,
                    paymentMethodId: null,
                    recurringType: null,
                    installments: null
                });
            }
            this.pendingAction = null;
            this.actionStage = 'summary';
            this.successMessage = 'The donation amount has been updated.';
            this.toast('Success', 'Amount updated.', 'success');
            await this.refresh();
        } catch (e) {
            this.actionStage = 'update';
            this.handleError(e);
        } finally {
            this.isBusy = false;
        }
    }

    async saveRecurringFrequencyChange() {
        if (!this.managedSubscription?.id && !this.canUsePendingScheduleActions) return;
        this.isBusy = true;
        try {
            const currentAmount = this.isRecurringDonationContext
                ? (this.recurringAmount ? Number(this.recurringAmount) : null)
                : (this.managedSubscription.amount ? Number(this.managedSubscription.amount) : null);
            if (this.canUsePendingScheduleActions) {
                await updatePendingSubscriptionSchedule({
                    contactId: this.actionContactId,
                    recurringDonationId: this.recurringDonationId,
                    amount: currentAmount,
                    currencyCode: 'usd',
                    interval: this.actionInstallmentPeriod,
                    intervalCount: Number(this.actionInstallmentFrequency || 1),
                    paymentMethodId: null,
                    nextGiftDate: null,
                    recurringType: null,
                    installments: null,
                    action: 'update',
                    closeReason: null
                });
            } else if (this.isRecurringDonationContext) {
                await this.executeRecurringDonationSync('frequency', {
                    installmentPeriod: this.actionInstallmentPeriod,
                    installmentFrequency: Number(this.actionInstallmentFrequency || 1)
                });
            } else {
                await updateSubscription({
                    contactId: this.actionContactId,
                    subscriptionId: this.managedSubscription.id,
                    amount: currentAmount,
                    currencyCode: 'usd',
                    interval: this.actionInstallmentPeriod,
                    intervalCount: Number(this.actionInstallmentFrequency || 1),
                    paymentMethodId: null,
                    recurringType: null,
                    installments: null
                });
            }
            this.pendingAction = null;
            this.actionStage = 'summary';
            this.successMessage = 'The donation frequency has been updated.';
            this.toast('Success', 'Frequency updated.', 'success');
            await this.refresh();
        } catch (e) {
            this.actionStage = 'update';
            this.handleError(e);
        } finally {
            this.isBusy = false;
        }
    }

    async confirmRecurringResume() {
        if (!this.managedSubscription?.id) return;
        this.isBusy = true;
        try {
            if (this.isRecurringDonationContext) {
                await this.executeRecurringDonationSync('resume');
            } else {
                await resumeSubscription({
                    contactId: this.actionContactId,
                    subscriptionId: this.managedSubscription.id
                });
            }
            this.pendingAction = null;
            this.pendingActionSubscriptionId = null;
            this.actionStage = 'summary';
            this.successMessage = 'The donation has been resumed.';
            this.toast('Success', 'Subscription payment collection resumed.', 'success');
            await this.refresh();
        } catch (e) {
            this.actionStage = 'update';
            this.handleError(e);
        } finally {
            this.isBusy = false;
        }
    }

    async confirmRecurringPause() {
        if (!this.managedSubscription?.id) return;
        this.isBusy = true;
        try {
            if (this.isRecurringDonationContext) {
                await this.executeRecurringDonationSync('pause', {
                    resumeDate: this.pauseResumeDateValue
                });
            } else {
                await pauseSubscription({
                    contactId: this.actionContactId,
                    subscriptionId: this.managedSubscription.id,
                    closeReason: this.selectedCloseReason,
                    resumeDate: this.pauseResumeDateValue
                });
            }
            this.pendingAction = null;
            this.pendingActionSubscriptionId = null;
            this.selectedCloseReason = null;
            this.actionStage = 'summary';
            this.successMessage = 'The donation has been paused.';
            this.toast('Success', 'Subscription payment collection paused.', 'success');
            await this.refresh();
        } catch (e) {
            this.actionStage = 'update';
            this.handleError(e);
        } finally {
            this.isBusy = false;
        }
    }

    async confirmRecurringCancel() {
        if (!this.managedSubscription?.id && !this.canUsePendingScheduleActions) return;
        if (this.canUsePendingScheduleActions) {
            this.isBusy = true;
            try {
                await updatePendingSubscriptionSchedule({
                    contactId: this.actionContactId,
                    recurringDonationId: this.recurringDonationId,
                    amount: null,
                    currencyCode: 'usd',
                    interval: null,
                    intervalCount: null,
                    paymentMethodId: null,
                    nextGiftDate: null,
                    recurringType: null,
                    installments: null,
                    action: 'cancel',
                    closeReason: this.selectedCloseReason
                });
                this.pendingAction = null;
                this.selectedCloseReason = null;
                this.actionStage = 'summary';
                this.successMessage = 'The pending donation schedule has been canceled.';
                this.toast('Success', 'Pending schedule canceled and recurring donation closed.', 'success');
                await this.refresh();
            } catch (e) {
                this.actionStage = 'update';
                this.handleError(e);
            } finally {
                this.isBusy = false;
            }
            return;
        }
        if (this.isRecurringDonationContext) {
            this.isBusy = true;
            try {
                await this.executeRecurringDonationSync('cancel', {
                    closeReason: this.selectedCloseReason
                });
                this.pendingAction = null;
                this.pendingActionSubscriptionId = null;
                this.selectedCloseReason = null;
                this.actionStage = 'summary';
                this.successMessage = 'The donation has been canceled.';
                this.toast('Success', 'Subscription canceled now.', 'success');
                await this.refresh();
            } catch (e) {
                this.actionStage = 'update';
                this.handleError(e);
            } finally {
                this.isBusy = false;
            }
            return;
        }
        this.isBusy = true;
        try {
            await cancelSubscription({
                contactId: this.actionContactId,
                subscriptionId: this.managedSubscription.id,
                atPeriodEnd: false,
                closeReason: this.selectedCloseReason
            });
            this.pendingAction = null;
            this.pendingActionSubscriptionId = null;
            this.selectedCloseReason = null;
            this.actionStage = 'summary';
            this.successMessage = 'The donation has been canceled.';
            this.toast('Success', 'Subscription canceled now.', 'success');
            await this.refresh();
        } catch (e) {
            this.actionStage = 'update';
            this.handleError(e);
        } finally {
            this.isBusy = false;
        }
    }

    async saveRecurringGiftDateChange() {
        if (!this.managedSubscription?.id && !this.canUsePendingScheduleActions) return;
        this.isBusy = true;
        try {
            if (this.canUsePendingScheduleActions) {
                await updatePendingSubscriptionSchedule({
                    contactId: this.actionContactId,
                    recurringDonationId: this.recurringDonationId,
                    amount: null,
                    currencyCode: 'usd',
                    interval: null,
                    intervalCount: null,
                    paymentMethodId: null,
                    nextGiftDate: this.projectedGiftDateChangeValue,
                    recurringType: null,
                    installments: null,
                    action: 'update',
                    closeReason: null
                });
            } else if (this.isRecurringDonationContext) {
                await this.executeRecurringDonationSync('gift_day', {
                    dayOfMonth: this.actionDayOfMonth,
                    nextGiftDate: this.projectedGiftDateChangeValue
                });
            } else {
                await updateSubscriptionGiftDay({
                    contactId: this.actionContactId,
                    subscriptionId: this.managedSubscription.id,
                    nextGiftDate: this.projectedGiftDateChangeValue
                });
            }
            this.pendingAction = null;
            this.pendingActionSubscriptionId = null;
            this.actionStage = 'summary';
            this.successMessage = 'A replacement donation schedule has been created for the new billing date.';
            this.toast('Success', 'Replacement billing schedule created.', 'success');
            await this.refresh();
        } catch (e) {
            this.actionStage = 'update';
            this.handleError(e);
        } finally {
            this.isBusy = false;
        }
    }

    async saveRecurringPaymentMethodChange() {
        if ((!this.managedSubscription?.id && !this.canUsePendingScheduleActions) || !this.actionPaymentMethodId) return;
        this.isBusy = true;
        try {
            if (this.canUsePendingScheduleActions) {
                await updatePendingSubscriptionSchedule({
                    contactId: this.actionContactId,
                    recurringDonationId: this.recurringDonationId,
                    amount: null,
                    currencyCode: 'usd',
                    interval: null,
                    intervalCount: null,
                    paymentMethodId: this.actionPaymentMethodId,
                    nextGiftDate: null,
                    recurringType: null,
                    installments: null,
                    action: 'update',
                    closeReason: null
                });
            } else {
                await updateSubscription({
                    contactId: this.actionContactId,
                    subscriptionId: this.managedSubscription.id,
                    amount: null,
                    currencyCode: 'usd',
                    interval: null,
                    intervalCount: null,
                    paymentMethodId: this.actionPaymentMethodId,
                    recurringType: null,
                    installments: null
                });
            }
            this.pendingAction = null;
            this.pendingActionSubscriptionId = null;
            this.actionStage = 'summary';
            this.successMessage = 'The donation payment method has been updated.';
            this.toast('Success', 'Payment method updated.', 'success');
            await this.refresh();
        } catch (e) {
            this.actionStage = 'update';
            this.handleError(e);
        } finally {
            this.isBusy = false;
        }
    }

    async saveRecurringGiftCountChange() {
        if (!this.managedSubscription?.id && !this.canUsePendingScheduleActions) return;
        this.isBusy = true;
        try {
            if (this.canUsePendingScheduleActions) {
                await updatePendingSubscriptionSchedule({
                    contactId: this.actionContactId,
                    recurringDonationId: this.recurringDonationId,
                    amount: null,
                    currencyCode: 'usd',
                    interval: null,
                    intervalCount: null,
                    paymentMethodId: null,
                    nextGiftDate: null,
                    recurringType: 'Fixed',
                    installments: Number(this.actionInstallments),
                    action: 'update',
                    closeReason: null
                });
            } else {
                await updateSubscription({
                    contactId: this.actionContactId,
                    subscriptionId: this.managedSubscription.id,
                    amount: null,
                    currencyCode: 'usd',
                    interval: null,
                    intervalCount: null,
                    paymentMethodId: null,
                    recurringType: 'Fixed',
                    installments: Number(this.actionInstallments)
                });
            }
            this.pendingAction = null;
            this.pendingActionSubscriptionId = null;
            this.actionStage = 'summary';
            this.successMessage = 'The donation gift count has been updated.';
            this.toast('Success', 'Gift count updated.', 'success');
            await this.refresh();
        } catch (e) {
            this.actionStage = 'update';
            this.handleError(e);
        } finally {
            this.isBusy = false;
        }
    }

    async confirmEndTrialNow() {
        if (!this.managedSubscription?.id) return;
        this.isBusy = true;
        try {
            await endSubscriptionTrialNow({
                contactId: this.actionContactId,
                subscriptionId: this.managedSubscription.id
            });
            this.pendingAction = null;
            this.pendingActionSubscriptionId = null;
            this.actionStage = 'summary';
            this.successMessage = 'The trial has been ended and Stripe was asked to charge now.';
            this.toast('Success', 'Trial ended and Stripe was asked to charge now.', 'success');
            await this.refresh();
        } catch (e) {
            this.actionStage = 'update';
            this.handleError(e);
        } finally {
            this.isBusy = false;
        }
    }

    async renderedCallback() {
        if (!this.shouldMountStripeElement || this.paymentElement || this.cardElementInitFailed) return;
        try {
            await this.ensureCardElementReady();
        } catch (e) {
            // Stop retrying on every re-render so a failed mount surfaces once
            // instead of looping (and hammering createSetupIntent) forever.
            this.cardElementInitFailed = true;
            this.handleError(e);
        }
    }

    get shouldMountStripeElement() {
        return this.showAddPaymentMethodModal || (this.editingPaymentMethod && this.addingNewCard);
    }

    get stripeElementHost() {
        return this.template.querySelector('.rd-pm-element-host')
            || this.template.querySelector('.card-host');
    }

    get stripeAddressHost() {
        return this.template.querySelector('.rd-pm-address-host')
            || this.template.querySelector('.address-host');
    }

    async loadStripeScript() {
        if (window.Stripe) return;
        await new Promise((resolve, reject) => {
            const s = document.createElement('script');
            s.src = 'https://js.stripe.com/v3/';
            s.onload = resolve;
            s.onerror = () => reject(new Error('Failed to load Stripe.js. Add js.stripe.com to CSP Trusted Sites.'));
            document.head.appendChild(s);
        });
    }

    async ensureCardElementReady() {
        if (!this.shouldMountStripeElement) return;
        if (!this.recordId) return;
        if (this.paymentElement) return;
        if (this.cardElementInitPromise) {
            await this.cardElementInitPromise;
            return;
        }
        const host = this.stripeElementHost;
        if (!host) return;
        this.cardElementInitPromise = this.initializeCardElement(host);
        try {
            await this.cardElementInitPromise;
        } finally {
            this.cardElementInitPromise = null;
        }
    }

    // Mounts Stripe's modern Payment Element (card tabs) plus a dedicated billing
    // Address Element, prefilled from the Contact mailing address. Card data stays
    // inside Stripe-hosted iframes - we never touch raw PAN/CVC.
    async initializeCardElement(host) {
        await this.loadStripeScript();
        const init = await createSetupIntent({ contactId: this.customerContactId || null, customerId: this.customerId });
        this.setupIntentClientSecret = init.clientSecret;
        if (!this.stripe) this.stripe = window.Stripe(init.publishableKey);
        this.elements = this.stripe.elements({ clientSecret: init.clientSecret });
        this.paymentElement = this.elements.create('payment', {
            layout: { type: 'tabs' },
            fields: { billingDetails: { address: 'never' } },
            wallets: { applePay: 'never', googlePay: 'never' }
        });
        this.paymentElement.mount(host);
        const addressHost = this.stripeAddressHost;
        if (addressHost) {
            this.addressElement = this.elements.create('address', {
                mode: 'billing',
                defaultValues: {
                    name: this.billingName || undefined,
                    address: {
                        line1: this.billingStreet || undefined,
                        city: this.billingCity || undefined,
                        state: this.billingState || undefined,
                        postal_code: this.billingPostalCode || undefined,
                        country: this.billingCountry || undefined
                    }
                }
            });
            this.addressElement.mount(addressHost);
        }
    }

    async handleSaveCard() {
        // Phase 1 - tokenize the card with Stripe. We deliberately do NOT set
        // isBusy here: in the inline "Update payment method" flow the card form
        // lives inside the schedule summary, which is hidden whenever isBusy is
        // true. Hiding it unmounts the Payment Element iframe, and confirmSetup
        // then waits forever for a postMessage from an iframe that no longer
        // exists (spinner that never stops). cardSaving disables the buttons and
        // shows the overlay spinner without unmounting the element.
        this.cardSaving = true;
        let pmId;
        try {
            await this.loadStripeScript();
            await this.ensureCardElementReady();
            const { error: submitError } = await this.elements.submit();
            if (submitError) {
                throw new Error(submitError.message);
            }
            if (this.addressElement) {
                const addr = await this.addressElement.getValue();
                if (!addr.complete) {
                    throw new Error('Please complete the billing address.');
                }
            }
            // Payment Element integration: pass the elements group (which already
            // includes the Address Element's billing details). Do not also pass
            // clientSecret or payment_method_data - that conflicts with elements
            // and makes confirmSetup error/stall.
            const result = await this.stripe.confirmSetup({
                elements: this.elements,
                confirmParams: {
                    return_url: window.location.href
                },
                redirect: 'if_required'
            });
            if (result.error) {
                throw new Error(result.error.message);
            }
            pmId = result.setupIntent?.payment_method;
            if (!pmId) throw new Error('Stripe did not return payment method id.');
        } catch (e) {
            this.cardSaving = false;
            this.handleError(e);
            return;
        }

        // Phase 2 - the Stripe element is no longer needed, so it is now safe to
        // flip the busy overlay (which unmounts the card form) while the Apex
        // callouts attach the card and update the subscription.
        const target = this.addPaymentMethodTarget;
        this.cardSaving = false;
        this.isBusy = true;
        try {
            await attachPaymentMethod({
                contactId: this.customerContactId || null,
                paymentMethodId: pmId,
                // Only adopt the new card as the customer-wide default when the
                // user is managing the customer's cards. When adding a card for a
                // specific new/existing subscription, the card is applied at the
                // subscription level instead, so other subscriptions keep theirs.
                makeDefault: target === 'customer',
                customerId: this.customerId
            });
            if (target === 'create') {
                this.selectedPmForSub = pmId;
            } else if (target === 'subscription' && (this.managedSubscription?.id || this.canUsePendingScheduleActions)) {
                this.actionPaymentMethodId = pmId;
                if (this.canUsePendingScheduleActions) {
                    await updatePendingSubscriptionSchedule({
                        contactId: this.actionContactId,
                        recurringDonationId: this.recurringDonationId,
                        amount: null,
                        currencyCode: 'usd',
                        interval: null,
                        intervalCount: null,
                        paymentMethodId: pmId,
                        nextGiftDate: null,
                        recurringType: null,
                        installments: null,
                        action: 'update',
                        closeReason: null
                    });
                } else {
                    await updateSubscription({
                        contactId: this.actionContactId,
                        subscriptionId: this.managedSubscription.id,
                        amount: null,
                        interval: null,
                        intervalCount: null,
                        currencyCode: 'usd',
                        paymentMethodId: pmId,
                        recurringType: null,
                        installments: null
                    });
                }
            }
            this.toast('Success', 'Card saved and attached.', 'success');
            this.closeAddPaymentMethod();
            await this.refresh();
        } catch (e) {
            this.handleError(e);
        } finally {
            this.isBusy = false;
        }
    }

    openAddPaymentMethod() {
        this.prefillBillingDetails(true);
        this.addPaymentMethodTarget = 'customer';
        this.showAddPaymentMethodModal = true;
        Promise.resolve().then(() => this.ensureCardElementReady());
    }

    openAddPaymentMethodForCreate() {
        this.prefillBillingDetails(true);
        this.addPaymentMethodTarget = 'create';
        this.showAddPaymentMethodModal = true;
        Promise.resolve().then(() => this.ensureCardElementReady());
    }

    openAddPaymentMethodForSubscription() {
        this.prefillBillingDetails(true);
        this.addPaymentMethodTarget = 'subscription';
        this.showAddPaymentMethodModal = true;
        Promise.resolve().then(() => this.ensureCardElementReady());
    }

    closeAddPaymentMethod() {
        this.showAddPaymentMethodModal = false;
        this.editingPaymentMethod = false;
        this.addingNewCard = false;
        this.teardownStripeElements();
        this.addPaymentMethodTarget = 'customer';
    }

    teardownStripeElements() {
        if (this.paymentElement) {
            try { this.paymentElement.destroy(); } catch (e) { /* element already gone */ }
            this.paymentElement = null;
        }
        if (this.addressElement) {
            try { this.addressElement.destroy(); } catch (e) { /* element already gone */ }
            this.addressElement = null;
        }
        if (this.cardElement) {
            try { this.cardElement.destroy(); } catch (e) { /* element already gone */ }
            this.cardElement = null;
        }
        this.elements = null;
        this.cardElementInitPromise = null;
        this.setupIntentClientSecret = null;
        this.cardElementInitFailed = false;
    }

    resetCreateForm() {
        this.amount = null;
        this.installmentPeriod = 'Monthly';
        this.startDate = null;
        this.selectedGauId = null;
        this.selectedGauName = null;
        this.selectedPmForSub = null;
        this.createRecurringType = 'Open';
        this.createInstallments = null;
        this.pendingCreateSubscription = false;
        this.createStage = 'form';
    }

    handleError(e) {
        const msg = this.extractErrorMessage(e);
        this.errorMessage = msg;
        this.toast('Error', msg, 'error');
    }

    // Surface the real cause. Apex DML/validation failures (e.g. record locks,
    // validation rules, NPSP automation) deliver the message in pageErrors/
    // fieldErrors rather than body.message, which otherwise shows "Unknown error".
    extractErrorMessage(e) {
        if (!e) return 'Unknown error';
        const body = e.body;
        if (typeof body === 'string' && body) return body;
        if (body) {
            if (typeof body.message === 'string' && body.message) return body.message;
            if (Array.isArray(body.pageErrors) && body.pageErrors.length) {
                return body.pageErrors[0].message;
            }
            if (body.fieldErrors) {
                const keys = Object.keys(body.fieldErrors);
                if (keys.length && Array.isArray(body.fieldErrors[keys[0]]) && body.fieldErrors[keys[0]].length) {
                    return body.fieldErrors[keys[0]][0].message;
                }
            }
            if (body.output && Array.isArray(body.output.errors) && body.output.errors.length) {
                return body.output.errors[0].message;
            }
            if (body.output && body.output.fieldErrors) {
                const keys = Object.keys(body.output.fieldErrors);
                if (keys.length && Array.isArray(body.output.fieldErrors[keys[0]]) && body.output.fieldErrors[keys[0]].length) {
                    return body.output.fieldErrors[keys[0]][0].message;
                }
            }
        }
        return e.message || 'Unknown error';
    }

    toast(title, message, variant) {
        this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
    }

    resolveActionSubscriptionId(event) {
        return event?.currentTarget?.dataset?.subid || this.pendingActionSubscriptionId || this.currentRecurringSubscription?.id || null;
    }

    decorateSubscriptionActionState() {
        const decorate = (sub) => ({
            ...sub,
            canChangeBillingDate: ((sub.status || '').toLowerCase() === 'active') && sub.collectionPaused !== true,
            isTrialingSubscription: ((sub.status || '').toLowerCase() === 'trialing') && sub.collectionPaused !== true,
            isActiveSubscription: ((sub.status || '').toLowerCase() === 'active') && sub.collectionPaused !== true,
            showAmountAction: !this.isRecurringDonationContext && this.pendingActionSubscriptionId === sub.id && this.pendingAction === 'amount',
            showFrequencyAction: !this.isRecurringDonationContext && this.pendingActionSubscriptionId === sub.id && this.pendingAction === 'frequency',
            showGiftDateAction: !this.isRecurringDonationContext && this.pendingActionSubscriptionId === sub.id && this.pendingAction === 'giftDate',
            showPauseAction: !this.isRecurringDonationContext && this.pendingActionSubscriptionId === sub.id && this.pendingAction === 'pause',
            showResumeAction: !this.isRecurringDonationContext && this.pendingActionSubscriptionId === sub.id && this.pendingAction === 'resume',
            showCancelAction: !this.isRecurringDonationContext && this.pendingActionSubscriptionId === sub.id && this.pendingAction === 'cancel',
            showPaymentMethodAction: !this.isRecurringDonationContext && this.pendingActionSubscriptionId === sub.id && this.pendingAction === 'paymentMethod',
            showGiftCountAction: !this.isRecurringDonationContext && this.pendingActionSubscriptionId === sub.id && this.pendingAction === 'giftCount',
            showEndTrialNowAction: !this.isRecurringDonationContext && this.pendingActionSubscriptionId === sub.id && this.pendingAction === 'endTrialNow'
        });
        this.subscriptions = (this.subscriptions || []).map(decorate);
        this.canceledSubscriptions = (this.canceledSubscriptions || []).map(decorate);
    }
}