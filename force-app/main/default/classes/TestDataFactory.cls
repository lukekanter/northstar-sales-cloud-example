/**
 * TestDataFactory — central builder of representative, *unsaved* standard
 * SObject records for Apex unit tests. Every later Apex test should construct
 * its Lead → Opportunity → Quote → Order → Contract graphs through these
 * builders rather than hand-rolling record literals, so that required-field
 * defaults live in exactly one place.
 *
 * Conventions
 * -----------
 * - Each builder is `build<Plural>(Integer count)` plus an overload
 *   `build<Plural>(Integer count, Map<String, Object> overrides)`. The map's
 *   keys are API field names; its values replace the per-record defaults
 *   (and can supply required lookups such as `OpportunityId`).
 * - Builders return UNSAVED records. Persist them with `insertAll(...)` or a
 *   plain `insert`. Records that require a parent Id (line items, quotes,
 *   orders, contracts) expect that Id to arrive via the overrides map after
 *   the parent has been inserted.
 * - Unique strings are derived from `Crypto.getRandomLong()` plus a per-record
 *   index so parallel test runs do not collide on uniqueness rules.
 *
 * Builders and their defaults (required fields only — see issue notes; custom
 * fields are added here by the issues that introduce them):
 *   buildAccounts            Name
 *   buildContacts            LastName
 *   buildLeads               LastName, Company, Status(default)
 *   buildOpportunities       Name, StageName=Prospecting, CloseDate=today+30
 *   buildOpportunityLineItems Quantity=1, UnitPrice=100  (needs OpportunityId, PricebookEntryId)
 *   buildQuotes              Name                         (needs OpportunityId; set Pricebook2Id for line items)
 *   buildQuoteLineItems      Quantity=1, UnitPrice=100    (needs QuoteId, PricebookEntryId)
 *   buildOrders              Status=Draft, EffectiveDate=today (needs AccountId; set Pricebook2Id for line items)
 *   buildOrderItems          Quantity=1, UnitPrice=100    (needs OrderId, PricebookEntryId)
 *   buildContracts           Status=Draft, StartDate=today, ContractTerm=12 (needs AccountId)
 *   buildCases               Subject, Status(default)
 *   buildTasks               Subject                      (new in 0015 — needs WhoId or WhatId for most flows)
 *   buildPricebooks          Name, IsActive=true
 *   buildProducts            Name, IsActive=true
 *   buildPricebookEntries    UnitPrice=100, IsActive=true (needs Pricebook2Id, Product2Id)
 *
 * Trigger bypass helpers
 * ----------------------
 * `bypassTriggers`/`restoreTriggers` wrap the per-handler bypass API on
 * TriggerHandler. The framework bypasses by handler NAME — there
 * is no global "bypass everything" flag — so `bypassTriggers` takes the
 * handler name(s) to suppress, and `restoreTriggers()` clears every bypass.
 */
