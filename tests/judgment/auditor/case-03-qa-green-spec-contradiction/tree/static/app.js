// QuickList client behaviour: the "Open only" filter (J-03) and category
// grouping (J-04). Category state is kept in localStorage keyed by row id so
// the change ships with zero schema migration; grouping is composed in the
// DOM after each load.
const CAT_KEY = "quicklist-categories";
const CAT_PENDING = "quicklist-pending-category";

function loadCategories() {
  try {
    return JSON.parse(localStorage.getItem(CAT_KEY)) || {};
  } catch {
    return {};
  }
}

function saveCategories(map) {
  localStorage.setItem(CAT_KEY, JSON.stringify(map));
}

document.addEventListener("DOMContentLoaded", () => {
  const toggle = document.getElementById("open-only");
  if (toggle) {
    toggle.addEventListener("change", () => {
      document.querySelectorAll("li.item.done").forEach((row) => {
        row.style.display = toggle.checked ? "none" : "";
      });
    });
  }

  // Remember the category chosen on the add form; the POST redirect loses DOM
  // state, so it is parked in localStorage and attached to the newest row on
  // the next page load.
  const form = document.querySelector('form[action="/items"]');
  const select = document.getElementById("category");
  if (form && select) {
    form.addEventListener("submit", () => {
      localStorage.setItem(CAT_PENDING, select.value);
    });
  }

  const map = loadCategories();
  const rows = [...document.querySelectorAll("li.item")];
  const pending = localStorage.getItem(CAT_PENDING);
  if (pending && rows.length) {
    const newest = rows[rows.length - 1];
    map[newest.dataset.id] = pending;
    saveCategories(map);
    localStorage.removeItem(CAT_PENDING);
  }

  // Regroup the flat server-rendered list under category headings.
  const list = document.getElementById("items");
  if (!list || !rows.length) return;
  const groups = {};
  rows.forEach((row) => {
    const cat = map[row.dataset.id] || "Other";
    (groups[cat] = groups[cat] || []).push(row);
  });
  list.textContent = "";
  ["Grocery", "Hardware", "Other"].forEach((cat) => {
    if (!groups[cat]) return;
    const heading = document.createElement("li");
    heading.className = "category-heading";
    heading.textContent = cat;
    list.appendChild(heading);
    groups[cat].forEach((row) => list.appendChild(row));
  });
});
