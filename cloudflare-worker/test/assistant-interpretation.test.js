import test from "node:test";
import assert from "node:assert/strict";
import { interpretNaturalLanguage } from "../src/nl-interpreter.js";

const input = { version: 1, localDate: "2026-09-12", timezone: "Asia/Shanghai" };
const statistics = { idol: "小爱", date_from: "2026-09-01", date_to: "2026-09-10" };

async function interpret(utterance, operation, extra = {}) {
  const request = new Request("https://example.test/api/nl/interpret", {
    method: "POST", headers: { "content-type": "application/json" },
    body: JSON.stringify({ ...input, utterance, ...extra }),
  });
  return interpretNaturalLanguage(request, { NL_LLM_API_KEY: "test-only-key" }, {
    skipRateLimit: true,
    fetchImpl: async (_url, init) => {
      const body = JSON.parse(init.body);
      assert.equal(body.model, "deepseek-flash");
      assert.deepEqual(JSON.parse(body.messages[1].content), { ...input, utterance, ...extra });
      const result = operation.kind ? operation : { version: 1, kind: "plan", operations: [operation] };
      return new Response(JSON.stringify({ choices: [{ message: { content: JSON.stringify(result) } }] }), {
        headers: { "content-type": "application/json" },
      });
    },
  });
}

async function accepts(utterance, intent, slots, extra = {}) {
  const result = await interpret(utterance, { intent, slots }, extra);
  assert.equal(result.status, 200, JSON.stringify(result.body));
  assert.deepEqual(result.body.operations, [{ intent, slots }]);
}

async function rejects(utterance, intent, slots, extra = {}, status = 422) {
  const result = await interpret(utterance, { intent, slots }, extra);
  assert.equal(result.status, status, JSON.stringify(result.body));
  assert.equal(result.body.kind, "reject");
}

test("original statistics wording emits only a validated closed date-range plan", async () => {
  await accepts("我在9月1号到9月10号切了谁多少张", "statscheki", {
    date_from: "2026-09-01", date_to: "2026-09-10",
  });
  await accepts("我切了谁多少张", "statscheki", {});
  await accepts("小爱在夏日祭切了多少张", "statscheki", { idol: "小爱", event: "夏日祭" });
});

for (const utterance of [
  "9月1日到9月10日切了多少张", "9月1號到9月10號切了多少張",
  "9月1日から9月10日までチェキを何枚撮った？",
  "How many cheki from September 1 to September 10?",
  "How many cheki from 1 September to 10 September?",
  "How many cheki from 9/1 to 9/10?",
]) {
  test(`four-language explicit dates: ${utterance}`, async () => {
    await accepts(utterance, "statscheki", { date_from: "2026-09-01", date_to: "2026-09-10" });
  });
}

for (const [utterance, from, to] of [
  ["今天", "2026-09-12", "2026-09-12"], ["昨天", "2026-09-11", "2026-09-11"],
  ["今日", "2026-09-12", "2026-09-12"], ["昨日", "2026-09-11", "2026-09-11"],
  ["today", "2026-09-12", "2026-09-12"], ["yesterday", "2026-09-11", "2026-09-11"],
  ["本月", "2026-09-01", "2026-09-30"], ["這個月", "2026-09-01", "2026-09-30"],
  ["今月", "2026-09-01", "2026-09-30"], ["this month", "2026-09-01", "2026-09-30"],
  ["上个月", "2026-08-01", "2026-08-31"], ["上個月", "2026-08-01", "2026-08-31"],
  ["先月", "2026-08-01", "2026-08-31"], ["last month", "2026-08-01", "2026-08-31"],
  ["今年", "2026-01-01", "2026-12-31"], ["this year", "2026-01-01", "2026-12-31"],
  ["去年", "2025-01-01", "2025-12-31"], ["昨年", "2025-01-01", "2025-12-31"],
  ["last year", "2025-01-01", "2025-12-31"], ["今週", "2026-09-07", "2026-09-13"],
  ["上週", "2026-08-31", "2026-09-06"], ["last week", "2026-08-31", "2026-09-06"],
]) {
  test(`deterministic relative calendar boundaries: ${utterance}`, async () => {
    await accepts(`${utterance} cheki?`, "statscheki", { date_from: from, date_to: to });
  });
}

