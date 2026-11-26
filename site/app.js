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
  ["bars", "usp-bars"].forEach(function (id) {
    var bars = $(id);
    if (!bars) return;
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
  });

  // ---- Hero: drops fall onto the photo's splash and spread ripples ----
  // The photo (1664x928) has its splash at about 49.7% across and 70% down.
  (function rain() {
    var cv = $("rain");
    if (!cv || reduced || !cv.getContext) return;
    var ctx = cv.getContext("2d"), dpr = Math.min(window.devicePixelRatio || 1, 2);
    var W = 0, H = 0, SX = 0, SY = 0, SCALE = 1;
    function size() {
      W = cv.clientWidth; H = cv.clientHeight;
      cv.width = W * dpr; cv.height = H * dpr; ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
      if (window.matchMedia("(max-width: 680px)").matches) {
        // Phones: the photo is 52% of the hero's height, anchored to the bottom (see styles.css).
        SCALE = (H * 0.52) / 928;
        SX = W / 2 + (0.497 - 0.5) * 1664 * SCALE;
        SY = H - (1 - 0.70) * 928 * SCALE;
      } else {
        SCALE = Math.max(W / 1664, H / 928);
        SX = W / 2 + (0.497 - 0.5) * 1664 * SCALE;
        SY = H / 2 + (0.70 - 0.5) * 928 * SCALE;
      }
    }
    size(); window.addEventListener("resize", size);

    var drops = [], rings = [], nextMain = 900, nextSide = 2600, visible = true;
    document.addEventListener("visibilitychange", function () { visible = !document.hidden; });
    function fall(x, y, main) { drops.push({ x: x, y: -30, floor: y, vy: 3, main: main }); }

    function tick(now) {
      if (visible) {
        if (now > nextMain) { fall(SX, SY - 34 * SCALE, true); nextMain = now + 2600; }
        if (now > nextSide) {
          var x = W * (0.12 + Math.random() * 0.76), y = SY + (Math.random() * 0.5 - 0.1) * 120 * SCALE;
          if (Math.abs(x - SX) > 160 * SCALE) fall(x, y, false);
          nextSide = now + 1800 + Math.random() * 2400;
        }
        ctx.clearRect(0, 0, W, H);
        for (var i = drops.length - 1; i >= 0; i--) {
          var d = drops[i];
          d.vy += 0.22; d.y += d.vy;
          ctx.fillStyle = d.main ? "rgba(190, 240, 247, 0.85)" : "rgba(143, 227, 239, 0.55)";
          ctx.beginPath(); ctx.ellipse(d.x, d.y, d.main ? 3.2 : 2, d.main ? 5 : 3.4, 0, 0, Math.PI * 2); ctx.fill();
          if (d.y >= d.floor) {
            var n = d.main ? 3 : 1;
            for (var k = 0; k < n; k++) rings.push({ x: d.x, y: d.floor + (d.main ? 30 * SCALE : 0), r: 4 + k * 10, a: d.main ? 0.55 - k * 0.12 : 0.35, w: d.main ? 1.6 : 1.1 });
            drops.splice(i, 1);
          }
        }
        for (var j = rings.length - 1; j >= 0; j--) {
          var r = rings[j];
          r.r += 1.25; r.a *= 0.982;
          ctx.strokeStyle = "rgba(143, 227, 239, " + r.a.toFixed(3) + ")"; ctx.lineWidth = r.w;
          ctx.beginPath(); ctx.ellipse(r.x, r.y, r.r * 2.4, r.r * 0.5, 0, 0, Math.PI * 2); ctx.stroke();
          if (r.a < 0.02) rings.splice(j, 1);
        }
      }
      requestAnimationFrame(tick);
    }
    requestAnimationFrame(tick);
  })();

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
