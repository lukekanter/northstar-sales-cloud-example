import { api, track } from "lwc";
import LightningModal from "lightning/modal";
import getPricebookEntries from "@salesforce/apex/QQ_SearchPricebookEntries.getPricebookEntries";

export default class QqProductsSearchModal extends LightningModal {
  // Input
  @api pricebookId;
  @api currencyCode;

  // Output
  selectedEntries = [];

  @track pricebookData = [];

  dataLoaded = false;
  moreDataAvailable = false;

  keyword = null;
  totalCount;
  totalFilteredCount;
  offset;
  limit = 50;

  saveHandler() {
    this.close(this.selectedEntries);
  }

  // QQ patch: copy each pricebook row into a plain object carrying an
  // `isSelected` flag from the retained selection set, so the checkbox can bind
  // to it across search/browse re-renders.
  decorateSelection(records) {
    return records.map((rec) => {
      return {
        ...rec,
        isSelected: this.selectedEntries.some((e) => e.Id === rec.Id)
      };
    });
  }

  getData(offset, resultLimit, concat) {
    getPricebookEntries({
      keyword: this.keyword,
      pricebookId: this.pricebookId,
      offset: offset,
      resultLimit: resultLimit,
      currencyCode: this.currencyCode
    })
      .then((result) => {
        let count = result.count;
        this.offset = offset;
        this.totalCount = result.totalCount;
        if (count > 0) {
          // QQ patch: decorate each row with `isSelected` derived
          // selectedEntries so a product chosen in a prior search renders checked
          // when it reappears — otherwise the modal can save rows the UI shows as
          // unselected. Diverges from upstream d1c406e.
          const decorated = this.decorateSelection(result.records);
          this.pricebookData = concat
            ? this.pricebookData.concat(decorated)
            : decorated;
        } else if (!concat) {
          // QQ patch: a fresh search (not a "load more") that returns
          // zero rows must clear the prior result set, otherwise users can
          // still select stale rows. Diverges from upstream d1c406e.
          this.pricebookData = [];
        }
        this.moreDataAvailable =
          this.pricebookData.length < this.totalCount ? true : false;
        this.dataLoaded = true;
      })
      .catch((error) => {
        console.log("**QQ: Error getting modal search data: " + error.message);
      });
  }

  rowSelectionHandler(event) {
    const id = event.currentTarget.dataset.id;
    const checked = event.currentTarget.checked;
    // QQ patch: entries are stored with an uppercase `Id` (see push
    // below), so match on `element.Id` — `element.id` never matched, so
    // deselected products were still returned. Diverges from upstream d1c406e.
    const arrayIndex = this.selectedEntries.findIndex(
      (element) => element.Id == id
    );
    if (checked) {
      // Add id to selectedEntries array if not already present
      if (arrayIndex == -1) {
        const entryData = this.pricebookData.find(
          (element) => element.Id == id
        );
        this.selectedEntries.push({
          Id: id,
          Name: entryData.Name,
          ProductCode: entryData.ProductCode,
          Product2Id: entryData.Product2Id,
          UnitPrice: entryData.UnitPrice
        });
      }
    } else {
      // Remove id from arry if present
      if (arrayIndex >= 0) {
        this.selectedEntries.splice(arrayIndex, 1);
      }
    }
    // QQ patch: keep the rendered row's checkbox state in sync with the
    // selection set so it persists across re-renders.
    this.pricebookData = this.pricebookData.map((rec) => {
      return rec.Id === id ? { ...rec, isSelected: checked } : rec;
    });
  }

  entrySearchHandler(event) {
    this.keyword = event.currentTarget.value;
    this.getData(0, this.limit);
  }

  loadMoreRecords(event) {
    this.getData(this.offset + this.limit, this.limit, true);
  }

  connectedCallback() {
    this.getData(0, this.limit, false);
  }
}
