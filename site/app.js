// Driplock site: the hero vessel, the unlock-calendar bars and the simulator.
// The grant follows the contract's rules: 12,000 DRIP, monthly steps,
// a 3-month cliff, cancel window until the cliff, backup after 6 months of silence.
(function () {
  "use strict";

  var TOTAL = 12000, CLIFF = 3, END = 12, LOST_AT = 4, SILENCE = 6, SPAN = 18;
  var reduced = window.matchMedia && window.matchMedia("(prefers-reduced-motion: reduce)").matches;

  function vestedAt(month) {
    if (month < CLIFF) return 0;
    if (month >= END) return TOTAL;
    return Math.floor(month) * (TOTAL / END);
  }
  function fmt(n) { return n.toLocaleString("en-US"); }
  function $(id) { return document.getElementById(id); }

  // ---- Hero vessel ----
  var liquid = $("liquid"), drop = $("drop"), ticks = $("v-ticks");
  if (liquid) {
    var NS = "http://www.w3.org/2000/svg";
    for (var k = 1; k < 12; k++) {
      var y = 210 - (k / 12) * 200;
      var t = document.createElementNS(NS, "line");
      t.setAttribute("x1", 118); t.setAttribute("x2", 130);
      t.setAttribute("y1", y); t.setAttribute("y2", y);
      t.setAttribute("class", "v-tick");
      ticks.appendChild(t);
    }

    var level = 0, shownMonth = -1, dropStart = -1, dropTarget = 0;

    function liquidPath(top, phase) {
      var a = reduced ? 0 : 3;
      var y1 = top + Math.sin(phase) * a, y2 = top + Math.sin(phase + 2) * a;
      return "M0 " + top + " C35 " + y1 + " 70 " + y2 + " 140 " + top + " V220 H0Z";
    }

    function setMonth(m) {
      var v = vestedAt(m);
      $("hero-vested").textContent = fmt(v);
      $("hero-locked").textContent = fmt(TOTAL - v);
      $("hero-month").textContent = String(Math.min(Math.floor(m), END));
      var pill = $("hero-pill");
      if (m < CLIFF) { pill.textContent = "Before cliff"; pill.className = "pill"; }
      else if (m < END) { pill.textContent = "Unlocking monthly"; pill.className = "pill live"; }
      else { pill.textContent = "Fully unlocked"; pill.className = "pill done"; }
      return v / TOTAL;
    }

    if (reduced) {
      var f = setMonth(7);
      liquid.setAttribute("d", liquidPath(210 - f * 200, 0));
    } else {
      var start = performance.now(), CYCLE = 16000, RUN = 13000;
      var frame = function (now) {
        var tt = (now - start) % CYCLE;
        var month = Math.min(tt / RUN * END, END);
        var whole = Math.floor(month);
        var target = setMonth(month);
        if (whole !== shownMonth) {
          if (whole >= CLIFF && whole <= END && shownMonth !== -1 && whole > shownMonth) {
            dropStart = now; dropTarget = 210 - target * 200;
          }
          if (whole < shownMonth) level = 0;
          shownMonth = whole;
        }
        level += (target - level) * 0.08;
        liquid.setAttribute("d", liquidPath(210 - level * 200, now / 600));
        if (dropStart > 0) {
          var p = (now - dropStart) / 450;
          if (p >= 1) { drop.style.opacity = 0; dropStart = -1; }
          else { drop.setAttribute("cy", -10 + p * (dropTarget + 10)); drop.style.opacity = 1; }
        }
        requestAnimationFrame(frame);
      };
      requestAnimationFrame(frame);
    }
  }

  // ---- Unlock calendar bars (from a local node's Proof of Lock page) ----
  var bars = $("bars");
  if (bars) {
    var data = [1, 1, 4.75, 2, 2, 2.75, 1, 1, 1.75, 1, 1, 1.75];
    var max = Math.max.apply(null, data);
    data.forEach(function (v) {
      var b = document.createElement("div");
      b.className = "bar" + (v === max ? " peak" : "");
      b.style.height = (v / max * 100) + "%";
      if (v === max) { var l = document.createElement("span"); l.textContent = v + " GNOT"; b.appendChild(l); }
      bars.appendChild(b);
    });
  }

  // ---- Simulator ----
  var range = $("month");
  if (!range) return;
  var lost = $("lost"), marks = $("track-marks"), fill = $("track-fill");

  function mark(month, cls) {
    var i = document.createElement("i");
    i.style.left = "calc(" + (month / SPAN * 100) + "% - 1px)";
    if (cls) i.className = cls;
    marks.appendChild(i);
    return i;
  }
  for (var m = CLIFF; m <= END; m++) mark(m);
  var keyMarks = [];

  function update() {
    var month = parseFloat(range.value), v = vestedAt(month);
    fill.style.width = (month / SPAN * 100) + "%";
    $("r-month").textContent = month % 1 === 0 ? String(month) : month.toFixed(2);
    range.setAttribute("aria-valuetext", $("r-month").textContent + " months");
    $("r-vested").textContent = fmt(v) + " DRIP";
    $("r-locked").textContent = fmt(TOTAL - v) + " DRIP";
    $("r-locked").className = TOTAL - v > 0 ? "lock" : "";
    $("r-cancel").textContent = month < CLIFF ? "Yes, until month " + CLIFF : "No, the window closed at month " + CLIFF;

    keyMarks.forEach(function (n) { n.remove(); });
    keyMarks = [];
    if (lost.checked) {
      keyMarks.push(mark(LOST_AT, "key"), mark(LOST_AT + SILENCE, "key"));
    }
    var owner;
    if (!lost.checked || month < LOST_AT) owner = "The recipient";
    else if (month < LOST_AT + SILENCE) owner = "Nobody yet. The backup can claim at month " + (LOST_AT + SILENCE);
    else owner = "The backup, which took the stream over at month " + (LOST_AT + SILENCE);
    $("r-owner").textContent = owner;
  }
  range.addEventListener("input", update);
  lost.addEventListener("change", update);
  update();
})();
