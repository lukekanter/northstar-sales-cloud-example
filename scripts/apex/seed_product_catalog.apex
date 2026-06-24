// seed_product_catalog.apex
// Idempotent seed for the Northstar product catalog & price books.
//
// Anonymous Apex cannot read repo files, so the canonical JSON datasets under
// `data/*.json` are embedded inline below. Keep them in sync — the script is
// the runtime source of truth; the JSON files are the reviewable source.
//
// Upsert keys:
//   - Product2:   ProductCode (queried, Id stamped, then upserted)
//   - Pricebook2: Name (queried, Id stamped, then upserted)
//   - PricebookEntry: (Pricebook2Id, Product2Id) — existing rows get
//     UnitPrice/IsActive only (lookups are not updateable on PBE).
//
// Standard-PB entries must be inserted before any custom-PB entries on the
// same product (Salesforce platform rule).
//
// Run:
//   sf apex run --file scripts/apex/seed_product_catalog.apex \
//     --target-org "$NS_ORG"

// ---------- Embedded JSON (compact; sync with data/*.json) ----------

String PRODUCTS_JSON = '[{"ProductCode":"NS-CORE-COMM","Name":"Northstar Core Platform - Commercial","Family":"Core Platform","IsActive":true,"Description":"Core workflow automation platform, commercial edition (annual subscription)."},{"ProductCode":"NS-CORE-ENT","Name":"Northstar Core Platform - Enterprise","Family":"Core Platform","IsActive":true,"Description":"Core workflow automation platform, enterprise edition with advanced controls (annual)."},{"ProductCode":"NS-ADD-ROUTE","Name":"Route Optimization Add-On","Family":"Core Platform","IsActive":true,"Description":"Route optimization capability for logistics and field operations (annual add-on)."},{"ProductCode":"NS-ADD-MOBILE","Name":"Field Team Mobile Add-On","Family":"Core Platform","IsActive":true,"Description":"Mobile app access for distributed field teams (annual add-on)."},{"ProductCode":"NS-ADD-ANALYTICS","Name":"Analytics Insights Add-On","Family":"Analytics Add-On","IsActive":true,"Description":"Advanced analytics and reporting insights (annual add-on)."},{"ProductCode":"NS-ADD-AIDISPATCH","Name":"AI Dispatch Assistant Add-On","Family":"AI Dispatch Add-On","IsActive":true,"Description":"AI-assisted dispatch and scheduling recommendations (annual add-on)."},{"ProductCode":"NS-SUP-STD","Name":"Premium Support - Standard","Family":"Premium Support","IsActive":true,"Description":"Premium support with business-hours SLAs (annual)."},{"ProductCode":"NS-SUP-ENT","Name":"Premium Support - Enterprise","Family":"Premium Support","IsActive":true,"Description":"Premium support with 24x7 SLAs and a named TAM (annual)."},{"ProductCode":"NS-IMPL-QS","Name":"Implementation Services - Quickstart","Family":"Implementation Services","IsActive":true,"Description":"Fixed-scope quickstart onboarding engagement (one-time)."},{"ProductCode":"NS-IMPL-ENT","Name":"Implementation Services - Enterprise","Family":"Implementation Services","IsActive":true,"Description":"Enterprise implementation engagement with custom SOW (one-time)."},{"ProductCode":"NS-TRAIN-ADMIN","Name":"Admin Training Package","Family":"Training","IsActive":true,"Description":"Administrator training package (one-time)."},{"ProductCode":"NS-USAGE-BLOCK","Name":"Usage Overage Block","Family":"Usage Overage","IsActive":true,"Description":"Prepaid block of usage overage units."}]';

String PRICEBOOKS_JSON = '[{"Name":"Commercial Price Book","IsActive":true},{"Name":"Enterprise Price Book","IsActive":true},{"Name":"Partner Price Book","IsActive":true},{"Name":"Renewal Price Book","IsActive":true}]';

