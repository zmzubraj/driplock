// Driplock demo: the vessel, the unlock-calendar bars and the time slider.
// Same rules as the contract: 12,000 DRIP, monthly steps, a 3-month cliff,
// cancel only before the cliff, and a backup after 6 months of silence.
(function () {
  "use strict";

  var TOTAL = 12000, CLIFF = 3, END = 12, LOST_AT = 4, SILENCE = 6, SPAN = 18;
  var reduced = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  function $(id) { return document.getElementById(id); }
  function fmt(n) { return n.toLocaleString("en-US"); }
  function vestedAt(m) {
    if (m < CLIFF) return 0;
    if (m >= END) return TOTAL;
    return Math.floor(m) * (TOTAL / END);
  }

  // Unlock calendar bars, read from a local node's Proof of Lock page.
  var bars = $("bars");
  if (bars) {
    var data = [1, 1, 4.75, 2, 2, 2.75, 1, 1, 1.75, 1, 1, 1.75];
    var max = Math.max.apply(null, data);
    data.forEach(function (v) {
      var b = document.createElement("div");
      b.className = "bar" + (v === max ? " peak" : "");
      b.style.height = (v / max * 100) + "%";
      b.title = v + " GNOT";
      if (v === max) { var s = document.createElement("span"); s.textContent = v + " GNOT"; b.appendChild(s); }
      bars.appendChild(b);
    });
  }

  var range = $("month");
  if (!range) return;
  var lost = $("lost"), fill = $("track-fill"), marks = $("track-marks");
  var liquid = $("liquid"), drop = $("drop");

  // Vessel ticks, one per month of the schedule.
  var NS = "http://www.w3.org/2000/svg", ticks = $("v-ticks");
  for (var k = 1; k < 12; k++) {
    var y = 210 - (k / 12) * 200, t = document.createElementNS(NS, "line");
    t.setAttribute("x1", 118); t.setAttribute("x2", 130); t.setAttribute("y1", y); t.setAttribute("y2", y);
    t.setAttribute("class", "v-tick");
    ticks.appendChild(t);
  }

  function mark(month, cls) {
    var i = document.createElement("i");
    i.style.left = "calc(" + (month / SPAN * 100) + "% - 1px)";
    if (cls) i.className = cls;
    marks.appendChild(i);
    return i;
  }
  for (var m = CLIFF; m <= END; m++) mark(m);
  var keyMarks = [];

  // The liquid eases toward its target level; a drop falls when a month unlocks.
  var level = 0, target = 0, lastVested = 0, dropAt = -1, dropTo = 0;
  function surface(lv) { return 210 - lv * 200; }
  function draw(now) {
    level += (target - level) * (reduced ? 1 : 0.12);
    var top = surface(level), a = reduced ? 0 : 2.5, ph = now / 500;
    liquid.setAttribute("d", "M0 " + top + " C35 " + (top + Math.sin(ph) * a) + " 70 " + (top + Math.sin(ph + 2) * a) +
      " 140 " + top + " V220 H0Z");
    if (dropAt > 0) {
      var p = (now - dropAt) / 420;
      if (p >= 1) { drop.style.opacity = 0; dropAt = -1; }
      else { drop.setAttribute("cy", -10 + p * (dropTo + 10)); drop.style.opacity = 1; }
    }
    if (!reduced) requestAnimationFrame(draw);
  }

  function update() {
    var month = parseFloat(range.value), v = vestedAt(month);
    target = v / TOTAL;
    if (v > lastVested && !reduced) { dropAt = performance.now(); dropTo = surface(target); }
    lastVested = v;
    if (reduced) draw(0);

    fill.style.width = (month / SPAN * 100) + "%";
    var label = month % 1 === 0 ? String(month) : month.toFixed(2);
    $("r-month").textContent = label;
    range.setAttribute("aria-valuetext", label + " months");
    $("v-pct").textContent = Math.round(target * 100) + "%";
    $("r-vested").textContent = fmt(v) + " DRIP";
    $("r-locked").textContent = fmt(TOTAL - v) + " DRIP";
    $("r-locked").className = TOTAL - v > 0 ? "lock" : "";
    $("r-cancel").textContent = month < CLIFF ? "Yes, until month " + CLIFF : "No, that closed at month " + CLIFF;

    keyMarks.forEach(function (n) { n.remove(); });
    keyMarks = lost.checked ? [mark(LOST_AT, "key"), mark(LOST_AT + SILENCE, "key")] : [];
    var owner;
    if (!lost.checked || month < LOST_AT) owner = "The recipient";
    else if (month < LOST_AT + SILENCE) owner = "Nobody for now. The backup can step in at month " + (LOST_AT + SILENCE);
    else owner = "The backup, since month " + (LOST_AT + SILENCE);
    $("r-owner").textContent = owner;
  }

  range.addEventListener("input", update);
  lost.addEventListener("change", update);
  update();
  if (!reduced) requestAnimationFrame(draw);
})();