test("relative periods handle leap years and year transitions", async () => {
  await accepts("上个月切了多少", "statscheki", { date_from: "2024-02-01", date_to: "2024-02-29" }, { localDate: "2024-03-01" });
  await accepts("last month cheki", "statscheki", { date_from: "2025-12-01", date_to: "2025-12-31" }, { localDate: "2026-01-02" });
  await accepts("yesterday cheki", "statscheki", { date_from: "2025-12-31", date_to: "2025-12-31" }, { localDate: "2026-01-01" });
});

test("statistics rejects invented, invalid, reversed, half, and guessed cross-year ranges", async () => {
  for (const slots of [
    { date_from: "2026-09-01" }, { date_to: "2026-09-10" },
    { date_from: "2026-09-10", date_to: "2026-09-01" },
    { date_from: "2026-09-01", date_to: "2026-09-11" },
    { date_from: "2026-02-29", date_to: "2026-09-10" },
    { date_from: "2026-09-01", date_to: "2026-09-10", count: 3 },
    { idol: "invented" },
  ]) await rejects("9月1号到9月10号切了多少", "statscheki", slots);
  await rejects("12月20日到1月5日切了多少", "statscheki", { date_from: "2026-12-20", date_to: "2027-01-05" });
});

test("half-range clarification retains known endpoint and continues without losing it", async () => {
  const draft = { intent: "statscheki", slots: { idol: "小爱", date_from: "2026-09-01" } };
  const result = await interpret("小爱从9月1号开始切了多少", {
    version: 1, kind: "clarify", draft, missing: ["date"],
  });
  assert.equal(result.status, 200);
  await accepts("到9月10号", "statscheki", statistics, { draft: { ...draft, missing: ["date"] } });
  await rejects("到9月10号", "statscheki", { ...statistics, date_from: "2026-09-10" }, { draft: { ...draft, missing: ["date"] } });
});

test("last-month follow-up keeps Idol and replaces the complete previous range", async () => {
  const context = { last_statistics: statistics };
  await accepts("那上个月呢", "statscheki", {
    idol: "小爱", date_from: "2026-08-01", date_to: "2026-08-31", context_ref: "last_statistics",
  }, { context });
  await rejects("那上个月呢", "statscheki", { ...statistics, context_ref: "last_statistics" }, { context });
  await rejects("那上个月呢", "statscheki", {
    date_from: "2026-08-01", date_to: "2026-08-31", context_ref: "last_statistics",
  }, { context });
});

test("changing Idol preserves previous dates and explicit all-time removes both dates", async () => {
  const context = { last_statistics: statistics };
  await accepts("那小A呢", "statscheki", { ...statistics, idol: "小A", context_ref: "last_statistics" }, { context });
  await accepts("那不限日期呢", "statscheki", { idol: "小爱", context_ref: "last_statistics" }, { context });
  await accepts("那所有偶像呢", "statscheki", { date_from: statistics.date_from, date_to: statistics.date_to, context_ref: "last_statistics" }, { context });
  await rejects("那小A呢", "statscheki", { idol: "小A", context_ref: "last_statistics" }, { context });
  await rejects("那小A呢", "statscheki", { ...statistics, idol: "小A" }, { context });
});

test("original quantity sentence adds three using record date without computing a new total", async () => {
  await accepts("9月1号我切了小A3张", "addrecord", {
    record_type: "cheki", idols: ["小A"], count: 3, date: "2026-09-01",
  });
  await rejects("9月1号我切了小A3张", "editrecord", { record_type: "cheki", target: "小A", count: 3 });
});

for (const [utterance, count] of [
  ["切了小爱三张", 3], ["切了小愛兩張", 2], ["小愛とチェキを三枚撮った", 3],
  ["Took three cheki with Alice", 3], ["切了小爱二十三张", 23],
  ["Took twenty-three cheki with Alice", 23], ["切了小爱一百张", 100],
  ["小愛とチェキを百枚撮った", 100],
]) {
  test(`count normalizes explicit quantities: ${utterance}`, async () => {
    await accepts(utterance, "addrecord", { record_type: "cheki", count });
  });
}