String ENTRIES_JSON = '[{"ProductCode":"NS-CORE-COMM","Pricebook":"Standard Price Book","UnitPrice":12000},{"ProductCode":"NS-CORE-ENT","Pricebook":"Standard Price Book","UnitPrice":36000},{"ProductCode":"NS-ADD-ROUTE","Pricebook":"Standard Price Book","UnitPrice":6000},{"ProductCode":"NS-ADD-MOBILE","Pricebook":"Standard Price Book","UnitPrice":4800},{"ProductCode":"NS-ADD-ANALYTICS","Pricebook":"Standard Price Book","UnitPrice":9000},{"ProductCode":"NS-ADD-AIDISPATCH","Pricebook":"Standard Price Book","UnitPrice":15000},{"ProductCode":"NS-SUP-STD","Pricebook":"Standard Price Book","UnitPrice":6000},{"ProductCode":"NS-SUP-ENT","Pricebook":"Standard Price Book","UnitPrice":18000},{"ProductCode":"NS-IMPL-QS","Pricebook":"Standard Price Book","UnitPrice":7500},{"ProductCode":"NS-IMPL-ENT","Pricebook":"Standard Price Book","UnitPrice":30000},{"ProductCode":"NS-TRAIN-ADMIN","Pricebook":"Standard Price Book","UnitPrice":3500},{"ProductCode":"NS-USAGE-BLOCK","Pricebook":"Standard Price Book","UnitPrice":1000},{"ProductCode":"NS-CORE-COMM","Pricebook":"Commercial Price Book","UnitPrice":12000},{"ProductCode":"NS-CORE-ENT","Pricebook":"Commercial Price Book","UnitPrice":36000},{"ProductCode":"NS-ADD-ROUTE","Pricebook":"Commercial Price Book","UnitPrice":6000},{"ProductCode":"NS-ADD-MOBILE","Pricebook":"Commercial Price Book","UnitPrice":4800},{"ProductCode":"NS-ADD-ANALYTICS","Pricebook":"Commercial Price Book","UnitPrice":9000},{"ProductCode":"NS-ADD-AIDISPATCH","Pricebook":"Commercial Price Book","UnitPrice":15000},{"ProductCode":"NS-SUP-STD","Pricebook":"Commercial Price Book","UnitPrice":6000},{"ProductCode":"NS-SUP-ENT","Pricebook":"Commercial Price Book","UnitPrice":18000},{"ProductCode":"NS-IMPL-QS","Pricebook":"Commercial Price Book","UnitPrice":7500},{"ProductCode":"NS-IMPL-ENT","Pricebook":"Commercial Price Book","UnitPrice":30000},{"ProductCode":"NS-TRAIN-ADMIN","Pricebook":"Commercial Price Book","UnitPrice":3500},{"ProductCode":"NS-USAGE-BLOCK","Pricebook":"Commercial Price Book","UnitPrice":1000},{"ProductCode":"NS-CORE-COMM","Pricebook":"Enterprise Price Book","UnitPrice":13800},{"ProductCode":"NS-CORE-ENT","Pricebook":"Enterprise Price Book","UnitPrice":41400},{"ProductCode":"NS-ADD-ROUTE","Pricebook":"Enterprise Price Book","UnitPrice":6900},{"ProductCode":"NS-ADD-MOBILE","Pricebook":"Enterprise Price Book","UnitPrice":5520},{"ProductCode":"NS-ADD-ANALYTICS","Pricebook":"Enterprise Price Book","UnitPrice":9000},{"ProductCode":"NS-ADD-AIDISPATCH","Pricebook":"Enterprise Price Book","UnitPrice":15000},{"ProductCode":"NS-SUP-STD","Pricebook":"Enterprise Price Book","UnitPrice":6000},{"ProductCode":"NS-SUP-ENT","Pricebook":"Enterprise Price Book","UnitPrice":18000},{"ProductCode":"NS-IMPL-QS","Pricebook":"Enterprise Price Book","UnitPrice":7500},{"ProductCode":"NS-IMPL-ENT","Pricebook":"Enterprise Price Book","UnitPrice":30000},{"ProductCode":"NS-TRAIN-ADMIN","Pricebook":"Enterprise Price Book","UnitPrice":3500},{"ProductCode":"NS-USAGE-BLOCK","Pricebook":"Enterprise Price Book","UnitPrice":1000},{"ProductCode":"NS-CORE-COMM","Pricebook":"Partner Price Book","UnitPrice":10800},{"ProductCode":"NS-CORE-ENT","Pricebook":"Partner Price Book","UnitPrice":32400},{"ProductCode":"NS-ADD-ROUTE","Pricebook":"Partner Price Book","UnitPrice":4800},{"ProductCode":"NS-ADD-MOBILE","Pricebook":"Partner Price Book","UnitPrice":3840},{"ProductCode":"NS-ADD-ANALYTICS","Pricebook":"Partner Price Book","UnitPrice":7200},{"ProductCode":"NS-ADD-AIDISPATCH","Pricebook":"Partner Price Book","UnitPrice":12000},{"ProductCode":"NS-SUP-STD","Pricebook":"Partner Price Book","UnitPrice":5400},{"ProductCode":"NS-SUP-ENT","Pricebook":"Partner Price Book","UnitPrice":16200},{"ProductCode":"NS-IMPL-QS","Pricebook":"Partner Price Book","UnitPrice":6750},{"ProductCode":"NS-IMPL-ENT","Pricebook":"Partner Price Book","UnitPrice":27000},{"ProductCode":"NS-TRAIN-ADMIN","Pricebook":"Partner Price Book","UnitPrice":3150},{"ProductCode":"NS-USAGE-BLOCK","Pricebook":"Partner Price Book","UnitPrice":900},{"ProductCode":"NS-CORE-COMM","Pricebook":"Renewal Price Book","UnitPrice":12600},{"ProductCode":"NS-CORE-ENT","Pricebook":"Renewal Price Book","UnitPrice":37800},{"ProductCode":"NS-ADD-ROUTE","Pricebook":"Renewal Price Book","UnitPrice":6300},{"ProductCode":"NS-ADD-MOBILE","Pricebook":"Renewal Price Book","UnitPrice":5040},{"ProductCode":"NS-ADD-ANALYTICS","Pricebook":"Renewal Price Book","UnitPrice":9450},{"ProductCode":"NS-ADD-AIDISPATCH","Pricebook":"Renewal Price Book","UnitPrice":15750},{"ProductCode":"NS-SUP-STD","Pricebook":"Renewal Price Book","UnitPrice":6300},{"ProductCode":"NS-SUP-ENT","Pricebook":"Renewal Price Book","UnitPrice":18900},{"ProductCode":"NS-IMPL-QS","Pricebook":"Renewal Price Book","UnitPrice":7875},{"ProductCode":"NS-IMPL-ENT","Pricebook":"Renewal Price Book","UnitPrice":31500},{"ProductCode":"NS-TRAIN-ADMIN","Pricebook":"Renewal Price Book","UnitPrice":3675},{"ProductCode":"NS-USAGE-BLOCK","Pricebook":"Renewal Price Book","UnitPrice":1050}]';

