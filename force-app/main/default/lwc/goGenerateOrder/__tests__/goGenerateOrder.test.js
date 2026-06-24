import { createElement } from "lwc";
import GoGenerateOrder from "c/goGenerateOrder";
import generateOrderForOpportunity from "@salesforce/apex/GO_GenerateOrderInvocable.generateOrderForOpportunity";
import generateOrderForOrder from "@salesforce/apex/GO_GenerateOrderInvocable.generateOrderForOrder";

// Imperative Apex + the screen-action close event are mocked so we can drive
// the component's success / failure branches deterministically.
jest.mock(
  "@salesforce/apex/GO_GenerateOrderInvocable.generateOrderForOpportunity",
  () => ({ default: jest.fn() }),
  { virtual: true }
);

jest.mock(
  "@salesforce/apex/GO_GenerateOrderInvocable.generateOrderForOrder",
  () => ({ default: jest.fn() }),
  { virtual: true }
);

jest.mock(
  "lightning/actions",
  () => ({
    CloseActionScreenEvent: jest.fn().mockImplementation(function () {
      return new CustomEvent("closeactionscreen");
    })
  }),
  { virtual: true }
);

const OPP_ID = "006000000000001AAA";
const ORDER_ID = "801000000000001AAA";

// Flush several microtask turns so the awaited Apex promise resolves and the
// LWC reactive re-render settles. Avoids setTimeout (banned by @lwc/lwc/no-async-operation).
async function flushPromises() {
  for (let i = 0; i < 5; i += 1) {
    // eslint-disable-next-line no-await-in-loop
    await Promise.resolve();
  }
}

const SOURCE_ORDER_ID = "801000000000002AAA";

function createComponent() {
  const element = createElement("c-go-generate-order", { is: GoGenerateOrder });
  element.objectApiName = "Opportunity";
  element.recordId = OPP_ID;
  document.body.appendChild(element);
  return element;
}

function createOrderComponent() {
  const element = createElement("c-go-generate-order", { is: GoGenerateOrder });
  element.objectApiName = "Order";
  element.recordId = SOURCE_ORDER_ID;
  document.body.appendChild(element);
  return element;
}

