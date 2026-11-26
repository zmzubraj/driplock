// The working dial: a 12,000 DRIP grant over 12 months, monthly steps,
// a 3-month cliff, cancelable only before the cliff, and a backup with a
// 6-month silence period. Mirrors the rules of the Driplock contract.
(function () {
  "use strict";

  var TOTAL = 12000, CLIFF = 3, END = 12, LOST_AT = 4, SILENCE = 6;
  var CX = 160, CY = 160, NS = "http://www.w3.org/2000/svg";

  var range = document.getElementById("month");
  var lost = document.getElementById("lost");
  if (!range) return;
  var out = document.getElementById("month-out");
  var hand = document.getElementById("hand");
  var vestedArc = document.getElementById("vested-arc");
  var r = {
    vested: document.getElementById("r-vested"),
    locked: document.getElementById("r-locked"),
    cancel: document.getElementById("r-cancel"),
    owner: document.getElementById("r-owner")
  };

  function point(radius, deg) {
    var a = (deg - 90) * Math.PI / 180;
    return [CX + radius * Math.cos(a), CY + radius * Math.sin(a)];
  }
  function arc(radius, from, to) {
    if (to - from >= 359.99) to = from + 359.99;
    var s = point(radius, from), e = point(radius, to);
    var large = to - from > 180 ? 1 : 0;
    return "M" + s[0] + " " + s[1] + " A" + radius + " " + radius + " 0 " + large + " 1 " + e[0] + " " + e[1];
  }
  function el(name, attrs) {
    var n = document.createElementNS(NS, name);
    for (var k in attrs) n.setAttribute(k, attrs[k]);
    return n;
  }

  // Ticks every quarter month, numerals every month.
  var ticks = document.getElementById("ticks"), nums = document.getElementById("numerals");
  for (var i = 0; i < 48; i++) {
    var major = i % 4 === 0, deg = i * 7.5;
    var p1 = point(major ? 104 : 112, deg), p2 = point(120, deg);
    ticks.appendChild(el("line", { x1: p1[0], y1: p1[1], x2: p2[0], y2: p2[1], "class": major ? "tick" : "tick minor" }));
  }
  for (var m = 1; m <= 12; m++) {
    var p = point(86, m * 30), t = el("text", { x: p[0], y: p[1] });
    t.textContent = String(m);
    nums.appendChild(t);
  }
  document.getElementById("cliff-arc").setAttribute("d", arc(132, 0, CLIFF * 30));

  function vestedAt(month) {
    if (month < CLIFF) return 0;
    if (month >= END) return TOTAL;
    return Math.floor(month) * (TOTAL / END); // whole months completed
  }
  function fmt(n) { return n.toLocaleString("en-US") + " DRIP"; }

  function update() {
    var month = parseFloat(range.value);
    var v = vestedAt(month);
    out.textContent = month % 1 === 0 ? String(month) : month.toFixed(2);
    range.setAttribute("aria-valuetext", out.textContent + " months");

    hand.style.transform = "rotate(" + (month * 30) + "deg)";
    vestedArc.setAttribute("d", v > 0 ? arc(124, 0, (v / TOTAL) * 360) : "");

    r.vested.textContent = fmt(v);
    r.locked.textContent = fmt(TOTAL - v);
    r.locked.className = TOTAL - v > 0 ? "locked" : "";

    r.cancel.textContent = month < CLIFF
      ? "Yes, until month " + CLIFF
      : "No. The window closed at month " + CLIFF;

    if (!lost.checked || month < LOST_AT) {
      r.owner.textContent = "The recipient";
    } else if (month < LOST_AT + SILENCE) {
      r.owner.textContent = "Nobody yet. The backup can claim at month " + (LOST_AT + SILENCE);
    } else {
      r.owner.textContent = "The backup, since month " + (LOST_AT + SILENCE);
    }
  }

  range.addEventListener("input", update);
  lost.addEventListener("change", update);
  update();
})();