test("count uses only legal Cheki create/edit ranges and current quantity evidence", async () => {
  for (const count of [0, 101, -1, true, "3", 2.5, null]) {
    await rejects("小爱切了3张", "addrecord", { record_type: "cheki", count });
  }
  for (const record_type of ["shame", "douga"]) {
    await rejects("小爱切了3张", "addrecord", { record_type, count: 3 });
  }
  for (const intent of ["listrecord", "showrecord", "deleterecord"]) {
    await rejects("小爱3张", intent, { record_type: "cheki", target: "小爱", count: 3 });
  }
  await rejects("9月3日切了小爱", "addrecord", { record_type: "cheki", count: 3 });
  await rejects("切了小爱-3张", "addrecord", { record_type: "cheki", count: 3 });
  await rejects("切了小爱3.5张", "addrecord", { record_type: "cheki", count: 5 });
  await rejects("took twenty-three cheki", "addrecord", { record_type: "cheki", count: 3 });
  await accepts("把小爱数量改成0张", "editrecord", { record_type: "cheki", target: "小爱", count: 0 });
  await accepts("set Alice total to 100 cheki", "editrecord", { record_type: "cheki", target: "Alice", count: 100 });
  await rejects("把小爱数量改成101张", "editrecord", { record_type: "cheki", target: "小爱", count: 101 });
  await rejects("把小爱数量改成3张", "editrecord", { record_type: "cheki", target: "小爱", count: 3, clear_fields: ["count"] });
});

test("partial undo/remove is never converted into an entire delete or remaining total", async () => {
  for (const utterance of ["撤销小爱3张", "刪除小愛三張", "小愛のチェキを三枚削除", "remove three cheki from Alice"]) {
    const name = utterance.includes("Alice") ? "Alice" : utterance.includes("小爱") ? "小爱" : "小愛";
    await rejects(utterance, "deleterecord", { record_type: "cheki", target: name });
    await rejects(utterance, "editrecord", { record_type: "cheki", target: name, count: 3 });
    await rejects(utterance, "addrecord", { record_type: "cheki", count: 3 });
  }
});

test("explicit ordinal Cheki targets remain deletable without looking like subtraction", async () => {
  for (const [utterance, target] of [
    ["删除第3张拍立得", "第3张"], ["刪除第三張拍立得", "第三張"],
    ["3枚目を削除", "3枚目"], ["三枚目を削除", "三枚目"],
    ["delete the third cheki", "third cheki"],
  ]) await accepts(utterance, "deletecheki", { target });
});

test("complete pending draft corrections replace quantity, date or Idol without another increment", async () => {
  const slots = { record_type: "cheki", idols: ["小A"], date: "2026-09-01", count: 2 };
  const draft = { intent: "addrecord", slots, missing: [] };
  await accepts("改成3张", "addrecord", { ...slots, count: 3 }, { draft });
  await accepts("日期昨天", "addrecord", { ...slots, date: "2026-09-11" }, { draft });
  await accepts("不是小A是小B", "addrecord", { ...slots, idols: ["小B"] }, { draft });
  await rejects("日期昨天", "addrecord", { ...slots, count: 3, date: "2026-09-11" }, { draft });
  await rejects("改成3张", "addrecord", { record_type: "cheki", count: 3 }, { draft });
  await rejects("改成3张", "editrecord", { record_type: "cheki", target: "小A", count: 3 }, { draft });
  await rejects("改成3张", "addrecord", { ...slots, date: "2026-09-02", count: 3 }, { draft });
});

test("pending corrections cannot use a different draft field as evidence for a new value", async () => {
  const draft = {
    intent: "editidol", slots: { target: "小A", name: "小B", bio: "小C" }, missing: [],
  };
  await accepts("名字改成小D", "editidol", { ...draft.slots, name: "小D" }, { draft });
  await rejects("名字改一下", "editidol", { ...draft.slots, name: "小C" }, { draft });
  await rejects("名字改成小D", "editidol", { ...draft.slots, target: "小C", name: "小D" }, { draft });
});