// ---------- Helpers ----------

List<Object> productList = (List<Object>) JSON.deserializeUntyped(PRODUCTS_JSON);
List<Object> pricebookList = (List<Object>) JSON.deserializeUntyped(PRICEBOOKS_JSON);
List<Object> entryList = (List<Object>) JSON.deserializeUntyped(ENTRIES_JSON);

// ---------- 1) Upsert Product2 by ProductCode ----------

Set<String> codes = new Set<String>();
for (Object o : productList) {
    codes.add((String) ((Map<String,Object>) o).get('ProductCode'));
}
Map<String, Product2> existingProducts = new Map<String, Product2>();
for (Product2 p : [SELECT Id, ProductCode FROM Product2 WHERE ProductCode IN :codes]) {
    existingProducts.put(p.ProductCode, p);
}

List<Product2> productsToUpsert = new List<Product2>();
for (Object o : productList) {
    Map<String,Object> m = (Map<String,Object>) o;
    String code = (String) m.get('ProductCode');
    Product2 p = existingProducts.containsKey(code) ? existingProducts.get(code) : new Product2();
    p.ProductCode = code;
    p.Name = (String) m.get('Name');
    p.Family = (String) m.get('Family');
    p.IsActive = (Boolean) m.get('IsActive');
    p.Description = (String) m.get('Description');
    productsToUpsert.add(p);
}
upsert productsToUpsert;

Map<String, Id> productIdByCode = new Map<String, Id>();
for (Product2 p : [SELECT Id, ProductCode FROM Product2 WHERE ProductCode IN :codes]) {
    productIdByCode.put(p.ProductCode, p.Id);
}

// ---------- 2) Upsert custom Pricebook2 by Name ----------

Set<String> pbNames = new Set<String>();
for (Object o : pricebookList) {
    pbNames.add((String) ((Map<String,Object>) o).get('Name'));
}
Map<String, Pricebook2> existingPbs = new Map<String, Pricebook2>();
for (Pricebook2 pb : [SELECT Id, Name FROM Pricebook2 WHERE Name IN :pbNames AND IsStandard = false]) {
    existingPbs.put(pb.Name, pb);
}

