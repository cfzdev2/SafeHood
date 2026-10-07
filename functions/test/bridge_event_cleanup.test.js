"use strict";

const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

test("usuwanie konta obejmuje potwierdzenia jego zdarzeń Bridge", async () => {
  const source = fs.readFileSync(
      path.join(__dirname, "..", "account_deletion.js"), "utf8",
  );
  const start = source.indexOf("async function deleteAccountTopLevelData(");
  const end = source.indexOf("\n/**", start);
  assert.ok(start >= 0 && end > start);
  const removed = [];
  const handler = vm.runInNewContext(source.slice(start, end) +
      "\ndeleteAccountTopLevelData;", {
    deleteQueryDocuments: async (_db, query) => {
      removed.push(query);
      return 1;
    },
    deleteDocumentReferences: async () => 0,
  });
  const result = await handler({collection: (name) => ({
    where: (field, operator, uid) => ({name, field, operator, uid}),
  })}, "owner-1", []);
  const receiptQuery = removed.find((query) =>
    query.name === "bridgeCameraEventReceipts");
  assert.equal(receiptQuery.uid, "owner-1");
  assert.equal(receiptQuery.field, "ownerId");
  assert.equal(receiptQuery.operator, "==");
  assert.equal(result.deletedBridgeEventReceiptCount, 1);
});
