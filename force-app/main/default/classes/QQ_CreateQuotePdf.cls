// Adapted from Quicker-Quotes (https://github.com/SalesforceLabs/Quicker-Quotes) @ d1c406e — BSD 3-Clause (© 2024 salesforce.com, inc.). See LICENSES/.
global with sharing class QQ_CreateQuotePdf {
  @InvocableMethod(
    label='Create PDF'
    description='Creates a Quote PDF document using the provided template'
  )
  global static void createPdf(List<RequestInput> inputs) {
    // QQ patch: validate synchronously, before enqueuing the @future, so a
    // missing template or missing QuoteDocument create access actually faults the
    // flow. A throw inside callFutureMethod runs in the async transaction after
    // the flow has already navigated to success, so the user's explicit PDF
    // request would be silently lost. (The PDF render itself stays async —
    // getContentAsPDF is a callout — so a render failure still can't fault the
    // flow; that residual is tracked as a known limitation.)
    RequestInput ri = inputs[0];
    if (ri.templateId == null) {
      throw new DmlException('A Quote Template is required to create a PDF');
    }
    if (!QuoteDocument.sObjectType.getDescribe().isCreateable()) {
      throw new DmlException(
        'User does not have access to create Quote Documents'
      );
    }
    callFutureMethod(ri.quoteId, ri.templateId);
  }

  @future(callout=true)
  public static void callFutureMethod(Id quoteId, Id templateId) {
    String quoteUrl = '/quote/quoteTemplateDataViewer.apexp?';

    quoteUrl += 'id=' + quoteId;
    quoteUrl += '&headerHeight=197&footerHeight=10';
    quoteUrl += '&summlid=' + templateId;

    PageReference pageRef = new PageReference(quoteUrl);

    QuoteDocument quoteDoc = new QuoteDocument();
    if (Test.isRunningTest()) {
      quoteDoc.Document = Blob.valueOf('Generate PDF');
    } else {
      quoteDoc.Document = pageRef.getContentAsPDF();
    }
    quoteDoc.QuoteId = quoteId;
    insert (quoteDoc);
  }

  global class RequestInput {
    @InvocableVariable(label='Quote Id' required=true)
    global Id quoteId;
    @InvocableVariable(label='Quote Template Id' required=true)
    global Id templateId;
  }
}
