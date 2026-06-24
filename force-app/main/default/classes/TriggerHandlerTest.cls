/**
 * Unit tests for the ported TriggerHandler framework base class.
 *
 * Coverage targets:
 *  - dispatch to every overrideable context method (the 7 contexts),
 *  - maxLoopCount enforcement / clearMaxLoopCount,
 *  - the bypass API (bypass / clearBypass / isBypassed / clearAllBypasses),
 *  - the "called outside of Trigger execution" guard,
 *  - the inner LoopCount helper.
 *
 * Because these tests run outside an actual DML trigger, they drive the
 * framework through the @TestVisible setTriggerContext(ctx, testMode) hook,
 * exactly as the upstream framework's own tests do.
 */
@IsTest
private class TriggerHandlerTest {
  private static TestHandler handler;

  static {
    handler = new TestHandler();
    // forces the isTriggerExecuting flag to true so we can drive contexts
    handler.isTriggerExecuting = true;
  }

  /***************************************
   * context dispatch
   ***************************************/

  @IsTest
  static void dispatchesBeforeInsert() {
    handler.setTriggerContext('before insert', true);
    handler.run();
    System.assertEquals(
      'beforeInsert',
      handler.lastMethodCalled,
      'before insert context should dispatch beforeInsert()'
    );
  }

  @IsTest
  static void dispatchesBeforeUpdate() {
    handler.setTriggerContext('before update', true);
    handler.run();
    System.assertEquals('beforeUpdate', handler.lastMethodCalled);
  }

  @IsTest
  static void dispatchesBeforeDelete() {
    handler.setTriggerContext('before delete', true);
    handler.run();
    System.assertEquals('beforeDelete', handler.lastMethodCalled);
  }

  @IsTest
  static void dispatchesAfterInsert() {
    handler.setTriggerContext('after insert', true);
    handler.run();
    System.assertEquals('afterInsert', handler.lastMethodCalled);
  }

  @IsTest
  static void dispatchesAfterUpdate() {
    handler.setTriggerContext('after update', true);
    handler.run();
    System.assertEquals('afterUpdate', handler.lastMethodCalled);
  }

  @IsTest
  static void dispatchesAfterDelete() {
    handler.setTriggerContext('after delete', true);
    handler.run();
    System.assertEquals('afterDelete', handler.lastMethodCalled);
  }

  @IsTest
  static void dispatchesAfterUndelete() {
    handler.setTriggerContext('after undelete', true);
    handler.run();
    System.assertEquals('afterUndelete', handler.lastMethodCalled);
  }

  /***************************************
   * guard: outside trigger execution
   ***************************************/

  @IsTest
  static void throwsWhenNotInTriggerContext() {
    // a fresh handler built outside a trigger has no context and is not executing
    TestHandler outside = new TestHandler();
    Boolean threw = false;
    try {
      outside.run();
    } catch (TriggerHandler.TriggerHandlerException e) {
      threw = true;
      System.assert(
        e.getMessage().contains('outside of Trigger execution'),
        'expected the outside-of-trigger guard message, got: ' + e.getMessage()
      );
    }
    System.assert(threw, 'run() outside a trigger should throw');
    System.assertEquals(
      null,
      outside.lastMethodCalled,
      'no context method should fire outside a trigger'
    );
  }

  /***************************************
   * loop count
   ***************************************/

  @IsTest
  static void enforcesMaxLoopCount() {
    handler.setTriggerContext('before insert', true);
    handler.setMaxLoopCount(2);

    // two runs are within the cap
    handler.run();
    handler.run();

    // the third run exceeds the cap
    Boolean threw = false;
    try {
      handler.run();
    } catch (TriggerHandler.TriggerHandlerException e) {
      threw = true;
      System.assert(
        e.getMessage().contains('Maximum loop count'),
        'expected loop-count message, got: ' + e.getMessage()
      );
    }
    System.assert(threw, 'exceeding the loop cap should throw');
  }

  @IsTest
  static void clearMaxLoopCountRemovesCap() {
    handler.setTriggerContext('before insert', true);
    handler.setMaxLoopCount(1);
    handler.clearMaxLoopCount();

    // with the cap cleared, repeated runs must not throw
    for (Integer i = 0; i < 5; i++) {
      handler.run();
    }
    System.assertEquals(
      'beforeInsert',
      handler.lastMethodCalled,
      'handler should keep running after the cap is cleared'
    );
  }

