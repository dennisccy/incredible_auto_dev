// QuickList client behaviour: the "Open only" filter (J-03).
document.addEventListener("DOMContentLoaded", () => {
  const toggle = document.getElementById("open-only");
  if (!toggle) return;
  toggle.addEventListener("change", () => {
    document.querySelectorAll("li.item.done").forEach((row) => {
      row.style.display = toggle.checked ? "none" : "";
    });
  });
});
