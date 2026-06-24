/**
 * GO_GenerateOrderInvocable
 *
 * Adapted from the open-source "sfdc-generate-order" accelerator
 * (https://github.com/caretgrowth/sfdc-generate-order) — MIT License,
 * Copyright (c) 2018 Mike Simpson. See LICENSES/sfdc-generate-order-LICENSE.txt
 * for the full text and for the pinned SHA.
 *
 * "Generate Order from Opportunity". Builds a Draft
 * Order plus Order Products from an Opportunity, sourced from the primary
 * accepted Quote (Quote Line Items) when one exists, otherwise from the
 * Opportunity's Products. This models the common real-world case where a
 * company hand-builds simple order generation instead of buying CPQ.
 *
 * Exposed two ways:
 *   - @InvocableMethod `generate` — the stable binding the Closed Won
 * orchestration flow calls. Bulk-safe: one set of queries
 *     all rows, one insert for Orders, one for Order Products.
 *   - @AuraEnabled `generateOrderForOpportunity` — backs the Generate_Order
 *     quick action (LWC `goGenerateOrder`).
 *
 * Five realistic failure paths each return a stable `errorCode`
 * plus a custom-label-backed `errorMessage`, so callers branch on the code and
 * surface the (translatable) message.
 */
public with sharing class GO_GenerateOrderInvocable {
  // Billing cadences the simple generator can model. "Multi-Year Upfront"
  // (and a null cadence) are intentionally unsupported — they need bespoke
  // revenue-schedule handling this accelerator does not provide.
  private static final Set<String> SUPPORTED_BILLING_FREQUENCIES = new Set<String>{
    'Monthly',
    'Quarterly',
    'Semi-Annual',
    'Annual'
  };

  // Order.Name is a standard field capped at 80 characters.
  private static final Integer ORDER_NAME_MAX = 80;

  // Stable error codes — callers (e.g. the Closed Won flow) branch on these;
  // the matching errorMessage comes from a CustomLabel so it stays translatable.
  @TestVisible
  static final String ERR_INVALID_BILL_TO = 'INVALID_BILL_TO_ACCOUNT';
  @TestVisible
  static final String ERR_NO_CONTRACT_START = 'NO_ACTIVE_CONTRACT_START_DATE';
  @TestVisible
  static final String ERR_MISSING_QUOTE = 'MISSING_PRIMARY_QUOTE';
  @TestVisible
  static final String ERR_UNSUPPORTED_FREQ = 'UNSUPPORTED_BILLING_FREQUENCY';
  @TestVisible
  static final String ERR_NO_PRODUCTS = 'NO_PRODUCTS';
  // Idempotency guard: an Order already sourced from this
  // Opportunity. Not a hard failure of the same kind as the five above — it
  // means a prior Generate Order (a repeat quick-action click, or the Closed Won
  // flow that already ran) created the Order, so we surface that Order instead
  // of inserting a duplicate.
  @TestVisible
  static final String ERR_ORDER_EXISTS = 'ORDER_ALREADY_EXISTS';
  // Order-context re-generate guard. The Order quick action
  // resolves the source Opportunity from Order.Source_Opportunity__c; an Order
  // created by hand (or whose source was cleared) has nothing to re-generate
  // from, so the entry point returns this coded result instead of querying on a
  // null id.
  @TestVisible
  static final String ERR_NO_SOURCE_OPP = 'NO_SOURCE_OPPORTUNITY';

  public class Request {
    @InvocableVariable(required=true label='Opportunity Id')
    public Id opportunityId;

    @InvocableVariable(
      label='Require Accepted Quote'
      description='When true, fail with MISSING_PRIMARY_QUOTE if there is no primary accepted Quote instead of falling back to Opportunity Products.'
    )
    public Boolean requireAcceptedQuote;
  }

  public class Result {
    @InvocableVariable(label='Success')
    @AuraEnabled
    public Boolean success;

    @InvocableVariable(label='Order Id')
    @AuraEnabled
    public Id orderId;

    @InvocableVariable(label='Error Code')
    @AuraEnabled
    public String errorCode;

    @InvocableVariable(label='Error Message')
    @AuraEnabled
    public String errorMessage;
  }

  // Internal carrier for a row that passed all guards and is ready to insert.
  private class PreparedOrder {
    Order ord;
    List<OrderItem> items;
    Result result;
  }

  // A later Request row that names an Opportunity already claimed by an earlier
  // row in the SAME bulk call. Its result is resolved
  // after the insert, once the reserved Order's id/number is known.
  private class DeferredDuplicate {
    Result result;
    Id opportunityId;
  }

  @InvocableMethod(
    label='Generate Order from Opportunity'
    description='Creates a Draft Order and Order Products from an Opportunity\'s primary accepted Quote (or Opportunity Products as a fallback). Returns a per-row success flag plus a stable errorCode/errorMessage for the five failure paths.'
    category='Northstar Orders'
  )
  public static List<Result> generate(List<Request> requests) {
    List<Result> results = new List<Result>();
    if (requests == null || requests.isEmpty()) {
      return results;
    }

    Set<Id> oppIds = new Set<Id>();
    for (Request req : requests) {
      if (req != null && req.opportunityId != null) {
        oppIds.add(req.opportunityId);
      }
    }

    // FOR UPDATE locks the source Opportunity rows so two
    // concurrent generate() transactions for the same Opportunity (e.g. the
    // quick action and the Closed Won flow firing near-simultaneously) serialize:
    // the second blocks until the first commits, then its idempotency lookup
    // below sees the committed Order. Order.Source_Opportunity__c is a plain
    // lookup with no DB-level uniqueness, so without this the pre-insert check
    // could race. Full DB-enforced uniqueness stays the deferred approach 3.
    Map<Id, Opportunity> oppsById = new Map<Id, Opportunity>(
      [
        SELECT
          Id,
          Name,
          AccountId,
          Pricebook2Id,
          ContractId,
          SyncedQuoteId,
          Billing_Frequency__c,
          Implementation_Package__c,
          Support_Tier__c,
          Sales_Motion__c,
          Contract.Status,
          Contract.StartDate,
          Contract.EndDate,
          Contract.Subscription_End_Date__c
        FROM Opportunity
        WHERE Id IN :oppIds
        FOR UPDATE
      ]
    );

    Map<Id, List<Quote>> acceptedQuotesByOpp = new Map<Id, List<Quote>>();
    for (Quote q : [
      SELECT
        Id,
        OpportunityId,
        Status,
        Pricebook2Id,
        Billing_Frequency__c,
        Implementation_Package__c,
        Premium_Support_Tier__c
      FROM Quote
      WHERE OpportunityId IN :oppIds AND Status = 'Accepted'
      ORDER BY CreatedDate ASC
    ]) {
      if (!acceptedQuotesByOpp.containsKey(q.OpportunityId)) {
        acceptedQuotesByOpp.put(q.OpportunityId, new List<Quote>());
      }
      acceptedQuotesByOpp.get(q.OpportunityId).add(q);
    }

    Set<Id> acceptedQuoteIds = new Set<Id>();
    for (List<Quote> quotes : acceptedQuotesByOpp.values()) {
      for (Quote q : quotes) {
        acceptedQuoteIds.add(q.Id);
      }
    }

    Map<Id, List<QuoteLineItem>> qlisByQuote = new Map<Id, List<QuoteLineItem>>();
    if (!acceptedQuoteIds.isEmpty()) {
      for (QuoteLineItem qli : [
        SELECT
          Id,
          QuoteId,
          PricebookEntryId,
          Quantity,
          UnitPrice,
          Description,
          ServiceDate,
          Revenue_Type__c,
          Support_Tier__c,
          Implementation_Phase__c,
          Billing_Start_Offset_Days__c,
          Usage_Band__c
        FROM QuoteLineItem
        WHERE QuoteId IN :acceptedQuoteIds
      ]) {
        if (!qlisByQuote.containsKey(qli.QuoteId)) {
          qlisByQuote.put(qli.QuoteId, new List<QuoteLineItem>());
        }
        qlisByQuote.get(qli.QuoteId).add(qli);
      }
    }

    Map<Id, List<OpportunityLineItem>> olisByOpp = new Map<Id, List<OpportunityLineItem>>();
    for (OpportunityLineItem oli : [
      SELECT
        Id,
        OpportunityId,
        PricebookEntryId,
        Quantity,
        UnitPrice,
        Description,
        ServiceDate,
        Revenue_Type__c,
        Support_Tier__c,
        Implementation_Phase__c,
        Billing_Start_Offset_Days__c,
        Usage_Band__c
      FROM OpportunityLineItem
      WHERE OpportunityId IN :oppIds
    ]) {
      if (!olisByOpp.containsKey(oli.OpportunityId)) {
        olisByOpp.put(oli.OpportunityId, new List<OpportunityLineItem>());
      }
      olisByOpp.get(oli.OpportunityId).add(oli);
    }

    // Idempotency lookup. One query across all input
    // Opportunities for an Order already sourced from them. Earliest wins so a
    // repeat click surfaces the original Order; if pre-existing duplicates
    // exist we still point at the first one created.
    Map<Id, Order> existingOrderByOpp = new Map<Id, Order>();
    for (Order existing : [
      SELECT Id, OrderNumber, Source_Opportunity__c
      FROM Order
      WHERE Source_Opportunity__c IN :oppIds
      ORDER BY CreatedDate ASC
    ]) {
      if (!existingOrderByOpp.containsKey(existing.Source_Opportunity__c)) {
        existingOrderByOpp.put(existing.Source_Opportunity__c, existing);
      }
    }

    List<PreparedOrder> prepared = new List<PreparedOrder>();
    // Tracks which Opportunities have already been claimed by a prepared row in
    // THIS bulk call, plus the later rows that named the same Opportunity, so a
    // duplicate Request row cannot slip a second Order past the query-based
    // Guard 0 (which sees only committed Orders).
    Map<Id, PreparedOrder> preparedByOpp = new Map<Id, PreparedOrder>();
    List<DeferredDuplicate> deferredDuplicates = new List<DeferredDuplicate>();

    for (Request req : requests) {
      Result res = new Result();
      res.success = false;
      results.add(res);

      Opportunity opp = (req == null ||
        req.opportunityId == null)
        ? null
        : oppsById.get(req.opportunityId);

      if (opp != null) {
        // Guard 0 — idempotency. If an Order already
        // traces to this Opportunity, a prior Generate Order (a repeat
        // quick-action click or the Closed Won flow) already committed one.
        // Surface that Order via orderId and a coded result instead of inserting
        // a duplicate. success stays false — we created nothing. The Closed Won
        // flow proceeds on this code (it means an Order is present), and the LWC
        // shows the message inline. A null/unknown Opportunity has no key here
        // and falls through to Guard 1.
        Order existing = existingOrderByOpp.get(opp.Id);
        if (existing != null) {
          res.orderId = existing.Id;
          setError(
            res,
            ERR_ORDER_EXISTS,
            String.format(
              Label.GO_Error_OrderAlreadyExists,
              new List<String>{ existing.OrderNumber }
            )
          );
          continue;
        }

        // Guard 0b — an earlier Request row in THIS same bulk call already
        // claimed this Opportunity. No Order is committed yet, so Guard 0's
        // query missed it; the first row keeps its reservation and this
        // duplicate row is resolved against that Order after the insert.
        if (preparedByOpp.containsKey(opp.Id)) {
          DeferredDuplicate dup = new DeferredDuplicate();
          dup.result = res;
          dup.opportunityId = opp.Id;
          deferredDuplicates.add(dup);
          continue;
        }
      }

      // Guard 1 — bill-to account. A null/unknown Opportunity also surfaces
      // here: with no resolvable Account there is nothing to bill.
      if (opp == null || opp.AccountId == null) {
        setError(res, ERR_INVALID_BILL_TO, Label.GO_Error_InvalidBillToAccount);
        continue;
      }

      // Guard 2 — active contract start date (Order.EffectiveDate derives from it).
      if (
        opp.ContractId == null ||
        opp.Contract.Status != 'Activated' ||
        opp.Contract.StartDate == null
      ) {
        setError(
          res,
          ERR_NO_CONTRACT_START,
          Label.GO_Error_NoActiveContractStartDate
        );
        continue;
      }

      Quote primaryQuote = resolvePrimaryQuote(opp, acceptedQuotesByOpp);
      Boolean useQuote = primaryQuote != null;

      // Guard 3 — missing primary quote (only when the caller demands one).
      if (req.requireAcceptedQuote == true && primaryQuote == null) {
        setError(res, ERR_MISSING_QUOTE, Label.GO_Error_MissingPrimaryQuote);
        continue;
      }

      String billingFreq = useQuote
        ? primaryQuote.Billing_Frequency__c
        : opp.Billing_Frequency__c;

      // Guard 4 — unsupported billing frequency.
      if (
        billingFreq == null ||
        !SUPPORTED_BILLING_FREQUENCIES.contains(billingFreq)
      ) {
        setError(
          res,
          ERR_UNSUPPORTED_FREQ,
          Label.GO_Error_UnsupportedBillingFrequency
        );
        continue;
      }

      List<OrderItem> items = new List<OrderItem>();
      if (useQuote) {
        List<QuoteLineItem> qlis = qlisByQuote.get(primaryQuote.Id);
        if (qlis != null) {
          for (QuoteLineItem qli : qlis) {
            items.add(orderItemFromQuoteLine(qli));
          }
        }
      } else {
        List<OpportunityLineItem> olis = olisByOpp.get(opp.Id);
        if (olis != null) {
          for (OpportunityLineItem oli : olis) {
            items.add(orderItemFromOppLine(oli));
          }
        }
      }

      // Guard 5 — no products on the chosen source.
      if (items.isEmpty()) {
        setError(res, ERR_NO_PRODUCTS, Label.GO_Error_NoProducts);
        continue;
      }

      Order ord = new Order(
        AccountId = opp.AccountId,
        Pricebook2Id = (useQuote && primaryQuote.Pricebook2Id != null)
          ? primaryQuote.Pricebook2Id
          : opp.Pricebook2Id,
        ContractId = opp.ContractId,
        OpportunityId = opp.Id,
        Name = boundedOrderName(opp.Name),
        Status = 'Draft',
        EffectiveDate = opp.Contract.StartDate,
        EndDate = opp.Contract.EndDate != null
          ? opp.Contract.EndDate
          : opp.Contract.Subscription_End_Date__c,
        Billing_Frequency__c = billingFreq,
        Implementation_Package__c = useQuote
          ? primaryQuote.Implementation_Package__c
          : opp.Implementation_Package__c,
        // Support tier mirrors the Quote's Premium_Support_Tier__c on the quote
        // path, else the Opportunity's tier. Sales motion only lives on the
        // Opportunity, so it always comes from there.
        Support_Tier__c = useQuote
          ? primaryQuote.Premium_Support_Tier__c
          : opp.Support_Tier__c,
        Sales_Motion__c = opp.Sales_Motion__c,
        Source_Opportunity__c = opp.Id,
        Source_Quote__c = useQuote ? primaryQuote.Id : null
      );

      PreparedOrder p = new PreparedOrder();
      p.ord = ord;
      p.items = items;
      p.result = res;
      prepared.add(p);
      preparedByOpp.put(opp.Id, p);
    }

    if (prepared.isEmpty()) {
      return results;
    }

    List<Order> ordersToInsert = new List<Order>();
    for (PreparedOrder p : prepared) {
      ordersToInsert.add(p.ord);
    }
    insert ordersToInsert;

    List<OrderItem> allItems = new List<OrderItem>();
    for (PreparedOrder p : prepared) {
      for (OrderItem oi : p.items) {
        oi.OrderId = p.ord.Id;
        allItems.add(oi);
      }
    }
    if (!allItems.isEmpty()) {
      insert allItems;
    }

    for (PreparedOrder p : prepared) {
      p.result.success = true;
      p.result.orderId = p.ord.Id;
      p.result.errorCode = null;
      p.result.errorMessage = null;
    }

    // Resolve in-batch duplicate rows against the single
    // Order their Opportunity's first row created. OrderNumber is an auto-number
    // not populated on the in-memory record after insert, so re-query once.
    if (!deferredDuplicates.isEmpty()) {
      Set<Id> reservedOrderIds = new Set<Id>();
      for (DeferredDuplicate dup : deferredDuplicates) {
        reservedOrderIds.add(preparedByOpp.get(dup.opportunityId).ord.Id);
      }
      Map<Id, Order> reservedById = new Map<Id, Order>(
        [SELECT Id, OrderNumber FROM Order WHERE Id IN :reservedOrderIds]
      );
      for (DeferredDuplicate dup : deferredDuplicates) {
        Order reserved = reservedById.get(
          preparedByOpp.get(dup.opportunityId).ord.Id
        );
        dup.result.orderId = reserved.Id;
        setError(
          dup.result,
          ERR_ORDER_EXISTS,
          String.format(
            Label.GO_Error_OrderAlreadyExists,
            new List<String>{ reserved.OrderNumber }
          )
        );
      }
    }

    return results;
  }

  /**
   * Quick-action entry point. Builds an Order for a single Opportunity using
   * the default (quote-preferred, OLI-fallback) behaviour and returns the row
   * result so the LWC can toast and navigate.
   */
  @AuraEnabled
  public static Result generateOrderForOpportunity(Id opportunityId) {
    Request req = new Request();
    req.opportunityId = opportunityId;
    req.requireAcceptedQuote = false;
    List<Result> results = generate(new List<Request>{ req });
    return results.isEmpty() ? null : results[0];
  }

  /**
   * Order-context entry point. Backs the Order `Generate_Order`
   * quick action, where the record in context is the Order, not the
   * Opportunity. Resolves the Order's `Source_Opportunity__c` and delegates to
   * the same `generate()` path. Because the source Opportunity already has this
   * Order, the idempotency guard (Guard 0) returns
   * `ORDER_ALREADY_EXISTS` pointing back at it rather than inserting a
   * duplicate — so this acts as a safe "re-generate / open the Order" action.
   * An Order with no source Opportunity (hand-created, or source cleared) has
   * nothing to re-generate from and returns `NO_SOURCE_OPPORTUNITY`.
   */
  @AuraEnabled
  public static Result generateOrderForOrder(Id orderId) {
    Result res = new Result();
    res.success = false;
    if (orderId == null) {
      setError(res, ERR_NO_SOURCE_OPP, Label.GO_Error_NoSourceOpportunity);
      return res;
    }
    List<Order> orders = [
      SELECT Id, Source_Opportunity__c
      FROM Order
      WHERE Id = :orderId
      LIMIT 1
    ];
    if (orders.isEmpty() || orders[0].Source_Opportunity__c == null) {
      setError(res, ERR_NO_SOURCE_OPP, Label.GO_Error_NoSourceOpportunity);
      return res;
    }
    return generateOrderForOpportunity(orders[0].Source_Opportunity__c);
  }

  private static Quote resolvePrimaryQuote(
    Opportunity opp,
    Map<Id, List<Quote>> acceptedQuotesByOpp
  ) {
    List<Quote> quotes = acceptedQuotesByOpp.get(opp.Id);
    if (quotes == null || quotes.isEmpty()) {
      return null;
    }
    // Prefer the synced quote when it is among the accepted ones; otherwise the
    // newest accepted quote (the list is built in CreatedDate ASC order).
    if (opp.SyncedQuoteId != null) {
      for (Quote q : quotes) {
        if (q.Id == opp.SyncedQuoteId) {
          return q;
        }
      }
    }
    return quotes[quotes.size() - 1];
  }

  private static OrderItem orderItemFromQuoteLine(QuoteLineItem qli) {
    // Product2Id is derived from PricebookEntryId on Order Products and is not
    // writable on insert, so it is intentionally not set here.
    return new OrderItem(
      PricebookEntryId = qli.PricebookEntryId,
      Quantity = qli.Quantity,
      UnitPrice = qli.UnitPrice,
      Description = qli.Description,
      ServiceDate = qli.ServiceDate,
      Revenue_Type__c = qli.Revenue_Type__c,
      Support_Tier__c = qli.Support_Tier__c,
      Implementation_Phase__c = qli.Implementation_Phase__c,
      Billing_Start_Offset_Days__c = qli.Billing_Start_Offset_Days__c,
      Usage_Band__c = qli.Usage_Band__c,
      Source_QuoteLineItem__c = qli.Id
    );
  }

  private static OrderItem orderItemFromOppLine(OpportunityLineItem oli) {
    // Product2Id is derived from PricebookEntryId on Order Products and is not
    // writable on insert, so it is intentionally not set here.
    return new OrderItem(
      PricebookEntryId = oli.PricebookEntryId,
      Quantity = oli.Quantity,
      UnitPrice = oli.UnitPrice,
      Description = oli.Description,
      ServiceDate = oli.ServiceDate,
      Revenue_Type__c = oli.Revenue_Type__c,
      Support_Tier__c = oli.Support_Tier__c,
      Implementation_Phase__c = oli.Implementation_Phase__c,
      Billing_Start_Offset_Days__c = oli.Billing_Start_Offset_Days__c,
      Usage_Band__c = oli.Usage_Band__c,
      Source_OpportunityLineItem__c = oli.Id
    );
  }

  // Order.Name caps at 80 chars while Opportunity.Name allows up to 120, so a
  // long deal name would otherwise blow up the insert with STRING_TOO_LONG.
  private static String boundedOrderName(String oppName) {
    if (oppName == null) {
      return null;
    }
    return oppName.length() > ORDER_NAME_MAX
      ? oppName.substring(0, ORDER_NAME_MAX)
      : oppName;
  }

  private static void setError(Result res, String code, String message) {
    res.success = false;
    res.errorCode = code;
    res.errorMessage = message;
  }
}
