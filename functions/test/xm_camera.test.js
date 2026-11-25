"use strict";

const assert = require("node:assert/strict");
const test = require("node:test");
const {parseXmAlarm} = require("../xm_camera");

const alarm = (change = {}) => ({
  param: JSON.stringify({
    SerialNumber: "0123456789ABCDEF",
    Channel: 0,
    AlarmID: "1234",
    AlarmEvent: "VideoMotion:1",
    AlarmTime: "2025-01-01 00:00:00",
    Status: "appEventStart",
    ...change,
  }),
});

test("normalizes documented motion and native human alarms", () => {
  const motion = parseXmAlarm(alarm());
  assert.equal(motion.serial, "0123456789abcdef");
  assert.equal(motion.type, "motion");
  assert.equal(
      parseXmAlarm(alarm({AlarmEvent: "appEventHumanDetectAlarm"})).type,
      "person",
  );
});

test("unknown and end messages do not invent detections", () => {
  assert.equal(parseXmAlarm(alarm({Status: "appEventEnd"})).type, null);
  assert.equal(
      parseXmAlarm(alarm({AlarmEvent: "VideoAnalyze"})).type,
      undefined,
  );
  assert.equal(
      parseXmAlarm(alarm({AlarmEvent: "VehicleMaybe"})).type,
      undefined,
  );
});

test("deduplicates retries while allowing reused counters", () => {
  const first = parseXmAlarm(alarm()).externalEventId;
  assert.equal(first, parseXmAlarm(alarm()).externalEventId);
  assert.notEqual(first, parseXmAlarm(alarm({
    AlarmTime: "2025-01-01 00:01:00",
  })).externalEventId);
  assert.notEqual(first, parseXmAlarm(alarm({
    AlarmEvent: "appEventHumanDetectAlarm",
  })).externalEventId);
});

test("rejects malformed, oversized and other-channel messages", () => {
  for (const input of [
    {},
    {param: "{"},
    {param: " ".repeat(16385)},
    alarm({SerialNumber: "../../other"}),
    alarm({Channel: 1}),
    alarm({AlarmID: {ownerId: "other"}}),
  ]) {
    assert.throws(() => parseXmAlarm(input));
  }
});