test("complete pending contextual targets retain local binding while correcting fields", async () => {
  const context = { last_target: { kind: "idol", name: "小A" } };
  const draft = {
    intent: "addrecord", slots: { record_type: "cheki", count: 2, context_ref: "last_target" }, missing: [],
  };
  await accepts("改成3张", "addrecord", { ...draft.slots, count: 3 }, { draft, context });
  await rejects("再来3张", "addrecord", { record_type: "cheki", count: 3 }, {
    draft: { intent: "addrecord", slots: { record_type: "cheki", count: 101 }, missing: [] },
  }, 400);
});

test("last-target permits only matching entity kinds with local identity resolution", async () => {
  for (const [kind, intent, other] of [
    ["idol", "showidol", {}], ["idol", "editidol", { bio: "快乐" }], ["idol", "deleteidol", {}],
    ["event", "showevent", {}], ["event", "editevent", { note: "快乐" }], ["event", "deleteevent", {}],
    ["cheki", "showcheki", {}], ["cheki", "editcheki", { note: "快乐" }], ["cheki", "deletecheki", {}],
    ["cheki_record", "showrecord", { record_type: "cheki" }],
    ["cheki_record", "editrecord", { record_type: "cheki", note: "快乐" }],
    ["cheki_record", "deleterecord", { record_type: "cheki" }],
  ]) {
    await accepts("刚才那个，快乐", intent, { ...other, context_ref: "last_target" }, { context: { last_target: { kind } } });
  }
  await accepts("她切了多少", "statscheki", { context_ref: "last_target" }, { context: { last_target: { kind: "idol", name: "小爱" } } });
  for (const kind of ["idol", "cheki_record"]) {
    await accepts("又切了她两张", "addrecord", { record_type: "cheki", count: 2, context_ref: "last_target" }, { context: { last_target: { kind } } });
  }
});

test("context does not authorize explicit conflicting targets, write values, wrong kinds or IDs", async () => {
  const context = { last_target: { kind: "idol", name: "小爱" }, last_statistics: statistics };
  await rejects("删除小爱", "deleteidol", { target: "小爱", context_ref: "last_target" }, { context });
  await rejects("删除小美", "deleteidol", { context_ref: "last_target" }, { context });
  await rejects("删除她", "deleteevent", { context_ref: "last_target" }, { context });
  await rejects("删除她", "deleteidol", { context_ref: "last_statistics" }, { context });
  await rejects("给她修改名字", "editidol", { name: "小爱", context_ref: "last_target" }, { context });
  await rejects("再切她", "addrecord", { record_type: "cheki", count: 3, context_ref: "last_target" }, { context });
  await rejects("再切她3张", "addrecord", { record_type: "douga", count: 3, context_ref: "last_target" }, { context });
  await rejects("再切她3张", "addrecord", { record_type: "cheki", idols: ["小爱"], count: 3, context_ref: "last_target" }, { context });
  await rejects("看看她", "showidol", { context_ref: "last_target" });
  for (const invalidContext of [
    { last_target: { kind: "user" } },
    { last_target: { kind: "idol", id: "local-id" } },
    { last_target: { kind: "idol", name: "018f3dc0-1234-7000-8000-0123456789ab" } },
    { last_target: { kind: "idol", name: "/tmp/private" } },
    { last_target: { kind: "idol", name: "https://example.test" } },
    { last_target: { kind: "idol", name: "123456" } },
    { last_statistics: { count: 3 } },
    { last_statistics: { date_from: "2026-09-01" } },
    { last_statistics: { date_from: "2026-09-10", date_to: "2026-09-01" } },
    { history: [] },
  ]) await rejects("看看她", "showidol", { context_ref: "last_target" }, { context: invalidContext }, 400);
});

test("review regression: date evidence cannot shrink a requested interval to one boundary", async () => {
  for (const [utterance, day] of [
    ["9月1日到9月10日切了多少", "2026-09-01"],
    ["上个月切了多少", "2026-08-01"],
    ["last month cheki", "2026-08-31"],
  ]) {
    await rejects(utterance, "statscheki", { date_from: day, date_to: day });
    await rejects(utterance, "statscheki", {});
  }
});