describe("c-go-generate-order", () => {
  afterEach(() => {
    while (document.body.firstChild) {
      document.body.removeChild(document.body.firstChild);
    }
    jest.clearAllMocks();
  });

  it("calls the invocable with the record id on open", async () => {
    generateOrderForOpportunity.mockResolvedValue({
      success: true,
      orderId: ORDER_ID
    });

    createComponent();
    await flushPromises();

    expect(generateOrderForOpportunity).toHaveBeenCalledWith({
      opportunityId: OPP_ID
    });
  });

  it("does not call the invocable until recordId is available", async () => {
    generateOrderForOpportunity.mockResolvedValue({
      success: true,
      orderId: ORDER_ID
    });

    // Connect with the object context but no recordId — generation must wait.
    const element = createElement("c-go-generate-order", {
      is: GoGenerateOrder
    });
    element.objectApiName = "Opportunity";
    document.body.appendChild(element);
    await flushPromises();
    expect(generateOrderForOpportunity).not.toHaveBeenCalled();

    // Once the id arrives, it fires exactly once.
    element.recordId = OPP_ID;
    await flushPromises();
    expect(generateOrderForOpportunity).toHaveBeenCalledTimes(1);
    expect(generateOrderForOpportunity).toHaveBeenCalledWith({
      opportunityId: OPP_ID
    });
  });

  it("waits for objectApiName before dispatching, so an Order id never hits the Opportunity path", async () => {
    generateOrderForOrder.mockResolvedValue({
      success: false,
      errorCode: "ORDER_ALREADY_EXISTS",
      orderId: ORDER_ID,
      errorMessage: "An Order (ON-1) already exists."
    });

    // recordId (an Order id) arrives BEFORE objectApiName — the component must
    // not fire yet, or it would send the Order id to generateOrderForOpportunity.
    const element = createElement("c-go-generate-order", {
      is: GoGenerateOrder
    });
    element.recordId = SOURCE_ORDER_ID;
    document.body.appendChild(element);
    await flushPromises();
    expect(generateOrderForOpportunity).not.toHaveBeenCalled();
    expect(generateOrderForOrder).not.toHaveBeenCalled();

    // Once the Order context lands, it dispatches to the Order entry point only.
    element.objectApiName = "Order";
    await flushPromises();
    expect(generateOrderForOpportunity).not.toHaveBeenCalled();
    expect(generateOrderForOrder).toHaveBeenCalledTimes(1);
    expect(generateOrderForOrder).toHaveBeenCalledWith({
      orderId: SOURCE_ORDER_ID
    });
  });

  it("closes the action and shows no error on success", async () => {
    generateOrderForOpportunity.mockResolvedValue({
      success: true,
      orderId: ORDER_ID
    });

    const element = createComponent();
    const closeHandler = jest.fn();
    element.addEventListener("closeactionscreen", closeHandler);
    await flushPromises();

    expect(closeHandler).toHaveBeenCalled();
    expect(
      element.shadowRoot.querySelector(".slds-text-color_error")
    ).toBeNull();
  });

  it("renders the invocable error message on a handled failure", async () => {
    generateOrderForOpportunity.mockResolvedValue({
      success: false,
      errorCode: "NO_PRODUCTS",
      errorMessage: "This Opportunity has no products to put on an Order."
    });

    const element = createComponent();
    await flushPromises();

    const error = element.shadowRoot.querySelector(".slds-text-color_error");
    expect(error).not.toBeNull();
    expect(error.textContent).toContain("no products");
  });

  it("renders a fallback message when the Apex call rejects", async () => {
    generateOrderForOpportunity.mockRejectedValue({
      body: { message: "boom" }
    });

    const element = createComponent();
    await flushPromises();

    const error = element.shadowRoot.querySelector(".slds-text-color_error");
    expect(error).not.toBeNull();
    expect(error.textContent).toContain("boom");
  });

  it("calls the Order entry point with the order id when on an Order", async () => {
    generateOrderForOrder.mockResolvedValue({
      success: false,
      errorCode: "ORDER_ALREADY_EXISTS",
      orderId: ORDER_ID,
      errorMessage: "An Order (ON-1) already exists."
    });

    createOrderComponent();
    await flushPromises();

    expect(generateOrderForOrder).toHaveBeenCalledWith({
      orderId: SOURCE_ORDER_ID
    });
    expect(generateOrderForOpportunity).not.toHaveBeenCalled();
  });

  it("opens the existing Order (no error) on ORDER_ALREADY_EXISTS from an Order", async () => {
    generateOrderForOrder.mockResolvedValue({
      success: false,
      errorCode: "ORDER_ALREADY_EXISTS",
      orderId: ORDER_ID,
      errorMessage: "An Order (ON-1) already exists."
    });

    const element = createOrderComponent();
    const closeHandler = jest.fn();
    element.addEventListener("closeactionscreen", closeHandler);
    await flushPromises();

    expect(closeHandler).toHaveBeenCalled();
    expect(
      element.shadowRoot.querySelector(".slds-text-color_error")
    ).toBeNull();
  });

  it("renders the error inline when an Order has no source Opportunity", async () => {
    generateOrderForOrder.mockResolvedValue({
      success: false,
      errorCode: "NO_SOURCE_OPPORTUNITY",
      errorMessage: "This Order has no source Opportunity to regenerate from."
    });

    const element = createOrderComponent();
    await flushPromises();

    const error = element.shadowRoot.querySelector(".slds-text-color_error");
    expect(error).not.toBeNull();
    expect(error.textContent).toContain("no source Opportunity");
  });
});
