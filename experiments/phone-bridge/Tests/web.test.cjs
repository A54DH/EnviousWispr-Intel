"use strict";
const assert = require("node:assert/strict");
const { webcrypto } = require("node:crypto");
const { SendState, makeID } = require("../Web/app.js");
const state = new SendState();
const first = state.begin("Dictated words", "ticket-one", () => "original-id");
assert.deepEqual(first, {id:"original-id", text:"Dictated words", ticket:"ticket-one"});
// Lost receipt: a retry cannot silently change the ID, text or target.
assert.strictEqual(state.begin("Changed draft", "ticket-two", () => "new-id"), first);
state.finish();
assert.equal(state.pending, null);
assert.equal(state.begin("Next words", "ticket-two", () => "new-id").id, "new-id");
const ids = Array.from({length:100}, () => makeID(webcrypto));
assert.equal(new Set(ids).size, 100);
assert.ok(ids.every(id => /^[a-f0-9]{32}$/.test(id)));
console.log("PASS: browser send identity, retry payload preservation, reset and ID generation");