test("review regression: complete replacements cannot add unrequested clears or flags", async () => {
  const idolDraft = {
    intent: "editidol", slots: { target: "小A", name: "Old", bio: "Profile" }, missing: [],
  };
  await rejects("名字改成小B", "editidol", { target: "小A", name: "小B", clear_fields: ["bio"] }, { draft: idolDraft });
  await accepts("名字改成小B并清空简介", "editidol", { target: "小A", name: "小B", clear_fields: ["bio"] }, { draft: idolDraft });
  const mediaDraft = {
    intent: "editcheki", slots: { target: "第一张", note: "old", favorite: false, size: "mini", user: "true" }, missing: [],
  };
  for (const unexpected of [{ favorite: true }, { size: "wide" }, { user: "false" }]) {
    await rejects("备注改成hello", "editcheki", { ...mediaDraft.slots, note: "hello", ...unexpected }, { draft: mediaDraft });
  }
  await accepts("备注改成hello并收藏", "editcheki", { ...mediaDraft.slots, note: "hello", favorite: true }, { draft: mediaDraft });
  await accepts("备注改成hello并设为wide", "editcheki", { ...mediaDraft.slots, note: "hello", size: "wide" }, { draft: mediaDraft });
});

test("review regression: ordinals are references and English quantities above ten are partial removals", async () => {
  for (const utterance of ["查看第3张", "3枚目を見せて", "第三張加到相冊"]) {
    await rejects(utterance, "addrecord", { record_type: "cheki", count: 3 });
  }
  for (const quantity of ["eleven", "twenty", "twenty-three", "one hundred"]) {
    await rejects(`delete ${quantity} cheki from Alice`, "deleterecord", { record_type: "cheki", target: "Alice" });
  }
});

test("review regression: explicitly negated writes cannot become mutation plans", async () => {
  await rejects("昨天我没有切小A3张", "addrecord", { record_type: "cheki", idols: ["小A"], count: 3, date: "2026-09-11" });
  await rejects("不要删除第3张", "deletecheki", { target: "第3张" });
  await rejects("不要刪除第三張", "deletecheki", { target: "第三張" });
  await rejects("don't delete the third cheki", "deletecheki", { target: "third cheki" });
  await rejects("3枚目を削除しないで", "deletecheki", { target: "3枚目" });
  await accepts("不要删除第3张", "showcheki", { target: "第3张" });
});

test("Idol context supports favorite while bound simple-record increments preserve identity", async () => {
  const idolContext = { last_target: { kind: "idol", name: "小A" } };
  await accepts("收藏她", "favoriteidol", { favorite: true, context_ref: "last_target" }, { context: idolContext });
  await accepts("取消收藏她", "favoriteidol", { favorite: false, context_ref: "last_target" }, { context: idolContext });
  await rejects("收藏她", "favoriteidol", { favorite: true, context_ref: "last_target" }, {
    context: { last_target: { kind: "event", name: "夏日祭" } },
  });
  const context = { last_target: { kind: "cheki_record" } };
  const slots = { record_type: "cheki", count: 3, context_ref: "last_target" };
  await accepts("再加她3张", "addrecord", slots, { context });
  for (const extra of [
    { note: "快乐" }, { size: "mini" }, { idx: 3 }, { favorite: true },
    { date: "2026-09-01" }, { event: "夏日祭" }, { idols: ["小A"] },
  ]) await rejects("再加她3张 快乐 mini 2026-09-01 夏日祭 小A", "addrecord", { ...slots, ...extra }, { context });
  await rejects("再加她", "addrecord", { record_type: "cheki", context_ref: "last_target" }, { context });
});

