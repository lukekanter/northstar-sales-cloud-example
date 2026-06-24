/**
 * TerritoryRoutingService — resolves the routing target for a deal from
 * `Revenue_Routing_Rule__mdt`, so flows and triggers share one source of
 * routing truth (services, Phase 2 task 7).
 *
 * Matching: a rule matches an input when each of its Segment / Region /
 * Product_Family fields is either blank (wildcard) or equal to the input.
 * Among the matches the **lowest `Priority__c`** wins — per the field's own
 * doc, "sorts ascending and applies the first match; lower number = higher
 * priority". A rule may target a queue OR a role (the seeds use one or the
 * other), so both are exposed.
 *
 * Rules are cached in a static for the transaction. A `@TestVisible` override
 * lets tests inject rules without DML (custom metadata can't be inserted).
 */
public with sharing class TerritoryRoutingService {
  @TestVisible
  private static List<Revenue_Routing_Rule__mdt> rulesOverrideForTest;
  private static List<Revenue_Routing_Rule__mdt> cachedRules;

  // Null priority sorts last (lowest precedence).
  @TestVisible
  private static final Decimal LOWEST_PRECEDENCE = 999999;

  // -------------------------------------------------------------------------
  // Static API (called from Apex)
  // -------------------------------------------------------------------------

  public static String resolveQueue(
    String segment,
    String region,
    String productFamily
  ) {
    Revenue_Routing_Rule__mdt rule = resolveRule(
      segment,
      region,
      productFamily
    );
    return rule == null ? null : rule.Target_Queue__c;
  }

  public static String resolveRole(
    String segment,
    String region,
    String productFamily
  ) {
    Revenue_Routing_Rule__mdt rule = resolveRule(
      segment,
      region,
      productFamily
    );
    return rule == null ? null : rule.Target_Role__c;
  }

  public static String resolveRoutingReason(
    String segment,
    String region,
    String productFamily
  ) {
    Revenue_Routing_Rule__mdt rule = resolveRule(
      segment,
      region,
      productFamily
    );
    return rule == null ? null : rule.Routing_Reason__c;
  }

  // -------------------------------------------------------------------------
  // Flow API
  // -------------------------------------------------------------------------

  public class RoutingRequest {
    @InvocableVariable(required=true label='Segment')
    public String segment;
    @InvocableVariable(label='Region')
    public String region;
    @InvocableVariable(label='Product Family')
    public String productFamily;
  }

  public class RoutingResult {
    @InvocableVariable
    public String targetQueue;
    @InvocableVariable
    public String targetRole;
    @InvocableVariable
    public String routingReason;
  }

  @InvocableMethod(
    label='Resolve Revenue Routing'
    description='Returns the highest-priority Revenue_Routing_Rule__mdt match (queue, role, reason) for a segment + region + product family.'
  )
  public static List<RoutingResult> resolveRouting(
    List<RoutingRequest> requests
  ) {
    List<RoutingResult> out = new List<RoutingResult>();
    for (RoutingRequest req : requests) {
      Revenue_Routing_Rule__mdt rule = resolveRule(
        req.segment,
        req.region,
        req.productFamily
      );
      RoutingResult result = new RoutingResult();
      if (rule != null) {
        result.targetQueue = rule.Target_Queue__c;
        result.targetRole = rule.Target_Role__c;
        result.routingReason = rule.Routing_Reason__c;
      }
      out.add(result);
    }
    return out;
  }

  // -------------------------------------------------------------------------
  // Matching
  // -------------------------------------------------------------------------

  @TestVisible
  private static Revenue_Routing_Rule__mdt resolveRule(
    String segment,
    String region,
    String productFamily
  ) {
    Revenue_Routing_Rule__mdt best;
    for (Revenue_Routing_Rule__mdt rule : rules()) {
      if (!matches(rule, segment, region, productFamily)) {
        continue;
      }
      if (best == null || priorityOf(rule) < priorityOf(best)) {
        best = rule;
      }
    }
    return best;
  }

  private static Boolean matches(
    Revenue_Routing_Rule__mdt rule,
    String segment,
    String region,
    String productFamily
  ) {
    return fieldMatches(rule.Segment__c, segment) &&
      fieldMatches(rule.Region__c, region) &&
      fieldMatches(rule.Product_Family__c, productFamily);
  }

  // A blank rule field is a wildcard that matches any input value.
  private static Boolean fieldMatches(String ruleValue, String inputValue) {
    return String.isBlank(ruleValue) || ruleValue == inputValue;
  }

  private static Decimal priorityOf(Revenue_Routing_Rule__mdt rule) {
    return rule.Priority__c == null ? LOWEST_PRECEDENCE : rule.Priority__c;
  }

  private static List<Revenue_Routing_Rule__mdt> rules() {
    if (rulesOverrideForTest != null) {
      return rulesOverrideForTest;
    }
    if (cachedRules == null) {
      cachedRules = Revenue_Routing_Rule__mdt.getAll().values();
    }
    return cachedRules;
  }
}
