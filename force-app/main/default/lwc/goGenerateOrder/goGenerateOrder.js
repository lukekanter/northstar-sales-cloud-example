import { LightningElement, api } from "lwc";
import { NavigationMixin } from "lightning/navigation";
import { ShowToastEvent } from "lightning/platformShowToastEvent";
import { CloseActionScreenEvent } from "lightning/actions";
import generateOrderForOpportunity from "@salesforce/apex/GO_GenerateOrderInvocable.generateOrderForOpportunity";
import generateOrderForOrder from "@salesforce/apex/GO_GenerateOrderInvocable.generateOrderForOrder";

/**
 * goGenerateOrder
 *
 * Screen quick action backing the `Generate_Order`
 * action on both Opportunity and Order. It is context-aware via
 * `objectApiName`:
 *   - On an Opportunity it calls `generateOrderForOpportunity`, building a draft
 *     Order from the primary accepted Quote (or Opportunity Products), then
 * toasts, closes, and navigates to the new Order.
 *   - On an Order it calls `generateOrderForOrder`, which resolves
 * the Order's source Opportunity and runs the same path. The
 *     idempotency guard means the existing Order is surfaced rather than
 *     duplicated, so the action simply opens that Order.
 * On a handled failure it surfaces the invocable's translatable error message
 * inline. Adapted from the "sfdc-generate-order" accelerator
 * (MIT, © 2018 Mike Simpson).
 */
export default class GoGenerateOrder extends NavigationMixin(LightningElement) {
  loading = true;
  errorMessage;
  _recordId;
  _objectApiName;
  _connected = false;
  _started = false;

  // recordId and objectApiName are not guaranteed to arrive before
  // connectedCallback, nor in a fixed order, for a record quick action. We pick
  // the Apex entry point from objectApiName, so generation must wait for BOTH
  // ids AND the object context — otherwise an Order id could be dispatched to
  // the Opportunity entry point before objectApiName lands. Kick off from
  // whichever of the setters / connect hook lands last.
  @api
  get recordId() {
    return this._recordId;
  }
  set recordId(value) {
    this._recordId = value;
    this.maybeGenerate();
  }

  // Set by the record action framework; tells us whether the record in context
  // is an Opportunity (build a new Order) or an Order (re-generate / open it).
  @api
  get objectApiName() {
    return this._objectApiName;
  }
  set objectApiName(value) {
    this._objectApiName = value;
    this.maybeGenerate();
  }

  connectedCallback() {
    this._connected = true;
    this.maybeGenerate();
  }

  maybeGenerate() {
    if (
      this._started ||
      !this._connected ||
      !this._recordId ||
      !this._objectApiName
    ) {
      return;
    }
    this._started = true;
    this.generate();
  }

  get isOrderContext() {
    return this.objectApiName === "Order";
  }

  async generate() {
    try {
      const result = this.isOrderContext
        ? await generateOrderForOrder({ orderId: this.recordId })
        : await generateOrderForOpportunity({ opportunityId: this.recordId });
      if (result && result.success) {
        this.toast(
          "Order created",
          "A draft Order was generated from this Opportunity.",
          "success"
        );
        this.close();
        this.navigateToOrder(result.orderId);
      } else if (
        this.isOrderContext &&
        result &&
        result.errorCode === "ORDER_ALREADY_EXISTS" &&
        result.orderId
      ) {
        // Re-generating from an Order is idempotent: the source Opportunity
        // already has this Order, so open it instead of reporting a
        // failure. On an Opportunity this same code still falls through to the
        // inline message, preserving the behaviour.
        this.toast(
          "Order already generated",
          result.errorMessage || "Opening the existing Order.",
          "info"
        );
        this.close();
        this.navigateToOrder(result.orderId);
      } else {
        this.loading = false;
        this.errorMessage =
          (result && result.errorMessage) ||
          "The Order could not be generated.";
      }
    } catch (error) {
      this.loading = false;
      this.errorMessage = this.reduceError(error);
    }
  }

  navigateToOrder(orderId) {
    this[NavigationMixin.Navigate]({
      type: "standard__recordPage",
      attributes: {
        recordId: orderId,
        objectApiName: "Order",
        actionName: "view"
      }
    });
  }

  handleClose() {
    this.close();
  }

  close() {
    this.dispatchEvent(new CloseActionScreenEvent());
  }

  toast(title, message, variant) {
    this.dispatchEvent(new ShowToastEvent({ title, message, variant }));
  }

  reduceError(error) {
    return (
      (error && error.body && error.body.message) ||
      "Unexpected error generating the Order."
    );
  }
}