test("pending replacement preserves each previous clear unless an explicit assignment replaces it", async () => {
  const draft = {
    intent: "editidol", slots: { target: "小A", clear_fields: ["group", "bio"] }, missing: [],
  };
  await rejects("名字改成小B", "editidol", { target: "小A", name: "小B", clear_fields: ["bio"] }, { draft });
  await rejects("名字改成小B", "editidol", { target: "小A", name: "小B" }, { draft });
  await accepts("名字改成小B", "editidol", { target: "小A", name: "小B", clear_fields: ["group", "bio"] }, { draft });
  await accepts("简介改成快乐", "editidol", { target: "小A", bio: "快乐", clear_fields: ["group"] }, { draft });
  await rejects("简介改一下", "editidol", { target: "小A", bio: "快乐", clear_fields: ["group"] }, { draft });
  await rejects("简介改成快乐", "editidol", { target: "小A", bio: "快乐", clear_fields: ["avatar"] }, { draft });
  await accepts("简介改成快乐并清空头像", "editidol", { target: "小A", bio: "快乐", clear_fields: ["group", "avatar"] }, { draft });
  const singleClearDraft = { intent: "editidol", slots: { target: "小A", clear_fields: ["bio"] }, missing: [] };
  await accepts("简介改成快乐", "editidol", { target: "小A", bio: "快乐" }, { draft: singleClearDraft });
  await rejects("名字改成小B", "editidol", { target: "小A", name: "小B" }, { draft: singleClearDraft });
});

test("Event creation preserves all explicitly supplied optional metadata", async () => {
  await accepts("添加9月1日的夏日祭，上海，星光场地，票价120元，购票https://example.test/tickets，备注提前入场", "addevent", {
    name: "夏日祭", date: "2026-09-01", city: "上海", livehouse: "星光场地", price: "120元",
    ticket_url: "https://example.test/tickets", note: "提前入场",
  });
  await accepts("Create Summer Show on September 1, city Tokyo, venue Star Hall, price 2000 JPY, note early entry", "addevent", {
    name: "Summer Show", date: "2026-09-01", city: "Tokyo", livehouse: "Star Hall", price: "2000 JPY", note: "early entry",
  });
});

test("Event creation metadata requires exact typed user provenance and normal field bounds", async () => {
  const base = { name: "夏日祭", date: "2026-09-01" };
  for (const extra of [
    { city: "上海" }, { livehouse: "星光场地" }, { price: "120元" }, { note: "提前入场" },
    { ticket_url: "https://example.test/tickets" }, { city: null }, { city: 123 },
    { price: 120 }, { note: "" }, { clear_fields: ["city"] },
  ]) await rejects("添加9月1日的夏日祭", "addevent", { ...base, ...extra });
  await rejects("添加9月1日的夏日祭，城市-", "addevent", { ...base, city: "-" });
  await rejects("添加9月1日的夏日祭，购票javascript:alert(1)", "addevent", { ...base, ticket_url: "javascript:alert(1)" });
  await rejects("添加9月1日的夏日祭，购票https://user:password@example.test/ticket", "addevent", {
    ...base, ticket_url: "https://user:password@example.test/ticket",
  });
  for (const [field, length] of [["city", 201], ["livehouse", 301], ["price", 301], ["note", 501]]) {
    const value = "x".repeat(length);
    await rejects(`添加9月1日的夏日祭 ${value}`, "addevent", { ...base, [field]: value });
  }
});

test("Event creation pending and partial drafts preserve provided metadata without inventing city", async () => {
  const slots = {
    name: "夏日祭", date: "2026-09-01", city: "上海", livehouse: "星光场地", price: "120元",
    ticket_url: "https://example.test/tickets", note: "提前入场",
  };
  const draft = { intent: "addevent", slots, missing: [] };
  await accepts("日期改成昨天", "addevent", { ...slots, date: "2026-09-11" }, { draft });
  await accepts("城市改成东京", "addevent", { ...slots, city: "东京" }, { draft });
  await rejects("日期改成昨天", "addevent", { ...slots, date: "2026-09-11", city: "东京" }, { draft });
  await rejects("日期改成昨天", "addevent", { name: slots.name, date: "2026-09-11" }, { draft });
  const partialSlots = { ...slots };
  delete partialSlots.date;
  await accepts("日期是9月1日", "addevent", slots, {
    draft: { intent: "addevent", slots: partialSlots, missing: ["date"] },
  });
  const clarified = await interpret("添加上海的夏日祭", {
    version: 1, kind: "clarify", draft: { intent: "addevent", slots: { name: "夏日祭", city: "上海" } }, missing: ["date"],
  });
  assert.equal(clarified.status, 200);
  await accepts("添加9月1日的夏日祭", "addevent", { name: "夏日祭", date: "2026-09-01" });
});