public with sharing class TestDataFactory {
  // Per-transaction base for unique strings; combined with a running index.
  private static final String UNIQUE_BASE = String.valueOf(
    Crypto.getRandomLong()
  );

  /***************************************
   * Builders
   ***************************************/

  public static List<Account> buildAccounts(Integer count) {
    return buildAccounts(count, null);
  }

  public static List<Account> buildAccounts(
    Integer count,
    Map<String, Object> overrides
  ) {
    List<Account> records = new List<Account>();
    for (Integer i = 0; i < count; i++) {
      // Custom-field defaults added per: representative values that
      // exercise the segmentation + health-score paths. Overrides win.
      Account record = new Account(
        Name = 'NS Account ' + suffix(i),
        Customer_Segment__c = 'Commercial',
        Region__c = 'NA East',
        Sales_Motion__c = 'New Logo',
        Partner_Influenced__c = false,
        Support_Tier__c = 'Standard',
        Health_Score__c = 80,
        Renewal_Risk_Level__c = 'Low'
      );
      applyOverrides(record, overrides);
      records.add(record);
    }
    return records;
  }

  public static List<Contact> buildContacts(Integer count) {
    return buildContacts(count, null);
  }

  public static List<Contact> buildContacts(
    Integer count,
    Map<String, Object> overrides
  ) {
    List<Contact> records = new List<Contact>();
    for (Integer i = 0; i < count; i++) {
      Contact record = new Contact(LastName = 'NS Contact ' + suffix(i));
      applyOverrides(record, overrides);
      records.add(record);
    }
    return records;
  }

  public static List<Lead> buildLeads(Integer count) {
    return buildLeads(count, null);
  }

  public static List<Lead> buildLeads(
    Integer count,
    Map<String, Object> overrides
  ) {
    List<Lead> records = new List<Lead>();
    for (Integer i = 0; i < count; i++) {
      // Custom-field defaults added. Overrides win.
      Lead record = new Lead(
        LastName = 'NS Lead ' + suffix(i),
        Company = 'NS Company ' + suffix(i),
        Customer_Segment__c = 'Commercial',
        Region__c = 'NA East',
        Lead_Source_Detail__c = 'Inbound Form',
        Lead_Score__c = 50,
        Requires_AI_Dispatch_Interest__c = false
      );
      applyOverrides(record, overrides);
      records.add(record);
    }
    return records;
  }

  public static List<Opportunity> buildOpportunities(Integer count) {
    return buildOpportunities(count, null);
  }

  public static List<Opportunity> buildOpportunities(
    Integer count,
    Map<String, Object> overrides
  ) {
    List<Opportunity> records = new List<Opportunity>();
    for (Integer i = 0; i < count; i++) {
      // Custom-field defaults added. Overrides win.
      Opportunity record = new Opportunity(
        Name = 'NS Opportunity ' + suffix(i),
        StageName = 'Prospecting',
        CloseDate = Date.today().addDays(30),
        Subscription_Term_Months__c = '12 Months',
        Subscription_Start_Date__c = Date.today(),
        Billing_Frequency__c = 'Annual',
        Implementation_Package__c = 'Quickstart',
        Support_Tier__c = 'Standard',
        Sales_Motion__c = 'New Logo',
        Provisioning_Status__c = 'Not Required',
        Requires_Legal_Review__c = false,
        Requires_Finance_Review__c = false,
        Primary_Quote_Accepted__c = false,
        Partner_Influenced__c = false
      );
      applyOverrides(record, overrides);
      records.add(record);
    }
    return records;
  }

  public static List<OpportunityLineItem> buildOpportunityLineItems(
    Integer count
  ) {
    return buildOpportunityLineItems(count, null);
  }

  public static List<OpportunityLineItem> buildOpportunityLineItems(
    Integer count,
    Map<String, Object> overrides
  ) {
    List<OpportunityLineItem> records = new List<OpportunityLineItem>();
    for (Integer i = 0; i < count; i++) {
      // Custom-field defaults added. Overrides win.
      OpportunityLineItem record = new OpportunityLineItem(
        Quantity = 1,
        UnitPrice = 100,
        Implementation_Phase__c = 'Phase 1',
        Revenue_Type__c = 'Subscription',
        Billing_Start_Offset_Days__c = 0,
        Support_Tier__c = 'Standard'
      );
      applyOverrides(record, overrides);
      records.add(record);
    }
    return records;
  }

  public static List<Quote> buildQuotes(Integer count) {
    return buildQuotes(count, null);
  }

  public static List<Quote> buildQuotes(
    Integer count,
    Map<String, Object> overrides
  ) {
    List<Quote> records = new List<Quote>();
    for (Integer i = 0; i < count; i++) {
      // Custom-field defaults added. Overrides win.
      Quote record = new Quote(
        Name = 'NS Quote ' + suffix(i),
        Subscription_Term_Months__c = '12 Months',
        Billing_Frequency__c = 'Annual',
        Implementation_Package__c = 'Quickstart',
        Premium_Support_Tier__c = 'Standard',
        Legal_Terms_Required__c = false,
        Approval_Status__c = 'Not Required',
        Effective_Date__c = Date.today(),
        Validity_Period_Days__c = 30
      );
      applyOverrides(record, overrides);
      records.add(record);
    }
    return records;
  }

  public static List<QuoteLineItem> buildQuoteLineItems(Integer count) {
    return buildQuoteLineItems(count, null);
  }

  public static List<QuoteLineItem> buildQuoteLineItems(
    Integer count,
    Map<String, Object> overrides
  ) {
    List<QuoteLineItem> records = new List<QuoteLineItem>();
    for (Integer i = 0; i < count; i++) {
      // Custom-field defaults added. Overrides win.
      QuoteLineItem record = new QuoteLineItem(
        Quantity = 1,
        UnitPrice = 100,
        Implementation_Phase__c = 'Phase 1',
        Revenue_Type__c = 'Subscription',
        Billing_Start_Offset_Days__c = 0,
        Support_Tier__c = 'Standard'
      );
      applyOverrides(record, overrides);
      records.add(record);
    }
    return records;
  }

  public static List<Order> buildOrders(Integer count) {
    return buildOrders(count, null);
  }

  public static List<Order> buildOrders(
    Integer count,
    Map<String, Object> overrides
  ) {
    List<Order> records = new List<Order>();
    for (Integer i = 0; i < count; i++) {
      // Custom-field defaults added. Overrides win.
      Order record = new Order(
        Status = 'Draft',
        EffectiveDate = Date.today(),
        Billing_Frequency__c = 'Annual',
        Implementation_Package__c = 'Quickstart',
        Support_Tier__c = 'Standard',
        Provisioning_Status__c = 'Not Required',
        Requires_AI_Dispatch_Setup__c = false,
        Onboarding_Action_Plan_Created__c = false,
        Sales_Motion__c = 'New Logo'
      );
      applyOverrides(record, overrides);
      records.add(record);
    }
    return records;
  }

  public static List<OrderItem> buildOrderItems(Integer count) {
    return buildOrderItems(count, null);
  }

  public static List<OrderItem> buildOrderItems(
    Integer count,
    Map<String, Object> overrides
  ) {
    List<OrderItem> records = new List<OrderItem>();
    for (Integer i = 0; i < count; i++) {
      // Custom-field defaults added. Overrides win.
      OrderItem record = new OrderItem(
        Quantity = 1,
        UnitPrice = 100,
        Implementation_Phase__c = 'Phase 1',
        Revenue_Type__c = 'Subscription',
        Billing_Start_Offset_Days__c = 0,
        Support_Tier__c = 'Standard'
      );
      applyOverrides(record, overrides);
      records.add(record);
    }
    return records;
  }

  public static List<Contract> buildContracts(Integer count) {
    return buildContracts(count, null);
  }

  public static List<Contract> buildContracts(
    Integer count,
    Map<String, Object> overrides
  ) {
    List<Contract> records = new List<Contract>();
    for (Integer i = 0; i < count; i++) {
      // Custom-field defaults added. Overrides win.
      Contract record = new Contract(
        Status = 'Draft',
        StartDate = Date.today(),
        ContractTerm = 12,
        Subscription_Start_Date__c = Date.today(),
        Subscription_End_Date__c = Date.today().addMonths(12).addDays(-1),
        Auto_Renewal_Enabled__c = true,
        Renewal_Created__c = false,
        Support_Tier__c = 'Standard',
        Health_Score__c = 80
      );
      applyOverrides(record, overrides);
      records.add(record);
    }
    return records;
  }

  public static List<Case> buildCases(Integer count) {
    return buildCases(count, null);
  }

  public static List<Case> buildCases(
    Integer count,
    Map<String, Object> overrides
  ) {
    List<Case> records = new List<Case>();
    for (Integer i = 0; i < count; i++) {
      // Custom-field defaults added. Overrides win.
      Case record = new Case(
        Subject = 'NS Case ' + suffix(i),
        Case_Category__c = 'Customer Support',
        Escalated_To_Renewal_Queue__c = false
      );
      applyOverrides(record, overrides);
      records.add(record);
    }
    return records;
  }

  public static List<Task> buildTasks(Integer count) {
    return buildTasks(count, null);
  }

  /**
   * Build standard Task records. Added in to round out the
   * factory for SDR / Action-Plan tests. The three Northstar custom Task
   * fields (Lead_Score_At_Creation__c, Action_Plan_Source__c,
   * Routing_Reason__c) are intentionally left unset — they're stamped by
   * routing/Action-Plan flows, not by the test fixture, and exercising
   * them is the test's job via overrides.
   */
  public static List<Task> buildTasks(
    Integer count,
    Map<String, Object> overrides
  ) {
    List<Task> records = new List<Task>();
    for (Integer i = 0; i < count; i++) {
      Task record = new Task(Subject = 'NS Task ' + suffix(i));
      applyOverrides(record, overrides);
      records.add(record);
    }
    return records;
  }

  public static List<Pricebook2> buildPricebooks(Integer count) {
    return buildPricebooks(count, null);
  }

  public static List<Pricebook2> buildPricebooks(
    Integer count,
    Map<String, Object> overrides
  ) {
    List<Pricebook2> records = new List<Pricebook2>();
    for (Integer i = 0; i < count; i++) {
      Pricebook2 record = new Pricebook2(
        Name = 'NS Pricebook ' + suffix(i),
        IsActive = true
      );
      applyOverrides(record, overrides);
      records.add(record);
    }
    return records;
  }

  public static List<Product2> buildProducts(Integer count) {
    return buildProducts(count, null);
  }

  public static List<Product2> buildProducts(
    Integer count,
    Map<String, Object> overrides
  ) {
    List<Product2> records = new List<Product2>();
    for (Integer i = 0; i < count; i++) {
      Product2 record = new Product2(
        Name = 'NS Product ' + suffix(i),
        IsActive = true
      );
      applyOverrides(record, overrides);
      records.add(record);
    }
    return records;
  }

  public static List<PricebookEntry> buildPricebookEntries(Integer count) {
    return buildPricebookEntries(count, null);
  }

  public static List<PricebookEntry> buildPricebookEntries(
    Integer count,
    Map<String, Object> overrides
  ) {
    List<PricebookEntry> records = new List<PricebookEntry>();
    for (Integer i = 0; i < count; i++) {
      PricebookEntry record = new PricebookEntry(
        UnitPrice = 100,
        IsActive = true
      );
      applyOverrides(record, overrides);
      records.add(record);
    }
    return records;
  }

  /***************************************
   * DML helper
   ***************************************/

  /**
   * Insert a heterogeneous list of records, grouped by SObjectType (a single
   * `insert` call cannot mix types). Records are inserted one type at a time;
   * the caller is responsible for inserting parents before children.
   */
  public static void insertAll(List<SObject> records) {
    if (records == null || records.isEmpty()) {
      return;
    }
    Map<SObjectType, List<SObject>> byType = new Map<SObjectType, List<SObject>>();
    for (SObject record : records) {
      SObjectType sot = record.getSObjectType();
      if (!byType.containsKey(sot)) {
        byType.put(sot, new List<SObject>());
      }
      byType.get(sot).add(record);
    }
    for (SObjectType sot : byType.keySet()) {
      insert byType.get(sot);
    }
  }

  /***************************************
   * Trigger bypass wrappers (framework)
   ***************************************/

  /** Suppress one trigger handler by name for the rest of the transaction. */
  public static void bypassTriggers(String handlerName) {
    TriggerHandler.bypass(handlerName);
  }

  /** Suppress several trigger handlers by name for the rest of the transaction. */
  public static void bypassTriggers(List<String> handlerNames) {
    if (handlerNames == null) {
      return;
    }
    for (String handlerName : handlerNames) {
      TriggerHandler.bypass(handlerName);
    }
  }

  /** Re-enable every handler suppressed via bypassTriggers. */
  public static void restoreTriggers() {
    TriggerHandler.clearAllBypasses();
  }

  /***************************************
   * private helpers
   ***************************************/

  private static void applyOverrides(
    SObject record,
    Map<String, Object> overrides
  ) {
    if (overrides == null) {
      return;
    }
    for (String field : overrides.keySet()) {
      record.put(field, overrides.get(field));
    }
  }

  // A per-record unique token: transaction base + record index.
  private static String suffix(Integer index) {
    return UNIQUE_BASE + '-' + index;
  }
}