  /***************************************
   * bypass API
   ***************************************/

  @IsTest
  static void bypassSuppressesHandler() {
    handler.setTriggerContext('before insert', true);

    // derive the handler name exactly as the framework does
    String handlerName = handler.getHandlerName();

    TriggerHandler.bypass(handlerName);
    System.assertEquals(
      true,
      TriggerHandler.isBypassed(handlerName),
      'handler should report as bypassed'
    );

    handler.run();
    System.assertEquals(
      null,
      handler.lastMethodCalled,
      'a bypassed handler must not dispatch'
    );

    TriggerHandler.clearBypass(handlerName);
    System.assertEquals(
      false,
      TriggerHandler.isBypassed(handlerName),
      'handler should no longer be bypassed'
    );

    handler.run();
    System.assertEquals(
      'beforeInsert',
      handler.lastMethodCalled,
      'handler should dispatch once the bypass is cleared'
    );
  }

  @IsTest
  static void clearAllBypassesResetsEverything() {
    TriggerHandler.bypass('HandlerA');
    TriggerHandler.bypass('HandlerB');
    System.assertEquals(true, TriggerHandler.isBypassed('HandlerA'));
    System.assertEquals(true, TriggerHandler.isBypassed('HandlerB'));

    TriggerHandler.clearAllBypasses();
    System.assertEquals(false, TriggerHandler.isBypassed('HandlerA'));
    System.assertEquals(false, TriggerHandler.isBypassed('HandlerB'));
  }

  /***************************************
   * inner LoopCount helper
   ***************************************/

  @IsTest
  static void loopCountHelperTracksMaxAndCount() {
    TriggerHandler.LoopCount lc = new TriggerHandler.LoopCount();
    System.assertEquals(5, lc.getMax(), 'default max is 5');
    System.assertEquals(0, lc.getCount(), 'starts at zero');

    lc.setMax(1);
    System.assertEquals(1, lc.getMax());

    System.assertEquals(false, lc.increment(), 'first increment is within cap');
    System.assertEquals(1, lc.getCount());
    System.assertEquals(true, lc.increment(), 'second increment exceeds cap');

    // a negative max disables the cap
    TriggerHandler.LoopCount unbounded = new TriggerHandler.LoopCount(-1);
    unbounded.increment();
    unbounded.increment();
    System.assertEquals(
      false,
      unbounded.exceeded(),
      'a negative max never reports exceeded'
    );
  }

  /***************************************
   * base no-op context methods
   ***************************************/

  @IsTest
  static void baseContextMethodsAreNoOps() {
    // a handler that overrides nothing exercises the base virtual bodies,
    // which must run without side effects in every context
    String[] contexts = new List<String>{
      'before insert',
      'before update',
      'before delete',
      'after insert',
      'after update',
      'after delete',
      'after undelete'
    };
    for (String ctx : contexts) {
      BareHandler bare = new BareHandler();
      bare.setTriggerContext(ctx, true);
      bare.run(); // dispatches to the un-overridden base method
    }
    // nothing to assert beyond "did not throw"; the base methods are no-ops
    System.assert(true, 'base context methods executed without error');
  }

  /***************************************
   * test fixtures
   ***************************************/

  // handler that overrides nothing, so run() dispatches to the base no-ops
  private class BareHandler extends TriggerHandler {
  }

  // concrete handler that records which context method fired
  private class TestHandler extends TriggerHandler {
    public String lastMethodCalled;

    public override void beforeInsert() {
      this.lastMethodCalled = 'beforeInsert';
    }
    public override void beforeUpdate() {
      this.lastMethodCalled = 'beforeUpdate';
    }
    public override void beforeDelete() {
      this.lastMethodCalled = 'beforeDelete';
    }
    public override void afterInsert() {
      this.lastMethodCalled = 'afterInsert';
    }
    public override void afterUpdate() {
      this.lastMethodCalled = 'afterUpdate';
    }
    public override void afterDelete() {
      this.lastMethodCalled = 'afterDelete';
    }
    public override void afterUndelete() {
      this.lastMethodCalled = 'afterUndelete';
    }
  }
}
