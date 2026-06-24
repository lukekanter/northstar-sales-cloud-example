/**
 * TerritoryRoutingServiceTest — covers matching, wildcards, priority, the
 * static API, and the invocable. Rules are injected via the @TestVisible
 * override (custom metadata can't be DML'd); one test omits it to exercise
 * the real getAll() path against the deployed seeds.
 */
@IsTest
private class TerritoryRoutingServiceTest {
  // -------------------------------------------------------------------------
  // Matching + priority
  // -------------------------------------------------------------------------

  @IsTest
  static void exactMatchResolvesQueueRoleAndReason() {
    TerritoryRoutingService.rulesOverrideForTest = new List<Revenue_Routing_Rule__mdt>{
      rule(
        'Commercial',
        'NA East',
        'Core Platform',
        20,
        'Commercial_Queue',
        null,
        'comm reason'
      ),
      rule(
        'Enterprise',
        'NA West',
        'Core Platform',
        10,
        null,
        'Northstar_Enterprise_AE',
        'ent reason'
      )
    };

    System.assertEquals(
      'Commercial_Queue',
      TerritoryRoutingService.resolveQueue(
        'Commercial',
        'NA East',
        'Core Platform'
      )
    );
    System.assertEquals(
      'comm reason',
      TerritoryRoutingService.resolveRoutingReason(
        'Commercial',
        'NA East',
        'Core Platform'
      )
    );
    System.assertEquals(
      'Northstar_Enterprise_AE',
      TerritoryRoutingService.resolveRole(
        'Enterprise',
        'NA West',
        'Core Platform'
      )
    );
  }

  @IsTest
  static void lowestPriorityNumberWins() {
    // Two rules match the same input; the lower Priority__c (10) should win.
    TerritoryRoutingService.rulesOverrideForTest = new List<Revenue_Routing_Rule__mdt>{
      rule(
        'Commercial',
        null,
        'Core Platform',
        20,
        'Low_Priority_Queue',
        null,
        'p20'
      ),
      rule(
        'Commercial',
        'NA East',
        'Core Platform',
        10,
        'High_Priority_Queue',
        null,
        'p10'
      )
    };

    System.assertEquals(
      'High_Priority_Queue',
      TerritoryRoutingService.resolveQueue(
        'Commercial',
        'NA East',
        'Core Platform'
      ),
      'The rule with the lower priority number must win.'
    );
  }

  @IsTest
  static void blankRuleFieldIsWildcard() {
    // Region is blank on the rule → matches any region.
    TerritoryRoutingService.rulesOverrideForTest = new List<Revenue_Routing_Rule__mdt>{
      rule(
        'Partner Managed',
        null,
        'Analytics Add-On',
        30,
        'Partner_Referral_Queue',
        null,
        'partner'
      )
    };

    System.assertEquals(
      'Partner_Referral_Queue',
      TerritoryRoutingService.resolveQueue(
        'Partner Managed',
        'EMEA',
        'Analytics Add-On'
      ),
      'A blank Region on the rule should match any input region.'
    );
  }

  @IsTest
  static void noMatchReturnsNull() {
    TerritoryRoutingService.rulesOverrideForTest = new List<Revenue_Routing_Rule__mdt>{
      rule(
        'Commercial',
        'NA East',
        'Core Platform',
        20,
        'Commercial_Queue',
        null,
        'comm'
      )
    };

    System.assertEquals(
      null,
      TerritoryRoutingService.resolveQueue('SMB', 'APAC', 'Usage Overage')
    );
    System.assertEquals(
      null,
      TerritoryRoutingService.resolveRole('SMB', 'APAC', 'Usage Overage')
    );
  }

  // -------------------------------------------------------------------------
  // Real getAll() path against the deployed seeds
  // -------------------------------------------------------------------------

  @IsTest
  static void seededRulesResolveViaGetAll() {
    TerritoryRoutingService.rulesOverrideForTest = null;
    // Commercial / NA East / Core Platform → Commercial_Queue (seed).
    System.assertEquals(
      'Commercial_Queue',
      TerritoryRoutingService.resolveQueue(
        'Commercial',
        'NA East',
        'Core Platform'
      )
    );
  }

  // -------------------------------------------------------------------------
  // Invocable
  // -------------------------------------------------------------------------

  @IsTest
  static void invocableResolvesRoutingBulk() {
    TerritoryRoutingService.rulesOverrideForTest = new List<Revenue_Routing_Rule__mdt>{
      rule(
        'Commercial',
        'NA East',
        'Core Platform',
        20,
        'Commercial_Queue',
        null,
        'comm'
      ),
      rule(
        'Enterprise',
        'NA West',
        'Core Platform',
        10,
        null,
        'Northstar_Enterprise_AE',
        'ent'
      )
    };

    TerritoryRoutingService.RoutingRequest r1 = new TerritoryRoutingService.RoutingRequest();
    r1.segment = 'Commercial';
    r1.region = 'NA East';
    r1.productFamily = 'Core Platform';
    TerritoryRoutingService.RoutingRequest r2 = new TerritoryRoutingService.RoutingRequest();
    r2.segment = 'Enterprise';
    r2.region = 'NA West';
    r2.productFamily = 'Core Platform';
    TerritoryRoutingService.RoutingRequest r3 = new TerritoryRoutingService.RoutingRequest();
    r3.segment = 'SMB';
    r3.region = 'APAC';
    r3.productFamily = 'Usage Overage';

    List<TerritoryRoutingService.RoutingResult> results = TerritoryRoutingService.resolveRouting(
      new List<TerritoryRoutingService.RoutingRequest>{ r1, r2, r3 }
    );

    System.assertEquals(3, results.size());
    System.assertEquals('Commercial_Queue', results[0].targetQueue);
    System.assertEquals('Northstar_Enterprise_AE', results[1].targetRole);
    System.assertEquals('ent', results[1].routingReason);
    System.assertEquals(
      null,
      results[2].targetQueue,
      'No match → null target.'
    );
  }

  // -------------------------------------------------------------------------
  // Helper
  // -------------------------------------------------------------------------

  private static Revenue_Routing_Rule__mdt rule(
    String segment,
    String region,
    String productFamily,
    Decimal priority,
    String targetQueue,
    String targetRole,
    String reason
  ) {
    return new Revenue_Routing_Rule__mdt(
      Segment__c = segment,
      Region__c = region,
      Product_Family__c = productFamily,
      Priority__c = priority,
      Target_Queue__c = targetQueue,
      Target_Role__c = targetRole,
      Routing_Reason__c = reason
    );
  }
}