List<Pricebook2> pbsToUpsert = new List<Pricebook2>();
for (Object o : pricebookList) {
    Map<String,Object> m = (Map<String,Object>) o;
    String nm = (String) m.get('Name');
    Pricebook2 pb = existingPbs.containsKey(nm) ? existingPbs.get(nm) : new Pricebook2();
    pb.Name = nm;
    pb.IsActive = (Boolean) m.get('IsActive');
    pbsToUpsert.add(pb);
}
upsert pbsToUpsert;

// Build name -> Id including the standard PB.
Map<String, Id> pbIdByName = new Map<String, Id>();
Pricebook2 stdPb = [SELECT Id, Name FROM Pricebook2 WHERE IsStandard = true LIMIT 1];
pbIdByName.put('Standard Price Book', stdPb.Id);
for (Pricebook2 pb : [SELECT Id, Name FROM Pricebook2 WHERE Name IN :pbNames AND IsStandard = false]) {
    pbIdByName.put(pb.Name, pb.Id);
}

// ---------- 3) Upsert PricebookEntry — standard PB first, then customs ----------

Set<Id> allPbIds = new Set<Id>(pbIdByName.values());
Set<Id> allProductIds = new Set<Id>(productIdByCode.values());

// Key existing PBEs by composite "Pricebook2Id|Product2Id".
Map<String, PricebookEntry> existingPbes = new Map<String, PricebookEntry>();
for (PricebookEntry pbe : [
    SELECT Id, Pricebook2Id, Product2Id, UnitPrice, IsActive, UseStandardPrice
    FROM PricebookEntry
    WHERE Pricebook2Id IN :allPbIds AND Product2Id IN :allProductIds
]) {
    existingPbes.put(pbe.Pricebook2Id + '|' + pbe.Product2Id, pbe);
}

List<PricebookEntry> standardNew = new List<PricebookEntry>();
List<PricebookEntry> standardUpdate = new List<PricebookEntry>();
List<PricebookEntry> customNew = new List<PricebookEntry>();
List<PricebookEntry> customUpdate = new List<PricebookEntry>();

for (Object o : entryList) {
    Map<String,Object> m = (Map<String,Object>) o;
    String code = (String) m.get('ProductCode');
    String pbName = (String) m.get('Pricebook');
    Decimal price = Decimal.valueOf(String.valueOf(m.get('UnitPrice')));

    Id productId = productIdByCode.get(code);
    Id pbId = pbIdByName.get(pbName);
    if (productId == null || pbId == null) {
        System.debug('Skipping entry — missing lookup: ' + code + ' / ' + pbName);
        continue;
    }

    String key = pbId + '|' + productId;
    Boolean isStd = (pbName == 'Standard Price Book');

    if (existingPbes.containsKey(key)) {
        // Existing: only UnitPrice + IsActive are safely updateable.
        PricebookEntry pbe = existingPbes.get(key);
        pbe.UnitPrice = price;
        pbe.IsActive = true;
        (isStd ? standardUpdate : customUpdate).add(pbe);
    } else {
        PricebookEntry pbe = new PricebookEntry(
            Pricebook2Id = pbId,
            Product2Id = productId,
            UnitPrice = price,
            UseStandardPrice = false,
            IsActive = true
        );
        (isStd ? standardNew : customNew).add(pbe);
    }
}

// Pass 1: Standard PB — inserts first, then updates.
if (!standardNew.isEmpty()) insert standardNew;
if (!standardUpdate.isEmpty()) update standardUpdate;

// Pass 2: Custom PBs — inserts then updates.
if (!customNew.isEmpty()) insert customNew;
if (!customUpdate.isEmpty()) update customUpdate;

// ---------- Summary ----------

Integer productCount = [SELECT COUNT() FROM Product2 WHERE ProductCode LIKE 'NS-%'];
Integer pbCount = [SELECT COUNT() FROM Pricebook2 WHERE IsStandard = false AND Name IN :pbNames];
Integer pbeCount = [SELECT COUNT() FROM PricebookEntry WHERE Product2Id IN :allProductIds];

System.debug('=== Northstar product catalog seed summary ===');
System.debug('Products (NS-%):           ' + productCount);
System.debug('Custom price books:        ' + pbCount);
System.debug('Pricebook entries (NS-%):  ' + pbeCount);
System.debug('Standard PBE inserts:      ' + standardNew.size());
System.debug('Standard PBE updates:      ' + standardUpdate.size());
System.debug('Custom PBE inserts:        ' + customNew.size());
System.debug('Custom PBE updates:        ' + customUpdate.size());
